import hashlib
import json

from conftest import request

TOKEN = "s3cret-token-for-a1"


def register(gw, agent, token):
    digest = hashlib.sha256(token.encode()).hexdigest()
    return request(gw, "PUT", "/_agentos/agents/" + agent, {"token_sha256": digest}, admin=True)


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
    assert request(gw, "PUT", "/_agentos/agents/a1", {"token_sha256": digest})[0] == 403
    assert store.agent_token("a1") is None
    assert request(gw, "PUT", "/_agentos/agents/a1", {"token_sha256": "nothex"}, admin=True)[0] == 400
    assert register(gw, "a1", "x")[0] == 200
    assert request(gw, "DELETE", "/_agentos/agents/a1", admin=True)[0] == 200
    assert store.agent_token("a1") is None
