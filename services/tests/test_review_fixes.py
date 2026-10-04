import json
import time

import pytest

from agentos_services.loops import fingerprint
from agentos_services.routing import Router
from agentos_services import config as configmod
from agentos_services.store import BudgetRefused
from agentos_services.usage import Pricing, apply_output_cap
from conftest import PRICING, request

ANTHROPIC = "/agent/a1/anthropic/v1/messages"
OPENAI = "/agent/f1/openai/v1/chat/completions"
HASH_A = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
HASH_B = "b1b2c3d4e5f60718293a4b5c6d7e8f9012345678"


# ── loops: tool arguments are not scrubbed ─────────────────────────────
def test_tool_argument_ids_stay_distinct():
    def anthropic(h):
        return {"messages": [{"role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_abcdefgh1234", "name": "git", "input": {"cmd": "git show " + h}}]}]}

    def openai(h):
        return {"messages": [{"role": "assistant", "tool_calls": [
            {"id": "call_abcdefgh1234", "type": "function",
             "function": {"name": "git", "arguments": json.dumps({"rev": h})}}]}]}

    def gemini(h):
        return {"contents": [{"role": "model", "parts": [{"functionCall": {"name": "git", "args": {"rev": h}}}]}]}

    for build in (anthropic, openai, gemini):
        assert fingerprint(build(HASH_A)) != fingerprint(build(HASH_B))
        assert fingerprint(build(HASH_A)) == fingerprint(build(HASH_A))
    # outside tool arguments ids are still ignored, including the call id itself
    text = lambda h: {"messages": [{"role": "user", "content": "built " + h}]}
    assert fingerprint(text(HASH_A)) == fingerprint(text(HASH_B))
    a, b = openai(HASH_A), openai(HASH_A)
    b["messages"][0]["tool_calls"][0]["id"] = "call_zzzzzzzz9999"
    assert fingerprint(a) == fingerprint(b)


# ── routing: unreachable targets are never selected ────────────────────
def _router(**kw):
    cfg = configmod.load("/nonexistent")["routing"]
    cfg.update(kw)
    return Router(cfg, Pricing(PRICING), {"local": {"api": "openai-compatible"}})


def test_router_skips_unreachable_targets():
    r = _router(strategy="cheapest", groups=[["claude-test", "llama3.1", "claude-cheap"]],
                targets={"llama3.1": "local"})
    assert r.route("a1", "anthropic", "claude-test")[0] == "llama3.1"          # no policy: as before
    assert r.route("a1", "anthropic", "claude-test", reachable=lambda p: False)[0] == "claude-cheap"
    r = _router(rewrites={"claude-test": "llama3.1"}, targets={"llama3.1": "local"})
    assert r.route("a1", "anthropic", "claude-test", reachable=lambda p: False) == ("claude-test", None)
    r = _router(downgrade={"threshold_pct": 10, "models": {"anthropic": "llama3.1"}}, targets={"llama3.1": "local"})
    assert r.route("a1", "anthropic", "claude-test", 50, reachable=lambda p: False) == ("claude-test", None)


def test_gateway_does_not_rewrite_to_unreachable_model(make_gateway, upstream):
    local = {"local": {"base_url": upstream.url, "api": "openai-compatible"}}
    gw = make_gateway(
        providers=_provs(upstream, local),
        routing={"strategy": "cheapest", "groups": [["claude-test", "llama3.1"]], "targets": {"llama3.1": "local"}})
    request(gw, "POST", ANTHROPIC, {"model": "claude-test", "max_tokens": 5, "messages": []})
    assert upstream.requests[-1]["body"]["model"] == "claude-test"


def _provs(upstream, extra, tmp=None):
    base = {"anthropic": {"base_url": upstream.url, "api": "anthropic"},
            "openai": {"base_url": upstream.url, "api": "openai"}}
    base.update(extra)
    return base


# ── usage: default output cap and candidate count ──────────────────────
def test_apply_output_cap_uses_the_providers_field():
    p = {"messages": []}
    assert apply_output_cap(p, "anthropic", "v1/messages", 99) and p["max_tokens"] == 99
    p = {"messages": []}
    assert apply_output_cap(p, "openai", "v1/chat/completions", 99) and p["max_completion_tokens"] == 99
    p = {"messages": []}
    assert apply_output_cap(p, "openai", "openai/deployments/x/chat/completions", 99, "2023-05-15")
    assert p["max_tokens"] == 99
    p = {"input": "hi"}
    assert apply_output_cap(p, "openai", "v1/responses", 99) and p["max_output_tokens"] == 99
    p = {"contents": []}
    assert apply_output_cap(p, "gemini", "v1beta/models/g:generateContent", 99)
    assert p["generationConfig"] == {"maxOutputTokens": 99}
    # a client limit is kept, and so are embeddings
    for payload, api, path in (({"messages": [], "max_tokens": 5}, "openai", "v1/chat/completions"),
                               ({"messages": [], "max_completion_tokens": 5}, "openai", "v1/chat/completions"),
                               ({"contents": [], "generationConfig": {"maxOutputTokens": 5}}, "gemini", "m:generateContent"),
                               ({"input": "x"}, "openai", "v1/embeddings")):
        before = json.dumps(payload)
        assert not apply_output_cap(payload, api, path, 99) and json.dumps(payload) == before


