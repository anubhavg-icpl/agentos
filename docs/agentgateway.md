# agentgateway (`nestlo.agentgateway`)

[agentgateway](https://github.com/agentgateway/agentgateway) (Apache-2.0, a
Linux Foundation project, Rust) is a proxy for agent traffic: MCP, A2A and LLM
requests. `nestlo.agentgateway` runs it on loopback as the **enforcement
point in front of Nestlo's MCP servers**:

| What | How |
|------|-----|
| One MCP endpoint | `http://127.0.0.1:9961/mcp` (streamable HTTP, `/sse` for old clients) multiplexes every enabled server of `/etc/nestlo/mcp-tools.json` and `mcp-servers.json`, plus `mcp.extraServers`. Tools are named `<server>_<tool>`. |
| Per-agent authorization | every agent has its own API key and a tool allow-list. A tool that is not allowed is hidden from `tools/list` and refused on `tools/call`. |
| LLM route | `http://127.0.0.1:9962/v1/...` forwards **only** to the Nestlo model gateway, as gateway agent `agentgateway` with a daily budget: budgets, DLP, loop detection and the audit trail apply, and provider keys never reach agentgateway. |
| Tracing | OTLP spans to the Nestlo observability collector when `nestlo.observability` is on. |
| Hardening | dedicated user, `ProtectSystem=strict`, no capabilities, MCP servers started with a cleared environment. |

## Status of the package

agentgateway is not in nixpkgs (`pkgs.agentgateway` and
`pkgs.unstable.agentgateway` do not exist), so `nixos/packages/agentgateway.nix`
builds v1.6.0 from source; `src.hash` and `cargoHash` are verified. The
embedded web UI is not built (it needs a pnpm build); the admin API on
`127.0.0.1:9963` is.

## Enable

```nix
nestlo.runtime = { enable = true; operators = [ "alice" ]; };
nestlo.mcp-registry.enable = true;   # and/or nestlo.mcp-servers.enable
nestlo.networking.enable = true;     # the Nestlo model gateway, for the LLM route

nestlo.agentgateway = {
  enable = true;

  # Which agent may call which tool. Names are MCP registry server names
  # and the server's own tool names; [ "*" ] is every tool of the server.
  mcp.agents = {
    claude-code.tools = { git = [ "*" ]; fetch = [ "fetch" ]; memory = [ "*" ]; };
    reviewer.tools.git = [ "git_status" "git_diff" "git_log" ];
  };

  # Secrets the registry servers reference as ${GITHUB_TOKEN} etc.
  environmentFile = "/run/secrets/agentgateway-env";

  llm = {
    enable = true;
    budgetUsd = 10;
    models.sonnet = { provider = "anthropic"; model = "claude-sonnet-4-5"; };
  };
};
```

Print the MCP client configuration of an agent (needs read access to the key,
which is group `nestlo` by default):

```sh
nestlo-agentgateway-mcp-config claude-code
# {"mcpServers":{"nestlo":{"type":"http","url":"http://127.0.0.1:9961/mcp",
#   "headers":{"Authorization":"Bearer agw_..."}}}}
```

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Run agentgateway. |
| `package` | `pkgs.nestlo.agentgateway` | The build above. |
| `listenAddress` | `127.0.0.1` | Address of the MCP and LLM listeners. A non-loopback address is refused unless `allowNonLoopback`. |
| `mcpPort`, `llmPort` | `9961`, `9962` | Listener ports. |
| `adminPort`, `metricsPort`, `readinessPort` | `9963`, `9964`, `9965` | Admin API, Prometheus metrics, readiness probe (always `127.0.0.1`). |
| `keyGroup` | `nestlo` | Group that may read the per-agent keys in `/var/lib/nestlo-agentgateway/keys`. |
| `environmentFile` | `null` | Root-only `NAME=value` file for MCP server secrets. Unset variables expand to the empty string. |
| `mcp.servers` | `null` | Registry servers to expose; `null` = every enabled one. |
| `mcp.excludeServers` | `[ "nestlo-bus" "agentgateway" ]` | Never exposed: `nestlo-bus` needs the calling agent's environment; `agentgateway` is this module's own registry entry. |
| `mcp.extraServers.<name>` | `{ }` | Extra servers: `command`/`args`/`env` (stdio) or `host`/`port`/`path` (remote streamable HTTP). |
| `mcp.path` | node, uv, git, coreutils, bash | `PATH` of the stdio servers (the registries start most with `npx` and `uvx`). |
| `mcp.agents.<id>.tools` | `{ }` | Server -> allowed tool names or `[ "*" ]`. |
| `mcp.agents.<id>.allowPromptsAndResources` | `false` | Also allow MCP prompts and resources of every server. |
| `llm.enable` | `false` | The LLM endpoint. Needs `nestlo.networking.enable` and at least one model. |
| `llm.agentId`, `llm.budgetUsd` | `agentgateway`, `10` | Model gateway identity and daily budget of every call through the endpoint. |
| `llm.models.<name>` | `{ }` | `provider` (`anthropic` or `openai`, a Nestlo gateway provider path) and `model`. Clients request `<name>`. |
| `tracing.enable` | `nestlo.observability.enable` | OTLP traces. |
| `tracing.endpoint` | `127.0.0.1:<otelCollectorPort>` | OTLP gRPC endpoint. |
| `tracing.sampling` | `"true"` | CEL expression deciding whether a request is traced. |
| `extraConfig` | `{ }` | Top-level agentgateway config merged (shallow) over the generated one. |
| `registerInRegistry` | `true` | Adds an `agentgateway` entry to `nestlo.mcp-registry.extraToolServers`. |
| `configFile`, `validateEnv` | read-only | The generated configuration, and the placeholder environment under which `agentgateway --validate-only -f <configFile>` succeeds. |

