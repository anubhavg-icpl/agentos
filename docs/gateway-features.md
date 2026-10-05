# Model gateway features

Features of the model gateway (`agentos-model-gateway`), all applied to
requests that agents send through `http://127.0.0.1:8080/agent/<id>/<provider>/...`.

| Feature | Where it is configured | Admin endpoint / CLI |
|:---|:---|:---|
| [Loop detection](#loop-detection) | `agentos.circuit-breaker` | `agentos-breaker reset-loop <id>` |
| [Model routing](#model-routing) | `agentos.budget-controller.routing` | `agentos budget routing [<agent> <provider> <model>]` |
| [Record and replay](#record-and-replay) | `agentos.networking.recordSessions` | `agentos-replay` |
| [Message bus](#message-bus) | always on | `agentos-msg`, MCP server `agentos-bus` |
| [Budget reservation](#budget-reservation) | `agentos.budget-controller` | |
| [Agent tokens and the 401 throttle](#agent-tokens-and-the-401-throttle) | `agentos.circuit-breaker` | |
| [Failing closed](#failing-closed) | always on | |
| [Providers](#providers) | `agentos.networking.providers` | |
| [Cache pricing and unreadable usage](#cache-pricing-and-unreadable-usage) | `pricing.json` | |
| [Fallbacks](#fallbacks) | `agentos.networking.providers.<name>.fallbacks` | |
| DLP on request bodies | `agentos.gateway.dlp` | see [dlp.md](dlp.md) |
| Audit events for requests, refusals and auth failures | `agentos.audit` | see [audit.md](audit.md) |

The gateway reads its settings from `/etc/agentos/services.toml`; the NixOS
options below generate the `[limits]`, `[routing]`, `[recording]` and `[bus]`
tables. Admin endpoints are served on the admin socket only
(`/run/agentos-gateway/admin.sock`, group `agentos`), so the sandboxed
`agentos-agent` user cannot reach them.

## Loop detection

An agent stuck repeating itself keeps sending the same conversation tail. The
gateway hashes the last few messages (Anthropic Messages, OpenAI Chat
Completions) or input items (OpenAI Responses) of each request body, ignoring
`cache_control` markers and surrounding whitespace. When the same fingerprint
arrives `loopRepeatThreshold` times in a row within `loopWindowSec` of the
first, the gateway answers `429` with error type `loop_detected` and does not
contact the provider. The first refusal publishes a `loop_detected` event; the
notifications module reports it in the `agent-error` group. A different
request ends the run, and so does the window expiring.

Ids and times that change on every retry do not hide a loop. Before hashing,
the gateway replaces `tool_use_id`, `call_id`, `request_id` and timestamp
fields, and inside text: UUIDs, ISO timestamps, clock times (`10:00:01`),
Unix epochs, long hex strings and ids such as `toolu_...`, `call_...`,
`msg_...`, with placeholders. Other differences (an issue number, a file
name) still make requests distinct. Gemini `contents` are fingerprinted too.

A second shape is caught as well: two requests alternating A, B, A, B, ...
`loopAlternationLength` consecutive requests of that pattern within
`loopWindowSec` (a sliding window of the last requests) get the same `429
loop_detected`, and the first refusal publishes a `loop_detected` event with
`kind = "alternation"`. A third distinct request breaks the pattern. 0
disables it; values below 4 are treated as 0.

```nix
agentos.circuit-breaker = {
  enableLoopDetection = true;   # default
  loopRepeatThreshold = 5;      # default
  loopWindowSec = 600;          # default
  loopAlternationLength = 8;    # default; 0 disables A/B detection
};
```

`agentos-breaker reset-loop <agent-id>` clears an agent's state. A growing
conversation never matches itself, so normal tool loops are not affected.
Requests without `messages` or `input` (for example model listings) are not
fingerprinted.

## Model routing

Rules rewrite the `model` field of the request body before it is forwarded.
They are applied in this order:

1. Static rewrites: `agentRewrites` (agent id prefix, longest prefix wins),
   then `rewrites` (global).
2. With `strategy = "cheapest"`: if the model is in an equivalence group,
   the cheapest member according to `pricing.json` (input plus output price
   per million tokens).
3. Budget-aware downgrade: once an agent has used `downgrade.thresholdPercent`
   of its daily budget, the model is replaced by `downgrade.models.<provider>`,
   unless that model is not cheaper than the current one.

```nix
agentos.budget-controller.routing = {
  strategy = "cheapest";
  rewrites."claude-opus-5-5" = "claude-sonnet-5-5";
  agentRewrites."ci-"."claude-sonnet-5-5" = "claude-haiku-4-5";
  equivalenceGroups = [ [ "claude-sonnet-5-5" "claude-haiku-4-5" ] ];
  downgrade = {
    thresholdPercent = 80;
    models.anthropic = "claude-haiku-4-5";
  };
};
```

A request is never routed to another vendor's model: the target's `provider`
in `pricing.json` must equal the requested model's. A rule that would cross
vendors is skipped with a log warning. The routed model is what the provider
receives and what the request is priced with. The request log
(`/var/lib/agentos/logs/<agent>.log`) records `original_model`,
`routed_model` and `route_reason` for routed requests.

`agentos budget routing` prints the configured rules. With
`<agent> <provider> <model>` it shows how that request would be routed right now
(the agent's current budget use counts).

## Record and replay

With `agentos.networking.recordSessions = true` the gateway stores every
request/response pair at `/var/lib/agentos/recordings/<agent-id>/<seq>.json`
(`<seq>` is `000001`, `000002`, ...). The directory is `0750 agentos:agentos`,
so operators in the `agentos` group can read it. Recording a single agent:
`agentos-replay record <agent-id>` (and `... off`).

A file holds the request method, path and body (with a canonical SHA-256 of the
body), and the response status, a subset of headers (`content-type`,
`request-id`, `x-request-id`) and the full body. Streamed responses are stored
raw. Credentials are not stored: the gateway records what the client sent, and
managed keys are injected after that. Recordings contain prompts and
completions, so treat them like the workspace.

Replay answers an agent from a recording:

```
agentos-replay list                    # recorded sessions
agentos-replay show <recording> [seq]  # requests of a session, or one in full
agentos-replay start <recording> [id]  # register replay for a new agent id
agentos-replay status <id>
agentos-replay stop <id>
```

`start` registers the replay through the admin socket
(`PUT /_agentos/replay/<agent> {"recording": "<agent-id>"}`) and prints the
environment to run the agent with (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, and
the `agentos-managed` keys). `agentos spawn` chooses its own agent id, so start
the agent in your own shell with those variables, in a workspace that matches
the recorded run.

Requests are answered in order, without contacting the provider and at zero
cost (budgets and rate limits do not apply). Each request must match the next
recorded one (method, path, canonical body hash); otherwise the gateway answers
`409` with error type `replay_diverged` and `error.details` (sequence number,
expected and received hashes) and does not advance. After the last recorded
request it answers `409 replay_exhausted`. Replayed responses carry an
`X-AgentOS-Replay: <recording>/<seq>` header and are logged with `replayed`.

The hash covers the body the client sent, before routing. An agent that puts
timestamps or random ids in its prompts diverges on its first changed request;
that is the point of the check.

## Message bus

Agents talk to each other through the gateway, backed by Redis streams (at most
1000 messages per topic, 64 KiB per message).

```
POST /agent/<id>/bus/<topic>                                    {"body": "..."}  (or any JSON, or plain text)
GET  /agent/<id>/bus/<topic>?after=<cursor>&wait=<sec>&limit=<n>
```

A message is `{id, from, topic, body, ts}`. `id` is the cursor: pass the last id
seen as `after`; `after=$` means "from now on". `wait` (capped at 30 seconds)
long-polls for a message. Topics use the agent id alphabet (letters, digits,
`.`, `_`, `-`). Topic `@<agent-id>` is that agent's inbox: anyone can send to it,
only that agent (and operators on the admin socket) can read it.

The sender is taken from the URL, like the agent id in every gateway path:
agents share the loopback listener, so a hostile agent can pose as another.
Treat the bus as a coordination channel between agents you trust equally.

For operators: `agentos-msg send [--from <name>] <topic> <text>`,
`agentos-msg read <topic> [--after <cursor>] [--wait <sec>] [--json]`,
`agentos-msg topics`. Group members use the admin socket; others can send and
read shared topics over TCP as agent `operator`.

For agents: the MCP server `agentos-bus` (registered in
`/etc/agentos/mcp-servers.json`, command `agentos-mcp-bus`) provides the tools
`send_message(topic, text)` and `read_messages(topic?, after?, wait?)` (topic
defaults to the agent's inbox). It reads `AGENTOS_AGENT_ID` and the gateway
address from the environment `agentos spawn` sets (`ANTHROPIC_BASE_URL` has the
shape `http://127.0.0.1:8080/agent/<id>/anthropic`; `AGENTOS_GATEWAY_URL`
overrides it).

## Budget reservation

Before forwarding, the gateway holds an estimated cost against the agent's
and the global daily budget: the input size (about 4 bytes per token) plus
`max_tokens` (or `defaultMaxTokens` when the request sets none) at the
model's output price. If the hold does not fit, the request is refused with
`402` and never reaches the provider. When the response ends, the hold is
replaced by the actual cost, so concurrent requests cannot overshoot a
budget. Requests to a zero-cost provider reserve nothing.

```nix
agentos.budget-controller = {
  reserveBudget = true;      # default
  defaultMaxTokens = 4096;   # default
};
```

## Agent tokens and the 401 throttle

Agents authenticate with the token `agentos spawn` registers. It can be sent
in the URL (`/agent/<id>:<token>/...`) or in the `x-agentos-token` header.
The header is preferred: the token then stays out of URLs, access logs and
the request log, and the gateway never logs a token. Operators on the admin
socket may omit it.

Failed authentications are counted per client address and minute. Beyond
`maxAuthFailuresPerMinute` (default 20; 0 disables) further failures answer
`429 rate_limited` with `Retry-After` instead of `401`, which stops token
guessing.

```nix
agentos.circuit-breaker.maxAuthFailuresPerMinute = 20;
```

## Failing closed

If the state store (Redis) is unavailable, the gateway answers `503` with
error type `store_unavailable` and `Retry-After: 5`. Without the store it
cannot authenticate, rate limit or meter, so it forwards nothing rather than
proxying unmetered traffic.

## Providers

Each entry of `agentos.networking.providers` names an adapter with `api`:

| `api` | Provider | Key header |
|:---|:---|:---|
| `anthropic` | Messages API | `x-api-key` |
| `openai` | Chat Completions and Responses | `Authorization: Bearer` |
| `openai-compatible` | Local server in the OpenAI format (ollama, llama.cpp, vLLM) | none needed |
| `azure-openai` | Azure OpenAI, deployments in the path; set `apiVersion` | `api-key` |
| `gemini` | Google Generative Language API | `x-goog-api-key` |

AWS Bedrock and Google Vertex AI are not supported (they need request signing
or OAuth tokens). A provider without `keyFile` works: no key is injected and
the client's own credentials are passed through (for `openai-compatible`
nothing is sent). Usage is read per adapter, so token metering and pricing work
for each.

### Zero-cost providers

`zeroCost = true` makes every model on that provider cost $0 (local
inference, a flat-rate gateway on your LAN). Tokens are still counted, nothing
is reserved, and the log shows `cost_usd = 0`. The default is `true` for
`openai-compatible` and `false` otherwise; `zeroCost = false` prices a
compatible server from `pricing.json`. A model that is not in `pricing.json`
and not on a zero-cost provider keeps the conservative default price.

Cost routing can send requests to such a provider: map a model to it with
`routing.targets` and put it in an equivalence group with `strategy =
"cheapest"`. Its unit cost is 0, so it wins, the user's key for the original
provider is not sent to it, and routing never crosses wire formats.

```nix
agentos.networking.providers.local = {
  baseUrl = "http://127.0.0.1:11434";
  api = "openai-compatible";      # zeroCost defaults to true
};
agentos.networking.providers.lan = {
  baseUrl = "http://10.0.0.5:8000";
  api = "openai";
  zeroCost = true;
};
```

## Cache pricing and unreadable usage

Anthropic cache writes with the 1 hour TTL are priced separately from 5
minute writes, at `cache_write_1h_per_1m` in `pricing.json` (default: twice
the input price). If a successful response carries no readable usage (a
format the gateway does not parse), the gateway charges the reservation
estimate instead of $0, logs a warning, and marks the log entry
`usage_estimated`.

## Fallbacks

`fallbacks` on a provider lists other providers to try, in order, when it
answers 5xx or 429, times out or cannot be reached before the first response
byte. A fallback is a provider name or `{ provider; model; }` to request
another model. Fallbacks must use the same wire format, and need a key or be
a local server; others are ignored with a warning. The client's credentials
are never sent to a fallback, its configured key is injected. Nothing is
retried once a response has started. The log records `fallback_provider` or
`fallbacks_failed`.

```nix
agentos.networking.providers.openai.fallbacks =
  [ "azure" { provider = "local"; model = "llama3.1"; } ];
```

## Testing

- `services/tests/`: `test_loops.py`, `test_routing.py`, `test_replay.py`,
  `test_bus.py`, `test_mcp_bus.py`, `test_reservation.py`, `test_auth.py`,
  `test_failclosed.py`, `test_providers.py`, `test_usage.py`,
  `test_unparsed.py`, `test_fallbacks.py` (run by `nix build .#services`).
- `tests/gateway-features.nix`: a VM test covering all four features against a
  mock provider.
