import json
import os

import pytest

from conftest import request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"


def test_health(make_gateway):
    gw = make_gateway()
    status, _, body = request(gw, "GET", "/_agentos/health")
    assert status == 200
    health = json.loads(body)
    assert health["providers"]["anthropic"]["managed_key"] is True
    assert health["providers"]["openai"]["managed_key"] is False


def test_proxies_and_prices_json(make_gateway, upstream, store, tmp_path):
    gw = make_gateway()
    status, headers, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test", "max_tokens": 5},
                                    {"x-api-key": "agentos-managed", "anthropic-version": "2023-06-01"})
    assert status == 200
    assert json.loads(body)["content"][0]["text"] == "hi"
    seen = upstream.requests[-1]
    assert seen["path"] == "/v1/messages"
    assert seen["headers"]["x-api-key"] == "sk-real-anthropic"   # managed key injected
    assert seen["headers"]["anthropic-version"] == "2023-06-01"
    assert store.spend("a1") == pytest.approx(3.0)                 # 1M input tokens at $3
    assert store.global_spend() == pytest.approx(3.0)

    lines = (tmp_path / "logs" / "a1.log").read_text().splitlines()
    entry = json.loads(lines[-1])
    assert entry["status"] == 200 and entry["model"] == "claude-test"
    assert entry["cost_usd"] == pytest.approx(3.0) and entry["priced"] is True


def test_client_key_is_not_overridden(make_gateway, upstream):
    gw = make_gateway()
    request(gw, "POST", ANTHROPIC, {"model": "claude-test"}, {"x-api-key": "sk-user"})
    assert upstream.requests[-1]["headers"]["x-api-key"] == "sk-user"
    request(gw, "POST", ANTHROPIC, {"model": "claude-test"}, {"Authorization": "Bearer oauth-token"})
    assert "x-api-key" not in upstream.requests[-1]["headers"]


def test_streaming_passthrough_and_usage(make_gateway, store):
    gw = make_gateway()
    status, headers, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test", "stream": True})
    assert status == 200
    assert headers["Content-Type"] == "text/event-stream"
    text = body.decode()
    assert text.count("data: ") == 4 and '"text": "hello"' in text
    # 1000 input * $3 + 500 output * $15 + 2000 cache reads * $0.3, per million
    assert store.spend("a1") == pytest.approx((1000 * 3 + 500 * 15 + 2000 * 0.3) / 1e6)
    tokens = store.snapshot()["agents"]["a1"]["tokens"]
    assert tokens == {"input_tokens": 1000, "output_tokens": 500, "cache_read_tokens": 2000}


def test_openai_stream_gets_include_usage(make_gateway, upstream, store):
    gw = make_gateway()
    status, _, _ = request(gw, "POST", "/agent/o1/openai/v1/chat/completions",
                           {"model": "gpt-test", "stream": True}, {"Authorization": "Bearer sk-user"})
    assert status == 200
    assert upstream.requests[-1]["body"]["stream_options"] == {"include_usage": True}
    assert upstream.requests[-1]["headers"]["Authorization"] == "Bearer sk-user"
    # 200 input * $1 + 100 output * $2 + 100 cached * $0.5
    assert store.spend("o1") == pytest.approx((200 * 1 + 100 * 2 + 100 * 0.5) / 1e6)


def test_unmanaged_path(make_gateway, store):
    gw = make_gateway()
    status, _, _ = request(gw, "POST", "/anthropic/v1/messages", {"model": "claude-test"})
    assert status == 200
    assert store.spend("unmanaged") == pytest.approx(3.0)


