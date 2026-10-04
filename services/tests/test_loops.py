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


def test_fingerprint_ignores_ids_and_timestamps():
    def msgs(call, stamp, uid):
        return {"messages": [
            {"role": "assistant", "content": [{"type": "tool_use", "id": call, "name": "bash",
                                               "input": {"command": "make test"}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call,
                                          "content": "FAILED at %s (run %s) request_id=%s" % (stamp, uid, call)}]},
        ]}
    a = msgs("toolu_01A2b3C4d5E6f7G8", "2025-01-02T03:04:05.123Z", "3f2504e0-4f89-11d3-9a0c-0305e82c3301")
    b = msgs("toolu_09Z8y7X6w5V4u3T2", "2025-06-30 23:59:01+02:00", "9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d")
    assert fingerprint(a, 2) == fingerprint(b, 2)
    assert fingerprint(msgs("toolu_01A2b3C4d5E6f7G8", "x", "y"), 2) != fingerprint(a, 2)
    # a real difference still matters, and so do ids that are arguments
    c = {"messages": [{"role": "user", "content": "get issue #5 at 10:00:01"}]}
    d = {"messages": [{"role": "user", "content": "get issue #6 at 10:00:02"}]}
    assert fingerprint(c) != fingerprint(d)
    assert fingerprint({"messages": [{"role": "user", "content": "id", "n": 1}]}) != \
        fingerprint({"messages": [{"role": "user", "content": "id", "n": 2}]})
    # Gemini contents are fingerprinted too
    assert fingerprint({"contents": [{"parts": [{"text": "hi"}]}]}) is not None


def test_alternation_run():
    from agentos_services.loops import alternation_run
    assert alternation_run([]) == 0 and alternation_run(["a"]) == 0
    assert alternation_run(["a", "a", "a"]) == 0               # a plain repeat is not an alternation
    assert alternation_run(["a", "b"]) == 2
    assert alternation_run(["x", "a", "b", "a", "b"]) == 4
    assert alternation_run(["a", "b", "a", "b", "a"]) == 5
    assert alternation_run(["a", "b", "a", "c"]) == 2
    assert alternation_run(["a", "b", "c", "a", "b", "c"]) == 2


def test_volatile_ids_do_not_hide_a_repeat(make_gateway):
    gw = make_gateway(limits={"loop_repeat_threshold": 3, "max_requests_per_minute": 0})
    for n, expect in enumerate((200, 200, 429)):
        body = {"model": "claude-test", "mock_tokens": {"input_tokens": 1}, "messages": [
            {"role": "user", "content": "retry at 2025-01-0%dT10:00:0%dZ id toolu_0123456789ab%d" % (n + 1, n, n)}]}
        assert request(gw, "POST", ANTHROPIC, body)[0] == expect


def test_alternation_is_detected_and_reset(make_gateway, store, events):
    gw = make_gateway(limits={"loop_alternation_length": 6, "max_requests_per_minute": 0})
    a, b = turn("run the tests"), turn("fix the test")
    codes = [request(gw, "POST", ANTHROPIC, m)[0] for m in (a, b, a, b, a, b)]
    assert codes == [200, 200, 200, 200, 200, 429]
    assert request(gw, "POST", ANTHROPIC, a)[0] == 429
    got = [e for e in events.drain() if e["type"] == "loop_detected"]
    assert len(got) == 1 and got[0]["kind"] == "alternation" and got[0]["count"] == 6
    # a third request breaks the pattern
    assert request(gw, "POST", ANTHROPIC, turn("something new"))[0] == 200
    assert request(gw, "POST", ANTHROPIC, a)[0] == 200
    # an operator reset clears it as well
    for m in (b, a, b, a):
        request(gw, "POST", ANTHROPIC, m)
    assert request(gw, "DELETE", "/_agentos/loop/a1", admin=True)[0] == 200
    assert request(gw, "POST", ANTHROPIC, b)[0] == 200


def test_alternation_window_slides(make_gateway, store):
    now = [1000.0]
    store.clock = lambda: now[0]
    gw = make_gateway(limits={"loop_alternation_length": 4, "loop_window_sec": 60, "max_requests_per_minute": 0})
    a, b = turn("a"), turn("b")
    for m in (a, b, a):
        assert request(gw, "POST", ANTHROPIC, m)[0] == 200
        now[0] += 25                                   # the oldest requests age out of the window
    assert request(gw, "POST", ANTHROPIC, b)[0] == 200


def test_alternation_can_be_disabled(make_gateway):
    gw = make_gateway(limits={"loop_alternation_length": 0, "max_requests_per_minute": 0})
    for m in (turn("a"), turn("b")) * 6:
        assert request(gw, "POST", ANTHROPIC, m)[0] == 200
