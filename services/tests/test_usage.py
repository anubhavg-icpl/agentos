import json

import pytest

from agentos_services.usage import Pricing, UsageParser, output_cap

from conftest import PRICING


def sse(*events):
    return b"".join(b"event: x\ndata: " + json.dumps(e).encode() + b"\n\n" for e in events)


def feed_bytewise(parser, data):
    for i in range(len(data)):
        parser.feed(data[i:i + 1])
    return parser.finish()


def test_anthropic_json():
    p = UsageParser("anthropic", "application/json")
    p.feed(json.dumps({"type": "message", "model": "claude-x", "usage": {
        "input_tokens": 10, "output_tokens": 20,
        "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40}}).encode())
    model, usage = p.finish()
    assert model == "claude-x"
    assert usage == {"input_tokens": 10, "output_tokens": 20, "cache_read_tokens": 30, "cache_write_tokens": 40}


def test_anthropic_stream_split_anywhere():
    data = sse(
        {"type": "message_start", "message": {"model": "claude-x", "usage": {
            "input_tokens": 5, "output_tokens": 1, "cache_creation_input_tokens": 7}}},
        {"type": "content_block_delta", "delta": {"text": "hi"}},
        {"type": "message_delta", "usage": {"output_tokens": 99}},
    )
    model, usage = feed_bytewise(UsageParser("anthropic", "text/event-stream"), data)
    assert model == "claude-x"
    assert usage == {"input_tokens": 5, "output_tokens": 99, "cache_read_tokens": 0, "cache_write_tokens": 7}


def test_crlf_event_separators():
    data = sse({"type": "message_start", "message": {"model": "m", "usage": {"input_tokens": 3}}}).replace(b"\n", b"\r\n")
    _, usage = feed_bytewise(UsageParser("anthropic", "text/event-stream"), data)
    assert usage["input_tokens"] == 3


def test_openai_chat_json_subtracts_cached():
    p = UsageParser("openai", "application/json")
    p.feed(json.dumps({"model": "gpt-x", "usage": {
        "prompt_tokens": 100, "completion_tokens": 7, "prompt_tokens_details": {"cached_tokens": 60}}}).encode())
    _, usage = p.finish()
    assert usage == {"input_tokens": 40, "output_tokens": 7, "cache_read_tokens": 60, "cache_write_tokens": 0}


def test_openai_chat_stream_with_done():
    data = (b"data: " + json.dumps({"model": "gpt-x", "usage": None}).encode() + b"\n\n"
            + b"data: " + json.dumps({"model": "gpt-x", "usage": {"prompt_tokens": 4, "completion_tokens": 2}}).encode() + b"\n\n"
            + b"data: [DONE]\n\n")
    model, usage = feed_bytewise(UsageParser("openai", "text/event-stream"), data)
    assert model == "gpt-x"
    assert usage["input_tokens"] == 4 and usage["output_tokens"] == 2


def test_openai_responses_stream():
    data = sse(
        {"type": "response.created", "response": {"model": "gpt-r", "usage": None}},
        {"type": "response.output_text.delta", "delta": "x"},
        {"type": "response.completed", "response": {"model": "gpt-r", "usage": {
            "input_tokens": 50, "output_tokens": 5, "input_tokens_details": {"cached_tokens": 20}}}},
    )
    model, usage = feed_bytewise(UsageParser("openai", "text/event-stream"), data)
    assert model == "gpt-r"
    assert usage == {"input_tokens": 30, "output_tokens": 5, "cache_read_tokens": 20, "cache_write_tokens": 0}


def test_no_usage_and_request_model_fallback():
    p = UsageParser("anthropic", "application/json", request_model="claude-req")
    p.feed(b'{"type": "error", "error": {"type": "overloaded_error"}}')
    assert p.finish() == ("claude-req", None)


def test_garbage_is_ignored():
    p = UsageParser("anthropic", "text/event-stream")
    p.feed(b"data: {not json\n\n: comment\n\n")
    assert p.finish()[1] is None


def test_pricing_exact_prefix_and_default():
    pricing = Pricing(PRICING)
    assert pricing.rates("claude-test")[1]
    rates, priced = pricing.rates("claude-test-2026-01-01")
    assert priced and rates["input_per_1m"] == 3.0
    assert pricing.rates("anthropic/claude-test")[1]
    rates, priced = pricing.rates("mystery-model")
    assert not priced and rates["output_per_1m"] == 50.0


def test_pricing_longest_prefix_wins():
    pricing = Pricing({"models": {"gpt-4o": {"input_per_1m": 2.5}, "gpt-4o-mini": {"input_per_1m": 0.15}}})
    assert pricing.rates("gpt-4o-mini-2024-07-18")[0]["input_per_1m"] == 0.15
    assert pricing.rates("gpt-4o-2024-08-06")[0]["input_per_1m"] == 2.5


def test_output_cap_counts_requested_candidates():
    assert output_cap({"max_tokens": 100, "n": 3}) == 300
    assert output_cap({"generationConfig": {"maxOutputTokens": 100, "candidateCount": 2}},
                      api="gemini") == 200


def test_cost_all_token_kinds():
    usd, priced = Pricing(PRICING).cost("claude-test", {
        "input_tokens": 1_000_000, "output_tokens": 1_000_000,
        "cache_read_tokens": 1_000_000, "cache_write_tokens": 1_000_000})
    assert priced
    assert usd == pytest.approx(3.0 + 15.0 + 0.3 + 3.75)


def test_cost_defaults_for_missing_cache_rates():
    pricing = Pricing({"models": {"m": {"input_per_1m": 4.0, "output_per_1m": 0}}})
    usd, _ = pricing.cost("m", {"input_tokens": 0, "output_tokens": 0,
                                "cache_read_tokens": 1_000_000, "cache_write_tokens": 1_000_000})
    assert usd == pytest.approx(4.0 + 5.0)


def test_anthropic_one_hour_cache_writes_are_priced_separately():
    p = UsageParser("anthropic", "application/json")
    p.feed(json.dumps({"type": "message", "model": "claude-test", "usage": {
        "input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 3_000_000,
        "cache_creation": {"ephemeral_5m_input_tokens": 1_000_000, "ephemeral_1h_input_tokens": 2_000_000}}}).encode())
    _, usage = p.finish()
    assert usage["cache_write_tokens"] == 1_000_000 and usage["cache_write_1h_tokens"] == 2_000_000
    # 5m writes at the listed $3.75, 1h writes default to twice the input price ($6)
    assert Pricing(PRICING).cost("claude-test", usage)[0] == pytest.approx(3.75 + 12.0)
    explicit = Pricing({"models": {"m": {"input_per_1m": 3.0, "cache_write_1h_per_1m": 7.0}}})
    assert explicit.cost("m", dict(usage, input_tokens=0))[0] == pytest.approx(3.75 + 14.0)


def test_openai_cached_tokens_are_priced_at_the_cache_rate():
    usage = {"prompt_tokens": 1_000_000, "completion_tokens": 0,
             "prompt_tokens_details": {"cached_tokens": 600_000}}
    p = UsageParser("openai", "application/json")
    p.feed(json.dumps({"model": "gpt-test", "usage": usage}).encode())
    _, got = p.finish()
    assert got["input_tokens"] == 400_000 and got["cache_read_tokens"] == 600_000
    assert Pricing(PRICING).cost("gpt-test", got)[0] == pytest.approx(0.4 * 1.0 + 0.6 * 0.5)


def test_responses_stream_variants_carry_usage():
    usage = {"input_tokens": 50, "output_tokens": 9, "input_tokens_details": {"cached_tokens": 10}}
    for kind in ("response.completed", "response.incomplete"):
        data = sse({"type": "response.created", "response": {"model": "gpt-test", "usage": None}},
                   {"type": "response.output_text.delta", "delta": "x"},
                   {"type": kind, "response": {"model": "gpt-test", "usage": usage}})
        model, got = feed_bytewise(UsageParser("openai", "text/event-stream"), data)
        assert model == "gpt-test"
        assert got == {"input_tokens": 40, "output_tokens": 9, "cache_read_tokens": 10, "cache_write_tokens": 0}