def test_budget_blocks_and_alerts(make_gateway, store, events):
    gw = make_gateway()
    status, _, _ = request(gw, "PUT", "/_agentos/budget/a1", {"daily_usd": 5}, admin=True)
    assert status == 200
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200   # $3: 60%
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200   # $6: over
    status, _, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    assert status == 402
    assert json.loads(body)["error"]["type"] == "budget_exceeded"
    assert store.spend("a1") == pytest.approx(6.0)

    got = events.drain()
    kinds = [e["type"] for e in got]
    assert kinds.count("budget_exceeded") == 1                       # deduplicated
    assert [e["threshold"] for e in got if e["type"] == "budget_threshold"] == [50, 80, 95]
    snap = json.loads(request(gw, "GET", "/_agentos/spend")[2])
    assert snap["agents"]["a1"]["limit_usd"] == 5.0
    assert snap["agents"]["a1"]["requests"] == {"2xx": 2, "4xx": 1}


def test_budget_writes_need_admin_socket(make_gateway, store):
    gw = make_gateway()
    status, _, body = request(gw, "PUT", "/_agentos/budget/a1", {"daily_usd": 1000})
    assert status == 403
    assert store.limit("a1", 50.0) == 50.0
    assert request(gw, "PUT", "/_agentos/budget/a1", {"daily_usd": -1}, admin=True)[0] == 400
    assert request(gw, "PUT", "/_agentos/budget/a1", {"nope": 1}, admin=True)[0] == 400
    assert request(gw, "DELETE", "/_agentos/budget/a1", admin=True)[0] == 200


def test_global_budget(make_gateway):
    gw = make_gateway(budget={"global_daily_usd": 2.0})
    assert request(gw, "POST", "/agent/x/anthropic/v1/messages", {"model": "claude-test"})[0] == 200
    status, _, body = request(gw, "POST", "/agent/y/anthropic/v1/messages", {"model": "claude-test"})
    assert status == 402 and b"global" in body


def test_rate_limit(make_gateway):
    gw = make_gateway(limits={"max_requests_per_minute": 2})
    cheap = {"model": "claude-test", "mock_tokens": {"input_tokens": 1}}
    assert request(gw, "POST", ANTHROPIC, cheap)[0] == 200
    assert request(gw, "POST", ANTHROPIC, cheap)[0] == 200
    status, headers, _ = request(gw, "POST", ANTHROPIC, cheap)
    assert status == 429 and int(headers["Retry-After"]) >= 1
    # other agents are unaffected
    assert request(gw, "POST", "/agent/other/anthropic/v1/messages", cheap)[0] == 200


def test_circuit_breaker(make_gateway, upstream, events):
    gw = make_gateway(limits={"max_consecutive_failures": 2, "cooldown_sec": 60})
    upstream.fail_status = 500
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 500
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 500
    upstream.fail_status = None
    status, headers, _ = request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    assert status == 503 and int(headers["Retry-After"]) > 0
    assert [e["type"] for e in events.drain()] == ["circuit_open"]
    assert request(gw, "DELETE", "/_agentos/circuit/a1", admin=True)[0] == 200
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200


def test_success_resets_failure_count(make_gateway, upstream):
    gw = make_gateway(limits={"max_consecutive_failures": 2})
    upstream.fail_status = 503
    request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    upstream.fail_status = None
    request(gw, "POST", ANTHROPIC, {"model": "claude-test", "mock_tokens": {}})
    upstream.fail_status = 503
    request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    upstream.fail_status = None
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test", "mock_tokens": {}})[0] == 200


def test_unreachable_upstream(make_gateway, store):
    gw = make_gateway()
    gw.cfg["providers"]["anthropic"]["base_url"] = "http://127.0.0.1:9"
    status, _, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    assert status == 502
    assert json.loads(body)["error"]["type"] == "api_error"


@pytest.mark.parametrize("path,status", [
    ("/nowhere", 404),
    ("/agent/a1/nosuch/v1/messages", 404),
    ("/agent/..%2Fetc/anthropic/v1/messages", 400),
    ("/_agentos/budget/a1", 403),
])
def test_bad_paths(make_gateway, path, status):
    gw = make_gateway()
    assert request(gw, "PUT" if "budget" in path else "POST", path, {})[0] == status


def test_admin_socket_permissions(make_gateway):
    gw = make_gateway()
    assert oct(os.stat(gw.socket_path).st_mode & 0o777) == "0o660"
