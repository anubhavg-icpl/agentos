"""Provider adapters: how the gateway talks to each kind of LLM API.

A provider in services.toml names its adapter with `api`:

  anthropic          Messages API. x-api-key header.
  openai             Chat Completions / Responses. Authorization: Bearer.
  openai-compatible  Local servers speaking the OpenAI wire format (ollama,
                     llama.cpp, vLLM, LM Studio). No key is needed and every
                     model costs $0 unless the provider sets zero_cost = false.
  azure-openai       Azure OpenAI. api-key header, deployments in the path
                     (/openai/deployments/<name>/chat/completions), and an
                     api-version query that the provider may set
                     (api_version = "2024-10-21").
  gemini             Google Generative Language API. x-goog-api-key header,
                     usageMetadata in responses, the model in the path
                     (/v1beta/models/<model>:generateContent).

An adapter decides four things: where the credential goes (inject_key), which
model a request is for (request_model/set_model, because Azure and Gemini put
it in the URL), small request edits (prepare, query_for), and which usage
format the responses use (wire, read by usage.UsageParser).

Not supported yet: AWS Bedrock (needs SigV4 request signing and the binary
event-stream framing) and Google Vertex AI (needs OAuth access tokens minted
from a service account). Both fit this interface, but not without credential
handling that does not belong in the gateway's request path yet.
"""

import re
import urllib.parse

from . import config as configmod

AUTH_HEADERS = ("authorization", "x-api-key", "api-key", "x-goog-api-key")
GENERATION_KEYS = ("messages", "input", "contents", "prompt")


def _has_output_limit(payload, fields):
    return any(key in payload for key in fields)


def _find(headers, name):
    for key in headers:
        if key.lower() == name:
            return key
    return None


class Adapter:
    name = "openai"
    wire = "openai"
    free = False            # models cost $0 by default
    model_in_path = False

    def __init__(self, prov=None):
        self.prov = prov or {}

    @property
    def zero_cost(self):
        value = self.prov.get("zero_cost")
        return self.free if value is None else bool(value)

    def inject_key(self, headers, key):
        if not key:
            return
        name = _find(headers, "authorization") or "Authorization"
        if headers.get(name, "") in ("", "Bearer " + configmod.MANAGED_KEY):
            headers[name] = "Bearer " + key

    def strip_credentials(self, headers):
        """Drop the client's credentials (used before talking to another provider)."""
        for name in [k for k in headers if k.lower() in AUTH_HEADERS]:
            del headers[name]

    def request_model(self, payload, rest):
        return payload.get("model") if isinstance(payload, dict) else None

    def set_model(self, payload, rest, model):
        """Point the request at `model`; returns the (possibly new) path parts."""
        if isinstance(payload, dict):
            payload["model"] = model
        return rest

    def prepare(self, payload, rest_path, default_max_tokens=4096):
        """Edit a JSON request body in place; True if it changed."""
        return False

    def query_for(self, query, strip=False):
        return query


class Anthropic(Adapter):
    name = wire = "anthropic"

    def prepare(self, payload, rest_path, default_max_tokens=4096):
        if (not isinstance(payload, dict) or not any(key in payload for key in GENERATION_KEYS)
                or _has_output_limit(payload, ("max_tokens",))):
            return False
        payload["max_tokens"] = int(default_max_tokens)
        return True

    def inject_key(self, headers, key):
        if not key:
            return
        name = _find(headers, "x-api-key")
        current = headers.get(name, "") if name else ""
        if current == configmod.MANAGED_KEY or (not current and _find(headers, "authorization") is None):
            headers[name or "x-api-key"] = key


class OpenAI(Adapter):
    name = wire = "openai"

    def prepare(self, payload, rest_path, default_max_tokens=4096):
        # Ask for usage on streamed Chat Completions so it can be priced
        if not isinstance(payload, dict):
            return False
        changed = False
        is_responses = rest_path.endswith("responses")
        valid_limits = ("max_output_tokens",) if is_responses else ("max_tokens", "max_completion_tokens")
        if any(key in payload for key in GENERATION_KEYS) and not _has_output_limit(payload, valid_limits):
            payload[valid_limits[0] if is_responses else "max_tokens"] = int(default_max_tokens)
            changed = True
        if (payload.get("stream") is True and rest_path.endswith("chat/completions")
                and "stream_options" not in payload):
            payload["stream_options"] = {"include_usage": True}
            changed = True
        return changed


