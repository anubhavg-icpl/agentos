# Beacon (`nestlo.beacon`)

[Agent Beacon](https://github.com/Asymptote-Labs/agent-beacon) (MIT, Go) captures
what coding agents do, in many harnesses at once, into one local JSONL log:
sessions, prompts, tool calls, commands, file edits, approvals, MCP calls and
token usage, in one normalized event format. On top of that log it gives you
session replay (`beacon traces`, a local dashboard), offline threat-detection
rules (`beacon scan`), token and cost reports, and a review loop that turns
selected sessions into **approved project memory** which later agents recall
over MCP and Agent Skills, whichever harness they run in.

`nestlo.beacon` makes it part of Nestlo, local-first: everything below runs on
the machine, nothing leaves it unless you turn on `nestlo.beacon.cloud`
(off, see "Beacon Cloud").

| What | How |
|------|-----|
| Package | `packages.<system>.agent-beacon`: `beacon` (CLI), `beacon-hooks` (hook adapter) and `beacon-otelcol` (collector), all built from the pinned source |
| Collector | `beacon-collector.service`: OTLP on `127.0.0.1:4317/4318`, writes `/var/lib/beacon/logs/runtime.jsonl`; own user, no capabilities, `IPAddressDeny=any` except loopback |
| Capture | `beacon-setup-<user>.service` per user runs Beacon's own installer (`beacon endpoint install --user --no-start --service none`): hooks, plugins and OTLP settings are **merged** into each agent's configuration |
| The sandboxed agent user | logs under its home (the only place `nestlo spawn` lets it write); `beacon-relay-nestlo-agent.service` appends that to the shared log; approved memory is copied to it |
| Retention | rotated segments are compressed into `/var/lib/beacon/archive` and pruned after `retention.days` |
| Knowledge back to agents | skill pack `beacon` ([skills.md](skills.md)), the `beacon` MCP server in the MCP registry (`nestlo-beacon-mcp`), and approved memory promoted to project skills |
| Observability | the collector's metrics on `127.0.0.1:9975`, scraped by `nestlo.observability` |
| Helper | `nestlo-beacon status\|log\|repair\|archive` |

## Enable

```nix
nestlo.runtime = { enable = true; operators = [ "alice" ]; };

nestlo.beacon = {
  enable = true;

  # who is captured and may read the shared log (default: the operators)
  users = [ "alice" ];

  # which agents get hooks/plugins/OTLP (default "auto": every supported agent
  # Beacon finds for the user)
  # harnesses = [ "claude" "codex" "opencode" ];

  retention.days = 180;
};
```

Then:

```console
$ nestlo-beacon status            # collector, health check, log, endpoint status
$ beacon traces                   # browse sessions in the terminal
$ beacon endpoint dashboard       # local web view (nestlo.beacon.dashboard.enable runs it as a service)
$ beacon scan                     # threat-detection rules over the log, offline
$ beacon token-usage              # token and cost rollups
$ beacon memory evaluations run --dry-run --limit 10   # what distillation would score (no network)
```

Restart an agent after the first switch so it picks up its new hooks.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Install Beacon and set everything below up |
| `package` | `pkgs.nestlo.agent-beacon` | CLI, `beacon-hooks`, `beacon-otelcol` |
| `users` | `nestlo.runtime.operators` that exist | Captured users. They join the group `beacon` and read the shared log and memory store |
| `includeAgentUser` | `nestlo.runtime.enable` | Capture `nestlo-agent` (hook events via the relay, OTLP directly) |
| `isolatedUsers` | `[ ]` | More users that run in a sandbox that cannot write `/var/lib/beacon`, treated like the agent user |
| `harnesses` | `"auto"` | `"auto"` or a list of `claude codex gemini antigravity opencode cline pi omp openclaw grok prime omo dsh qwen kimi kiro muse hermes factory cursor devin-cli devin-desktop` |
| `ports.otlpGrpc` / `otlpHttp` / `health` | 4317 / 4318 / 13133 | Loopback ports. The OTLP ones are written into the agents' settings |
| `ports.metrics` | 9975 | Collector metrics (Prometheus, loopback); `null` turns them off |
| `collector.memoryLimitMiB` / `includeRuntimeMetrics` / `includeCodexSpans` | 128 / off / off | Collector tuning (see `beacon endpoint install --help` for the last two) |
| `retention.days` / `interval` | 90 / `15min` | Archive depth and how often rotated segments are archived; 0 keeps archives forever |
| `memory.shareWithAgents` / `syncInterval` | on / `10min` | Copy approved memory to the isolated users |
| `evaluator.endpoint` / `model` | unset | `BEACON_JEV_ENDPOINT` / `BEACON_JEV_MODEL` for `beacon memory evaluations run` (see "Distillation") |
| `mcp.enable` | `true` | List the MCP server in the Nestlo MCP registry |
| `skills.enable` | `true` | Turn on the `beacon` skill pack when `nestlo.skills` is enabled |
| `dashboard.enable` / `port` | off / 8765 | Run the read-only dashboard as a loopback service |
| `cloud.enable` / `vectorPackage` | off / `pkgs.vector` | Beacon Cloud forwarding. See below |

## How capture is wired

```
 operators (alice)                          nestlo-agent (sandboxed)
 agent -> hooks / plugins                   agent -> hooks / plugins
        |  (beacon-hooks --log shared)             |  (--log ~/.beacon/endpoint/logs/runtime.jsonl)
        |                                          v
        |                          beacon-relay-nestlo-agent  (group beacon, this process only)
        v                                          |
   /var/lib/beacon/logs/runtime.jsonl  <-----------+
        ^
        | beacon-collector (user beacon, loopback only)
        | OTLP 127.0.0.1:4317/4318  <- Claude Code, Codex, Gemini CLI export
```

* `beacon-setup-<user>.service` runs as the user (hardened: only the user's
  home and, for operators, the shared log directory are writable; no network).
  It calls `beacon endpoint install --user --no-start --service none --no-backfill
  --harness <harnesses> --log-path <log>` once per switch and per boot. That is
  Beacon's own installer, so the merge is Beacon's tested one: other settings and
  other hooks in `~/.claude/settings.json`, `~/.codex/config.toml`,
  `~/.gemini/settings.json`, ... stay. Beacon writes a backup
  `<file>.beacon.<time>.bak` on every run; the unit keeps only the oldest per
  file, which holds your configuration from before Beacon. The
  hook adapter is copied to `~/.beacon/endpoint/hooks/beacon-hooks` from the
  copy embedded in the CLI (the same store build), so a package update replaces
  it at the next switch. It never asks a question (`BEACON_ONBOARDING=0`),
  never backfills and never connects anywhere.
* The user's `~/.beacon/endpoint/config.json` names the shared log, so every
  `beacon` command (traces, scan, memory, mcp, ...) of an operator reads it
  without flags. `/etc/beacon/endpoint/config.json` (written by
  `beacon-endpoint-config.service`, keeping what `beacon endpoint connect`
  recorded) makes `beacon endpoint status --system` work.
* **Why a relay for the agent user.** Inside `nestlo spawn`, task runner and
  herdr units the agent user has `ProtectSystem=strict` with only its
  workspace and home writable (`nixos/packages/cli.nix`), so hooks cannot append
  to `/var/lib/beacon`. They log under the home and the relay (running as
  `nestlo-agent` with the supplementary group `beacon`, `ProtectSystem=strict`,
  loopback only) appends whole lines to the shared log, surviving rotation.
  The agent's own processes are not in the group: they cannot read the
  operators' sessions in the shared log.

### What is captured from which agent

Collection methods are Beacon's: `hook` (runtime-native hooks that execute
`beacon-hooks`), `plugin` (a Beacon-managed file the runtime loads), `otlp`
(the runtime exports OpenTelemetry to the collector). The Beacon event fields
`harness.collection_method` and `event.fidelity` say which one produced an event
and whether its action was observed or inferred.

