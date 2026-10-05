import http.server
import json
import threading
import time

import pytest

from nestlo_services import genai_trace as gt


class Sink(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, status=200, delay=0.0):
        super().__init__(("127.0.0.1", 0), SinkHandler)
        self.status, self.delay = status, delay
        self.posts = []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d/v1/traces" % self.server_address[1]

    def spans(self):
        out = []
        for _h, doc in self.posts:
            for rs in doc["resourceSpans"]:
                out += rs["scopeSpans"][0]["spans"]
        return out


class SinkHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.server.delay:
            time.sleep(self.server.delay)
        self.server.posts.append((dict(self.headers), json.loads(body)))
        self.send_response(self.server.status)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")


@pytest.fixture
def sink():
    s = Sink()
    yield s
    s.shutdown()
    s.server_close()


def attrs(span):
    out = {}
    for a in span["attributes"]:
        (kind, val), = a["value"].items()
        out[a["key"]] = int(val) if kind == "intValue" else val if kind != "arrayValue" else [v["stringValue"] for v in val["values"]]
    return out


PROVIDERS = {"anthropic": {"api": "anthropic", "base_url": "https://api.anthropic.com"},
             "local": {"api": "openai-compatible", "base_url": "http://127.0.0.1:11434"}}

ENTRY = {
    "ts": 1_800_000_000.5, "agent": "alice", "method": "POST", "path": "/v1/messages", "provider": "anthropic",
    "status": 200, "model": "claude-test-20260101", "duration_ms": 1500,
    "usage": {"input_tokens": 100, "output_tokens": 20, "cache_read_tokens": 50, "cache_write_tokens": 10},
    "cost_usd": 0.0123, "priced": True,
}


def make(sink, **cfg):
    return gt.Exporter(dict(endpoint=sink.url, flush_interval_sec=0.05, **cfg), providers=PROVIDERS)


def test_genai_attributes(sink):
    t = make(sink)
    assert t.record(dict(ENTRY, original_model="claude-big", routed_model="claude-test", route_reason="budget 90%"))
    assert t.flush()
    t.close()
    (span,) = sink.spans()
    a = attrs(span)
    assert span["name"] == "chat claude-test" and span["kind"] == 3
    assert a["gen_ai.operation.name"] == "chat"
    assert a["gen_ai.provider.name"] == "anthropic"
    assert a["gen_ai.request.model"] == "claude-test"
    assert a["gen_ai.response.model"] == "claude-test-20260101"
    assert a["gen_ai.usage.input_tokens"] == 160          # includes cached tokens
    assert a["gen_ai.usage.output_tokens"] == 20
    assert a["gen_ai.usage.cache_read.input_tokens"] == 50
    assert a["gen_ai.usage.cache_write.input_tokens"] == 10
    assert a["server.address"] == "api.anthropic.com"
    assert a["nestlo.agent.id"] == "alice"
    assert a["nestlo.cost_usd"] == 0.0123
    assert a["nestlo.route.original_model"] == "claude-big"
    assert a["nestlo.route.routed_model"] == "claude-test"
    assert a["nestlo.route.reason"] == "budget 90%"
    assert "error.type" not in a and "gen_ai.system" not in a and "status" not in span
    assert len(span["traceId"]) == 32 and len(span["spanId"]) == 16
    assert int(span["endTimeUnixNano"]) - int(span["startTimeUnixNano"]) == 1_500_000_000
    doc = sink.posts[0][1]["resourceSpans"][0]
    assert attrs({"attributes": doc["resource"]["attributes"]})["service.name"] == "nestlo-model-gateway"


def test_error_and_providers(sink):
    t = make(sink, legacy_system_attribute=True)
    t.record(dict(ENTRY, status=429, error="budget_exceeded", usage=None, provider="local", path="/v1/chat/completions"))
    t.record({"method": "POST", "path": "/v1/messages", "status": 404, "agent": "x", "ts": 1.0})   # refused before routing
    t.flush()
    t.close()
    s1, s2 = sink.spans()
    a = attrs(s1)
    assert a["error.type"] == "budget_exceeded" and a["gen_ai.provider.name"] == "local"
    assert a["gen_ai.system"] == "local" and s1["status"]["code"] == 2
    assert "gen_ai.usage.input_tokens" not in a
    b = attrs(s2)
    assert b["error.type"] == "404" and "gen_ai.provider.name" not in b


@pytest.mark.parametrize("path,op", [
    ("/v1/chat/completions", "chat"), ("/v1/messages", "chat"), ("/v1/responses", "chat"),
    ("/v1/embeddings", "embeddings"), ("/v1/completions", "text_completion"),
    ("/v1beta/models/gemini:generateContent", "generate_content"),
    ("/v1beta/models/gemini:streamGenerateContent", "generate_content"),
    ("/v1/models", None), ("/v1/messages/count_tokens", None),
])
def test_operation_for(path, op):
    assert gt.operation_for(path) == op


