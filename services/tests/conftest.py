import copy
import http.client
import http.server
import json
import os
import shutil
import socket
import tempfile
import threading
import time

import fakeredis
import pytest

from nestlo_services import config as configmod
from nestlo_services.gateway import serve
from nestlo_services.store import Store
from nestlo_services.usage import Pricing

PRICING = {
    "models": {
        # $3 / $15 per million input / output tokens
        "claude-test": {"input_per_1m": 3.0, "output_per_1m": 15.0, "cache_read_per_1m": 0.3, "cache_write_per_1m": 3.75},
        "gpt-test": {"input_per_1m": 1.0, "output_per_1m": 2.0, "cache_read_per_1m": 0.5},
        "gemini-test": {"input_per_1m": 1.0, "output_per_1m": 4.0, "cache_read_per_1m": 0.25},
        # models with a vendor, for routing tests
        "claude-cheap": {"provider": "anthropic", "input_per_1m": 1.0, "output_per_1m": 5.0},
        "claude-mid": {"provider": "anthropic", "input_per_1m": 2.0, "output_per_1m": 10.0},
        "claude-pricey": {"provider": "anthropic", "input_per_1m": 20.0, "output_per_1m": 100.0},
        "gpt-cheap": {"provider": "openai", "input_per_1m": 0.1, "output_per_1m": 0.2},
    },
    "default": {"input_per_1m": 10.0, "output_per_1m": 50.0},
}


class MockUpstream(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), MockHandler)
        self.requests = []
        self.fail_status = None
        self.delay = 0.0

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]


class MockHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        self.server.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
        if self.server.delay:
            time.sleep(self.server.delay)
        if self.server.fail_status:
            return self._json(self.server.fail_status, {"type": "error", "error": {"type": "api_error"}})
        model = body.get("model", "claude-test")
        route = self.path.split("?")[0]
        if "/models/" in route and ":" in route.rsplit("/", 1)[-1]:
            return self._gemini(route, body)
        if route.startswith("/openai/deployments/") and route.endswith("/chat/completions"):
            deployment = route.split("/")[3]
            return self._json(200, {"model": body.get("model", "gpt-test"), "deployment": deployment, "choices": [],
                                    "usage": {"prompt_tokens": 1000, "completion_tokens": 500,
                                              "prompt_tokens_details": {"cached_tokens": 200}}})
        if route == "/v1/responses" and body.get("stream"):
            usage = {"input_tokens": 400, "output_tokens": 100, "input_tokens_details": {"cached_tokens": 100}}
            return self._sse([
                ("response.created", {"type": "response.created", "response": {"model": model, "usage": None}}),
                ("response.output_text.delta", {"type": "response.output_text.delta", "delta": "hi"}),
                ("response.completed", {"type": "response.completed", "response": {"model": model, "usage": usage}}),
            ])
        if route == "/v1/nousage":
            return self._json(200, {"model": model, "result": "no usage block here"})
        if self.path == "/v1/messages":
            if body.get("stream"):
                return self._sse([
                    ("message_start", {"type": "message_start", "message": {
                        "id": "msg_1", "type": "message", "model": model,
                        "usage": {"input_tokens": 1000, "output_tokens": 1,
                                  "cache_read_input_tokens": 2000, "cache_creation_input_tokens": 0}}}),
                    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                             "delta": {"type": "text_delta", "text": "hello"}}),
                    ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
                                       "usage": {"output_tokens": 500}}),
                    ("message_stop", {"type": "message_stop"}),
                ])
            tokens = body.get("mock_tokens", {"input_tokens": 1_000_000, "output_tokens": 0})
            return self._json(200, {"id": "msg_1", "type": "message", "model": model,
                                    "content": [{"type": "text", "text": body["mock_text_rev"][::-1] if "mock_text_rev" in body
                                                                     else body.get("mock_text", "hi")}],
                                    "usage": tokens})
        if self.path == "/v1/chat/completions":
            if body.get("stream"):
                usage = {"prompt_tokens": 300, "completion_tokens": 100,
                         "prompt_tokens_details": {"cached_tokens": 100}}
                include = (body.get("stream_options") or {}).get("include_usage")
                return self._sse([
                    (None, {"model": model, "choices": [{"delta": {"content": "hi"}}], "usage": None}),
                    (None, {"model": model, "choices": [], "usage": usage if include else None}),
                    (None, "[DONE]"),
                ])
            return self._json(200, {"model": model, "choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 5}})
        self._json(404, {"error": "no route"})

    def _gemini(self, route, body):
        name = route.rsplit("/", 1)[-1]
        model, _, method = name.partition(":")
        usage = {"promptTokenCount": 1000, "cachedContentTokenCount": 400,
                 "candidatesTokenCount": 300, "thoughtsTokenCount": 100, "totalTokenCount": 1400}
        chunk = {"candidates": [{"content": {"parts": [{"text": "hi"}]}}], "modelVersion": model}
        if method == "streamGenerateContent":
            # usage is cumulative: partial on the first chunk, final on the last
            first = dict(chunk, usageMetadata={"promptTokenCount": 1000, "cachedContentTokenCount": 400})
            return self._sse([(None, first), (None, dict(chunk, usageMetadata=usage))])
        return self._json(200, dict(chunk, usageMetadata=usage))

    def _json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for name, data in events:
            payload = data if isinstance(data, str) else json.dumps(data)
            text = ("event: %s\n" % name if name else "") + "data: %s\n\n" % payload
            raw = text.encode()
            # split each event across two chunks to exercise reassembly
            for part in (raw[:7], raw[7:]):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(part), part))
                self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")


