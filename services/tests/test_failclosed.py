import hashlib
import json

import pytest
import redis

from conftest import request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"


class BrokenRedis:
    """Every command fails, like a Redis that went away."""

    def __getattr__(self, name):
        def fail(*args, **kwargs):
            raise redis.ConnectionError("redis is down")
        return fail

    def pipeline(self, *args, **kwargs):
        return self

    def transaction(self, *args, **kwargs):
        raise redis.ConnectionError("redis is down")


def test_redis_outage_refuses_traffic_unmetered(make_gateway, upstream, store):
    gw = make_gateway()
    good = store.r
    store.r = BrokenRedis()
    status, headers, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test", "messages": []})
    assert status == 503
    assert json.loads(body)["error"]["type"] == "store_unavailable"
    assert int(headers["Retry-After"]) > 0
    assert upstream.requests == []                       # nothing reached the provider
    store.r = good                                       # and it recovers
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 200


def test_redis_outage_during_authentication(make_gateway, upstream, store):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    digest = hashlib.sha256(b"tok").hexdigest()
    request(gw, "PUT", "/_nestlo/agents/a1", {"token_sha256": digest}, admin=True)
    store.r = BrokenRedis()
    assert request(gw, "POST", "/agent/a1:tok/anthropic/v1/messages", {"model": "claude-test"})[0] == 503
    assert upstream.requests == []


def test_budget_reservation_failing_alone_refuses(make_gateway, upstream, store, monkeypatch):
    gw = make_gateway()

    def boom(*args, **kwargs):
        raise redis.TimeoutError("slow")

    monkeypatch.setattr(store, "reserve", boom)
    assert request(gw, "POST", ANTHROPIC, {"model": "claude-test"})[0] == 503
    assert upstream.requests == []


def test_accounting_failure_after_response_does_not_break_the_reply(make_gateway, store, monkeypatch):
    gw = make_gateway()

    def boom(*args, **kwargs):
        raise redis.ConnectionError("down")

    monkeypatch.setattr(store, "record", boom)
    status, _, body = request(gw, "POST", ANTHROPIC, {"model": "claude-test"})
    assert status == 200 and json.loads(body)["content"][0]["text"] == "hi"


def test_health_needs_no_redis(make_gateway, store):
    gw = make_gateway()
    store.r = BrokenRedis()
    assert request(gw, "GET", "/_nestlo/health")[0] == 200
    assert request(gw, "GET", "/_nestlo/spend")[0] == 503
