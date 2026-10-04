"""Token usage extraction and pricing.

The gateway feeds every upstream response body through a UsageParser, which
understands:

  * Anthropic Messages API: JSON responses and SSE streams
    (message_start carries input/cache usage, message_delta carries the
    cumulative output count).
  * OpenAI Chat Completions: JSON responses and SSE streams (the final chunk
    carries usage when stream_options.include_usage is set, which the gateway
    adds).
  * OpenAI Responses API: JSON responses and the response.completed event.
  * Gemini generateContent: usageMetadata on JSON responses, on every SSE
    chunk (alt=sse) and on the elements of a streamed JSON array.

Provider kinds that share a wire format (azure-openai, openai-compatible)
are parsed as the format they speak.

Usage is normalised to four counters: input, output, cache_read and
cache_write tokens, where input excludes cached tokens. Anthropic cache
writes with the 1 hour lifetime (priced higher than the 5 minute ones) are
counted separately in cache_write_1h_tokens, which is present only when
non-zero; cache_write_tokens then holds the 5 minute writes.
"""

import json

FIELDS = ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")
OPTIONAL_FIELDS = ("cache_write_1h_tokens",)

# Stop buffering non-streaming bodies beyond this size
MAX_JSON_BODY = 32 * 1024 * 1024


def empty_usage():
    return {f: 0 for f in FIELDS}


def _int(value):
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError):
        return 0


WIRE = {"azure-openai": "openai", "openai-compatible": "openai"}


def wire_format(api):
    return WIRE.get(api, api)


def _normalise_gemini(raw):
    cached = _int(raw.get("cachedContentTokenCount"))
    prompt = _int(raw.get("promptTokenCount")) + _int(raw.get("toolUsePromptTokenCount"))
    return {
        "input_tokens": max(0, prompt - cached),
        # thinking tokens are billed as output
        "output_tokens": _int(raw.get("candidatesTokenCount")) + _int(raw.get("thoughtsTokenCount")),
        "cache_read_tokens": cached,
        "cache_write_tokens": 0,
    }


def normalise(raw, api):
    """Map a provider usage object onto FIELDS."""
    if not isinstance(raw, dict):
        return None
    api = wire_format(api)
    if api == "gemini":
        return _normalise_gemini(raw)
    if api == "anthropic":
        written = _int(raw.get("cache_creation_input_tokens"))
        detail = raw.get("cache_creation")
        hour = _int(detail.get("ephemeral_1h_input_tokens")) if isinstance(detail, dict) else 0
        hour = min(hour, written)
        out = {
            "input_tokens": _int(raw.get("input_tokens")),
            "output_tokens": _int(raw.get("output_tokens")),
            "cache_read_tokens": _int(raw.get("cache_read_input_tokens")),
            "cache_write_tokens": written - hour,
        }
        if hour:
            out["cache_write_1h_tokens"] = hour
        return out
    if "prompt_tokens" in raw or "completion_tokens" in raw:
        # Chat Completions
        cached = _int((raw.get("prompt_tokens_details") or {}).get("cached_tokens"))
        return {
            "input_tokens": max(0, _int(raw.get("prompt_tokens")) - cached),
            "output_tokens": _int(raw.get("completion_tokens")),
            "cache_read_tokens": cached,
            "cache_write_tokens": 0,
        }
    if "input_tokens" in raw or "output_tokens" in raw:
        # Responses API
        cached = _int((raw.get("input_tokens_details") or {}).get("cached_tokens"))
        return {
            "input_tokens": max(0, _int(raw.get("input_tokens")) - cached),
            "output_tokens": _int(raw.get("output_tokens")),
            "cache_read_tokens": cached,
            "cache_write_tokens": 0,
        }
    return None


