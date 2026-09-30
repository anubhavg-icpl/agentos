# VM test of the model gateway features beyond proxying and budgets:
#
#   nix build .#checks.x86_64-linux.gateway-features
#
# Uses the same module setup and mock LLM as tests/e2e.nix and drives the
# gateway with curl:
#
#   loop detection   the same request repeated K times is refused with 429
#   model routing    a rewrite rule changes the model the provider receives
#   replay           a recorded session is served again without the provider
#   message bus      two agents exchange messages (direct and long-poll)
{ pkgs, agentosModules }:

let
  # Mock of the Anthropic Messages API (+ a webhook sink). Every reply
  # carries a running number so replayed responses can be told from new ones.
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json

    LOG = "/var/lib/mock-llm/requests.jsonl"
    HOOKS = "/var/lib/mock-llm/hooks.jsonl"


    def count():
        try:
            with open(LOG) as f:
                return len(f.read().splitlines())
        except OSError:
            return 0


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            if self.path == "/hook":
                with open(HOOKS, "a") as f:
                    f.write(json.dumps(body) + "\n")
                return self.reply({"ok": True})
            seq = count() + 1
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path,
                                    "model": body.get("model"),
                                    "seq": seq}) + "\n")
            self.reply({"id": "msg_%d" % seq, "type": "message",
                        "model": body.get("model", "claude-sonnet-5-5"),
                        "content": [{"type": "text", "text": "reply-%d" % seq}],
                        "usage": {"input_tokens": 1000, "output_tokens": 10}})

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
in
pkgs.testers.runNixOSTest {
  name = "agentos-gateway-features";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    agentos = {
      runtime.enable = true;
      networking = {
        enable = true;
        recordSessions = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/agentos-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      budget-controller = {
        enable = true;
        routing.rewrites."claude-opus-5-5" = "claude-sonnet-5-5";
      };
      circuit-breaker = {
        enable = true;
        loopRepeatThreshold = 3;
      };
      notifications = {
        enable = true;
        webhookUrl = "http://127.0.0.1:9999/hook";
        notifyOn = [ "agent-error" ];
      };
    };

    environment.etc."agentos-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "agentos";
    };

    environment.systemPackages = [ pkgs.jq ];

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

    GW = "http://127.0.0.1:8080"

    def admin(cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def post(agent, path, body):
        """POST JSON as an agent; returns (status, parsed body)."""
        out = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' -H 'content-type: application/json' "
            f"-H 'x-api-key: agentos-managed' -d {json.dumps(json.dumps(body))} {GW}/agent/{agent}/{path}"
        )
        text, code = out.rsplit("\n", 1)
        return int(code), json.loads(text)

    def get(agent, path):
        return json.loads(machine.succeed(f"curl -fsS '{GW}/agent/{agent}/{path}'"))

    def upstream_requests():
        raw = machine.succeed("cat /var/lib/mock-llm/requests.jsonl 2>/dev/null || true")
        return [json.loads(l) for l in raw.splitlines()]

    def message(text, model="claude-sonnet-5-5"):
        return {"model": model, "max_tokens": 16, "messages": [{"role": "user", "content": text}]}

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-model-gateway.service",
                 "agentos-daemon.service", "mock-llm.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)

    with subtest("loop detection: the third identical request is refused"):
        stuck = message("fix the failing build")
        codes = [post("looper", "anthropic/v1/messages", stuck)[0] for _ in range(4)]
        print("loop codes:", codes)
        assert codes == [200, 200, 429, 429], codes
        status, err = post("looper", "anthropic/v1/messages", stuck)
        assert err["error"]["type"] == "loop_detected", err
        # an operator can clear the loop state; other agents were never affected
        admin("curl -fsS --unix-socket /run/agentos-gateway/admin.sock -X DELETE "
              "http://localhost/_agentos/loop/looper")
        assert post("looper", "anthropic/v1/messages", stuck)[0] == 200
        assert post("looper", "anthropic/v1/messages", message("something new"))[0] == 200
        assert post("bystander", "anthropic/v1/messages", stuck)[0] == 200
        # refused requests never reached the provider: 2 + 3
        assert len(upstream_requests()) == 5, upstream_requests()
        # the daemon forwards the event as an agent-error notification
        machine.wait_until_succeeds("grep -q loop_detected /var/lib/mock-llm/hooks.jsonl", timeout=30)
        hooks = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/hooks.jsonl").splitlines()]
        assert any(h["type"] == "loop_detected" and h["agent"] == "looper" for h in hooks), hooks

    with subtest("routing: the provider receives the rewritten model"):
        before = len(upstream_requests())
        status, resp = post("router1", "anthropic/v1/messages", message("hello", model="claude-opus-5-5"))
        assert status == 200
        seen = upstream_requests()[before:]
        assert [r["model"] for r in seen] == ["claude-sonnet-5-5"], seen
        logs = machine.succeed("cat /var/lib/agentos/logs/router1.log")
        entry = json.loads(logs.splitlines()[-1])
        assert entry["original_model"] == "claude-opus-5-5", entry
        assert entry["routed_model"] == "claude-sonnet-5-5", entry
        # priced with the routed model
        snap = json.loads(admin("agentos budget status --json"))
        assert "claude-sonnet-5-5" in snap["models"] and "claude-opus-5-5" not in snap["models"], snap
        view = json.loads(admin("agentos budget routing router1 anthropic claude-opus-5-5"))
        assert view["effective"]["routed_model"] == "claude-sonnet-5-5", view

    with subtest("replay: a recorded session is served without the provider"):
        first = message("write a test")
        second = message("now make it pass")
        originals = [post("rec1", "anthropic/v1/messages", b)[1]["content"][0]["text"] for b in (first, second)]
        assert originals[0] != originals[1], originals
        machine.succeed("test -f /var/lib/agentos/recordings/rec1/000001.json")
        machine.succeed("test -f /var/lib/agentos/recordings/rec1/000002.json")
        assert "rec1" in admin("agentos-replay list")
        assert "/v1/messages" in admin("agentos-replay show rec1")
        out = admin("agentos-replay start rec1 play1")
        print(out)
        assert "ANTHROPIC_BASE_URL=http://127.0.0.1:8080/agent/play1/anthropic" in out, out

        upstream_before = len(upstream_requests())
        # a request that differs from the recording is reported, not forwarded
        status, err = post("play1", "anthropic/v1/messages", message("something else"))
        assert status == 409 and err["error"]["type"] == "replay_diverged", err
        assert err["error"]["details"]["seq"] == 1, err
        replayed = [post("play1", "anthropic/v1/messages", b) for b in (first, second)]
        assert [s for s, _ in replayed] == [200, 200], replayed
        assert [r["content"][0]["text"] for _, r in replayed] == originals, replayed
        assert len(upstream_requests()) == upstream_before, "replay contacted the provider"
        status, err = post("play1", "anthropic/v1/messages", first)
        assert status == 409 and err["error"]["type"] == "replay_exhausted", err
        snap = json.loads(admin("agentos budget status --json"))
        assert snap["agents"]["play1"]["usd"] == 0, snap["agents"]["play1"]
        assert snap["agents"]["rec1"]["usd"] > 0, snap["agents"]["rec1"]
        assert "2 of 2 requests served" in admin("agentos-replay status play1")
        admin("agentos-replay stop play1")

    with subtest("message bus: two agents talk"):
        # direct message to an inbox
        code, sent = post("alice", "bus/@bob", {"body": "please review PR 7"})
        assert code == 200 and sent["from"] == "alice", sent
        inbox = get("bob", "bus/@bob")
        assert [(m["from"], m["body"]) for m in inbox["messages"]] == [("alice", "please review PR 7")], inbox
        # inboxes are private to their owner
        assert machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {GW}/agent/eve/bus/@bob") == "403"
        # long poll: bob waits on a shared topic, alice publishes a second later
        cursor = get("bob", "bus/builds?after=$")["cursor"]
        machine.execute(f"(curl -s '{GW}/agent/bob/bus/builds?wait=20&after={cursor}' > /tmp/poll.json &)")
        machine.succeed("sleep 1")
        post("alice", "bus/builds", {"body": "build 42 is green"})
        machine.wait_until_succeeds("test -s /tmp/poll.json", timeout=30)
        polled = json.loads(machine.succeed("cat /tmp/poll.json"))
        assert [m["body"] for m in polled["messages"]] == ["build 42 is green"], polled
        # operators use agentos-msg
        admin("agentos-msg send --from ops builds 'freeze deploys'")
        out = admin("agentos-msg read builds")
        assert "alice: build 42 is green" in out and "ops: freeze deploys" in out, out
        assert "alice: please review PR 7" in admin("agentos-msg read @bob")
        # the MCP server talks to the same bus
        rpc = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": "read_messages", "arguments": {"topic": "builds"}}})
        out = machine.succeed(
            f"echo {json.dumps(rpc)} | AGENTOS_AGENT_ID=carol "
            f"ANTHROPIC_BASE_URL={GW}/agent/carol/anthropic agentos-mcp-bus"
        )
        assert "freeze deploys" in out, out

    with subtest("the sandbox user cannot reach the admin endpoints"):
        machine.fail("su -s /bin/sh agentos-agent -c "
                     "'curl -fsS --unix-socket /run/agentos-gateway/admin.sock http://x/_agentos/recordings'")
        code = machine.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X PUT "
                               f"-d '{{\"recording\": \"rec1\"}}' {GW}/_agentos/replay/anyone")
        assert code == "403", code
  '';
}