def test_non_generation_requests_are_skipped(sink):
    t = make(sink)
    assert not t.record(dict(ENTRY, path="/v1/models", method="GET"))
    assert not t.record(dict(ENTRY, path="/v1/messages/count_tokens"))
    t.close()
    assert sink.posts == []


def test_traceparent_and_sampling(sink):
    t = make(sink)
    tp = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    t.record(dict(ENTRY, traceparent=tp))
    t.record(dict(ENTRY, traceparent="garbage"))
    t.flush()
    first, second = sink.spans()
    assert first["traceId"] == "0af7651916cd43dd8448eb211c80319c" and first["parentSpanId"] == "b7ad6b7169203331"
    assert "parentSpanId" not in second
    t.close()
    off = make(sink, sample_ratio=0.0)
    assert not off.record(ENTRY)
    off.close()


def test_batches_and_headers(sink, tmp_path):
    hf = tmp_path / "hdr"
    hf.write_text("# comment\nAuthorization: Basic abc\nx-langfuse-ingestion-version: 4\n")
    t = make(sink, batch=3, headers={"X-Static": "1"}, headers_file=str(hf))
    for _ in range(7):
        t.record(ENTRY)
    t.flush()
    assert len(sink.spans()) == 7 and len(sink.posts) >= 3
    h = {k.lower(): v for k, v in sink.posts[0][0].items()}
    assert h["authorization"] == "Basic abc" and h["x-static"] == "1" and h["content-type"] == "application/json"
    hf.write_text("Authorization: Basic new\n")
    t.record(ENTRY)
    t.flush()
    assert {k.lower(): v for k, v in sink.posts[-1][0].items()}["authorization"] == "Basic new"
    t.close()
    assert t.stats()["exported"] == 8


def test_record_never_blocks_on_slow_or_dead_endpoint():
    slow = Sink(delay=1.5)
    t = gt.Exporter(dict(endpoint=slow.url, queue=4, batch=1, timeout_sec=0.3, flush_interval_sec=0.05))
    start = time.monotonic()
    for _ in range(50):
        t.record(ENTRY)
    assert time.monotonic() - start < 0.5
    assert t.stats()["dropped_full"] > 0
    t.close()
    assert t.stats()["errors"] >= 1                       # timeouts counted, not raised
    slow.shutdown()
    slow.server_close()

    dead = gt.Exporter(dict(endpoint="http://127.0.0.1:1/v1/traces", flush_interval_sec=0.05))
    dead.record(ENTRY)
    assert dead.flush()
    assert dead.stats()["dropped_failed"] == 1
    dead.close()


def test_http_error_drops_batch():
    s = Sink(status=500)
    t = gt.Exporter(dict(endpoint=s.url, flush_interval_sec=0.05))
    t.record(ENTRY)
    assert t.flush()
    assert t.stats()["dropped_failed"] == 1 and t.stats()["exported"] == 0
    t.close()
    s.shutdown()
    s.server_close()


def test_garbage_entries_do_not_raise(sink):
    t = make(sink)
    for bad in (None, {}, {"path": 5}, {"usage": "x", "path": "/v1/messages"}, {"ts": "x", "path": "/v1/messages"}):
        assert t.record(bad) in (True, False)
    t.close()


def test_from_config():
    assert not gt.from_config({}).enabled
    assert not gt.from_config({"tracing": {"enabled": True, "endpoint": "ftp://x"}}).enabled
    # a token never travels in clear text to another host
    assert not gt.from_config({"tracing": {"enabled": True, "endpoint": "http://example.com/v1/traces",
                                           "headers": {"Authorization": "x"}}}).enabled
    t = gt.from_config({"tracing": {"enabled": True}, "providers": PROVIDERS})
    assert t.enabled and t.url.port == 4318
    t.close()
    assert gt.Tracer().record(ENTRY) is False


def test_gateway_exports_a_span(make_gateway, sink):
    """Needs the gateway patch described in docs/llm-observability.md (Gateway.tracer)."""
    from conftest import request
    from nestlo_services import config as configmod
    if "tracing" not in configmod.DEFAULTS:
        pytest.skip("config.py has no [tracing] defaults yet")
    gw = make_gateway(tracing={"enabled": True, "endpoint": sink.url, "flush_interval_sec": 0.05})
    if not hasattr(gw, "tracer"):
        pytest.skip("gateway.py is not patched for GenAI tracing yet")
    status, _h, _b = request(gw, "POST", "/agent/alice/anthropic/v1/messages", {"model": "claude-test", "max_tokens": 5},
                             {"x-api-key": "nestlo-managed", "anthropic-version": "2023-06-01"})
    assert status == 200
    assert gw.tracer.flush(5)
    (span,) = sink.spans()
    a = attrs(span)
    assert a["gen_ai.provider.name"] == "anthropic" and a["nestlo.agent.id"] == "alice"
    assert a["gen_ai.request.model"] == "claude-test" and "gen_ai.usage.output_tokens" in a
