import io
import json

import pytest

from agentos_services import mcp_bus
from agentos_services.mcp_bus import BusServer, derive_base


def rpc(method, params=None, mid=1):
    msg = {"jsonrpc": "2.0", "id": mid, "method": method}
    if params is not None:
        msg["params"] = params
    return msg


class FakeGateway:
    def __init__(self):
        self.calls = []

    def __call__(self, method, url, body=None, timeout=60):
        self.calls.append((method, url, body))
        if method == "POST":
            return {"id": "1-0", "topic": "t"}
        return {"topic": "t", "cursor": "5-0", "messages": [
            {"id": "5-0", "from": "a2", "topic": "t", "body": "hello", "ts": 1.0}]}


@pytest.fixture
def server():
    gw = FakeGateway()
    return BusServer("http://127.0.0.1:8080/agent/a1", "a1", gw), gw


def test_derive_base():
    env = {"ANTHROPIC_BASE_URL": "http://127.0.0.1:8080/agent/a-1/anthropic"}
    assert derive_base(env) == ("http://127.0.0.1:8080/agent/a-1", "a-1")
    env = {"OPENAI_BASE_URL": "http://127.0.0.1:8080/agent/o1/openai/v1", "AGENTOS_AGENT_ID": "o1"}
    assert derive_base(env) == ("http://127.0.0.1:8080/agent/o1", "o1")
    env = {"AGENTOS_GATEWAY_URL": "http://gw:9/", "AGENTOS_AGENT_ID": "x"}
    assert derive_base(env) == ("http://gw:9/agent/x", "x")
    with pytest.raises(ValueError):
        derive_base({})


def test_initialize_and_lists(server):
    srv, _ = server
    res = srv.handle(rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}}))
    assert res["id"] == 1 and res["result"]["protocolVersion"] == "2025-03-26"
    assert res["result"]["serverInfo"]["name"] == "agentos-bus" and "tools" in res["result"]["capabilities"]
    tools = srv.handle(rpc("tools/list", mid=2))["result"]["tools"]
    assert [t["name"] for t in tools] == ["send_message", "read_messages"]
    assert tools[0]["inputSchema"]["required"] == ["topic", "text"]
    assert srv.handle(rpc("ping", mid=3))["result"] == {}


def test_notifications_get_no_response(server):
    srv, _ = server
    assert srv.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None


def test_send_message(server):
    srv, gw = server
    res = srv.handle(rpc("tools/call", {"name": "send_message", "arguments": {"topic": "@a2", "text": "hi"}}))
    assert res["result"]["isError"] is False and "sent to @a2" in res["result"]["content"][0]["text"]
    assert gw.calls == [("POST", "http://127.0.0.1:8080/agent/a1/bus/@a2", "hi")]


def test_read_messages_defaults_to_own_inbox(server):
    srv, gw = server
    res = srv.handle(rpc("tools/call", {"name": "read_messages", "arguments": {"after": "3-0", "wait": 2}}))
    text = res["result"]["content"][0]["text"]
    assert "a2: hello" in text and "cursor: 5-0" in text
    method, url, _ = gw.calls[0]
    assert method == "GET" and "/bus/@a1?" in url and "after=3-0" in url and "wait=2" in url


def test_tool_errors_are_reported_in_band(server):
    srv, _ = server
    res = srv.handle(rpc("tools/call", {"name": "send_message", "arguments": {"topic": "t"}}))
    assert res["result"]["isError"] is True
    assert srv.handle(rpc("tools/call", {"name": "nope"}))["error"]["code"] == -32602
    assert srv.handle(rpc("resources/list"))["error"]["code"] == -32601

    def broken(*a, **k):
        raise RuntimeError("gateway returned 403: only a2 can read this inbox")
    srv.fetch = broken
    res = srv.handle(rpc("tools/call", {"name": "read_messages", "arguments": {"topic": "@a2"}}))
    assert res["result"]["isError"] and "403" in res["result"]["content"][0]["text"]


def test_stdio_loop(server):
    srv, _ = server
    lines = [json.dumps(rpc("initialize", {})), "", "not json",
             json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
             json.dumps(rpc("tools/list", mid=2))]
    out = io.StringIO()
    srv.serve(io.StringIO("\n".join(lines) + "\n"), out)
    replies = [json.loads(line) for line in out.getvalue().splitlines()]
    assert [r.get("id") for r in replies] == [1, None, 2]
    assert replies[1]["error"]["code"] == -32700


def test_end_to_end_against_the_gateway(make_gateway):
    gw = make_gateway()
    base = "http://127.0.0.1:%d/agent/a1" % gw.port
    other = "http://127.0.0.1:%d/agent/a2" % gw.port
    sender, receiver = BusServer(base, "a1"), BusServer(other, "a2")
    send = rpc("tools/call", {"name": "send_message", "arguments": {"topic": "@a2", "text": "review please"}})
    assert sender.handle(send)["result"]["isError"] is False
    got = receiver.handle(rpc("tools/call", {"name": "read_messages", "arguments": {}}))
    assert "a1: review please" in got["result"]["content"][0]["text"]
    denied = sender.handle(rpc("tools/call", {"name": "read_messages", "arguments": {"topic": "@a2"}}))
    assert denied["result"]["isError"] and "403" in denied["result"]["content"][0]["text"]


def test_main_needs_configuration(monkeypatch, capsys):
    for var in ("AGENTOS_AGENT_ID", "AGENTOS_GATEWAY_URL", "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL"):
        monkeypatch.delenv(var, raising=False)
    assert mcp_bus.main() == 1
    assert "AGENTOS_AGENT_ID" in capsys.readouterr().err