def test_gateway_forwards_the_cap_it_reserved_against(make_gateway, upstream, store):
    gw = make_gateway(budget={"default_max_tokens": 321})
    request(gw, "POST", ANTHROPIC, {"model": "claude-test", "messages": [{"role": "user", "content": "x"}]})
    assert upstream.requests[-1]["body"]["max_tokens"] == 321
    request(gw, "POST", OPENAI, {"model": "gpt-test", "messages": [{"role": "user", "content": "x"}]})
    assert upstream.requests[-1]["body"]["max_completion_tokens"] == 321
    request(gw, "POST", OPENAI, {"model": "gpt-test", "max_tokens": 9, "messages": [{"role": "user", "content": "x"}]})
    body = upstream.requests[-1]["body"]
    assert body["max_tokens"] == 9 and "max_completion_tokens" not in body


# ── providers: credentials and keys ────────────────────────────────────
CREDS = {"Authorization": "Bearer sk-user", "x-api-key": "k1", "api-key": "k2", "x-goog-api-key": "k3"}


def _seen(upstream):
    return {k.lower(): v for k, v in upstream.requests[-1]["headers"].items()}


def test_openai_compatible_never_receives_caller_credentials(make_gateway, upstream, tmp_path):
    local = {"local": {"base_url": upstream.url, "api": "openai-compatible"}}
    gw = make_gateway(providers=_provs(upstream, local))
    request(gw, "POST", "/agent/l1/local/v1/chat/completions", {"model": "m", "messages": []}, CREDS)
    seen = _seen(upstream)
    assert not {"authorization", "x-api-key", "api-key", "x-goog-api-key"} & set(seen)
    key = tmp_path / "local.key"
    key.write_text("sk-local\n")
    local["local"]["key_file"] = str(key)
    gw = make_gateway(providers=_provs(upstream, local))
    request(gw, "POST", "/agent/l1/local/v1/chat/completions", {"model": "m", "messages": []}, CREDS)
    seen = _seen(upstream)
    assert seen["authorization"] == "Bearer sk-local"
    assert not {"x-api-key", "api-key", "x-goog-api-key"} & set(seen)


def _fallback_gw(make_gateway, upstream, upstream2, tmp_path, primary, backup, fallbacks, **cfg):
    key = tmp_path / "backup.key"
    key.write_text("sk-backup\n")
    provs = {"primary": dict({"base_url": upstream.url, "fallbacks": fallbacks}, **primary),
             "backup": dict({"base_url": upstream2.url, "key_file": str(key)}, **backup)}
    return make_gateway(providers=provs, **cfg)


def test_fallback_drops_the_gemini_key_query(make_gateway, upstream, upstream2, tmp_path):
    gw = _fallback_gw(make_gateway, upstream, upstream2, tmp_path, {"api": "gemini"}, {"api": "gemini"}, ["backup"])
    upstream.fail_status = 500
    path = "/agent/g1/primary/v1beta/models/gemini-test:generateContent?key=user-secret&alt=json"
    status = request(gw, "POST", path, {"contents": [{"parts": [{"text": "hi"}]}]})[0]
    assert status == 200
    assert "key=user-secret" in upstream.requests[-1]["path"]               # primary: passthrough
    assert "key=" not in upstream2.requests[-1]["path"] and "alt=json" in upstream2.requests[-1]["path"]
    assert _seen(upstream2)["x-goog-api-key"] == "sk-backup"


# ── fallbacks are charged for what they may cost ───────────────────────
def _log(tmp_path, agent):
    return json.loads((tmp_path / "logs" / (agent + ".log")).read_text().splitlines()[-1])


