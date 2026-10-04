import json

import pytest

from agentos_services import config as configmod
from agentos_services.providers import adapter_for
from agentos_services.usage import UsageParser
from conftest import request


def provs(upstream, tmp_path, **extra):
    key = tmp_path / "k.key"
    key.write_text("real-key\n")
    out = {
        "gemini": {"base_url": upstream.url, "api": "gemini", "key_file": str(key)},
        "azure": {"base_url": upstream.url, "api": "azure-openai", "key_file": str(key), "api_version": "2024-10-21"},
        "local": {"base_url": upstream.url, "api": "openai-compatible"},
    }
    out.update(extra)
    return out


GEMINI = "/agent/g1/gemini/v1beta/models/gemini-test:generateContent"
ANTHROPIC = "/agent/a1/anthropic/v1/messages"


def test_gemini_key_usage_and_pricing(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path))
    status, _, body = request(gw, "POST", GEMINI, {"contents": [{"parts": [{"text": "hi"}]}]},
                              {"x-goog-api-key": "agentos-managed"})
    assert status == 200
    seen = upstream.requests[-1]
    assert seen["path"] == "/v1beta/models/gemini-test:generateContent"
    assert seen["headers"]["x-goog-api-key"] == "real-key"
    # 600 input * $1 + 400 output (candidates + thoughts) * $4 + 400 cached * $0.25
    assert store.spend("g1") == pytest.approx((600 + 1600 + 100) / 1e6)
    assert store.snapshot()["agents"]["g1"]["tokens"] == {
        "input_tokens": 600, "output_tokens": 400, "cache_read_tokens": 400}


def test_gemini_streaming_usage_and_legacy_key_param(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path))
    path = "/agent/g1/gemini/v1beta/models/gemini-test:streamGenerateContent?alt=sse&key=agentos-managed"
    status, headers, body = request(gw, "POST", path, {"contents": [{"parts": [{"text": "hi"}]}]})
    assert status == 200 and body.count(b"data: ") == 2
    seen = upstream.requests[-1]
    assert seen["path"] == "/v1beta/models/gemini-test:streamGenerateContent?alt=sse"   # placeholder dropped
    assert seen["headers"]["x-goog-api-key"] == "real-key"
    assert store.spend("g1") == pytest.approx((600 + 1600 + 100) / 1e6)


def test_gemini_fallback_drops_client_query_key(make_gateway, upstream, upstream2, tmp_path):
    primary_key = tmp_path / "gemini.key"
    backup_key = tmp_path / "gemini-backup.key"
    primary_key.write_text("primary-key\n")
    backup_key.write_text("backup-key\n")
    upstream.fail_status = 500
    gw = make_gateway(providers={
        "gemini": {"base_url": upstream.url, "api": "gemini", "key_file": str(primary_key),
                   "fallbacks": ["backup"]},
        "backup": {"base_url": upstream2.url, "api": "gemini", "key_file": str(backup_key)},
    })
    path = GEMINI + "?key=client-secret&alt=sse"
    status, _, _ = request(gw, "POST", path, {"contents": [{"parts": [{"text": "hi"}]}]})
    assert status == 200
    assert "key=client-secret" in upstream.requests[-1]["path"]
    fallback = upstream2.requests[-1]
    assert "key=" not in fallback["path"]
    assert "alt=sse" in fallback["path"]
    assert fallback["headers"]["x-goog-api-key"] == "backup-key"


def test_gemini_client_key_is_kept_and_model_routes_in_path(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path),
                      routing={"rewrites": {"gemini-test": "gemini-other"}})
    request(gw, "POST", GEMINI, {"contents": [{"parts": []}]}, {"x-goog-api-key": "mine"})
    seen = upstream.requests[-1]
    assert seen["headers"]["x-goog-api-key"] == "mine"
    assert seen["path"] == "/v1beta/models/gemini-other:generateContent"


