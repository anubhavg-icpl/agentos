# VM test of the OpenClaw integration.
#
#   nix build .#checks.x86_64-linux.openclaw
#
# Boots a VM with the runtime, model gateway, orchestrator and OpenClaw (the
# real package, with a Telegram channel configured so that its schema is
# exercised too; no chat traffic is generated). Checks:
#
#   the service listens on loopback only, its config is a copy (not a link)
#   that passes `openclaw config validate`, and holds no secret
#   -> the gateway registration: the generated agent token reaches a mock LLM
#   through the Nestlo model gateway, with the real key injected and the
#   daily budget enforced; a wrong token is refused
#   -> `nestlo-task-chat` submits to the orchestrator through the bridge: only
#   allowlisted agents and workspaces, a fixed budget, no field it was not
#   given, no view of other people's tasks, a cap on active tasks
#   -> OpenClaw itself has no access to the orchestrator or admin sockets
#
# What it does not cover: the model deciding to call the skill (needs a real
# model) and the Telegram/Slack network protocols.
{ pkgs, nestloModules }:

let
  # Mock of the Anthropic Messages API: $2 per request at claude-sonnet-5-5
  # prices, and a log of what reached it
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json

    LOG = "/var/lib/mock-llm/requests.jsonl"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path,
                                    "key": self.headers.get("x-api-key"),
                                    "model": body.get("model")}) + "\n")
            data = json.dumps({
                "id": "msg_test", "type": "message",
                "model": body.get("model", "claude-sonnet-5-5"),
                "content": [{"type": "text", "text": "ok"}],
                "usage": {"input_tokens": 1000000, "output_tokens": 0},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
  '';

  # A headless "coding agent" for the tasks OpenClaw submits
  fakeTaskAgent = pkgs.writeShellApplication {
    name = "fake-task-agent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      prompt="$1"
      echo "user=$(id -un) task=$NESTLO_TASK_ID"
      echo "prompt=[$prompt]"
      case "$prompt" in
        *SLEEP*) sleep 600 ;;
      esac
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "nestlo-openclaw";
  globalTimeout = 3600;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "admin" ];
        agents.fake = "fake-task-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      orchestration = {
        enable = true;
        taskCommands.fake = [ "fake-task-agent" "{prompt}" ];
      };
      openclaw = {
        enable = true;
        acceptPromptInjectionRisk = true;
        budgetUsd = 5;
        agents = [ "fake" ];
        workspaces = [ "proj" ];
        channels.telegram = {
          enable = true;
          tokenFile = "/etc/nestlo-test/telegram.token";
          allowFrom = [ "123456789" ];
        };
      };
    };

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };
    environment.etc."nestlo-test/telegram.token" = {
      text = "123456:test-telegram-token";
      mode = "0400";
    };

    environment.systemPackages = [ fakeTaskAgent pkgs.jq ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-model-gateway.service" ];
      serviceConfig = {
        ExecStart = "${mockLlm}/bin/mock-llm";
        StateDirectory = "mock-llm";
      };
    };
  };

  testScript = ''
    import json
    import shlex

    STATE = "/var/lib/openclaw"
    BRIDGE = "/run/nestlo-openclaw/bridge.sock"

    def admin(cmd):
        return machine.succeed(f"su - admin -c {shlex.quote(cmd)}")

    def as_openclaw(cmd):
        return f"runuser -u openclaw -- {cmd}"

    def chat(*args):
        return as_openclaw("nestlo-task-chat " + " ".join(shlex.quote(a) for a in args))

    def task_status(task_id):
        return machine.succeed(chat("status", task_id))

    def wait_status(task_id, status, timeout=240):
        machine.wait_until_succeeds(chat("status", task_id) + f" | grep -q 'status:    {status}'", timeout=timeout)

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-nestlo.service", "mock-llm.service", "nestlo-model-gateway.service",
                 "nestlo-daemon.service", "nestlo-orchestrator.service",
                 "nestlo-openclaw-bridge.service", "openclaw.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)
    machine.wait_for_open_port(18789)
    machine.wait_until_succeeds("test -S /run/nestlo-openclaw/bridge.sock")
    for name in ["proj", "other"]:
        admin(f"nestlo workspace create {name}")

    with subtest("the gateway listens on loopback only"):
        listeners = machine.succeed("ss -Hltn 'sport = :18789'").splitlines()
        print(listeners)
        assert listeners, "nothing listens on 18789"
        for line in listeners:
            local = line.split()[3]
            assert local.startswith("127.0.0.1:") or local.startswith("[::1]:"), listeners
        for addr in machine.succeed("ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1").split():
            machine.fail(f"curl -sS -m 3 -o /dev/null http://{addr}:18789/")
        machine.succeed("curl -sS -m 5 -o /dev/null http://127.0.0.1:18789/")

    with subtest("the config is a validated copy that holds no secret"):
        conf = f"{STATE}/.openclaw/openclaw.json"
        machine.succeed(f"test -f {conf} && test ! -L {conf}")
        assert machine.succeed(f"stat -c '%U %a' {conf}").strip() == "openclaw 600"
        cfg = json.loads(machine.succeed(f"cat {conf}"))
        assert cfg["gateway"]["bind"] == "loopback" and cfg["gateway"]["auth"]["mode"] == "token", cfg
        assert cfg["channels"]["telegram"]["dmPolicy"] == "allowlist", cfg
        assert cfg["channels"]["telegram"]["allowFrom"] == ["123456789"], cfg
        assert "botToken" not in cfg["channels"]["telegram"], cfg
        for token_file in ["nestlo-token", "gateway-token"]:
            token = machine.succeed(f"cat {STATE}/{token_file}").strip()
            assert len(token) == 64, token
            assert token not in json.dumps(cfg)
            machine.fail(f"systemctl cat openclaw.service | grep -q {token}")
            assert machine.succeed(f"stat -c '%U %a' {STATE}/{token_file}").strip() == "openclaw 400"
        machine.fail("systemctl cat openclaw.service | grep -q 123456:test-telegram-token")
        machine.succeed("nestlo-openclaw config validate")
        print(machine.execute("nestlo-openclaw doctor --non-interactive 2>&1 | tail -40")[1])

    with subtest("the service is sandboxed"):
        show = dict(
            line.split("=", 1)
            for line in machine.succeed(
                "systemctl show openclaw.service -p NoNewPrivileges -p ProtectSystem -p ProtectHome "
                "-p PrivateTmp -p PrivateDevices -p CapabilityBoundingSet -p MemoryMax -p User"
            ).splitlines()
        )
        print(show)
        assert show["NoNewPrivileges"] == "yes" and show["ProtectSystem"] == "strict", show
        assert show["ProtectHome"] == "yes" and show["PrivateTmp"] == "yes" and show["PrivateDevices"] == "yes", show
        assert show["User"] == "openclaw" and show["CapabilityBoundingSet"] == "", show
        assert show["MemoryMax"] != "infinity", show
        machine.fail("runuser -u openclaw -- touch /etc/openclaw-escape")
        assert "Seccomp:\t2" in machine.succeed("grep Seccomp: /proc/$(systemctl show -p MainPID --value openclaw.service)/status")

    with subtest("the gateway registration: the openclaw token reaches the LLM through the Nestlo gateway"):
        token = machine.succeed(f"cat {STATE}/nestlo-token").strip()
        base = f"http://127.0.0.1:8080/agent/openclaw:{token}/anthropic"
        assert cfg["models"]["providers"]["nestlo"]["baseUrl"] == (
            "http://127.0.0.1:8080/agent/openclaw:" + "$" + "{NESTLO_OPENCLAW_TOKEN}/anthropic"), cfg["models"]
        body = '{"model": "claude-sonnet-5-5", "max_tokens": 16, "messages": []}'

        def call(url):
            return machine.succeed(
                "curl -s -o /dev/null -w '%{http_code}' -H 'x-api-key: nestlo-managed' "
                f"-H 'content-type: application/json' -d {shlex.quote(body)} {url}/v1/messages"
            ).strip()

        assert call(base) == "200"
        assert call("http://127.0.0.1:8080/agent/openclaw:wrong-token/anthropic") == "401"
        assert call("http://127.0.0.1:8080/agent/openclaw/anthropic") == "401"
        seen = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/requests.jsonl").splitlines()]
        assert seen and seen[-1]["key"] == "sk-test-real-key" and seen[-1]["path"] == "/v1/messages", seen
        budget = json.loads(admin("nestlo budget status --json"))
        assert budget["agents"]["openclaw"]["limit_usd"] == 5.0, budget
        assert abs(budget["agents"]["openclaw"]["usd"] - 2.0) < 1e-6, budget
        # $2 per request against a $5 daily budget: the fourth is refused
        codes = [call(base) for _ in range(3)]
        print(codes)
        assert codes == ["200", "200", "402"], codes

    with subtest("exec is limited to the task wrapper and the skill is read-only"):
        approvals = json.loads(machine.succeed(f"cat {STATE}/.openclaw/exec-approvals.json"))
        main = approvals["agents"]["main"]
        assert main["security"] == "allowlist" and main["askFallback"] == "deny", approvals
        patterns = [e["pattern"] for e in main["allowlist"]]
        assert len(patterns) == 1 and patterns[0].endswith("/bin/nestlo-task-chat"), patterns
        machine.succeed(f"test -x {patterns[0]}")
        assert cfg["tools"]["exec"]["security"] == "allowlist" and cfg["tools"]["exec"]["ask"] == "off", cfg["tools"]
        skill = f"{STATE}/workspace/skills/nestlo/SKILL.md"
        assert machine.succeed(f"stat -c '%U %a' {skill}").strip() == "root 444"
        machine.succeed(f"grep -q nestlo-task-chat {skill}")
        machine.fail(f"runuser -u openclaw -- sh -c 'echo x >> {skill}'")
        machine.fail(f"runuser -u openclaw -- rm -rf {STATE}/workspace/skills")

    with subtest("OpenClaw cannot reach the orchestrator or the gateway admin socket"):
        assert "nestlo" not in machine.succeed("id -nG openclaw").split()
        machine.fail(as_openclaw("curl -sS -m 5 --unix-socket /run/nestlo-orchestrator/orchestrator.sock http://x/tasks"))
        machine.fail(as_openclaw("curl -sS -m 5 --unix-socket /run/nestlo-gateway/admin.sock http://x/_nestlo/health"))

    with subtest("nestlo-task-chat submits a task through the bridge"):
        out = machine.succeed(chat("submit", "--agent", "fake", "--workspace", "proj", "--prompt", "hello from chat"))
        print(out)
        task_id = out.split()[1]
        wait_status(task_id, "succeeded")
        shown = task_status(task_id)
        assert "prompt=[hello from chat]" in shown and "untrusted" in shown, shown
        task = json.loads(admin(f"nestlo-task show {task_id} --json"))
        assert task["origin"] == "openclaw" and task["agent"] == "fake", task
        assert task["workspace"].endswith("/workspaces/proj") and task["budget_usd"] == 2, task
        assert task["timeout_sec"] == 1800 and not task.get("depends_on") and not task.get("group"), task
        assert task_id in machine.succeed(chat("list"))

    with subtest("the bridge enforces the policy, not the wrapper"):
        for args in [["--agent", "fake", "--workspace", "other", "--prompt", "x"],
                     ["--agent", "fake", "--workspace", "../../etc", "--prompt", "x"],
                     ["--agent", "fake", "--workspace", "/etc", "--prompt", "x"],
                     ["--agent", "claude", "--workspace", "proj", "--prompt", "x"],
                     ["--agent", "fake", "--workspace", "proj", "--prompt", "--dangerous"],
                     ["--agent", "fake", "--workspace", "proj", "--prompt", "x", "--budget", "100"],
                     ["--agent", "fake", "--workspace", "proj", "--prompt", "x", "--swarm", "9"]]:
            machine.fail(chat("submit", *args))
        for payload in ['{"agent":"fake","workspace":"proj","prompt":"x","budget_usd":999}',
                        '{"agent":"fake","workspace":"proj","prompt":"x","origin":"schedule:x"}',
                        '{"agent":"fake","workspace":"proj","prompt":"x","swarm":50}',
                        '{"agent":"fake","workspace":"other","prompt":"x"}']:
            code = machine.succeed(as_openclaw(
                f"curl -s -o /dev/null -w '%{{http_code}}' --unix-socket {BRIDGE} -X POST "
                f"-d {shlex.quote(payload)} http://bridge/tasks")).strip()
            assert code in ("400", "403"), (payload, code)
        # nothing but the four endpoints
        for method, path in [("GET", "/groups/x"), ("POST", "/tasks/x/start"), ("DELETE", "/tasks/x")]:
            code = machine.succeed(as_openclaw(
                f"curl -s -o /dev/null -w '%{{http_code}}' --unix-socket {BRIDGE} -X {method} http://bridge{path}")).strip()
            assert code in ("404", "405"), (method, path, code)
        # the bridge cannot see the gateway's admin socket
        pid = machine.succeed("systemctl show -p MainPID --value nestlo-openclaw-bridge.service").strip()
        machine.fail(f"nsenter -t {pid} -m -- ls /run/nestlo-gateway/admin.sock")

    with subtest("tasks of other submitters are invisible; active tasks are capped"):
        other = admin("nestlo-task submit --agent fake --workspace proj --prompt 'operator task' 2>/dev/null").split()[0]
        machine.fail(chat("status", other))
        machine.fail(chat("cancel", other))
        assert other not in machine.succeed(chat("list"))
        # the cap is 3 active tasks
        ids = []
        for i in range(3):
            ids.append(machine.succeed(chat("submit", "--agent", "fake", "--workspace", "proj",
                                            "--prompt", f"SLEEP {i}")).split()[1])
        out = machine.execute(chat("submit", "--agent", "fake", "--workspace", "proj", "--prompt", "one too many") + " 2>&1")[1]
        assert "already queued or running" in out, out
        for i in ids:
            machine.succeed(chat("cancel", i))
        for i in ids:
            wait_status(i, "cancelled")
        # the operator's own task was never touched
        assert json.loads(admin(f"nestlo-task show {other} --json"))["status"] != "cancelled"
        machine.execute(f"su - admin -c 'nestlo-task cancel {other}'")
  '';
}
