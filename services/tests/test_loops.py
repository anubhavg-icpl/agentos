import json

import pytest

from agentos_services.loops import fingerprint
from conftest import request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"


def turn(text, model="claude-test"):
    return {"model": model, "mock_tokens": {"input_tokens": 1},
            "messages": [{"role": "user", "content": text}]}


def test_fingerprint_uses_tail_and_ignores_cache_markers():
    msgs = [{"role": "user", "content": "a"}, {"role": "assistant", "content": "b"},
            {"role": "user", "content": "c"}]
    base = fingerprint({"messages": msgs}, 2)
    # earlier history does not matter, a different tail does
    assert fingerprint({"messages": [{"role": "user", "content": "zzz"}] + msgs}, 2) == base
    assert fingerprint({"messages": msgs[:2]}, 2) != base
    # cache_control markers and surrounding whitespace are not part of the request
    plain = [{"role": "user", "content": [{"type": "text", "text": "c"}]}]
    marked = [{"role": "user", "content": [{"type": "text", "text": " c ", "cache_control": {"type": "ephemeral"}}]}]
    assert fingerprint({"messages": plain}) == fingerprint({"messages": marked})
    assert fingerprint({"input": "hello"}) == fingerprint({"input": [" hello "]})
    assert fingerprint({"model": "x"}) is None
    assert fingerprint({"messages": []}) is None
    assert fingerprint([1, 2]) is None


def test_loop_is_refused_after_k_repeats(make_gateway, store, events):
    gw = make_gateway(limits={"loop_repeat_threshold": 3})
    same = turn("please fix the build")
    assert request(gw, "POST", ANTHROPIC, same)[0] == 200
    assert request(gw, "POST", ANTHROPIC, same)[0] == 200
    status, headers, body = request(gw, "POST", ANTHROPIC, same)
    assert status == 429
    assert json.loads(body)["error"]["type"] == "loop_detected"
    assert "Retry-After" in headers
    # still refused, but the event fires once
    assert request(gw, "POST", ANTHROPIC, same)[0] == 429
    got = [e for e in events.drain() if e["type"] == "loop_detected"]
    assert len(got) == 1 and got[0]["agent"] == "a1" and got[0]["count"] == 3
    # a different request breaks the run
    assert request(gw, "POST", ANTHROPIC, turn("something else"))[0] == 200
    assert request(gw, "POST", ANTHROPIC, same)[0] == 200
    # refused requests never reached the provider or cost anything
    assert store.spend("a1") == pytest.approx(4 * 0.000003)


def test_growing_conversation_is_not_a_loop(make_gateway):
    gw = make_gateway(limits={"loop_repeat_threshold": 2})
    for i in range(5):
        assert request(gw, "POST", ANTHROPIC, turn("step %d" % i))[0] == 200


def test_other_agents_and_disabled(make_gateway):
    gw = make_gateway(limits={"loop_repeat_threshold": 2})
    same = turn("x")
    request(gw, "POST", ANTHROPIC, same)
    assert request(gw, "POST", ANTHROPIC, same)[0] == 429
    assert request(gw, "POST", "/agent/other/anthropic/v1/messages", same)[0] == 200

    gw2 = make_gateway(limits={"loop_repeat_threshold": 2, "loop_detection": False})
    for _ in range(4):
        assert request(gw2, "POST", ANTHROPIC, same)[0] == 200


def test_window_expiry_and_admin_reset(make_gateway, store):
    now = [1000.0]
    store.clock = lambda: now[0]
    gw = make_gateway(limits={"loop_repeat_threshold": 3, "loop_window_sec": 60, "max_requests_per_minute": 0})
    same = turn("x")
    request(gw, "POST", ANTHROPIC, same)
    now[0] += 30
    request(gw, "POST", ANTHROPIC, same)
    now[0] += 40          # 70s after the first: the run restarts
    assert request(gw, "POST", ANTHROPIC, same)[0] == 200
    now[0] += 1
    request(gw, "POST", ANTHROPIC, same)
    assert request(gw, "POST", ANTHROPIC, same)[0] == 429
    assert request(gw, "DELETE", "/_agentos/loop/a1")[0] == 403          # admin socket only
    assert request(gw, "DELETE", "/_agentos/loop/a1", admin=True)[0] == 200
    assert request(gw, "POST", ANTHROPIC, same)[0] == 200


def test_openai_responses_input_is_fingerprinted(make_gateway):
    gw = make_gateway(limits={"loop_repeat_threshold": 2})
    body = {"model": "gpt-test", "input": [{"role": "user", "content": "go"}]}
    path = "/agent/o1/openai/v1/chat/completions"
    assert request(gw, "POST", path, body)[0] == 200
    assert request(gw, "POST", path, body)[0] == 429