def test_fallback_refused_when_budget_cannot_cover_it(make_gateway, upstream, upstream2, store, tmp_path):
    # a free local primary, a paid fallback
    gw = _fallback_gw(make_gateway, upstream, upstream2, tmp_path, {"api": "openai-compatible"}, {"api": "openai"},
                      ["backup"], budget={"default_daily_usd": 0.001})
    upstream.fail_status = 500
    body = {"model": "gpt-test", "messages": [{"role": "user", "content": "hi"}]}     # cap 4096 -> ~$0.008
    assert request(gw, "POST", "/agent/f1/primary/v1/chat/completions", body)[0] == 500
    assert upstream2.requests == []
    assert _log(tmp_path, "f1")["fallbacks_failed"][-1]["provider"] == "backup"
    assert store.reserved("f1") == 0


def test_fallback_to_pricier_model_is_refused_but_the_cheap_one_runs(make_gateway, upstream, upstream2, store, tmp_path):
    chain = [{"provider": "backup", "model": "claude-pricey"}, "backup"]
    gw = _fallback_gw(make_gateway, upstream, upstream2, tmp_path, {"api": "openai"}, {"api": "openai"}, chain,
                      budget={"default_daily_usd": 0.005})
    upstream.fail_status = 503
    body = {"model": "gpt-test", "max_tokens": 100, "messages": [{"role": "user", "content": "hi"}]}
    assert request(gw, "POST", "/agent/f2/primary/v1/chat/completions", body)[0] == 200
    assert upstream2.requests[-1]["body"]["model"] == "gpt-test"       # $0.01 pricey fallback skipped, same model used
    assert len(upstream2.requests) == 1
    assert store.reserved("f2") == 0 and store.spend("f2") > 0


def test_fallback_hold_grows_and_the_free_primary_is_capped_for_the_paid_fallback(
        make_gateway, upstream, upstream2, store, tmp_path):
    gw = _fallback_gw(make_gateway, upstream, upstream2, tmp_path, {"api": "openai-compatible"}, {"api": "openai"},
                      ["backup"], budget={"default_max_tokens": 77})
    upstream.fail_status = 500
    body = {"model": "gpt-test", "messages": [{"role": "user", "content": "hi"}]}
    assert request(gw, "POST", "/agent/f3/primary/v1/chat/completions", body)[0] == 200
    assert "max_completion_tokens" not in upstream.requests[-1]["body"]        # free: not capped
    assert upstream2.requests[-1]["body"]["max_completion_tokens"] == 77       # paid: capped
    assert store.reserved("f3") == 0


# ── reservation lease ──────────────────────────────────────────────────
def test_grow_checks_the_budget_atomically(store):
    held = store.reserve("a1", 1.0, 5.0, 100.0)
    other = store.reserve("a1", 3.0, 5.0, 100.0)
    with pytest.raises(BudgetRefused):
        store.grow(held, 2.5, 5.0, 100.0)               # 3.0 + 2.5 > 5
    assert store.reserved("a1") == 4.0                  # untouched by the refusal
    store.grow(held, 2.0, 5.0, 100.0)                   # 3.0 + 2.0 fits; its own $1 is not counted twice
    assert store.reserved("a1") == 5.0
    held.release()
    other.release()
    assert store.reserved("a1") == 0
    free = store.reserve("a1", 0.0, 5.0, 100.0)         # a zero-cost request can grow too
    store.grow(free, 1.0, 5.0, 100.0)
    assert store.reserved("a1") == 1.0
    free.release()
    assert store.reserved() == 0


def test_renewed_hold_outlives_its_first_deadline(store):
    now = [1000.0]
    store.clock = lambda: now[0]
    held = store.reserve("a1", 4.0, 5.0, 100.0, hold_sec=60)
    now[0] += 50
    held.renew()
    now[0] += 50                                        # past the original deadline
    assert store.reserved("a1") == 4.0
    with pytest.raises(BudgetRefused):
        store.reserve("a1", 2.0, 5.0, 100.0)
    now[0] += 100                                       # no more renewals: it lapses
    assert store.reserved("a1") == 0


def test_streaming_request_renews_its_hold(make_gateway, store):
    gw = make_gateway()
    calls = []
    original = store.renew
    store.renew = lambda resv: (calls.append(resv.rid), original(resv))[1]
    ticks = [time.time()]

    def clock():
        ticks[0] += 1000                                # every read looks like a long wait
        return ticks[0]

    gw.clock = clock
    body = {"model": "claude-test", "stream": True, "max_tokens": 1000, "messages": [{"role": "user", "content": "hi"}]}
    assert request(gw, "POST", ANTHROPIC, body)[0] == 200
    assert len(calls) >= 2
    assert store.reserved("a1") == 0


def test_lease_covers_the_longest_provider_timeout(make_gateway, upstream):
    gw = make_gateway()
    assert gw.lease_sec() == gw.cfg["gateway"]["upstream_timeout_sec"] + 60
    gw.cfg["providers"]["openai"]["timeout_sec"] = 5000
    assert gw.lease_sec() == 5060