def extract(obj, api):
    """Return (model, usage) found in one JSON object or SSE event payload."""
    if not isinstance(obj, dict):
        return None, None
    api = wire_format(api)
    if api == "gemini":
        meta = obj.get("usageMetadata")
        return obj.get("modelVersion"), (_normalise_gemini(meta) if isinstance(meta, dict) else None)
    if api == "anthropic":
        kind = obj.get("type")
        if kind == "message_start":
            msg = obj.get("message") or {}
            return msg.get("model"), normalise(msg.get("usage"), api)
        if kind == "message_delta":
            return None, normalise(obj.get("usage"), api)
        if kind == "message" or "usage" in obj:
            return obj.get("model"), normalise(obj.get("usage"), api)
        return None, None
    # OpenAI
    resp = obj.get("response")
    if isinstance(resp, dict) and ("usage" in resp or "model" in resp):
        return resp.get("model"), normalise(resp.get("usage"), api)
    return obj.get("model"), normalise(obj.get("usage"), api)


class UsageParser:
    """Incrementally parses a response body for model and token usage."""

    def __init__(self, api, content_type="", request_model=None):
        self.api = api
        self.streaming = "text/event-stream" in (content_type or "")
        self.model = None
        self.request_model = request_model
        self.usage = empty_usage()
        self.seen_usage = False
        self._buf = b""
        self._overflow = False

    def feed(self, chunk):
        if not chunk:
            return
        if self.streaming:
            self._buf += chunk
            while True:
                # SSE events are separated by a blank line (\n\n or \r\n\r\n)
                idx, sep = self._find_event_end()
                if idx < 0:
                    break
                event, self._buf = self._buf[:idx], self._buf[idx + sep:]
                self._handle_event(event)
        elif not self._overflow:
            self._buf += chunk
            if len(self._buf) > MAX_JSON_BODY:
                self._overflow = True
                self._buf = b""

    def _find_event_end(self):
        best, sep = -1, 0
        for marker in (b"\r\n\r\n", b"\n\n"):
            i = self._buf.find(marker)
            if i >= 0 and (best < 0 or i < best):
                best, sep = i, len(marker)
        return best, sep

    def _handle_event(self, event):
        data = []
        for line in event.splitlines():
            if line.startswith(b"data:"):
                data.append(line[5:].strip())
        if not data:
            return
        payload = b"\n".join(data)
        if payload == b"[DONE]":
            return
        self._absorb(payload)

    def _absorb(self, payload):
        try:
            obj = json.loads(payload)
        except (ValueError, UnicodeDecodeError):
            return
        for item in (obj if isinstance(obj, list) else [obj]):
            self._absorb_obj(item)

    def _absorb_obj(self, obj):
        model, usage = extract(obj, self.api)
        if model and not self.model:
            self.model = model
        if usage:
            self.seen_usage = True
            # Streaming counters are cumulative; keep the largest value seen
            for f in FIELDS + OPTIONAL_FIELDS:
                self.usage[f] = max(self.usage.get(f, 0), usage.get(f, 0))

    def finish(self):
        """Return (model, usage or None) once the body is complete."""
        if self.streaming:
            if self._buf.strip():
                self._handle_event(self._buf)
        elif self._buf:
            self._absorb(self._buf)
        self._buf = b""
        model = self.model or self.request_model or "unknown"
        if not self.seen_usage:
            return model, None
        usage = {f: v for f, v in self.usage.items() if f in FIELDS or v}
        return model, usage


