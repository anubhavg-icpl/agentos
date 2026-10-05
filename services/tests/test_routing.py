import json

import pytest

from nestlo_services import config as configmod
from nestlo_services.routing import Router
from nestlo_services.usage import Pricing
from conftest import PRICING, request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"


def router(**overrides):
    cfg = configmod.load("/nonexistent")["routing"]
    cfg.update(overrides)
    return Router(cfg, Pricing(PRICING))


def test_static_rewrites_and_agent_prefixes():
    r = router(rewrites={"claude-pricey": "claude-mid"},
               agents={"ci-": {"claude-pricey": "claude-cheap"}, "ci-big": {"claude-pricey": "claude-mid"}})
    assert r.route("a1", "anthropic", "claude-pricey") == ("claude-mid", "rewrite")
    assert r.route("ci-1", "anthropic", "claude-pricey") == ("claude-cheap", "rewrite:agent:ci-")
    assert r.route("ci-big-2", "anthropic", "claude-pricey")[0] == "claude-mid"     # longest prefix wins
    assert r.route("a1", "anthropic", "claude-mid") == ("claude-mid", None)
    assert r.route("a1", "anthropic", None) == (None, None)


def test_never_routes_across_vendors():
    r = router(rewrites={"claude-pricey": "gpt-cheap"})
    assert r.route("a1", "anthropic", "claude-pricey") == ("claude-pricey", None)
    r = router(strategy="cheapest", groups=[["claude-pricey", "gpt-cheap", "claude-cheap"]])
    assert r.route("a1", "anthropic", "claude-pricey")[0] == "claude-cheap"
    r = router(downgrade={"threshold_pct": 10, "models": {"anthropic": "gpt-cheap"}})
    assert r.route("a1", "anthropic", "claude-pricey", 50)[0] == "claude-pricey"


def test_cheapest_group():
    r = router(strategy="cheapest", groups=[["claude-pricey", "claude-mid", "claude-cheap"]])
    assert r.route("a1", "anthropic", "claude-mid") == ("claude-cheap", "cheapest")
    assert r.route("a1", "anthropic", "claude-cheap")[1] is None
    assert r.route("a1", "anthropic", "unlisted")[1] is None
    # groups are ignored unless the strategy asks for them
    assert router(groups=[["claude-mid", "claude-cheap"]]).route("a1", "anthropic", "claude-mid")[1] is None


def test_budget_downgrade_never_upgrades():
    r = router(downgrade={"threshold_pct": 80, "models": {"anthropic": "claude-mid"}})
    assert r.route("a1", "anthropic", "claude-pricey", 79.9)[1] is None
    assert r.route("a1", "anthropic", "claude-pricey", 80) == ("claude-mid", "downgrade:80%")
    assert r.route("a1", "anthropic", "claude-cheap", 99)[1] is None           # already cheaper
    assert r.route("a1", "openai", "gpt-cheap", 99)[1] is None                  # no rule for the provider


def test_rules_compose():
    r = router(rewrites={"claude-pricey": "claude-mid"},
               downgrade={"threshold_pct": 50, "models": {"anthropic": "claude-cheap"}})
    assert r.route("a1", "anthropic", "claude-pricey", 60) == ("claude-cheap", "rewrite,downgrade:50%")


def test_gateway_routes_prices_and_logs(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(routing={"rewrites": {"claude-pricey": "claude-cheap"}})
    body = {"model": "claude-pricey", "max_tokens": 5, "messages": [{"role": "user", "content": "hi"}]}
    status, _, resp = request(gw, "POST", ANTHROPIC, body)
    assert status == 200
    assert upstream.requests[-1]["body"]["model"] == "claude-cheap"
    assert upstream.requests[-1]["body"]["max_tokens"] == 5                      # rest untouched
    assert store.spend("a1") == pytest.approx(1.0)                              # 1M input at claude-cheap's $1
    entry = json.loads((tmp_path / "logs" / "a1.log").read_text().splitlines()[-1])
    assert entry["model"] == "claude-cheap"
    assert entry["original_model"] == "claude-pricey" and entry["routed_model"] == "claude-cheap"
    assert entry["route_reason"] == "rewrite"
    # unrouted models pass through and carry no routing fields
    request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    entry = json.loads((tmp_path / "logs" / "a1.log").read_text().splitlines()[-1])
    assert "original_model" not in entry and upstream.requests[-1]["body"]["model"] == "claude-test"


def test_gateway_budget_downgrade(make_gateway, upstream, store):
    gw = make_gateway(routing={"downgrade": {"threshold_pct": 25, "models": {"anthropic": "claude-cheap"}}})
    assert request(gw, "PUT", "/_nestlo/budget/a1", {"daily_usd": 10}, admin=True)[0] == 200
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200     # $3 = 30% of $10
    assert upstream.requests[-1]["body"]["model"] == "claude-test"                # used 0% when it arrived
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200
    assert upstream.requests[-1]["body"]["model"] == "claude-cheap"
    assert store.spend("a1") == pytest.approx(3.0 + 1.0)


def test_gateway_routing_admin_view(make_gateway):
    gw = make_gateway(routing={"strategy": "cheapest", "groups": [["claude-mid", "claude-cheap"]]})
    assert request(gw, "GET", "/_nestlo/routing")[0] == 403
    status, _, body = request(gw, "GET", "/_nestlo/routing?agent=a1&provider=anthropic&model=claude-mid", admin=True)
    view = json.loads(body)
    assert status == 200 and view["strategy"] == "cheapest"
    assert view["effective"]["routed_model"] == "claude-cheap" and view["effective"]["reason"] == "cheapest"
