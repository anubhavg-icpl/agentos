# VM test of the tamper-evident audit log and the gateway DLP stage:
#
#   nix build .#checks.x86_64-linux.audit
#
#   the writer         starts as the dedicated agentos-audit user; the signing
#                      key was generated at first boot and is root-only
#   chained records    a gateway request produces a hash-chained record without
#                      the prompt; checkpoints are signed; `agentos-audit verify` passes
#   append only        the services (user agentos) and the agent user cannot
#                      modify the log files
#   non-blocking       with the writer stopped requests still succeed and the
#                      buffered events arrive when it returns
#   DLP                a secret in a prompt is masked (or blocked per agent),
#                      the audit log records the detector type, never the value
#   tamper evidence    editing a line makes `agentos-audit verify` fail
{ pkgs, agentosModules }:

let
  # Mock of the Anthropic Messages API that remembers the prompt it received
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json

    LOG = "/var/lib/mock-llm/requests.jsonl"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            msgs = body.get("messages") or [{}]
            with open(LOG, "a") as f:
                f.write(json.dumps({"model": body.get("model"),
                                    "content": msgs[0].get("content")}) + "\n")
            usage = {"input_tokens": 1000, "output_tokens": 10}
            reply = {"id": "msg_1", "type": "message",
                     "model": body.get("model", "claude-sonnet-5-5"),
                     "content": [{"type": "text", "text": "ok"}],
                     "usage": usage}
            data = json.dumps(reply).encode()
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
  name = "agentos-audit";
  globalTimeout = 1200;

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
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/agentos-test/anthropic.key";
        };
      };
      audit = {
        enable = true;
        checkpointEvery = 3;
      };
      gateway.dlp = {
        mode = "mask";
        overrides."strict-" = { mode = "block"; };
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
    AUDIT = "/var/lib/agentos-audit"
    SECRET = "AKIAIOSFODNN7EXAMPLE"
    TOKENS = {}

    def admin(cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def seg(agent):
        """The "<id>:<token>" URL segment, registering a token like agentos spawn does."""
        if agent not in TOKENS:
            token = machine.succeed("od -An -N16 -tx1 /dev/urandom | tr -d ' \\n'").strip()
            digest = machine.succeed(f"printf %s {token} | sha256sum | cut -d' ' -f1").strip()
            machine.succeed(
                "curl -fsS --unix-socket /run/agentos-gateway/admin.sock -X PUT "
                f"-d '{{\"token_sha256\": \"{digest}\"}}' http://localhost/_agentos/agents/{agent}"
            )
            TOKENS[agent] = token
        return f"{agent}:{TOKENS[agent]}"

    def post(agent, text):
        """POST a message as an agent; returns (status, body text)."""
        body = {"model": "claude-sonnet-5-5", "max_tokens": 16,
                "messages": [{"role": "user", "content": text}]}
        out = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' -H 'content-type: application/json' "
            f"-H 'x-api-key: agentos-managed' -d {json.dumps(json.dumps(body))} "
            f"{GW}/agent/{seg(agent)}/anthropic/v1/messages"
        )
        text_out, code = out.rsplit("\n", 1)
        return int(code), text_out

    def records():
        raw = admin("agentos-audit tail -n 1000 --json")
        return [json.loads(line) for line in raw.splitlines() if line.strip()]

    def upstream():
        raw = machine.succeed("cat /var/lib/mock-llm/requests.jsonl 2>/dev/null || true")
        return [json.loads(line) for line in raw.splitlines()]

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-audit-keygen.service", "agentos-audit.service",
                 "agentos-model-gateway.service", "agentos-daemon.service", "mock-llm.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_file("/run/agentos-audit/audit.sock")
    machine.wait_for_open_port(8080)

    with subtest("the writer is a dedicated user and the key is root-only"):
        assert machine.succeed("systemctl show -p User --value agentos-audit").strip() == "agentos-audit"
        assert machine.succeed(f"stat -c '%U:%G %a' {AUDIT}").strip() == "agentos-audit:agentos-audit 750"
        assert machine.succeed("stat -c '%U %a' /var/lib/agentos-audit-key/signing.key").strip() == "root 400"
        # the public key is published next to the log for `agentos-audit verify`
        assert len(machine.succeed(f"cat {AUDIT}/public.keys").split()[0]) == 64

    with subtest("a gateway request produces a chained record without the prompt"):
        code, _ = post("alice", "refactor the parser module")
        assert code == 200, code
        machine.wait_until_succeeds(
            "su - admin -c 'agentos-audit tail -n 1000 --json' | grep -q '\"type\": \"gateway.request\"'", timeout=30)
        recs = records()
        req = [r for r in recs if r["type"] == "gateway.request" and r["actor"] == "alice"]
        assert req, recs
        data = req[0]["data"]
        assert data["provider"] == "anthropic" and data["status"] == 200 and data["cost_usd"] > 0, data
        assert req[0]["source"] == "gateway" and req[0]["peer"]["uid"] > 0, req[0]
        assert "refactor the parser" not in json.dumps(recs)
        # seq is gapless and each record links to the one before
        assert [r["seq"] for r in recs] == list(range(recs[0]["seq"], recs[0]["seq"] + len(recs)))
        assert all(len(r["hash"]) == 64 and len(r["prev"]) == 64 for r in recs)

    with subtest("signed checkpoints are written and verify passes"):
        for i in range(4):
            post("alice", f"another request {i}")
        machine.wait_until_succeeds(
            "su - admin -c 'agentos-audit tail -n 1000 --json' | grep -q audit.checkpoint", timeout=30)
        out = admin("agentos-audit verify")
        print(out)
        assert out.startswith("OK:") and "checkpoint signature" in out, out

    with subtest("DLP masks a secret before it leaves and the audit log records only the type"):
        code, _ = post("alice", f"deploy with {SECRET} please")
        assert code == 200
        sent = upstream()[-1]["content"]
        assert sent == "deploy with [REDACTED:aws_access_key] please", sent
        machine.wait_until_succeeds(
            "su - admin -c 'agentos-audit tail -n 1000 --json' | grep -q dlp.detection", timeout=30)
        det = [r for r in records() if r["type"] == "dlp.detection"]
        assert det[-1]["data"]["detections"] == {"aws_access_key": 1}, det
        assert det[-1]["data"]["action"] == "masked"
        machine.fail(f"grep -rq {SECRET} {AUDIT}")
        machine.fail(f"grep -q {SECRET} /var/lib/agentos/logs/alice.log")

    with subtest("DLP blocks for agents with a stricter prefix"):
        before = len(upstream())
        code, body = post("strict-1", f"key {SECRET}")
        assert code == 403 and "dlp_blocked" in body, (code, body)
        assert SECRET not in body
        assert len(upstream()) == before

    with subtest("the services and the agent user cannot rewrite the log"):
        segment = machine.succeed(f"ls {AUDIT}/audit-*.jsonl | head -n 1").strip()
        machine.fail(f"su -s /bin/sh agentos -c 'echo forged >> {segment}'")
        machine.fail(f"su -s /bin/sh agentos -c 'rm -f {segment}'")
        machine.fail(f"su -s /bin/sh agentos-agent -c 'cat {segment}'")
        machine.fail(f"su -s /bin/sh agentos-agent -c 'ls {AUDIT}'")
        # the socket directory is reachable by group members only
        machine.fail("su -s /bin/sh agentos-agent -c 'ls /run/agentos-audit/'")

    with subtest("requests do not wait for the audit writer, and buffered events arrive later"):
        count = "su - admin -c 'agentos-audit tail -n 100000 --json' | grep -c 'gateway.request'"
        before = int(machine.succeed(count + " || true").strip() or "0")
        machine.succeed("systemctl stop agentos-audit.service")
        code, _ = post("alice", "while the writer is down")
        assert code == 200
        machine.succeed("systemctl start agentos-audit.service")
        machine.wait_for_file("/run/agentos-audit/audit.sock")
        machine.wait_until_succeeds(f"[ $({count}) -gt {before} ]", timeout=60)
        assert admin("agentos-audit verify").startswith("OK:")

    with subtest("editing a record makes verify fail"):
        machine.succeed("systemctl stop agentos-audit.service")
        segment = machine.succeed(f"ls {AUDIT}/audit-*.jsonl | head -n 1").strip()
        machine.succeed(f"sed -i '0,/\"status\":200/s//\"status\":403/' {segment}")
        out = machine.execute("su - admin -c 'agentos-audit verify 2>&1'")
        print(out)
        assert out[0] == 1, out
        assert "hash_mismatch" in out[1], out
  '';
}
