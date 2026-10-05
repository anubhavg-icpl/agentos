# VM test of nestlo.llmObservability (the GenAI span exporter):
#
#   nix build .#checks.x86_64-linux.llm-observability
#
# The Nestlo model gateway has the exporter built in (Gateway.tracer, the
# tracer.record() call in Gateway.write_log, [tracing] defaults in config.py).
#
# A mock Anthropic upstream answers with token usage, and a local OTLP sink (a
# Python HTTP server in the VM) stands in for the backend. The test sends a
# model call through the gateway as a registered agent and checks that the
# sink receives a span with the GenAI attributes, the Nestlo attributes and
# the headers from the headers file, and that the gateway keeps serving
# requests while the sink is down. The Langfuse and OpenLIT stacks are not
# started (they need registries).
{ pkgs, nestloModules }:

let
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            data = json.dumps({
                "id": "msg_1", "type": "message", "role": "assistant",
                "model": body.get("model") + "-20260101",
                "content": [{"type": "text", "text": "hello from the mock"}],
                "stop_reason": "end_turn",
                "usage": {"input_tokens": 1000, "output_tokens": 10,
                          "cache_read_input_tokens": 200},
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

  otlpSink = pkgs.writers.writePython3Bin "otlp-sink" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json

    LOG = "/var/lib/otlp-sink/posts.jsonl"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            with open(LOG, "a") as f:
                f.write(json.dumps({"path": self.path,
                                    "authorization": self.headers.get("Authorization"),
                                    "content-type": self.headers.get("Content-Type"),
                                    "body": body}) + "\n")
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 4318), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-llm-observability";

  nodes.machine = { ... }: {
    imports = nestloModules;

    nestlo = {
      runtime.enable = true;
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
      };
      llmObservability = {
        enable = true;
        exporter = {
          backend = "custom";
          endpoint = "http://127.0.0.1:4318/v1/traces";
          headersFile = "/etc/nestlo-test/otlp-headers";
        };
      };
    };

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };
    environment.etc."nestlo-test/otlp-headers" = {
      text = "Authorization: Bearer sink-token\n";
      mode = "0440";
      group = "nestlo";
    };
    environment.systemPackages = [ pkgs.jq ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-model-gateway.service" ];
      serviceConfig.ExecStart = "${mockLlm}/bin/mock-llm";
    };
    systemd.services.otlp-sink = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${otlpSink}/bin/otlp-sink";
        StateDirectory = "otlp-sink";
      };
    };
  };

  testScript = ''
    import json

    ADMIN = "curl -fsS --unix-socket /run/nestlo-gateway/admin.sock http://x/_nestlo/"

    def attrs(span):
        out = {}
        for a in span["attributes"]:
            (kind, val), = a["value"].items()
            out[a["key"]] = int(val) if kind == "intValue" else val
        return out

    def spans():
        out = []
        for line in machine.succeed("cat /var/lib/otlp-sink/posts.jsonl 2>/dev/null || true").splitlines():
            post = json.loads(line)
            for rs in post["body"]["resourceSpans"]:
                for ss in rs["scopeSpans"]:
                    out += [(post, s) for s in ss["spans"]]
        return out

    def call(agent, token, model="claude-test"):
        body = json.dumps({"model": model, "max_tokens": 16, "messages": [{"role": "user", "content": "hi"}]})
        return machine.succeed(
            f"curl -sS -m 30 -X POST http://127.0.0.1:8080/agent/{agent}:{token}/anthropic/v1/messages "
            f"-H 'x-api-key: nestlo-managed' -H 'anthropic-version: 2023-06-01' "
            f"-H 'Content-Type: application/json' -d '{body}'")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-model-gateway.service")
    machine.wait_for_unit("otlp-sink.service")
    machine.wait_for_open_port(4318)

    with subtest("the gateway is configured to trace"):
        cfg = machine.succeed("cat /etc/nestlo/services.toml")
        assert "[tracing]" in cfg and "http://127.0.0.1:4318/v1/traces" in cfg, cfg
        assert "/etc/nestlo-test/otlp-headers" in cfg, cfg

    machine.succeed("echo -n tracetoken > /tmp/tok")
    h = machine.succeed("sha256sum /tmp/tok | cut -d' ' -f1").strip()
    machine.succeed(ADMIN + "agents/tracer -X PUT -H 'Content-Type: application/json' "
                    + f"-d '{json.dumps({'token_sha256': h})}'")
    machine.succeed(ADMIN + "budget/tracer -X PUT -H 'Content-Type: application/json' -d '{\"daily_usd\": 5}'")

    with subtest("a model call produces a span with GenAI attributes"):
        out = call("tracer", "tracetoken")
        assert "hello from the mock" in out, out
        machine.wait_until_succeeds("test -s /var/lib/otlp-sink/posts.jsonl", timeout=30)
        post, span = spans()[-1]
        assert post["path"] == "/v1/traces", post["path"]
        assert post["authorization"] == "Bearer sink-token", post
        assert post["content-type"] == "application/json", post
        a = attrs(span)
        assert span["name"] == "chat claude-test" and span["kind"] == 3, span
        assert a["gen_ai.operation.name"] == "chat", a
        assert a["gen_ai.provider.name"] == "anthropic", a
        assert a["gen_ai.request.model"] == "claude-test", a
        assert a["gen_ai.response.model"] == "claude-test-20260101", a
        assert a["gen_ai.usage.input_tokens"] == 1200, a        # includes the 200 cached tokens
        assert a["gen_ai.usage.output_tokens"] == 10, a
        assert a["gen_ai.usage.cache_read.input_tokens"] == 200, a
        assert a["nestlo.agent.id"] == "tracer", a
        assert "nestlo.cost_usd" in a and "error.type" not in a, a
        assert "gen_ai.system" not in a, a                      # deprecated, off by default
        res = {x["key"]: x["value"]["stringValue"] for x in post["body"]["resourceSpans"][0]["resource"]["attributes"]}
        assert res["service.name"] == "nestlo-model-gateway", res
        # the prompt and the answer never leave the gateway
        assert "hello from the mock" not in machine.succeed("cat /var/lib/otlp-sink/posts.jsonl")

    with subtest("a refused call is a span with error.type"):
        machine.succeed(ADMIN + "budget/tracer -X PUT -H 'Content-Type: application/json' -d '{\"daily_usd\": 0.000001}'")
        code = machine.succeed(
            "curl -s -o /dev/null -w '%{http_code}' -X POST "
            "http://127.0.0.1:8080/agent/tracer:tracetoken/anthropic/v1/messages "
            "-H 'x-api-key: nestlo-managed' -H 'Content-Type: application/json' "
            "-d '{\"model\":\"claude-test\",\"max_tokens\":16,\"messages\":[]}'").strip()
        assert code == "402", code      # budget_exceeded
        machine.wait_until_succeeds(
            "grep -q error.type /var/lib/otlp-sink/posts.jsonl", timeout=30)
        failed = [s for _, s in spans() if "error.type" in attrs(s)][-1]
        assert failed["status"]["code"] == 2, failed
        machine.succeed(ADMIN + "budget/tracer -X PUT -H 'Content-Type: application/json' -d '{\"daily_usd\": 5}'")

    with subtest("requests keep working while the backend is down"):
        machine.systemctl("stop otlp-sink.service")
        out = call("tracer", "tracetoken")
        assert "hello from the mock" in out, out
        machine.succeed("systemctl is-active nestlo-model-gateway.service")
        machine.systemctl("start otlp-sink.service")
        machine.wait_for_open_port(4318)
  '';
}