class OpenAICompatible(OpenAI):
    name = "openai-compatible"
    free = True

    def inject_key(self, headers, key):
        self.strip_credentials(headers)
        super().inject_key(headers, key)

class AzureOpenAI(OpenAI):
    name = "azure-openai"
    model_in_path = True

    def inject_key(self, headers, key):
        if not key:
            return
        name = _find(headers, "api-key")
        current = headers.get(name, "") if name else ""
        if current == configmod.MANAGED_KEY or (not current and _find(headers, "authorization") is None):
            headers[name or "api-key"] = key

    def _deployment(self, rest):
        for i, part in enumerate(rest[:-1]):
            if part == "deployments":
                return i + 1
        return None

    def request_model(self, payload, rest):
        i = self._deployment(rest)
        if i is not None:
            return rest[i]
        return super().request_model(payload, rest)

    def set_model(self, payload, rest, model):
        i = self._deployment(rest)
        if i is None:
            return super().set_model(payload, rest, model)
        return rest[:i] + [model] + rest[i + 1:]

    def query_for(self, query, strip=False):
        version = self.prov.get("api_version")
        if version and "api-version" not in urllib.parse.parse_qs(query or ""):
            query = (query + "&" if query else "") + "api-version=" + urllib.parse.quote(str(version))
        return query


class Gemini(Adapter):
    name = wire = "gemini"
    model_in_path = True
    _MODEL = re.compile(r"^(?P<model>[^:]+)(?P<method>:[A-Za-z]+)?$")

    def inject_key(self, headers, key):
        if not key:
            return
        name = _find(headers, "x-goog-api-key")
        current = headers.get(name, "") if name else ""
        if current in ("", configmod.MANAGED_KEY) and _find(headers, "authorization") is None:
            headers[name or "x-goog-api-key"] = key

    def _index(self, rest):
        for i, part in enumerate(rest[:-1]):
            if part == "models":
                return i + 1
        return None

    def request_model(self, payload, rest):
        i = self._index(rest)
        if i is None:
            return None
        m = self._MODEL.match(rest[i])
        return m.group("model") if m else None

    def set_model(self, payload, rest, model):
        i = self._index(rest)
        if i is None:
            return rest
        m = self._MODEL.match(rest[i])
        return rest[:i] + [model + ((m.group("method") or "") if m else "")] + rest[i + 1:]

    def prepare(self, payload, rest_path, default_max_tokens=4096):
        if not isinstance(payload, dict) or not any(key in payload for key in GENERATION_KEYS):
            return False
        gen = payload.get("generationConfig")
        if isinstance(gen, dict) and "maxOutputTokens" in gen:
            return False
        if gen is None:
            gen = {}
        elif not isinstance(gen, dict):
            return False
        gen["maxOutputTokens"] = int(default_max_tokens)
        payload["generationConfig"] = gen
        return True

    def query_for(self, query, strip=False):
        # Older Google clients send the key as ?key=; the managed placeholder
        # must not reach Google (inject_key supplies the header instead).
        # Never forward a client's key to a fallback provider.
        if not query:
            return query
        pairs = [(k, v) for k, v in urllib.parse.parse_qsl(query, keep_blank_values=True)
                 if not (k == "key" and (strip or v == configmod.MANAGED_KEY))]
        return urllib.parse.urlencode(pairs)


ADAPTERS = {cls.name: cls for cls in (Anthropic, OpenAI, OpenAICompatible, AzureOpenAI, Gemini)}


def adapter_for(prov):
    """Adapter for a provider table from services.toml."""
    api = prov.get("api", "openai")
    try:
        return ADAPTERS[api](prov)
    except KeyError:
        raise ValueError("unknown provider api %r (known: %s)" % (api, ", ".join(sorted(ADAPTERS))))