def test_gemini_json_array_stream():
    chunks = [{"modelVersion": "m", "usageMetadata": {"promptTokenCount": 5}},
              {"modelVersion": "m", "usageMetadata": {"promptTokenCount": 5, "candidatesTokenCount": 7}}]
    p = UsageParser("gemini", "application/json")
    p.feed(json.dumps(chunks).encode())
    model, usage = p.finish()
    assert model == "m" and usage["input_tokens"] == 5 and usage["output_tokens"] == 7


def test_azure_deployment_path_key_and_api_version(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path))
    path = "/agent/z1/azure/openai/deployments/my-gpt/chat/completions"
    status, _, _ = request(gw, "POST", path, {"messages": [{"role": "user", "content": "x"}]},
                           {"api-key": "agentos-managed"})
    assert status == 200
    seen = upstream.requests[-1]
    assert seen["path"] == "/openai/deployments/my-gpt/chat/completions?api-version=2024-10-21"
    assert seen["headers"]["api-key"] == "real-key"
    assert "Authorization" not in seen["headers"]
    # response says gpt-test (the underlying model): 800*1 + 500*2 + 200*0.5
    assert store.spend("z1") == pytest.approx(1900 / 1e6)
    # an explicit api-version from the client wins
    request(gw, "POST", path + "?api-version=2023-05-15", {"messages": []}, {"api-key": "agentos-managed"})
    assert upstream.requests[-1]["path"].endswith("?api-version=2023-05-15")


def test_azure_stream_gets_include_usage_and_deployment_rewrite(make_gateway, upstream, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path), routing={"rewrites": {"big": "small"}})
    request(gw, "POST", "/agent/z1/azure/openai/deployments/big/chat/completions",
            {"stream": True, "messages": []}, {"api-key": "x"})
    seen = upstream.requests[-1]
    assert seen["body"]["stream_options"] == {"include_usage": True}
    assert seen["path"].startswith("/openai/deployments/small/chat/completions")


def test_local_openai_compatible_is_free_and_keyless(make_gateway, upstream, store, tmp_path):
    gw = make_gateway(providers=provs(upstream, tmp_path), budget={"default_daily_usd": 0.0001})
    body = {"model": "llama3.1", "max_tokens": 100000, "messages": [{"role": "user", "content": "hi"}]}
    status, _, _ = request(gw, "POST", "/agent/l1/local/v1/chat/completions", body)
    assert status == 200                                  # reserves nothing, so a tiny budget is fine
    assert "Authorization" not in upstream.requests[-1]["headers"]
    assert store.spend("l1") == 0
    tokens = store.snapshot()["agents"]["l1"]["tokens"]
    assert tokens == {"input_tokens": 10, "output_tokens": 5}      # still metered in tokens
    log = (tmp_path / "logs" / "l1.log").read_text().splitlines()[-1]
    assert json.loads(log)["priced"] is True and json.loads(log)["cost_usd"] == 0


def test_zero_cost_override_on_any_provider(make_gateway, upstream, store, tmp_path):
    extra = {"lan-openai": {"base_url": upstream.url, "api": "openai", "zero_cost": True}}
    gw = make_gateway(providers=provs(upstream, tmp_path, **extra))
    request(gw, "POST", "/agent/l2/lan-openai/v1/chat/completions", {"model": "whatever", "messages": []})
    assert store.spend("l2") == 0
    # and a compatible server can opt back in to prices
    priced = {"paid": {"base_url": upstream.url, "api": "openai-compatible", "zero_cost": False}}
    gw2 = make_gateway(providers=provs(upstream, tmp_path, **priced))
    request(gw2, "POST", "/agent/l3/paid/v1/chat/completions", {"model": "gpt-test", "messages": []})
    assert store.spend("l3") > 0


def test_plain_openai_without_key_still_works(make_gateway, upstream, store):
    gw = make_gateway()
    assert request(gw, "POST", "/agent/o2/openai/v1/chat/completions", {"model": "gpt-test"})[0] == 200
    assert "Authorization" not in upstream.requests[-1]["headers"]


