import json

import pytest

from conftest import request

OPENAI = "/agent/u1/openai/v1/nousage"


def gen(**extra):
    return dict({"model": "gpt-test", "max_tokens": 1000, "messages": [{"role": "user", "content": "hi"}]}, **extra)


def test_unreadable_usage_is_charged_at_the_estimate(make_gateway, store, tmp_path):
    gw = make_gateway()
    status, _, _ = request(gw, "POST", OPENAI, gen())
    assert status == 200
    # 1000 output tokens * $2/M plus the (small) input estimate
    assert 0.002 <= store.spend("u1") < 0.0021
    assert store.unparsed() == {"openai": 1}
    entry = json.loads((tmp_path / "logs" / "u1.log").read_text().splitlines()[-1])
    assert entry["usage_estimated"] is True and entry["priced"] is False
    assert store.reserved("u1") == 0
    snap = json.loads(request(gw, "GET", "/_nestlo/spend")[2])
    assert snap["usage_unparsed"] == {"openai": 1}


def test_estimate_is_not_charged_for_errors_or_non_generations(make_gateway, upstream, store):
    gw = make_gateway()
    upstream.fail_status = 500
    request(gw, "POST", OPENAI, gen())
    upstream.fail_status = None
    request(gw, "POST", OPENAI, {"model": "gpt-test"})           # no messages/input: not a generation
    assert store.spend("u1") == 0 and store.unparsed() == {}


def test_free_provider_without_usage_costs_nothing(make_gateway, upstream, store):
    gw = make_gateway(providers={"local": {"base_url": upstream.url, "api": "openai-compatible"}})
    request(gw, "POST", "/agent/u2/local/v1/nousage", gen())
    assert store.spend("u2") == 0 and store.unparsed() == {}


def test_parsed_usage_is_not_replaced_by_the_estimate(make_gateway, store):
    gw = make_gateway()
    request(gw, "POST", "/agent/u3/openai/v1/chat/completions", gen())
    assert store.spend("u3") == pytest.approx((10 * 1 + 5 * 2) / 1e6)
    assert store.unparsed() == {}


def test_estimate_counts_without_reservation(make_gateway, store):
    gw = make_gateway(budget={"reserve": False})
    request(gw, "POST", OPENAI, gen())
    assert store.spend("u1") >= 0.002
