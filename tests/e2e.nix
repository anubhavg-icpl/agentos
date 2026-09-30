# End-to-end test of the AgentOS agent service layer.
#
#   nix build .#checks.x86_64-linux.e2e
#
# Boots a VM with the runtime, gateway, budget, circuit-breaker,
# notification and security modules, points the Anthropic provider at a mock
# API, and drives a fake agent through `agentos spawn`:
#
#   spawn (sandboxed, agentos-agent user) -> model gateway (key injection,
#   pricing) -> budget exceeded -> daemon stops the agent -> webhook
#
# plus checks on the sandbox, the control-plane isolation and the egress
# firewall.
{ pkgs, agentosModules }:

let
  # Mock of the Anthropic Messages API (+ a webhook sink)
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json

    LOG = "/var/lib/mock-llm/requests.jsonl"
    HOOKS = "/var/lib/mock-llm/hooks.jsonl"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/hook":
                with open(HOOKS, "a") as f:
                    f.write(json.dumps(body) + "\n")
                return self.reply({"ok": True})
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path,
                                    "key": self.headers.get("x-api-key"),
                                    "model": body.get("model")}) + "\n")
            # 1M input tokens: $2 at claude-sonnet-5-5 prices
            self.reply({"id": "msg_test", "type": "message",
                        "model": body.get("model", "claude-sonnet-5-5"),
                        "content": [{"type": "text", "text": "ok"}],
                        "usage": {"input_tokens": 1000000, "output_tokens": 0}})

        def reply(self, obj):
            data = json.dumps(obj).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
  '';

  # Behaves like a coding agent: uses ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY,
  # writes into its workspace, then keeps working until it is stopped.
  fakeAgent = pkgs.writeShellApplication {
    name = "fake-agent";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      id -un > whoami.txt
      echo "$ANTHROPIC_API_KEY" > key-seen.txt
      echo "$ANTHROPIC_BASE_URL" > base-url.txt
      echo "written by the agent" > notes.txt
      if touch /var/lib/agentos/escape 2>/dev/null; then echo yes; else echo no; fi > escaped.txt
      if curl -s -m 5 --unix-socket /run/redis-agentos/redis.sock http://x/ >/dev/null 2>&1; then echo yes; else echo no; fi > redis.txt
      for i in $(seq 1 "''${1:-3}"); do
        code=$(curl -s -o /dev/null -w '%{http_code}' \
          -H "x-api-key: $ANTHROPIC_API_KEY" -H 'content-type: application/json' \
          -d '{"model": "claude-sonnet-5-5", "max_tokens": 16, "messages": []}' \
          "$ANTHROPIC_BASE_URL/v1/messages")
        echo "$i $code" >> requests.txt
        sleep 2
      done
      sleep 600
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "agentos-e2e";
  globalTimeout = 3600;

  nodes.machine = { lib, ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    agentos = {
      runtime = {
        enable = true;
        agents.fake = "fake-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/agentos-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      budget-controller.enable = true;
      circuit-breaker.enable = true;
      notifications = {
        enable = true;
        webhookUrl = "http://127.0.0.1:9999/hook";
        notifyOn = [ "budget-threshold" "agent-error" ];
      };
      security = {
        enable = true;
        defaultEgress = "deny";
        # api.anthropic.com is what real deployments restrict to the gateway
        gatewayOnlyDomains = [ "api.anthropic.com" ];
      };
    };

    environment.etc."agentos-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "agentos";
    };

    environment.systemPackages = [ fakeAgent pkgs.redis pkgs.ipset ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "agentos-model-gateway.service" ];
      serviceConfig = {
        ExecStart = "${mockLlm}/bin/mock-llm";
        StateDirectory = "mock-llm";
      };
    };
  };

  testScript = ''
    import json

    def admin(cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def fail_as_admin(cmd):
        return machine.fail(f"su - admin -c {json.dumps(cmd)}")

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-model-gateway.service",
                 "agentos-daemon.service", "mock-llm.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)
    machine.wait_for_open_port(9950)

    with subtest("gateway health reports the managed key"):
        health = json.loads(machine.succeed("curl -fsS http://127.0.0.1:8080/_agentos/health"))
        assert health["providers"]["anthropic"]["managed_key"], health

    with subtest("workspace creation"):
        admin("agentos workspace create demo")
        machine.succeed("test -d /var/lib/agentos/workspaces/demo/.git")

    with subtest("spawn a sandboxed agent with a $3 budget"):
        machine.succeed(
            "setsid -f su - admin -c "
            "'cd /var/lib/agentos/workspaces/demo && agentos spawn fake --budget 3 -- 5' "
            ">/tmp/spawn.log 2>&1 </dev/null"
        )
        machine.wait_until_succeeds("ls /var/lib/agentos/state/fake-*.json", timeout=60)
        agent_id = machine.succeed("basename /var/lib/agentos/state/fake-*.json .json").strip()
        print("agent id:", agent_id)

    with subtest("budget exceeded -> daemon stops the agent"):
        machine.wait_until_succeeds(f"test -f /var/lib/agentos/state/history/{agent_id}.json", timeout=180)
        state = json.loads(machine.succeed(f"cat /var/lib/agentos/state/history/{agent_id}.json"))
        print(state)
        assert state["status"] == "killed", state
        assert "budget" in state["reason"], state
        machine.fail(f"systemctl is-active agentos-agent-{agent_id}.service")
        requests = machine.succeed("cat /var/lib/agentos/workspaces/demo/requests.txt").split("\n")
        codes = [line.split()[1] for line in requests if line.strip()]
        print("request codes:", codes)
        assert codes[:2] == ["200", "200"], codes
        assert all(c == "402" for c in codes[2:]), codes

    with subtest("spend was priced and recorded"):
        budget = json.loads(admin("agentos budget status --json"))
        spent = budget["agents"][agent_id]["usd"]
        assert abs(spent - 4.0) < 1e-6, budget
        assert budget["agents"][agent_id]["limit_usd"] == 3.0, budget
        # further requests with the agent's credentials are refused before
        # reaching the provider
        base = machine.succeed("cat /var/lib/agentos/workspaces/demo/base-url.txt").strip()
        assert base.startswith(f"http://127.0.0.1:8080/agent/{agent_id}:"), base
        code = machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' -H 'content-type: application/json' "
            f"-d '{{}}' {base}/v1/messages"
        )
        assert code == "402", code
        # without the token (or with a made-up id) the gateway does not serve
        # the request at all, so budgets cannot be sidestepped
        for path in [f"/agent/{agent_id}/anthropic/v1/messages",
                     "/agent/fresh-id/anthropic/v1/messages",
                     "/anthropic/v1/messages"]:
            code = machine.succeed(
                f"curl -s -o /dev/null -w '%{{http_code}}' -H 'content-type: application/json' "
                f"-d '{{}}' http://127.0.0.1:8080{path}"
            )
            assert code in ("401", "403"), (path, code)

    with subtest("agent ran sandboxed as agentos-agent with a managed key"):
        ws = "/var/lib/agentos/workspaces/demo"
        assert machine.succeed(f"cat {ws}/whoami.txt").strip() == "agentos-agent"
        assert machine.succeed(f"cat {ws}/key-seen.txt").strip() == "agentos-managed"
        assert machine.succeed(f"cat {ws}/escaped.txt").strip() == "no"
        assert machine.succeed(f"cat {ws}/redis.txt").strip() == "no"
        machine.fail("test -e /var/lib/agentos/escape")
        # the provider saw the real key, never the placeholder
        seen = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/requests.jsonl").splitlines()]
        assert seen and all(r["key"] == "sk-test-real-key" for r in seen), seen
        # the operator can edit what the agent wrote, and the agent's branch exists
        admin(f"echo 'reviewed' >> {ws}/notes.txt")
        admin(f"git -C {ws} rev-parse --verify agent/{agent_id}")
        assert admin(f"git -C {ws} branch --show-current").strip() == f"agent/{agent_id}"

    with subtest("CLI views"):
        out = admin("agentos list")
        print(out)
        assert agent_id in out and "killed" in out
        logs = admin(f"agentos logs {agent_id}")
        print(logs)
        assert "claude-sonnet-5-5" in logs and "402" in logs
        print(admin("agentos status"))

    with subtest("metrics"):
        metrics = machine.succeed("curl -fsS http://127.0.0.1:9950/metrics")
        assert f'agentos_agent_spend_usd_today{{agent="{agent_id}"}} 4.0' in metrics, metrics
        assert "agentos_agents_running 0" in metrics, metrics

    with subtest("notifications reached the webhook"):
        machine.wait_until_succeeds("grep -q agent_killed /var/lib/mock-llm/hooks.jsonl", timeout=30)
        hooks = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/hooks.jsonl").splitlines()]
        kinds = {h["type"] for h in hooks}
        assert {"budget_exceeded", "agent_killed", "budget_threshold"} <= kinds, kinds

    with subtest("control plane is closed to the agent user"):
        machine.fail("su -s /bin/sh agentos-agent -c 'sudo -n true'")
        machine.fail("su -s /bin/sh agentos-agent -c 'redis-cli -s /run/redis-agentos/redis.sock ping'")
        machine.fail("su -s /bin/sh agentos-agent -c "
                     "'curl -fsS --unix-socket /run/agentos-gateway/admin.sock -X PUT "
                     "-d {\"daily_usd\":999} http://x/_agentos/budget/me'")
        # budget changes over TCP are refused
        code = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X PUT -d '{\"daily_usd\": 999}' "
            "http://127.0.0.1:8080/_agentos/budget/anyone"
        )
        assert code == "403", code
        # the operator can
        assert "$7" in admin("agentos budget set someone 7")

    with subtest("egress allowlist"):
        machine.fail("getent hosts example.com")
        rules = machine.succeed("iptables -S agentos-egress")
        print(rules)
        assert "--uid-owner" in rules and "agentos-llm" in rules and "REJECT" in rules
        machine.succeed("ipset list agentos-llm")
        machine.succeed("ipset list agentos-egress")

    with subtest("unknown agents and workspaces outside the root are refused"):
        fail_as_admin("agentos spawn nosuchagent")
        fail_as_admin("mkdir -p ~/elsewhere && cd ~/elsewhere && agentos spawn fake")
  '';
}