def test_cost_routing_can_choose_the_local_provider(make_gateway, upstream, store, tmp_path):
    other = {"local": {"base_url": upstream.url, "api": "openai-compatible"}}
    gw = make_gateway(
        providers=provs(upstream, tmp_path, **other),
        routing={"strategy": "cheapest", "groups": [["gpt-test", "llama3.1"]],
                 "targets": {"llama3.1": "local"}})
    status, _, _ = request(gw, "POST", "/agent/r1/openai/v1/chat/completions",
                           {"model": "gpt-test", "messages": []}, {"Authorization": "Bearer sk-user-openai"})
    assert status == 200
    seen = upstream.requests[-1]
    assert seen["body"]["model"] == "llama3.1"
    assert "Authorization" not in seen["headers"]            # the user's OpenAI key is not sent to the local server
    assert store.spend("r1") == 0
    entry = json.loads((tmp_path / "logs" / "r1.log").read_text().splitlines()[-1])
    assert entry["provider"] == "local" and entry["routed_provider"] == "local"
    described = json.loads(request(gw, "GET", "/_agentos/routing?agent=r1&provider=openai&model=gpt-test", admin=True)[2])
    assert described["effective"]["routed_provider"] == "local"


def test_cheapest_routing_skips_unreachable_provider_target(make_gateway, upstream, tmp_path):
    providers = provs(upstream, tmp_path)
    providers["anthropic"] = {"base_url": upstream.url, "api": "anthropic"}
    gw = make_gateway(
        providers=providers,
        routing={"strategy": "cheapest", "groups": [["claude-test", "llama3.1"]],
                 "targets": {"llama3.1": "local"}})
    body = {"model": "claude-test", "messages": [{"role": "user", "content": "hi"}]}
    assert request(gw, "POST", ANTHROPIC, body)[0] == 200
    assert upstream.requests[-1]["body"]["model"] == "claude-test"


def test_default_output_limits_are_forwarded(make_gateway, upstream, tmp_path):
    providers = provs(upstream, tmp_path)
    providers["anthropic"] = {"base_url": upstream.url, "api": "anthropic"}
    providers["openai"] = {"base_url": upstream.url, "api": "openai"}
    gw = make_gateway(providers=providers)

    assert request(gw, "POST", ANTHROPIC, {"messages": []})[0] == 200
    assert upstream.requests[-1]["body"]["max_tokens"] == 4096

    assert request(gw, "POST", "/agent/o1/openai/v1/chat/completions", {"model": "gpt-test", "messages": []})[0] == 200
    assert upstream.requests[-1]["body"]["max_completion_tokens"] == 4096

    assert request(gw, "POST", "/agent/o1/openai/v1/responses",
                   {"model": "gpt-test", "input": [], "stream": True})[0] == 200
    assert upstream.requests[-1]["body"]["max_output_tokens"] == 4096

    assert request(gw, "POST", GEMINI, {"contents": []})[0] == 200
    assert upstream.requests[-1]["body"]["generationConfig"]["maxOutputTokens"] == 4096


def test_routing_never_moves_across_wire_formats(make_gateway, upstream, tmp_path):
    gw = make_gateway(
        providers=provs(upstream, tmp_path),
        routing={"rewrites": {"claude-test": "llama3.1"}, "targets": {"llama3.1": "local"}})
    request(gw, "POST", "/agent/r2/anthropic/v1/messages", {"model": "claude-test"})
    # the model was rewritten but the request stayed on the Anthropic provider
    assert upstream.requests[-1]["path"] == "/v1/messages"


def test_responses_api_stream_usage(make_gateway, store):
    gw = make_gateway()
    status, _, body = request(gw, "POST", "/agent/o3/openai/v1/responses", {"model": "gpt-test", "stream": True})
    assert status == 200 and b"response.completed" in body
    assert store.spend("o3") == pytest.approx((300 * 1 + 100 * 2 + 100 * 0.5) / 1e6)


def test_unknown_api_is_rejected():
    with pytest.raises(ValueError):
        adapter_for({"api": "bedrock"})
    assert set(configmod.API_KINDS) == {"anthropic", "openai", "openai-compatible", "azure-openai", "gemini"}
