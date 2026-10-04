import json
import threading
import time

import pytest

from agentos_services.store import BudgetRefused
from conftest import request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"


def big(out_tokens=100_000):
    # Estimated at 100k output tokens * $15/M = $1.50; it really costs the same
    return {"model": "claude-test", "max_tokens": out_tokens, "messages": [{"role": "user", "content": "hi"}],
            "mock_tokens": {"input_tokens": 0, "output_tokens": out_tokens}}


def test_concurrent_requests_cannot_overshoot_the_budget(make_gateway, upstream, store):
    gw = make_gateway(limits={"max_requests_per_minute": 0, "loop_detection": False}, budget={"default_daily_usd": 5.0})
    upstream.delay = 0.4          # every request is in flight at once
    results = []

    def go():
        results.append(request(gw, "POST", ANTHROPIC, big())[0])

    threads = [threading.Thread(target=go) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    # $1.50 each: three fit under $5, the other seven are refused up front
    assert sorted(results) == [200] * 3 + [402] * 7
    assert len(upstream.requests) == 3
    assert store.spend("a1") == pytest.approx(4.5)
    assert store.reserved("a1") == 0 and store.reserved() == 0


def test_global_budget_is_reserved_across_agents(make_gateway, upstream, store):
    gw = make_gateway(limits={"max_requests_per_minute": 0, "loop_detection": False}, budget={"global_daily_usd": 4.0})
    upstream.delay = 0.4
    results = []

    def go(n):
        results.append(request(gw, "POST", "/agent/ag%d/anthropic/v1/messages" % n, big())[0])

    threads = [threading.Thread(target=go, args=(i,)) for i in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [200] * 2 + [402] * 4
    assert store.global_spend() == pytest.approx(3.0)


def test_refusal_message_distinguishes_reservation_from_exhaustion(make_gateway):
    gw = make_gateway(budget={"default_daily_usd": 1.0})
    status, _, body = request(gw, "POST", ANTHROPIC, big())
    assert status == 402
    assert "cannot cover" in json.loads(body)["error"]["message"]


def test_reservation_released_after_streamed_response(make_gateway, store):
    gw = make_gateway()
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test", "stream": True, "max_tokens": 100_000, "messages": [{"role": "user", "content": "hi"}]})[0] == 200
    assert store.reserved("a1") == 0
    assert store.spend("a1") > 0


def test_gateway_renews_hold_for_long_running_request(make_gateway, upstream, store):
    gw = make_gateway(limits={"max_requests_per_minute": 0, "loop_detection": False})
    upstream.delay = 0.8
    reserve = store.reserve

    def short_hold(agent, usd, agent_limit, global_limit, hold_sec=900):
        return reserve(agent, usd, agent_limit, global_limit, hold_sec=0.3)

    gw.store.reserve = short_hold
    results = []
    request_thread = threading.Thread(target=lambda: results.append(
        request(gw, "POST", ANTHROPIC, big())[0]))
    request_thread.start()
    time.sleep(0.45)
    assert store.reserved("a1") > 0
    request_thread.join(3)
    assert not request_thread.is_alive() and results == [200]
    assert store.reserved("a1") == 0


def test_reservation_released_after_upstream_error(make_gateway, upstream, store):
    gw = make_gateway()
    upstream.fail_status = 500
    assert request(gw, "POST", ANTHROPIC, big())[0] == 500
    assert store.reserved("a1") == 0
    assert store.spend("a1") == 0


def test_reservation_released_when_upstream_unreachable(make_gateway, store):
    gw = make_gateway()
    gw.cfg["providers"]["anthropic"]["base_url"] = "http://127.0.0.1:9"
    assert request(gw, "POST", ANTHROPIC, big())[0] == 502
    assert store.reserved("a1") == 0


def test_reservation_can_be_disabled(make_gateway):
    gw = make_gateway(budget={"default_daily_usd": 1.0, "reserve": False})
    assert request(gw, "POST", ANTHROPIC, big())[0] == 200


def test_stale_reservations_expire(store):
    now = [1000.0]
    store.clock = lambda: now[0]
    held = store.reserve("a1", 4.0, 5.0, 100.0, hold_sec=60)
    with pytest.raises(BudgetRefused):
        store.reserve("a1", 2.0, 5.0, 100.0)
    now[0] += 120                       # the holder died; its hold lapses
    store.reserve("a1", 2.0, 5.0, 100.0)
    assert store.reserved("a1") == 2.0
    held.release()


def test_live_reservation_can_be_renewed(store):
    now = [1000.0]
    store.clock = lambda: now[0]
    held = store.reserve("a1", 4.0, 5.0, 100.0, hold_sec=10)
    now[0] += 8
    assert held.renew()
    now[0] += 5
    assert store.reserved("a1") == 4.0
    held.release()
    assert not held.renew()


def test_input_size_is_part_of_the_estimate(make_gateway):
    gw = make_gateway(budget={"default_daily_usd": 1.0})
    # ~2M bytes of prompt = ~500k tokens * $3/M = $1.5
    body = {"model": "claude-test", "max_tokens": 1,
            "messages": [{"role": "user", "content": "x" * 2_000_000}]}
    assert request(gw, "POST", ANTHROPIC, body)[0] == 402
