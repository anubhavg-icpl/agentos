import hashlib
import json

from conftest import request

TOKEN = "s3cret-token-for-a1"


def register(gw, agent, token):
    digest = hashlib.sha256(token.encode()).hexdigest()
    return request(gw, "PUT", "/_nestlo/agents/" + agent, {"token_sha256": digest}, admin=True)


def test_agent_must_present_registered_token(make_gateway, store):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    assert register(gw, "a1", TOKEN)[0] == 200
    ok = request(gw, "POST", "/agent/a1:%s/anthropic/v1/messages" % TOKEN, {"model": "claude-test"})
    assert ok[0] == 200
    assert store.spend("a1") > 0

    for path in ("/agent/a1/anthropic/v1/messages",                 # no token
                 "/agent/a1:wrong/anthropic/v1/messages",           # wrong token
                 "/agent/fresh-id:anything/anthropic/v1/messages"):  # never registered
        status, _, body = request(gw, "POST", path, {"model": "claude-test"})
        assert status == 401, path
        assert json.loads(body)["error"]["type"] == "authentication_error"
    # failed attempts are not accounted to the agent they named
    assert store.snapshot()["agents"]["a1"]["requests"] == {"2xx": 1}


def test_token_cannot_be_used_for_another_agent(make_gateway):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    register(gw, "a1", TOKEN)
    register(gw, "a2", "other-token")
    assert request(gw, "POST", "/agent/a2:%s/anthropic/v1/messages" % TOKEN, {"model": "claude-test"})[0] == 401


def test_unmanaged_path_is_admin_only(make_gateway):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    assert request(gw, "POST", "/anthropic/v1/messages", {"model": "claude-test"})[0] == 403
    assert request(gw, "POST", "/anthropic/v1/messages", {"model": "claude-test"}, admin=True)[0] == 200


def test_bus_sender_is_authenticated(make_gateway):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    register(gw, "a1", TOKEN)
    assert request(gw, "POST", "/agent/a2/bus/general", {"body": "spoof"})[0] == 401
    status, _, body = request(gw, "POST", "/agent/a1:%s/bus/general" % TOKEN, {"body": "hello"})
    assert status == 200, body
    status, _, body = request(gw, "GET", "/agent/a1:%s/bus/general" % TOKEN)
    messages = json.loads(body)["messages"]
    assert [m["from"] for m in messages] == ["a1"]


def test_registration_needs_admin_socket_and_valid_hash(make_gateway, store):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    digest = hashlib.sha256(b"x").hexdigest()
    assert request(gw, "PUT", "/_nestlo/agents/a1", {"token_sha256": digest})[0] == 403
    assert store.agent_token("a1") is None
    assert request(gw, "PUT", "/_nestlo/agents/a1", {"token_sha256": "nothex"}, admin=True)[0] == 400
    assert register(gw, "a1", "x")[0] == 200
    assert request(gw, "DELETE", "/_nestlo/agents/a1", admin=True)[0] == 200
    assert store.agent_token("a1") is None


def test_token_header_with_plain_agent_path(make_gateway, upstream, store):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    register(gw, "a1", TOKEN)
    path = "/agent/a1/anthropic/v1/messages"
    assert request(gw, "POST", path, {"model": "claude-test"}, {"x-nestlo-token": TOKEN})[0] == 200
    assert "x-nestlo-token" not in {k.lower() for k in upstream.requests[-1]["headers"]}
    assert request(gw, "POST", path, {"model": "claude-test"}, {"x-nestlo-token": "wrong"})[0] == 401
    assert request(gw, "POST", path, {"model": "claude-test"})[0] == 401
    # the bus accepts it too, and the URL form keeps working
    assert request(gw, "POST", "/agent/a1/bus/t", {"body": "x"}, {"x-nestlo-token": TOKEN})[0] == 200
    assert request(gw, "POST", "/agent/a1:%s/anthropic/v1/messages" % TOKEN, {"model": "claude-test"})[0] == 200


def test_token_is_redacted_from_logs(make_gateway, tmp_path, caplog):
    import logging
    caplog.set_level(logging.DEBUG)
    gw = make_gateway(gateway={"require_agent_tokens": True})
    register(gw, "a1", TOKEN)
    wrong = "/agent/a1:%s/anthropic/v1/nosuch" % "wrong-secret-token"
    assert request(gw, "POST", "/agent/a1:%s/anthropic/v1/messages" % TOKEN, {"model": "claude-test"})[0] == 200
    assert request(gw, "POST", wrong, {"model": "claude-test"})[0] == 401
    assert request(gw, "POST", "/agent/a1:%s/nosuch/v1/x" % TOKEN, {"model": "claude-test"})[0] == 404
    assert request(gw, "POST", "/agent/a1%%3A%s/nosuch/v1/x" % TOKEN, {"model": "claude-test"})[0] == 404
    text = caplog.text + (tmp_path / "logs" / "a1.log").read_text()
    assert "/agent/a1:***/" in text
    assert TOKEN not in text and "wrong-secret-token" not in text


def test_redact():
    from nestlo_services.gateway import redact
    assert redact("POST /agent/a1:abc/anthropic/v1 HTTP/1.1") == "POST /agent/a1:***/anthropic/v1 HTTP/1.1"
    assert redact("/agent/a1%3Aabc?x=1") == "/agent/a1:***?x=1"
    assert redact("/agent/a1/anthropic") == "/agent/a1/anthropic"
    assert redact("/anthropic/v1:2") == "/anthropic/v1:2"


def test_failed_authentication_is_throttled_per_address(make_gateway, store):
    gw = make_gateway(gateway={"require_agent_tokens": True}, limits={"max_auth_failures_per_minute": 3})
    register(gw, "a1", TOKEN)
    path = "/agent/a1:guess/anthropic/v1/messages"
    codes = [request(gw, "POST", path, {"model": "claude-test"})[0] for _ in range(5)]
    assert codes == [401, 401, 401, 429, 429]
    status, headers, body = request(gw, "POST", path, {"model": "claude-test"})
    assert status == 429 and int(headers["Retry-After"]) >= 1
    # an agent that proves its token is not locked out by a neighbour's mistakes
    assert request(gw, "POST", "/agent/a1:%s/anthropic/v1/messages" % TOKEN, {"model": "claude-test"})[0] == 200


def test_auth_throttle_window_resets(make_gateway, store):
    now = [1000.0]
    store.clock = lambda: now[0]
    gw = make_gateway(gateway={"require_agent_tokens": True}, limits={"max_auth_failures_per_minute": 1})
    gw.clock = store.clock
    path = "/agent/a1:guess/anthropic/v1/messages"
    assert [request(gw, "POST", path, {})[0] for _ in range(2)] == [401, 429]
    now[0] += 61
    assert request(gw, "POST", path, {})[0] == 401
