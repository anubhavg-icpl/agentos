import json

import pytest

from conftest import request

OPENAI = "/agent/f1/openai/v1/chat/completions"
BODY = {"model": "gpt-test", "messages": [{"role": "user", "content": "hi"}]}


@pytest.fixture
def gw(make_gateway, upstream, upstream2, tmp_path):
    key = tmp_path / "backup.key"
    key.write_text("sk-backup\n")

    def make(fallbacks, primary_extra=None, budget=None, **backup):
        provs = {
            "openai": dict({"base_url": upstream.url, "api": "openai", "fallbacks": fallbacks}, **(primary_extra or {})),
            "backup": dict({"base_url": upstream2.url, "api": "openai", "key_file": str(key)}, **backup),
            "local": {"base_url": upstream2.url, "api": "openai-compatible"},
        }
        gw = make_gateway(providers=provs, **({"budget": budget} if budget is not None else {}))
        return gw
    return make


@pytest.mark.parametrize("status", [500, 502, 503, 429])
def test_falls_back_on_5xx_and_429(gw, upstream, upstream2, store, status):
    g = gw(["backup"])
    upstream.fail_status = status
    code, _, body = request(g, "POST", OPENAI, BODY, {"Authorization": "Bearer sk-user"})
    assert code == 200 and json.loads(body)["model"] == "gpt-test"
    assert len(upstream.requests) == 1 and len(upstream2.requests) == 1
    # the user's key for the first provider is never sent to the backup, whose own key is used
    assert upstream2.requests[-1]["headers"]["Authorization"] == "Bearer sk-backup"
    assert store.spend("f1") > 0
    assert store.snapshot()["agents"]["f1"]["requests"] == {"2xx": 1}


def test_fallback_is_logged_and_does_not_trip_the_breaker(gw, upstream, store, tmp_path):
    g = gw(["backup"])
    g.cfg["limits"]["max_consecutive_failures"] = 1
    upstream.fail_status = 503
    for _ in range(3):
        assert request(g, "POST", OPENAI, BODY)[0] == 200
    entry = json.loads((tmp_path / "logs" / "f1.log").read_text().splitlines()[-1])
    assert entry["provider"] == "backup" and entry["fallback_provider"] == "backup"
    assert entry["fallbacks_failed"] == [{"provider": "openai", "status": 503}]


def test_no_fallback_for_client_errors_or_success(gw, upstream, upstream2):
    g = gw(["backup"])
    assert request(g, "POST", OPENAI, BODY)[0] == 200
    upstream.fail_status = 400
    assert request(g, "POST", OPENAI, BODY)[0] == 400
    assert upstream2.requests == []


def test_all_attempts_fail_returns_the_last_answer(gw, upstream, upstream2):
    g = gw(["backup"])
    upstream.fail_status = 500
    upstream2.fail_status = 429
    assert request(g, "POST", OPENAI, BODY)[0] == 429
    assert len(upstream.requests) == 1 and len(upstream2.requests) == 1


def test_connection_failure_falls_back(gw, upstream2):
    g = gw(["backup"])
    g.cfg["providers"]["openai"]["base_url"] = "http://127.0.0.1:9"
    assert request(g, "POST", OPENAI, BODY)[0] == 200
    assert len(upstream2.requests) == 1


def test_timeout_before_first_byte_falls_back(gw, upstream, upstream2):
    g = gw(["backup"], primary_extra={"timeout_sec": 0.3})
    upstream.delay = 1.5
    assert request(g, "POST", OPENAI, BODY)[0] == 200
    assert len(upstream2.requests) == 1


def test_unreachable_everywhere_is_502(gw):
    g = gw(["backup"])
    g.cfg["providers"]["openai"]["base_url"] = "http://127.0.0.1:9"
    g.cfg["providers"]["backup"]["base_url"] = "http://127.0.0.1:9"
    assert request(g, "POST", OPENAI, BODY)[0] == 502


def test_fallback_can_change_the_model_and_chain(gw, upstream, upstream2):
    g = gw([{"provider": "backup", "model": "gpt-cheap"}, "local"])
    upstream.fail_status = 500
    upstream2.fail_status = 500          # backup fails too; local (same mock) would too
    assert request(g, "POST", OPENAI, BODY)[0] == 500
    assert [r["body"]["model"] for r in upstream2.requests] == ["gpt-cheap", "gpt-test"]
    assert upstream2.requests[-1]["headers"].get("Authorization") is None   # keyless local server


def test_streamed_request_falls_back_before_first_byte(gw, upstream, upstream2, store):
    g = gw(["backup"])
    upstream.fail_status = 503
    code, headers, body = request(g, "POST", OPENAI, dict(BODY, stream=True))
    assert code == 200 and headers["Content-Type"] == "text/event-stream"
    assert upstream2.requests[-1]["body"]["stream_options"] == {"include_usage": True}
    assert store.spend("f1") == pytest.approx((200 * 1 + 100 * 2 + 100 * 0.5) / 1e6)


def test_incompatible_or_keyless_fallbacks_are_ignored(gw, upstream, upstream2):
    g = gw(["nosuch", "anthropic", "openai"])
    upstream.fail_status = 500
    assert request(g, "POST", OPENAI, BODY)[0] == 500
    assert upstream2.requests == []
    g2 = gw(["backup"])
    g2.cfg["providers"]["backup"].pop("key_file")      # no key and not a local server
    assert request(g2, "POST", OPENAI, BODY)[0] == 500
    assert upstream2.requests == []


def test_no_fallbacks_configured_is_unchanged(make_gateway, upstream):
    g = make_gateway()
    upstream.fail_status = 500
    assert request(g, "POST", OPENAI, BODY)[0] == 500
    assert len(upstream.requests) == 1


def test_paid_fallback_cost_is_reserved_before_zero_cost_primary(gw, upstream, upstream2, store):
    g = gw([{"provider": "backup", "model": "claude-pricey"}],
           primary_extra={"api": "openai-compatible"},
           budget={"default_daily_usd": 0.05})
    body = dict(BODY, max_tokens=1000)
    status, _, _ = request(g, "POST", "/agent/f1/openai/v1/chat/completions", body)
    assert status == 402
    assert upstream.requests == [] and upstream2.requests == []
    assert store.reserved("f1") == 0