## How it works

The configuration is generated from the options and the two registry files
(read at evaluation time) and is YAML-compatible JSON in the Nix store. It
follows the upstream schema (`schema/config.json` at v1.6.0; the generated
file validates against it):

* `gateways.mcp` / `gateways.llm` bind the two ports on `listenAddress`;
* `mcp.targets` has one `stdio` target per server (`clear_env: true`, with only
  `PATH`, `HOME` and the CA bundle plus the server's own env) and one `mcp`
  target per ToolHive-isolated server;
* `mcp.policies.apiKey` authenticates `Authorization: Bearer <key>`
  (`mode: strict`) and attaches `agent: <id>` to the request; the keys are
  stored hashed (`keyHash: sha256:...`);
* `mcp.policies.mcpAuthorization.rules` are CEL expressions, one per
  (agent, server): `apiKey.agent == "reviewer" && has(mcp.tool) &&
  mcp.tool.target == "git" && mcp.tool.name in ["git_status"]`. agentgateway
  evaluates them per tool, so `tools/list` is filtered too;
* `llm.models[]` point at `http://127.0.0.1:<gatewayPort>/agent/agentgateway:<token>/anthropic/v1`
  (or `/openai/v1`) with the placeholder key `nestlo-managed`, which the model
  gateway replaces with the real provider key.

Secrets stay out of the store: `nestlo-agentgateway-setup.service` (root,
before the main unit) creates one key per agent in
`/var/lib/nestlo-agentgateway/keys/<id>` (mode `0640 root:<keyGroup>`),
registers the gateway agent and budget through the Nestlo model gateway admin
socket, and writes `/var/lib/nestlo-agentgateway/env` (`0600 root`) with the
key hashes and the gateway token. agentgateway expands `${AG_KEYHASH_n}` and
`${NESTLO_GW_TOKEN}` in the configuration from that environment.

Server names must not contain `_` (it separates server and tool in tool
names). `$` in values would be expanded by agentgateway; avoid it in
`extraConfig`.

## Pointing agents at agentgateway instead of at individual servers

Nestlo's registries (`mcp-registry`, `mcp-servers`) only list servers; no
module writes per-agent MCP client configs. To make agents use the single
endpoint:

1. Give each agent's MCP client the output of
   `nestlo-agentgateway-mcp-config <agent>` (above), or enable the registry
   entry (`registerInRegistry`, an `npx mcp-remote` bridge that reads the key
   from `NESTLO_AGENTGATEWAY_KEY`).
2. So that the registries stop advertising the individual servers to
   clients, the registry modules need a change that is **not made here**
   (they are shared files). Today `/etc/nestlo/mcp-tools.json` and
   `mcp-servers.json` are both the list clients see and the source this
   module reads at evaluation time, so hiding entries from clients would
   also hide them from the gateway. The change: give each registry module a
   read-only option with the full server definitions
   (`nestlo.mcp-registry.definitions`, `nestlo.mcp-servers.definitions`, the
   attribute sets that are now serialized into the JSON) and a switch
   `advertise` (default `true`) that empties the `tools`/`servers` list in the
   `/etc` file. `mcp-registry` already declares `enableBuiltinTools` without
   using it; it is the natural place for the first switch. This module would
   then read the `definitions` options instead of parsing the `/etc` text,
   and `nestlo.agentgateway.registerInRegistry` (already on by default) is
   the one entry left for clients.

## Security notes

* Whoever can read `keys/<id>` can act as that agent towards the gateway. The
  default group is `nestlo` (operators). All sandboxed agents run as the one
  user `nestlo-agent`, so per-agent keys separate **agents by credential, not
  by operating-system user**: do not add `nestlo-agent` to `keyGroup` unless
  that is acceptable, and hand each agent its key through the environment you
  start it with.
* stdio servers run as the `nestlo-agentgateway` user (member of
  `nestlo-agent`, writable: the workspace root) inside the unit's sandbox:
  `ProtectSystem=strict`, no capabilities, private `/tmp`. They have network
  access and a writable home under `/var/lib/nestlo-agentgateway/home`; for
  stronger isolation run the server through `nestlo.toolhive`
  ([toolhive.md](toolhive.md)).
* The MCP servers' own credentials (`environmentFile`) are available to every
  agent that may call the server. Scope tools tightly.
* `failureMode` is `failOpen`: a server that fails to start (for example a
  registry entry whose command is not installed) is skipped instead of
  taking the endpoint down.

## Limits

* The VM test `tests/agentgateway.nix` runs `agentgateway --validate-only`, a real
  stdio MCP server and per-agent authorization.
* The admin API (`adminPort`, loopback) is unauthenticated: any local process
  can read `/config_dump` (which contains the model gateway token inside the
  LLM `baseUrl`) or call `/quitquitquit`. Do not run untrusted local code on
  the same network namespace, or block the port for other users (for example an
  `iptables -m owner` rule that admits only `nestlo-agentgateway`).
* Audit: agentgateway logs JSON request logs to the journal
  (`journalctl -u nestlo-agentgateway`); they are **not** forwarded to the
  Nestlo audit log. LLM traffic is audited by the Nestlo model gateway.
* The LLM route offers Anthropic Messages and OpenAI Chat Completions
  providers of the Nestlo model gateway; other providers are not mapped.
* A2A: agentgateway can also front A2A agents; this module does not configure
  it. `nestlo.a2a` ([a2a.md](a2a.md)) is a separate server.
* The embedded UI is not built.