class Pricing:
    """Per-model USD prices per million tokens, loaded from pricing.json.

    Models are matched exactly, then by the longest configured name that
    prefixes the reported model (so dated snapshots such as
    "gpt-4o-2024-08-06" price as "gpt-4o"). Unknown models use the
    "default" entry and are reported as unpriced.
    """

    FALLBACK_DEFAULT = {"input_per_1m": 10.0, "output_per_1m": 50.0}

    def __init__(self, data):
        self.models = dict(data.get("models", {}))
        self.default = data.get("default") or self.FALLBACK_DEFAULT

    @classmethod
    def from_file(cls, path):
        with open(path) as f:
            return cls(json.load(f))

    def rates(self, model):
        model = (model or "").strip()
        # Provider-prefixed ids, e.g. "anthropic/claude-..." or "models/gemini-..."
        bare = model.rsplit("/", 1)[-1]
        for candidate in (model, bare):
            if candidate in self.models:
                return self.models[candidate], True
        best = None
        for name in self.models:
            if bare.startswith(name) and (best is None or len(name) > len(best)):
                best = name
        if best is not None:
            return self.models[best], True
        return self.default, False

    def cost(self, model, usage):
        """Return (usd, priced) for a normalised usage dict."""
        rates, priced = self.rates(model)
        inp = float(rates.get("input_per_1m", 0.0))
        out = float(rates.get("output_per_1m", 0.0))
        cache_read = float(rates.get("cache_read_per_1m", inp))
        cache_write = float(rates.get("cache_write_per_1m", inp * 1.25))
        cache_write_1h = float(rates.get("cache_write_1h_per_1m", inp * 2.0))
        usd = (
            usage["input_tokens"] * inp
            + usage["output_tokens"] * out
            + usage["cache_read_tokens"] * cache_read
            + usage["cache_write_tokens"] * cache_write
            + usage.get("cache_write_1h_tokens", 0) * cache_write_1h
        ) / 1_000_000
        return usd, priced


DEFAULT_MAX_OUTPUT_TOKENS = 4096
GENERATION_KEYS = ("messages", "input", "contents", "prompt")


def _positive(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def output_cap(payload, default=DEFAULT_MAX_OUTPUT_TOKENS):
    """Total output allowance across all requested candidates."""
    if not isinstance(payload, dict):
        return default
    gen = payload.get("generationConfig")
    gen = gen if isinstance(gen, dict) else {}
    cap = default
    for key in ("max_tokens", "max_completion_tokens", "max_output_tokens"):
        value = payload.get(key)
        if isinstance(value, (int, float)) and value > 0:
            cap = int(value)
            break
    else:
        value = gen.get("maxOutputTokens")
        if isinstance(value, (int, float)) and value > 0:
            cap = int(value)
    count = gen.get("candidateCount", payload.get("n", 1))
    if isinstance(count, int) and not isinstance(count, bool) and count > 0:
        cap *= count
    return cap


def apply_output_cap(payload, api, rest_path, default, api_version=None):
    """Give a generation request that sets no output limit one, so what is
    reserved against the budget is also what the provider may produce.

    The field is the provider's own: max_tokens (Anthropic and legacy
    completions), max_completion_tokens (OpenAI chat; Azure from api-version
    2024-09), max_output_tokens (Responses), generationConfig.maxOutputTokens
    (Gemini). Returns True if the payload changed.
    """
    if not isinstance(payload, dict) or not any(k in payload for k in GENERATION_KEYS):
        return False
    if rest_path.endswith("embeddings") or not _positive(default):
        return False
    default = int(default)
    if api == "gemini":
        gen = payload.setdefault("generationConfig", {})
        if not isinstance(gen, dict) or "maxOutputTokens" in gen:
            return False
        gen["maxOutputTokens"] = default
        return True
    if any(payload.get(k) is not None for k in ("max_tokens", "max_completion_tokens", "max_output_tokens")):
        return False
    if api == "anthropic":
        field = "max_tokens"
    elif rest_path.endswith("responses"):
        field = "max_output_tokens"
    elif rest_path.endswith("chat/completions"):
        field = "max_completion_tokens"
        if api_version is not None and str(api_version) < "2024-09":
            field = "max_tokens"
    elif "prompt" in payload:
        field = "max_tokens"
    else:
        return False
    payload[field] = default
    return True


def estimate_cost(pricing, model, input_bytes, max_output_tokens):
    """Worst-case-ish USD for a request: ~4 bytes per input token plus the
    full output allowance, both at the model's list price."""
    rates, _ = pricing.rates(model)
    in_tokens = (int(input_bytes) + 3) // 4
    return (in_tokens * float(rates.get("input_per_1m", 0.0))
            + int(max_output_tokens) * float(rates.get("output_per_1m", 0.0))) / 1_000_000
