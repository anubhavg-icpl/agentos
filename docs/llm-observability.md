# LLM observability

`nestlo.llmObservability` makes the Nestlo model gateway emit standard
OpenTelemetry GenAI traces. Every request the gateway handles becomes one span
with the attributes the
[OpenTelemetry GenAI semantic conventions](https://github.com/open-telemetry/semantic-conventions-genai)
define, plus Nestlo's own (agent, cost, routing). Any OTLP backend can show
them. Langfuse (MIT core) and OpenLIT (Apache-2.0) are available as opt-in
loopback stacks.

| Part | What it is |
|------|------------|
| Exporter | `services/nestlo_services/genai_trace.py`: standard library only, OTLP/HTTP JSON, background thread, bounded queue, timeouts. Never blocks or fails a request |
| Backends | The Nestlo OTel collector (default), a Langfuse stack, an OpenLIT stack, or any OTLP endpoint |
| Default | Exporter only. No container stack runs unless you enable it |

## Enable

```nix
nestlo.networking.enable = true;          # the model gateway
nestlo.observability.enable = true;       # the OTel collector -> Tempo -> Grafana
nestlo.llmObservability.enable = true;    # spans go to the collector
```

Langfuse instead (heavy: Postgres, ClickHouse, Redis, MinIO, web, worker):

```nix
nestlo.llmObservability = {
  enable = true;
  exporter.backend = "langfuse";
  langfuse.enable = true;
};
```

The UI is on `http://127.0.0.1:3300` (tunnel with SSH). The admin login is
`langfuse.adminEmail` and the password `ADMIN_PASSWORD` in
`/var/lib/nestlo-langfuse/secrets/secrets.env` (root only).

## Gateway patch required

The exporter is driven by two small changes to `gateway.py` and `config.py`
that are not part of this module. Without them the module still evaluates and
writes `[tracing]` to `services.toml`, but nothing is exported.

`services/nestlo_services/gateway.py`:

```python
from . import genai_trace                       # with the other imports

# in Gateway.__init__, before self.dlp = ...
        self.tracer = genai_trace.from_config(cfg)

# in Gateway.write_log: build the entry first, trace it, then the log_dir check
    def write_log(self, agent, entry):
        entry = dict(entry, ts=round(self.clock(), 3), agent=agent)
        self.tracer.record(entry)           # GenAI span; non-blocking, never raises
        if not self.log_dir:
            return
        line = json.dumps(entry, sort_keys=True) + "\n"
        ...
```

`write_log` is the one place every outcome passes through: forwarded calls
(with provider, model, usage, cost, route fields), replays, and refused calls
(budget, rate limit, circuit breaker) of authenticated agents.

`services/nestlo_services/config.py`, a new section in `DEFAULTS`:

```python
    "tracing": {
        "enabled": False,
        "endpoint": "http://127.0.0.1:4318/v1/traces",
        "headers": {},
        "headers_file": "",
        "ca_file": "",
        "service_name": "nestlo-model-gateway",
        "timeout_sec": 5,
        "queue": 2048,
        "batch": 128,
        "flush_interval_sec": 2,
        "sample_ratio": 1.0,
        "legacy_system_attribute": False,
    },
```

`services/tests/test_genai_trace.py` has a gateway test that is skipped until
`Gateway.tracer` exists. `tests/llm-observability.nix` is written against the
patched gateway.

## What a span contains

Span name `chat claude-sonnet-4-6` (`{gen_ai.operation.name} {gen_ai.request.model}`),
kind CLIENT, one per request, with the gateway as the client of the provider.

| Attribute | Value |
|-----------|-------|
| `gen_ai.operation.name` | `chat` (Messages, Chat Completions, Responses), `embeddings`, `text_completion`, `generate_content` (Gemini), from the request path. Other paths (model lists, token counting) produce no span |
| `gen_ai.provider.name` | `anthropic`, `openai`, `azure.ai.openai`, `gcp.gemini`; for `openai-compatible` providers the gateway's provider name |
| `gen_ai.request.model` | The model the gateway asked the provider for (after cost-based routing) |
| `gen_ai.response.model` | The model the response names |
| `gen_ai.usage.input_tokens` | Input tokens including cached ones, as the convention says (the gateway's own counter excludes them, so the three kinds are summed) |
| `gen_ai.usage.output_tokens` | Output tokens |
| `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_write.input_tokens` | When non-zero |
| `error.type` | The gateway's error type (`budget_exceeded`, ...) or the HTTP status, when the call failed. The span status is then ERROR |
| `server.address` | Host of the provider's base URL |
| `http.request.method`, `http.response.status_code`, `url.path` | The proxied request (the agent token is redacted) |
| `nestlo.agent.id` | Gateway agent id |
| `nestlo.cost_usd`, `nestlo.cost.priced` | Cost the gateway charged, and whether the model had a price |
| `nestlo.route.original_model`, `.routed_model`, `.reason`, `.routed_provider`, `.fallback_provider`, `.fallbacks_failed` | Cost-based routing and fallback decisions |
| `nestlo.replayed`, `nestlo.client_disconnected`, `nestlo.usage_estimated`, `nestlo.dlp.types`, `nestlo.dlp.response` | Gateway events on the request |
| `gen_ai.system` | Only with `legacySystemAttribute` (deprecated by the conventions) |

Resource: `service.name = nestlo-model-gateway`, `service.namespace = nestlo`.

Prompts, completions and system instructions (the conventions' opt-in
`gen_ai.input.messages` and friends) are never exported: the gateway does not
put them in the log entry and the exporter has no switch for them. The trade-off
is that Langfuse and OpenLIT show cost, latency, tokens and routing but not
conversation text. Use the gateway's recorder (`docs/gateway-features.md`) when
you need bodies.

Semantic-convention status: the GenAI conventions are at Development
stability and their attribute names have moved before (`gen_ai.system` to
`gen_ai.provider.name`, `gen_ai.usage.prompt_tokens` to `input_tokens`). The
names above were checked against the `semantic-conventions-genai` repository on
2026-10-05.

## Delivery guarantees

- `record()` builds the span and queues it; the caller never waits for I/O.
- A full queue (`queueSize`) drops new spans; an unreachable backend or an HTTP
  error drops the batch. Both are counted (`Exporter.stats()`), and a failure is
  logged as a warning at most once a minute.
- Spans are batched (up to 128, flushed every 2 seconds), sent with a connect
  and read timeout of `timeoutSec`, with no retry. Tracing is best effort, not an
  audit trail; the tamper-evident record of requests is `nestlo.audit`.
- A malformed config (bad URL, headers over plain http to a non-loopback host)
  disables tracing and logs an error; it does not stop the gateway.
- The exporter is a daemon thread: on shutdown, spans queued in the last two
  seconds can be lost.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | The exporter. Asserts `nestlo.networking.enable` |
| `exporter.backend` | `collector` | `collector` (needs `nestlo.observability.enable`), `langfuse`, `openlit` (each needs its stack enabled) or `custom` (needs `exporter.endpoint`) |
| `exporter.endpoint` | by backend | Full OTLP/HTTP traces URL; overrides the backend's. `http://` with headers must be loopback, otherwise `https://` |
| `exporter.headersFile` | none (langfuse: generated) | File of `Name: value` headers, re-read when it changes; readable by `nestlo`; never copied to the store |
| `exporter.sampleRatio` | `1.0` | Fraction of requests traced |
| `exporter.legacySystemAttribute` | `false` | Also set the deprecated `gen_ai.system` |
| `exporter.queueSize` | `2048` | Spans held while the exporter is busy |
| `exporter.timeoutSec` | `5` | Export request timeout |
| `langfuse.enable` | `false` | The Langfuse stack |
| `langfuse.port` | `3300` | Loopback port of the UI and OTLP endpoint |
| `langfuse.url` | `http://127.0.0.1:3300` | URL Langfuse believes it is served at |
| `langfuse.adminEmail` | `admin@nestlo.local` | First admin user; sign-up is disabled |
| `langfuse.images` | pinned, see below | `web`, `worker`, `clickhouse`, `postgres`, `redis` |
| `langfuse.memoryLimitMB` | `2048` | ClickHouse container limit |
| `openlit.enable` | `false` | The OpenLIT stack |
| `openlit.uiPort` | `3301` | Loopback port of the UI |
| `openlit.otlpPort` | `4328` | Loopback OTLP/HTTP receiver (4318 is the Nestlo collector's) |
| `openlit.retentionDays` | `30` | ClickHouse trace TTL |
| `openlit.images` | pinned, see below | `openlit`, `clickhouse` |

The collector path reuses `nestlo.observability`, which already forwards traces to
Tempo (Grafana explore). Its OTLP/HTTP receiver listens on all interfaces
(`0.0.0.0:4318`, see modules/observability); the gateway uses
`127.0.0.1:4318`.

## The Langfuse stack

Six podman containers on a private podman network (`nestlo-langfuse`): Langfuse
web and worker (v4), Postgres 17, ClickHouse 25.12, Redis 7 and MinIO. Only the
web container publishes a port, on `127.0.0.1`. MinIO (Langfuse's S3 event
store) is built by Nix from nixpkgs and loaded from the store; the other images
come from Docker Hub.

Secrets are generated by `nestlo-langfuse-secrets.service` at first start, in
`/var/lib/nestlo-langfuse/secrets` (root only, one env file per container):
database and Redis passwords, MinIO key, `NEXTAUTH_SECRET`, `SALT`,
`ENCRYPTION_KEY`, the admin password and the project's API key pair
(`LANGFUSE_INIT_PROJECT_*`, so no manual key creation). The only file the
gateway can read is `/var/lib/nestlo-langfuse/otlp-headers`
(`Authorization: Basic base64(pk:sk)`, mode 0640, group `nestlo`). Nothing
secret is in the Nix store. The secrets persist across restarts; deleting the
directory and the podman volumes starts a fresh instance.

Spans go to `/api/public/otel/v1/traces`. Langfuse maps `gen_ai.*` attributes to
its model, usage and cost fields.

Image pins (digests resolved from Docker Hub on 2026-10-05; podman pulls by
digest, the tag is informational):

| Image | Tag | Digest |
|-------|-----|--------|
| `langfuse/langfuse` | 4.50.0 | `sha256:3d2ae888a0e6edb41fdba6e7d5baca5e4baede3a870dac7970dadd9d925b018e` |
| `langfuse/langfuse-worker` | 4.50.0 | `sha256:52f7fd41ded2f1a6acab13ff7cb1832d36dfe2cbf44adea402b7a09cfa4ce800` |
| `clickhouse/clickhouse-server` | 25.12 | `sha256:8a790dd3468db22b1d4e7b18a176f378ff5ff6053b9c48dd4ea1fa71a24c5ba6` |
| `postgres` | 17 | `sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f` |
| `redis` | 7 | `sha256:c6eabf748fc7a61dbb5a705c78bcf3d6377b1127a97d0ce965c11c44ba46896f` |

The tags 25.12, 17 and 7 move with patch releases, so those digests are a
snapshot of today's image; bump them in `langfuse.images` when you update.

## The OpenLIT stack

Two containers on `nestlo-openlit`: OpenLIT 2.1.0 (UI plus its OpenTelemetry
collector, which writes to ClickHouse) and ClickHouse. UI on
`127.0.0.1:3301`, OTLP/HTTP receiver on `127.0.0.1:4328`. The ClickHouse
password is generated into `/var/lib/nestlo-openlit/secrets`. OpenLIT's OTLP
receiver does not authenticate, which is why it is only published on loopback.
ClickHouse gets the trace tables from the SQL OpenLIT ships (traces only; metric
and controller tables are not created). OpenLIT creates its first user at first
sign-up in the UI.

## Limits

- Not verified in this repository's test environment (no registry access, no
  KVM): that the Langfuse and OpenLIT containers start, that Langfuse's OTLP
  endpoint accepts the JSON encoding (its documentation says HTTP/JSON and
  protobuf are supported, gRPC is not), and that OpenLIT's collector accepts
  these spans. The exporter and its attribute mapping are unit tested against a
  local OTLP sink, and `tests/llm-observability.nix` covers the gateway end to
  end with a sink (needs the gateway patch).
- OpenLIT's compose file uses ClickHouse 24.4.1; this module uses the 25.12
  image that the Langfuse stack pins (the 24.4.1 digest could not be resolved
  offline).
- Langfuse needs about 3-4 GB of RAM; the OpenLIT stack about 1.5 GB.
- The containers are rootful podman, with `no-new-privileges`, memory limits
  and, for the app containers and MinIO, all capabilities dropped. They are
  reachable only through the loopback port and the private podman network.
- One span per request, not per conversation or agent run: the gateway does not
  see sessions. Spans from one agent share `nestlo.agent.id`, not a trace.
- Streaming spans cover the whole response; time to first token is not
  recorded.
- Trace context towards agents is not propagated. The exporter does accept a
  W3C `traceparent` in the log entry (`entry["traceparent"]`), and the gateway
  could set it from an incoming `traceparent` request header so an agent
  that already traces its work gets the gateway span as a child; that is not
  wired. Propagating a context the other way, to agents, would mean a response
  header (`traceparent` of the gateway span) set in `send_head`, also not done.