| Agent in Nestlo | `harnesses` name | How it is captured | Written to |
|-----------------|------------------|--------------------|------------|
| Claude Code | `claude` | hooks (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse(Failure), Stop, SubagentStart/Stop, PermissionRequest, SessionEnd) + OTLP (`CLAUDE_CODE_ENABLE_TELEMETRY` and the `OTEL_*` variables, prompts and tool details on) | `~/.claude/settings.json` |
| Codex | `codex` | OTLP logs and one completed-turn trace for tokens, plus a SessionStart hook for OS-user context | `~/.codex/config.toml`, `~/.codex/hooks.json` |
| Gemini CLI | `gemini` | OTLP (`telemetry.target=local`, prompts logged) | `~/.gemini/settings.json` |
| OpenCode | `opencode` | plugin forwarding chat, session, command, permission, diff and error events | `~/.config/opencode/plugins/beacon.ts` |
| Cline | `cline` | plugin (beforeRun, beforeTool, afterTool, afterRun) | `~/.cline/plugins/beacon.ts` |
| pi (pi-coding-agent) | `pi` | extension | `~/.pi/agent/extensions/beacon.ts` |
| Qwen Code | `qwen` | hooks (no OTLP export exists) | `~/.qwen/settings.json` |
| Cursor CLI | `cursor` | hooks (Cursor's hooks.json format; Beacon documents the IDE, the CLI reading the same file was not verified) | `~/.cursor/hooks.json` |
| Factory Droid | `factory` | hooks (SessionStart, UserPromptSubmit, writes, Stop, SessionEnd); its OTLP endpoint is launch-environment only and not set | `~/.factory/settings.json` |
| Kiro CLI | `kiro` | hooks | `~/.kiro/hooks/` |
| OpenClaw | `openclaw` (opt-in) | managed plugin. Not in the default set: `nestlo.openclaw` manages `/var/lib/openclaw` itself, and combining the two is untested. Add `openclaw` to `isolatedUsers` if you try it | the OpenClaw config |
| GitHub Copilot CLI | none | needs `COPILOT_OTEL_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318` in its launch environment; not set globally on purpose | |
| goose | none | `beacon-hooks` has a goose adapter, Beacon has no installer for it; wire the hooks yourself | |
| aider, Amp, Crush, Codebuff, Mistral Vibe, Continue, Kilo Code, Open Interpreter | none | not among Beacon's supported runtimes at the pinned commit | |

`"auto"` configures only what Beacon finds (the agent binary on the unit's
`PATH`, `/run/current-system/sw/bin`, or the agent's configuration directory).
An explicit list configures those agents even if they are not installed yet.
Other harnesses Beacon knows (Antigravity CLI, Oh My Pi, Grok Build, Hermes,
Kimi Code, Muse Code, Devin, DeepSeek Harness, Senpi, Prime Agent) are in the
`harnesses` enum and work the same way. OpenHands and Claude Cowork need
per-repository or admin configuration and are reported, not configured.

**What is in the log.** Prompts, responses where the runtime exposes them,
commands, file paths and diffs, MCP calls, approvals, token counts. Beacon
redacts secrets, sanitizes and truncates before writing (the collector exporter
runs with `redact_secrets: true`; events are capped at 64 KiB). It is a record of
your sessions, so treat the log like the sessions themselves.

### Who can read what

* `/var/lib/beacon` is `beacon:beacon 2770`. Members of the group `beacon`
  (`nestlo.beacon.users`) read and append the shared log and read and write
  the memory store (`memory.db` is created `0660` by tmpfiles, because SQLite
  would otherwise make it `0644`); nobody else can enter the directory.
* Upstream makes the log itself `0666` so any user's hooks can append; the
  directory mode is what restricts it here. Everyone in the group sees
  everyone's sessions, and anyone in the group can write events into the log.
  The log is **not tamper-evident**: it is a convenience record. The
  hash-chained, signed record of what the platform did is `nestlo.audit`.
* The group `beacon` is applied at the next login of a user.

## Retention

Beacon rotates `runtime.jsonl` at 10 MiB and keeps five segments; the hook
adapter and the collector exporter share that contract and neither reads it from
configuration, so the live history is about 60 MiB. `beacon-archive.timer`
(every `retention.interval`) compresses rotated segments that nobody has written
for two minutes into `/var/lib/beacon/archive/runtime-<time>-<bytes>.jsonl.zst`
(zstd) and deletes archives older than `retention.days`. `beacon traces` and the
dashboard read the live files; read an archive with `zstdcat`. Approved memory
(`/var/lib/beacon/memory.db`) is never pruned.

## Knowledge back to agents

* **Skills.** `skills.enable` turns on the `beacon` pack of `nestlo.skills`
  (`beacon-memory-recall`, `beacon-memory-distill`, `beacon-memory-promote`,
  `beacon-lens-create`) for every user and agent CLI. Recall reads memory over MCP
  and falls back to `beacon memory list`.
* **MCP.** `nestlo-beacon-mcp` (registry entry `beacon`, `nestlo-tools list`) runs
  `beacon mcp serve` over stdio with `--log-path` chosen by the caller: the shared
  log for members of the group `beacon`, `~/.beacon/endpoint/logs/runtime.jsonl`
  for everyone else (the agent user). Tools: `search_activity`,
  `summarize_activity`, `get_activity_event`, `list_activity_filters`,
  `search_memory`, `get_memory`, `get_memory_context`. Memory tools return only
  approved memory. The MCP registry is a catalogue: add the server to an agent
  with that agent's own command, for example
  `claude mcp add beacon -- nestlo-beacon-mcp`.
* **Approved memory for the sandboxed agent.** `beacon-memory-sync-nestlo-agent.timer`
  copies the `memories` table (current rows only) from
  `/var/lib/beacon/memory.db` to the agent's `~/.beacon/endpoint/memory.db`; no
  evaluations, candidates or trace evidence go along. One way: the agent cannot
  change the shared store. Memory is scoped by repository, as in Beacon.
* **Promote.** `beacon memory skills install <candidate-id> --project <repo>`
  writes `.agents/skills/<slug>/SKILL.md` into the repository, where every
  skill-capable agent (the sandboxed ones too) loads it without a lookup.

### The review loop

1. Agents work; Beacon records.
2. An operator (or an agent acting for one) picks traces: `beacon memory evaluations
   run --dry-run`, then reads the source trace of a candidate and writes the lesson
   (`beacon memory candidates create --trace ... --body-file`, or lets the
   `beacon-memory-distill` skill do the reading and drafting with the user).
3. `beacon memory candidates approve <id>` after review. Only approved memory is
   served.

Writing the lesson is the model's job, and it happens in the agent that runs the
skill, which already goes through the Nestlo model gateway. Beacon itself does
not call a model.

### Distillation and the network

`beacon memory evaluations run` (never run by Nestlo, never by a service) scores
traces with TypeSafe's **Jev** evaluator over HTTPS. Beacon's default endpoint is
the hosted `https://api.typesafe.ai/v1/systemone`; a run sends a projection of the
trace (up to 80 events, with text) there, and needs `TYPESAFE_API_KEY` or
`BEACON_JEV_API_KEY` in the environment, so nothing goes out without a person
supplying a key and dropping `--dry-run`. It is TypeSafe's own System One
request/response format, not a chat-completions API, so it **cannot be routed
through the Nestlo model gateway** (that is why there is no gateway agent id or
budget for Beacon). To keep scoring local, serve a System One compatible
evaluator and set `nestlo.beacon.evaluator.endpoint` (and `model`); they become
`BEACON_JEV_ENDPOINT` / `BEACON_JEV_MODEL` in the system environment. Everything
else in the loop, including writing candidates yourself, is local.

## Observability and audit

* **Metrics.** The collector serves its own OpenTelemetry metrics on
  `127.0.0.1:9975` (`otelcol_receiver_accepted_log_records_total`,
  `otelcol_exporter_sent_log_records_total{exporter="beaconjson"}`, memory, queue
  sizes). With `nestlo.observability.enable` Prometheus scrapes them as job
  `beacon-collector`. They count events; they carry no content.
* **OTLP the other way.** Beacon is an OTLP receiver whose only exporter writes
  JSONL; it does not forward to `nestlo.observability`'s OpenTelemetry collector.
  Use `nestlo.audit.export` or your own log shipper on `runtime.jsonl` for SIEM
  forwarding.
* **Audit.** Not wired. The Nestlo audit log accepts a closed set of event types
  from the platform's own services (`services/nestlo_services/audit.py`,
  `EVENT_TYPES`), and the Beacon log is not tamper-evident and can be written by
  every member of the group, so mirroring it into the chain would put unverifiable
  claims into a verifiable record. Do the join by session id: `agent.spawn` and
  `gateway.request` records carry the agent id and the workspace; Beacon's
  events carry `session.id`, `session.cwd` and the repository.

## Beacon Cloud (off)

Beacon Cloud forwards the runtime log to beacon.sh through a Vector process.
`nestlo.beacon.cloud.enable` is `false`. When you set it:

* `BEACON_VECTOR_BIN` points at `cloud.vectorPackage` (nixpkgs' Vector) and
  `beacon-asymptote-forwarder.service` runs it, but only once
  `/etc/beacon/endpoint/asymptote/vector.toml` exists;
* nothing is enrolled by the option. An administrator runs
  `sudo beacon endpoint connect --system` and approves the device in a browser;
* evaluation prints a warning, because from then on prompts, commands and file
  paths leave the machine (Beacon's Standard mode; `--privacy-mode metadata-only`
  keeps content out).

**Not verified:** this path was not run. `beacon endpoint connect` also tries to
write its own systemd unit under `/etc/systemd/system`, which NixOS manages as
store symlinks, so it may report an error for that step after it has written
the Vector configuration; the declared unit is there to run what it wrote.
Everything else works without any of this and never touches the network.

With the option off, no Nestlo service has a route to the network that Beacon
uses: the collector, archiver, relay, memory sync, dashboard and per-user setup
units all run with `IPAddressDeny=any` and loopback allowed, the collector
does not contain the Splunk, Falcon or http(s) config-provider code of Beacon's
release build, and the hook adapter only contacts a bucket in cloud-agent mode
(`BEACON_ORIGIN=cloud`, never set here). The remaining ways data can leave are
commands a person runs: `beacon memory evaluations run` (see above),
`beacon endpoint connect`, `beacon login`, `beacon mcp connect`, `beacon endpoint
update` and `beacon version check`; none runs on a schedule.

## Isolation levels that do not reach the collector

The collector listens on the host's loopback. Agents started with
`nestlo spawn --isolation container` (own network namespace) or `pullrun` cannot
reach `127.0.0.1:4317`, so their OTLP export (Claude Code, Codex, Gemini CLI) is
lost. Their hook events depend on whether the agent user's home (and so
`~/.beacon/endpoint/logs`) is what the container sees, which was not checked.
If you need OTLP from them, run a second collector on the bridge; that is not
wired.

## Operations

```console
$ nestlo-beacon status                  # unit, health, log, `beacon endpoint status`
$ nestlo-beacon repair [user ...]       # re-run the per-user setup
$ systemctl status beacon-collector beacon-archive.timer
$ journalctl -u beacon-collector -u beacon-relay-nestlo-agent -u beacon-setup-alice
$ beacon endpoint doctor --system       # Beacon's own checks (some are about its own systemd units and can be ignored)
```

* Do not run `beacon endpoint install` or `beacon endpoint hooks install`
  yourself for the same agents: the setup unit already did, and a second run with
  different options would duplicate nothing but fight it. To stop capturing a
  user, set `harnesses = [ ]` for a switch (this installs collector settings
  only), or remove the user from `users`, then
  `beacon endpoint hooks uninstall --harness <name>` as that user removes the
  entries again (other hooks stay).
* `beacon endpoint status` without `--system` reports the per-user install, which
  has no collector of its own; `nestlo-beacon status` is the right overview.
* A user in `users` who has just been added needs a new login for the group.
* The agent user's hook adapter is
  `~/.beacon/endpoint/hooks/beacon-hooks` inside the sandbox-writable home.

## The package

`nixos/packages/agent-beacon.nix` pins `Asymptote-Labs/agent-beacon` at
`82a6fba5` (v1.3.22 and later, 2026-10-05) and builds with `buildGoModule`:

| Binary | From | Notes |
|--------|------|-------|
| `beacon-hooks` | `cli/beacon-hooks` | static |
| `beacon` | `cli/beacon` | static; embeds `beacon-hooks` as upstream's release does; the plugins for OpenCode, Cline, pi, Oh My Pi and OpenClaw are committed upstream and compiled in |
| `beacon-otelcol` | `collector-builder` | upstream generates it with the OpenTelemetry Collector Builder (`builder.yaml`); the generated `main` is in `nixos/packages/agent-beacon/otelcol` (`go.mod`/`go.sum` from `go mod tidy`) with OTLP receiver, batch, memory_limiter, health_check and the `beaconjson` exporter only |

Not built: `beacon-sandbox` (upstream's own verification harness: real Claude
Code sessions in cloud sandboxes, billed), the browser extension, the JS SDK and
Vector (Beacon's release bundles it; only `cloud.enable` needs one, from
nixpkgs).

To update: change `rev` and `hash` in the package and in
`nixos/packages/skills/sources.nix`, set the three `vendorHash`es to
`lib.fakeHash` and copy the real ones from the build errors; if upstream's
`builder.yaml` moves to other OpenTelemetry versions, run `go mod tidy` in
`nixos/packages/agent-beacon/otelcol` against the new tree and review
`components.go`.

## Verification status

Verified here: the package builds (all three binaries run: `beacon --help`,
`beacon version`, `beacon-otelcol --version`); the collector with this module's
configuration starts, answers its health check, turns an OTLP log record into a
`prompt.submitted` event in the JSONL log and serves Prometheus metrics; Beacon's
installer, run as in `beacon-setup-<user>` against scratch homes, writes the
documented files for Claude Code, Codex, Gemini CLI, OpenCode, Cline, pi and Qwen
Code, keeps user settings and hooks and leaves a single backup on re-runs; the
relay, the memory copy (approved memory visible, candidates not), the MCP
handshake with `--log-path` and `beacon memory`/`scan` against a shared log were
run as scripts; the skills pack builds; the module and `tests/beacon.nix`
evaluate on the `nestlo` host.

Not verified: the VM test (`checks.<system>.beacon`) was evaluated, not run (no
KVM here); the systemd sandboxing of the units (`ProtectSystem`, supplementary
groups, `IPAddressDeny`) is declared and evaluated but was not exercised on a
booted system; hooks and plugins were installed but never driven by the real
agents (no network and no agent credentials), so what each agent then emits is
Beacon's documented behaviour, not something observed here; the Cursor CLI,
Kiro, Factory Droid and OpenClaw paths; Beacon Cloud.
