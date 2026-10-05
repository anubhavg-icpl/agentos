# A2A and ACP (`nestlo.a2a`)

Two open protocols (both Apache-2.0) connect Nestlo agents to other software:

* **A2A**, the Agent2Agent protocol
  ([a2aproject/A2A](https://github.com/a2aproject/A2A)): other agent systems
  discover a Nestlo agent from its Agent Card and send it work. `nestlo-a2a`
  serves Nestlo agents as A2A agents.
* **ACP**, the Agent Client Protocol
  ([agentclientprotocol](https://github.com/agentclientprotocol)): editors
  (Zed, herdr, JetBrains, ...) drive a coding agent over stdio.
  `nestlo-acp <agent>` starts an installed agent in its ACP mode, with its model
  calls through the Nestlo model gateway.

They are unrelated protocols; both live in this module.

## A2A server

```nix
nestlo.runtime = { enable = true; operators = [ "alice" ]; agents.claude = "claude"; };
nestlo.orchestration.enable = true;
nestlo.networking.enable = true;          # needed for budgetUSD

nestlo.a2a = {
  enable = true;
  tokenFile = "/run/secrets/nestlo-a2a-tokens";   # root-only, see below
  agents.coder = {
    agent = "claude";                              # runtime agent with a taskCommand
    workspace = "widgets";                         # fixed: clients cannot choose it
    description = "Fixes bugs in the widgets repository";
    budgetUSD = 5;
    gate = true;                                   # an operator approves each task
  };
};
```

Token file, one client per line (`openssl rand -hex 32` makes a token):

```
partner-bot:3f1c...e9a2
ci:9b07...51de:coder,docs
```

`name:token` lets the client use every agent; `name:token:a,b` limits it to
those agents (any other looks like it does not exist).

### Endpoints

| Path | Auth | |
|------|------|-|
| `GET /.well-known/agent-card.json` | none (`publicCard`) | card of the default agent (the only one, or `defaultAgent`) |
| `GET /agents/<name>/.well-known/agent-card.json` | none | card of one agent |
| `POST /agents/<name>` | Bearer | JSON-RPC 2.0 of that agent; streaming answers are `text/event-stream` |
| `POST /` | Bearer | JSON-RPC of the default agent |
| `GET /health` | none | liveness |

The card path and shape follow A2A v1.0 (`supportedInterfaces`,
`securitySchemes.bearer.httpAuthSecurityScheme`, `capabilities.streaming`); with
`protocolVersion = "0.3"` the card is the v0.3 one (`url`,
`preferredTransport`, `type: http`). Only the JSON-RPC binding is implemented
(no gRPC, no HTTP+JSON); push notifications, extended cards and card
signatures are not.

### Methods

Both method spellings are accepted and answered in their own dialect:

| v1.0 | v0.3 | |
|------|------|-|
| `SendMessage` | `message/send` | creates a task; blocks until it finishes, needs approval, or `blockTimeoutSec` passes (v1.0: `configuration.returnImmediately: true` returns at once; v0.3: blocks only with `configuration.blocking: true`) |
| `SendStreamingMessage` | `message/stream` | creates a task and streams the task, status updates and the output artifact (SSE) |
| `GetTask` | `tasks/get` | |
| `CancelTask` | `tasks/cancel` | `TaskNotCancelable` (-32002) once finished |
| `SubscribeToTask` | `tasks/resubscribe` | stream of a running task |
| `ListTasks` | | the client's own tasks of that agent, `pageSize` <= 100, no paging |

v1.0 uses `ROLE_USER`, `TASK_STATE_*` and parts without `kind`; v0.3 uses
`user`, `submitted`/`working`/... and `kind`. Other methods answer -32601;
push-notification methods -32003; `GetExtendedAgentCard` -32007.

### How a message becomes a task

The text parts of the message (and data parts, as JSON text) become the prompt
of one orchestrator task with `origin = "a2a:<client>/<agent>"`. Everything
else comes from the agent's configuration: agent, workspace, budget, timeout,
isolation, gate, model. The request cannot set them, and unknown fields in it
are ignored. File parts are refused (-32005). `message.messageId` is the
task's `dedupe_key`, so a retried message returns the live task. A message with
`taskId` is refused (-32004): Nestlo tasks are single-shot.

| Nestlo status | A2A state |
|---------------|-----------|
| `awaiting_approval` | `INPUT_REQUIRED` (an operator runs `nestlo task approve`; the client cannot) |
| `queued` | `SUBMITTED` |
| `running` | `WORKING` |
| `succeeded` | `COMPLETED` |
| `failed`, `timeout` | `FAILED` (status message carries the error) |
| `cancelled` | `CANCELED` |
| `skipped` | `REJECTED` |

The tail of the agent's output is the artifact `output`; `metadata.nestlo` has
the Nestlo status, exit code and branch.

### Security

* Loopback by default (`address = "127.0.0.1"`); publish it with a TLS reverse
  proxy and set `publicUrl`. A non-loopback `address` is refused unless
  `allowNonLoopback`.
* Every JSON-RPC request needs a bearer token from the root-only file (a
  systemd credential; re-read on change; compared in constant time). The Agent
  Card is public unless `publicCard = false`; it carries only what you wrote in
  `description` and `skills`.
* A client sees, streams and cancels only tasks it submitted, through the agent
  they were submitted to; others are reported as not found.
* The orchestrator remains the authority: it validates the request, applies
  policy and RBAC (the service runs as user `nestlo`), honors the approval gate,
  and the model gateway enforces the budget and DLP. Use `gate = true` for any
  agent exposed to clients you do not fully trust: a prompt is code execution
  by an agent in a workspace.
* Hardened unit: `User=nestlo`, no capabilities, `ProtectSystem=strict`,
  `MemoryDenyWriteExecute`, `RestrictAddressFamilies`, private `/tmp`. Request
  bodies are capped (1 MiB) before they are read and must arrive within 30 s;
  idle connections time out after 30 s; at most 128 connections and 8 open
  streams per client; `/health` and the default card reveal no configuration.

### Options

| Option | Default | |
|--------|---------|-|
| `enable` | `false` | |
| `address`, `port` | `127.0.0.1`, `9966` | |
| `allowNonLoopback` | `false` | |
| `publicUrl` | `null` | base URL written into the cards (default `http://<address>:<port>`) |
| `tokenFile` | `null` (required) | |
| `protocolVersion` | `"1.0"` | card dialect, `"1.0"` or `"0.3"` |
| `publicCard` | `true` | |
| `blockTimeoutSec` | `120` | |
| `defaultAgent` | `null` | |
| `agents.<name>.agent` / `.workspace` | required | |
| `agents.<name>.description`, `.version`, `.skills` | | card contents |
| `agents.<name>.budgetUSD`, `.timeoutSec`, `.model`, `.maxRetries`, `.priority` | `null` | passed to every task |
| `agents.<name>.isolate` | `true` | a git worktree per task |
| `agents.<name>.gate` | `false` | hold each task for approval |
| `acp.enable` | `false` | install `nestlo-acp` |
| `acp.agents.<name>.command` / `.env` | see below | |

## ACP: `nestlo-acp`

```nix
nestlo.a2a.acp.enable = true;
```

```sh
nestlo-acp --list
nestlo-acp claude --workspace widgets --budget 5
```

The launcher starts the agent in ACP mode on stdin/stdout, in the workspace,
as the calling user. Like `nestlo spawn` it registers a gateway agent id
(`acp-<agent>-<time>-<rand>`) with a fresh token (and a budget with
`--budget`) and sets `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` to the
per-agent gateway URLs, `*_API_KEY=nestlo-managed` where the gateway holds the
key, and `NESTLO_AGENT_ID`, `NESTLO_WORKSPACE`. Registering needs membership
in the `nestlo` group (an operator). Nothing but the agent writes to stdout.

| Name | Command | Source |
|------|---------|--------|
| `claude` | `claude-agent-acp` (nixpkgs `claude-agent-acp`) | adapter [agentclientprotocol/claude-agent-acp](https://github.com/agentclientprotocol/claude-agent-acp), npm `@agentclientprotocol/claude-agent-acp` (formerly Zed's `claude-code-acp`) |
| `codex` | `codex-acp` (nixpkgs `codex-acp`) | adapter [agentclientprotocol/codex-acp](https://github.com/agentclientprotocol/codex-acp) |
| `gemini` | `gemini --acp` | Gemini CLI docs `cli/acp-mode.md`; `--experimental-acp` is the deprecated spelling |
| `goose` | `goose acp` | `goose --help`: "Run goose as an ACP agent server on stdio" |
| `opencode` | `opencode acp` | OpenCode docs (ACP page) |
| `qwen` | `qwen --acp` | Qwen Code CLI option `acp` (`--experimental-acp` deprecated) |

Add or replace entries with `nestlo.a2a.acp.agents.<name>.command`.

Editor configuration, for example Zed (`settings.json`):

```json
{ "agent_servers": {
    "Nestlo Claude": { "command": "nestlo-acp", "args": ["claude", "--workspace", "widgets"] },
    "Nestlo Codex":  { "command": "nestlo-acp", "args": ["codex",  "--workspace", "widgets"] } } }
```

### ACP limits

* The agent runs as the calling user, not in the `nestlo spawn` sandbox
  (ACP needs the editor's stdio and, for most agents, the editor's file
  access). It is like `nestlo spawn --unsandboxed`. Use A2A or the
  orchestrator for sandboxed, unattended runs.
* Whether an agent routes its model calls through the gateway depends on it
  honoring the variables the launcher sets: `ANTHROPIC_BASE_URL` /
  `OPENAI_BASE_URL` (Claude Code, Codex, Qwen Code, OpenCode), `ANTHROPIC_HOST` /
  `OPENAI_HOST` (Goose; verified in goose v1.28 `providers/`) and, when the
  gateway has a `gemini` provider, `GOOGLE_GEMINI_BASE_URL` (Gemini CLI). An agent
  that uses another variable or its own login talks to its provider directly,
  outside budgets and DLP.
* The adapters' own login flows (Claude subscription, ChatGPT) are not
  involved when the gateway holds the key; with `nestlo-managed` keys the
  gateway's provider key is used.
* Verified against upstream sources at the nixpkgs versions (claude-agent-acp
  0.36.1, codex-acp 0.13.0, Gemini CLI 0.42 `--acp`, goose 1.28 `acp`, OpenCode
  1.15 `acp`, Qwen Code 0.16 `--acp`): the commands and flags exist; they were
  not started in a VM.

## Limits

* JSON-RPC binding only; no push notifications; no extended card; no card
  signatures; one task per message; file parts are refused.
* The server polls the orchestrator once a second for blocking calls and
  streams; the orchestrator has no event feed.
* The server does not use Redis directly; everything goes through the
  orchestrator's socket and its RBAC.
* Tested with the repository's unit tests (`services/tests/test_a2a.py`,
  against the real orchestrator with fakeredis) and a VM test
  (`tests/a2a.nix`, not run here: no KVM).