@pytest.fixture
def upstream():
    srv = MockUpstream()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()


@pytest.fixture
def store():
    # A fresh server per test: FakeRedis instances share one by default
    return Store(fakeredis.FakeRedis(server=fakeredis.FakeServer(), decode_responses=True))


@pytest.fixture
def short_dir():
    # AF_UNIX socket paths are limited to ~108 bytes; pytest's tmp_path can be longer
    base = "/tmp" if os.access("/tmp", os.W_OK) else None
    path = tempfile.mkdtemp(prefix="agos", dir=base)
    yield path
    shutil.rmtree(path, ignore_errors=True)


@pytest.fixture
def make_gateway(tmp_path, short_dir, upstream, store):
    servers = []

    def make(**overrides):
        cfg = copy.deepcopy(configmod.DEFAULTS)
        key_file = tmp_path / "anthropic.key"
        key_file.write_text("sk-real-anthropic\n")
        cfg["providers"] = {
            "anthropic": {"base_url": upstream.url, "api": "anthropic", "key_file": str(key_file)},
            "openai": {"base_url": upstream.url, "api": "openai"},
        }
        # Most tests address agents by bare id; test_auth.py covers tokens
        cfg["gateway"].update(require_agent_tokens=False, listen="127.0.0.1", port=0, log_dir=str(tmp_path / "logs"),
                              admin_socket=os.path.join(short_dir, "admin.sock"))
        (tmp_path / "logs").mkdir(exist_ok=True)
        for section, values in overrides.items():
            cfg[section].update(values)
        gw, srvs = serve(cfg, store=store, pricing=Pricing(PRICING))
        servers.extend(srvs)
        gw.port = srvs[0].server_address[1]
        gw.socket_path = cfg["gateway"]["admin_socket"]
        return gw

    yield make
    for srv in servers:
        srv.shutdown()
        srv.server_close()


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost")
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


def request(gw, method, path, body=None, headers=None, admin=False):
    conn = UnixHTTPConnection(gw.socket_path) if admin else http.client.HTTPConnection("127.0.0.1", gw.port, timeout=10)
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    conn.request(method, path, body=data, headers=hdrs)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    return resp.status, dict(resp.getheaders()), raw


class EventRecorder:
    def __init__(self, store):
        self.pubsub = store.subscribe()

    def drain(self, quiet=0.3):
        """Collect events until none arrive for `quiet` seconds."""
        events = []
        deadline = time.time() + quiet
        while time.time() < deadline:
            msg = self.pubsub.get_message(timeout=0.05)
            if msg and msg["type"] == "message":
                events.append(json.loads(msg["data"]))
                deadline = time.time() + quiet
        return events


@pytest.fixture
def events(store):
    return EventRecorder(store)


@pytest.fixture
def upstream2():
    srv = MockUpstream()
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()
