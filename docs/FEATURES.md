# Nestlo — Feature Reference

Complete documentation of every feature built into Nestlo.

> [!NOTE]
> The orchestrator, scheduler, MCP gateway/registry service, provisioner and
> memory manager are designed but not implemented yet; their modules install
> configuration only. [STATUS.md](STATUS.md) lists exactly what works and how
> it is tested.

---

## Core Infrastructure

### 1. Runtime (`modules/runtime`)
Runs each agent in its own sandbox and keeps track of it.
- **Sandboxed agents:** `nestlo spawn` starts the agent as a transient systemd unit (`nestlo-agent-<id>.service`) running as the unprivileged `nestlo-agent` user: no sudo, read-only system, private /tmp, home directories hidden, write access only to its workspace and its own home.
- **Resource limits:** memory, CPU quota and process count per agent (from `nestlo.circuit-breaker`).
- **Shared workspaces:** `/var/lib/nestlo/workspaces/<name>`, shared between the operator and the agent user through group ACLs. Every run gets its own `agent/<id>` git branch.
- **Agent daemon:** tracks running agents, stops agents that exceed their budget, sends notifications, and exports Prometheus metrics on `127.0.0.1:9950`.
- **Control-plane Redis:** unix socket only; agents cannot read or change spend or budgets.
- **Config:** `nestlo.runtime.enable = true;` (`maxAgents`, `operators`, `agents`)

**CLI:**
```bash
nestlo workspace create api --from https://github.com/me/api.git
nestlo spawn claude --workspace api --budget 5
nestlo list                  # running + recent agents, spend today
nestlo logs <agent-id> [-f]  # every model API call: model, tokens, cost
nestlo kill <agent-id>
nestlo shell <agent-id>      # shell inside the agent's sandbox
nestlo status
```

### 2. Storage & Snapshots (`modules/storage`)
btrfs-based copy-on-write filesystem for instant branching and snapshots.
- **btrfs subvolumes:** Each workspace is a subvolume; snapshots are instant.
- **Auto-snapshots:** Hourly snapshots with configurable retention.
- **Deduplication:** Daily content-addressed dedup saves disk space.
- **Workspace GC:** Automatically cleans up abandoned workspaces.
- **Config:** `nestlo.storage.enable = true;`

### 3. Networking & Model Gateway (`modules/networking`)
Every LLM call from a sandboxed agent goes through the model gateway on `127.0.0.1:8080`.
- **Per-agent routing:** agents get `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` pointing at `/agent/<id>/<provider>`, so each request is attributed to the agent that made it.
- **Metering:** token usage is read from JSON and streaming (SSE) responses of the Anthropic Messages API and the OpenAI Chat Completions and Responses APIs, then priced with `pricing.json`.
- **Key injection:** with a provider `keyFile` (e.g. a sops secret), agents only see the placeholder key `nestlo-managed`; the gateway adds the real key upstream.
- **Enforcement:** budgets (402), per-agent rate limit (429), circuit breaker (503).
- **Admin socket:** `/run/nestlo-gateway/admin.sock` for budget changes, writable by operators only.
- **Config:** `nestlo.networking.providers.<name> = { baseUrl; api; keyFile; };`

### 4. Security (`modules/security`)
- **Egress allowlist:** with `defaultEgress = "deny"`, dnsmasq only resolves allowlisted domains and records their addresses in an ipset; iptables rejects every other outbound connection (host-wide).
- **Gateway-only provider APIs:** the `nestlo-agent` user cannot connect to provider API hosts directly, use a DNS server other than the local one, or use IPv6. Budgets cannot be bypassed.
- **AppArmor, auditd, kernel hardening** (sysctl, BPF JIT hardening, protected links/FIFOs).
- **Config:** `nestlo.security.defaultEgress = "deny";`

### 5. Observability (`modules/observability`)
Full observability stack: Prometheus + Tempo + Grafana.
- **Tracing:** OpenTelemetry collector → Tempo pipeline (agents don't emit traces yet).
- **Dashboards:** Grafana on `localhost:2342` (reach it with `ssh -L 2342:localhost:2342`); set `grafanaAdminPasswordFile`.
- **Agent metrics:** the daemon exports spend, budgets, tokens and request counts per agent; Prometheus scrapes it.
- **Retention:** 30 days by default.
- **Config:** `nestlo.observability.enable = true;`

---

## Agent Intelligence

### 6. Context & Memory (`modules/context`)
Persistent vector memory for agents.
- **Vector database:** Qdrant for semantic search over past context.
- **Per-agent memory:** Each agent remembers past sessions.
- **Shared knowledge base:** Agents share learnings about a project.
- **Embedding service:** Text → vectors using `text-embedding-3-small`.
- **Memory GC:** Old memories auto-expired after 90 days.
- **Config:** `nestlo.context.enable = true;`

**CLI:**
```bash
nestlo-memory stats        # Show vector counts
nestlo-memory search       # Browse collections
nestlo-memory forget       # Clear all memories
```

### 7. Multi-Agent Orchestration (`modules/orchestration`)
Queued tasks, pipelines, swarms with verify and judge steps, DAG workflows,
approval gates, retries and priorities, driven by `nestlo-task`. GitHub
webhooks can create tasks and publish pull requests. See
[orchestration.md](orchestration.md) and [triggers.md](triggers.md).

### 7a. Software factory (`modules/factory`)
`nestlo.factory.lines.<name>` runs work items (GitHub issues or
`nestlo-factory`) through planner, builder, verify, reviewer, a fix loop and
QA against the acceptance criteria, then opens a pull request (`supervised`,
`approval-first`) or merges it (`dark`, which needs `allowAutoMerge` on the
repository, a verify command, a QA role and a plan approval or scope guard).
Every step is an orchestrator task. Metrics `nestlo_factory_*`, alerts
`NestloFactoryBlocked`, `NestloFactoryStuck`, `NestloFactoryBudgetBurn`.
See [factory.md](factory.md).

---

## Tool Ecosystem

### 8. MCP Tool Registry (`modules/mcp-registry`)
Manages MCP (Model Context Protocol) tool servers that extend agent capabilities.
- **15+ built-in tools:** filesystem, git, github, postgres, sqlite, fetch, memory, puppeteer, brave-search, sequential-thinking, slack, linear, sentry, semgrep, mermaid.
- **Per-agent permissions:** Control which tools each agent can use.
- **Auto-discovery:** Tools register themselves on startup.
- **Health checking:** Registry monitors tool server health.
- **Config:** `nestlo.mcp-registry.enable = true;`

**CLI:**
```bash
nestlo-tools list                           # List all tools
nestlo-tools enable puppeteer               # Enable a tool
nestlo-tools disable sqlite                 # Disable a tool
nestlo-tools add my-tool "npx @my/tool"     # Add custom tool
nestlo-tools test github                    # Health check
```

---

## Safety & Control

### 9. Budget Controller (`modules/budget-controller`)
Caps what agents can spend on LLM APIs. Enforced by the model gateway.
- **Per-agent daily budget** (default $50, UTC day) and a **global daily budget** (default $500).
- **Requests over budget** are refused with HTTP 402 before they reach the provider.
- **Threshold alerts** at 50/80/95% and an event when the budget is exceeded.
- **Auto-shutdown:** the agent daemon stops the agent's unit.
- **Pricing** for current Claude, OpenAI, Gemini, DeepSeek, Qwen and Llama models (`pricing.json`, USD per million tokens, including cache reads and writes). Unknown models are priced conservatively.
- **Config:** `nestlo.budget-controller.defaultDailyBudgetUSD = 50.0;`

**CLI:**
```bash
nestlo-budget status       # spend per agent today, limits, request counts
nestlo-budget set <id> 25  # daily budget for one agent
nestlo-budget reset <id>   # back to the default
nestlo-budget history      # 7-day global spend
nestlo-budget by-model
```

### 10. Circuit Breaker (`modules/circuit-breaker`)
- **Rate limit:** max LLM requests per agent per minute (HTTP 429 with Retry-After).
- **Circuit breaker:** after N consecutive upstream failures an agent's requests are refused for a cooldown (HTTP 503).
- **Resource limits:** memory, CPU share and process count for each sandboxed agent.
- **Config:** `nestlo.circuit-breaker.maxConsecutiveFailures = 5;`

**CLI:**
```bash
nestlo-breaker status
nestlo-breaker reset <id>  # close an open circuit
```

### 11. Secrets Manager (`modules/secrets-manager`)
Secure API key management.
- **Encrypted at rest:** sops-nix with age encryption.
- **Per-agent access:** Agents only see their allowed keys.
- **Never in logs:** Secrets injected at spawn, not persisted in env.
- **Auto-rotation:** Optional periodic key rotation.
- **9 pre-configured keys:** Anthropic, OpenAI, Google, GitHub, Factory, Slack, Linear, Sentry, Brave.
- **Config:** `nestlo.secrets-manager.backend = "sops";`

**CLI:**
```bash
nestlo-secrets list        # Show configured keys (values hidden)
nestlo-secrets set KEY     # Set a secret (prompted, hidden)
nestlo-secrets edit        # Edit secrets file in $EDITOR
nestlo-secrets check       # Show access mapping
```

---

## Developer Experience

### 12. Git Automation (`modules/git-automation`)
- **Branch per agent session:** `nestlo spawn` creates `agent/<agent-id>` in the workspace.
- **Hooks:** pre-commit checks for secrets, large files and failing tests (`nestlo-git init`).
- **Helpers** for commits, checkpoints and PRs via the GitHub CLI.
- `autoCommit` is not acted on yet. `autoPR` pushes `agent/<task-id>` and opens a PR for successful orchestrator tasks of workspaces listed in `publish.repos` (see docs/triggers.md).

**CLI:**
```bash
nestlo-git init            # Set up hooks in workspace
nestlo-git commit "msg"
nestlo-git pr "title"      # Create PR via GitHub CLI
nestlo-git snapshot        # Checkpoint commit
nestlo-git undo            # Undo last commit, keep changes
```

### 13. Environment Provisioning (`modules/provisioning`)
Auto-detects project type and provisions the right environment.
- **Auto-detection:** Reads package.json, requirements.txt, go.mod, Cargo.toml, etc.
- **8+ templates:** Python 3.11/3.12, Node 20/22, Go 1.23, Rust stable, C++, Java 21.
- **Nix dev shells:** Reproducible environments per project.
- **Local cache:** Binary cache for fast environment creation.
- **Pre-build:** Pre-build common environments at install time.
- **Config:** `nestlo.provisioning.enable = true;`

**CLI:**
```bash
nestlo-env detect          # Detect project type
nestlo-env list            # List available environments
nestlo-env shell           # Launch detected environment
nestlo-env shell python-3.11  # Launch specific environment
nestlo-env init            # Create shell.nix for current project
nestlo-env prebuild        # Pre-build environments
```

---

## Automation

### 14. Scheduler (`modules/scheduler`)
Recurring tasks on systemd `OnCalendar` schedules, managed with
`nestlo-schedule` or declared in Nix. See [orchestration.md](orchestration.md).

### 15. Notifications (`modules/notifications`)
The agent daemon forwards events to Slack, Discord or a generic JSON webhook.
- **Events:** `agent-started`, `task-completed`, `budget-threshold` (thresholds, budget exceeded), `agent-error` (agent stopped, circuit opened).
- **Secret URLs** are read from files (`slackWebhookFile`, `discordWebhookFile`, `webhookUrlFile`), e.g. sops secrets, never the Nix store.
- **Config:** `nestlo.notifications.slackWebhookFile = "/run/secrets/SLACK_WEBHOOK";`

**CLI:**
```bash
nestlo-notify status
nestlo-notify test "hello"
```

---

## Pre-installed Agents (20 total)

See [AGENTS.md](./AGENTS.md) for the complete list and usage.

| Source | Agents |
|------|--------|
| nixpkgs (16) | Claude Code, Codex, Aider, Gemini, Qwen Code, Amp, Goose, OpenCode, Crush, Cursor CLI, GitHub Copilot CLI, Kilo Code, Mistral Vibe, Kiro CLI, Codebuff, Pi |
| npm launcher (3) | Factory Droid, Cline, Continue |
| PyPI launcher (1) | Open Interpreter |

---

## Feature Summary

| Feature | Module | CLI Command | Status |
|---------|--------|-------------|---------|
| Sandboxed agents, registry, daemon | runtime | `nestlo spawn` | ✅ (VM-tested) |
| Model gateway | networking | (automatic) | ✅ (VM-tested) |
| Budget controller | budget-controller | `nestlo-budget` | ✅ (VM-tested) |
| Circuit breaker, rate limit, resource limits | circuit-breaker | `nestlo-breaker` | ✅ |
| Notifications | notifications | `nestlo-notify` | ✅ (VM-tested) |
| Egress allowlist, gateway-only provider access | security | (automatic) | ✅ (VM-tested) |
| Storage & snapshots | storage | `nestlo snapshot` | ✅ |
| Observability | observability | Grafana | ✅ |
| Secrets manager | secrets-manager | `nestlo-secrets` | ✅ (after sops setup) |
| Git automation | git-automation | `nestlo-git` | Helpers ✅, auto-PR for orchestrator tasks ✅, auto-commit planned |
| Context & memory | context | `nestlo-memory` | Qdrant ✅, memory manager planned |
| MCP servers | mcp-servers | `nestlo-mcp` | ✅ (config) |
| Provisioning | provisioning | `nestlo-env` | ✅ (provisioner service planned) |
| Orchestration | orchestration | `nestlo-task` | ✅ |
| Scheduler | scheduler | `nestlo-schedule` | ✅ |
| 20 coding agents | agents | `nestlo agents` | ✅ |
| Agent Orca (Kubernetes operator on k3s) | orca | `aoctl` | ✅ (VM test) |
| NVIDIA OpenShell sandboxes | openshell | `openshell` | ✅ (VM test) |
| Nestlo Cloud | cloud | `ssh lobby@<host>` | ✅ (VM test) |
| Agent security (promptfoo, agent-scan, PR-Agent) | agent-security | `nestlo-redteam`, `nestlo-agent-scan`, `nestlo-pr-review` | ✅ (VM test) |
| Runtime security (Tetragon) | agent-runtime-security | (automatic) | ✅ (VM test) |
| Agent identity and Cedar | agent-identity | `nestlo-svid`, `nestlo-authz` | ✅ (VM test) |
| OpenBao | openbao | `nestlo-bao` | ✅ (VM test) |
| LLM observability | llm-observability | (automatic) | ✅ (VM test) |
| Beacon | beacon | `beacon`, `nestlo-beacon` | ✅ (VM test) |
| LocalAI and vLLM | local-ai | (automatic) | ✅ (VM test) |
| A2A server, ACP launcher | a2a | `nestlo-acp` | ✅ (VM test) |
| agentgateway | agentgateway | `nestlo-agentgateway-mcp-config` | Package unbuilt, test not in checks |
| ToolHive | toolhive | `thv` | Config only, no VM test |

---

## VIBE Integration (anubhavg-icpl/vibe)

Nestlo installs the VIBE library into the supported agent CLIs on first boot, fetching it from GitHub with `npx`.

| Asset Type | Count | Description |
|-----------|-------|-------------|
| Modes | 853 | Expert chat modes across 52 categories |
| Skills | 5340 | Reusable skill bundles |
| Subagents | 200 | Specialized workers in 10 categories |
| Commands | 112 | Slash commands in 8 categories |
| Plugins | 120 | Plugin trees with agents + commands |
| Rules | 111 | Universal behavior policies |
| Prompts | 106 | Domain prompt templates |
| System Prompts | 759 | Reference system prompts |
| Recipes | 18 | End-to-end workflows |

**Auto-install:** On first boot, VIBE installs into Claude Code, Codex, Cursor, OpenCode, Gemini, Copilot, and Droid.

**CLI:**
```bash
nestlo-vibe install     # Install into all agents
nestlo-vibe status      # Check installation
nestlo-vibe categories  # List 52 categories
nestlo-vibe search rag  # Search library
nestlo-vibe add <name>  # Install specific asset

# Direct VIBE CLI also available:
vibe                     # Interactive picker
vibe list                # List all assets
vibe search "security"   # Search
```

---

## Agent Skills (`modules/skills`)

`nestlo.skills` links skill packs (nixos/packages/skills, pinned sources) into every agent CLI's user-level skills directory, for the agent user and `nestlo.skills.users`.

- Packs: `fwc-swiftui-skills`, `ui-skills`, `img2threejs`; one `nestlo.skills.packs.<name>.enable` option per pack.
- Targets (`nestlo.skills.targets`): `.agents/skills`, `.claude/skills`, `.codex/skills`, `.config/opencode/skills`, `.gemini/skills`, `.copilot/skills`, `.cursor/skills`, `.factory/skills`, `.config/agents/skills` (Amp), `.config/goose/skills`, `.qwen/skills`, `.config/crush/skills`.
- A name used by two packs fails the build. Skills a user wrote are not overwritten; stale links of ours are removed.
- Pack tools are added to the PATH; pack MCP servers to `nestlo.mcp-registry.extraToolServers`.

```bash
nestlo-skills list
nestlo-skills doctor
nestlo-skills path <skill>
```

See [skills.md](skills.md). Checks: `skills-eval` (no VM) and the VM test `skills`.

---

## herdr (`modules/herdr`)

`nestlo.herdr` integrates [herdr](https://herdr.dev), persistent terminal workspaces in which panes are marked working, blocked or idle.

- A headless herdr server for the agent user (`nestlo-herdr-server-nestlo-agent`, sandboxed, not restarted by rebuilds); operators attach with `nestlo-herdr attach`.
- Management bridge `nestlo-herdr status|metrics|monitor`: panes and agents per user and state, loopback Prometheus metrics (`nestlo_herdr_panes{user,state}`, scraped by `nestlo.observability`), and a notification through `nestlo.notifications` when an agent stays blocked.
- The Nestlo herdr plugin (`integrations/herdr-plugin`): orchestrator tasks, factory items, budgets, approve and cancel for gated tasks.
- Declarative plugins (`nestlo.herdr.plugins`, pinned to a commit, idempotent, uninstalls only what it installed) and `nestlo-herdr-plugins` (marketplace catalog, review, pinned install, `install-all`, update with manifest diff).
- Opt-in daily marketplace sweep (`marketplace.installAll`): unreviewed third-party code, off by default, warned about for the agent user.
- Skill pack `herdr`, `packages.<system>.herdr`, desktop launcher entry.

See [herdr.md](herdr.md). VM test `herdr`; unit tests `services/tests/test_herdr_*.py`.

## Agent Orca (`modules/orca`)

`nestlo.orca` runs [Agent Orca](https://github.com/heddles/agent-orca), a Kubernetes operator for AI agents, on a single-node k3s cluster.

- k3s with pod and service ranges clear of Nestlo's networks; the operator, UI, model router, MCP ingester, Redis and pause images are built by Nix and loaded into k3s (nothing of the platform is pulled from a registry); the Helm chart is deployed by k3s' Helm controller.
- `ModelProvider` resources and a `default` `ModelSelector` that send every model call through the Nestlo model gateway as agent `orca` (`nestlo-orca-setup`), with a daily budget (`budgetUsd`); the cluster holds no provider keys.
- UI, ACP API and task API on loopback (9980, 9981, 9982); `aoctl` and `kubectl` configured; a firewall chain limits pods to the gateway and the API server on the host.
- `allowedRegistries` restricts agent images. Not included: Postgres run archival, Hindsight, offline CoreDNS images.

See [orca.md](orca.md). VM test `orca`.

## OpenShell (`modules/openshell`)

`nestlo.openshell` integrates [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell), a runtime that runs agents in sandboxes under declarative policies.

- `packages.<system>.openshell`: `openshell`, `openshell-gateway`, `openshell-supervisor`, `openshell-sandbox` and `openshell-prover`, built from the pinned source.
- Sandboxes with Landlock, seccomp and deny-by-default network egress; policies in YAML; providers that hand credentials only to authorized endpoints; the prover for boundary checks; OCSF logs.
- Skill pack `openshell` (`openshell-cli`, `generate-sandbox-policy`, `debug-inference`, `debug-openshell-cluster`).
- `nestlo-openshell-gateway`: the gateway as a hardened service on loopback with mutual TLS, driving podman or docker; `openshell` for operators with their client certificate.
- Sandbox model calls go through the Nestlo model gateway as agent `openshell` (provider profile `nestlo-gateway`, budget, DLP, audit); real provider keys never enter a sandbox.
- Policies declared in Nix (checked at evaluation, rendered to `/etc/openshell/policies/`, optionally the gateway-global policy), upstream and custom provider profiles, provider instances from secret files, gateway OCSF log and OTLP export.

See [openshell.md](openshell.md). VM test `openshell`.

## Security & identity

### Agent security (`modules/agent-security`)

`nestlo.agentSecurity` tests and gates the AI side of the host; model calls go through the Nestlo model gateway and runs are audited (`security.redteam`, `security.agent_scan`, `security.pr_review`).

- `nestlo-redteam` / `nestlo-eval`: [promptfoo](https://github.com/promptfoo/promptfoo) red-team and eval suites against a model behind the gateway, as agent `redteam` with its own budget; hosted attack generation and telemetry off; optional weekly timer.
- `nestlo-agent-scan`: local rules over Nestlo's MCP server lists and the skill bundle (hidden unicode, instruction overrides, exfiltration, tool shadowing, toxic flows, inline secrets, unpinned packages) in a unit without network; Snyk agent-scan inspect and remote analysis are opt-in.
- `nestlo-pr-review`: [PR-Agent](https://github.com/qodo-ai/pr-agent) through the gateway as agent `pr-review`, optionally on the `agent/*` pull requests the publisher opens.

See [agent-security.md](agent-security.md). VM test `agent-security`.

### Agent runtime security (`modules/agent-runtime-security`)

`nestlo.agentRuntimeSecurity` runs [Tetragon](https://tetragon.io) (eBPF) with policies for agent users: credential reads (including the providers' key files), writes to protected paths, raw sockets, ptrace, kernel modules and egress that bypasses the gateway. A forwarder keeps the events of agent users, writes alerts, sends `runtime.security` audit events and Prometheus counters. Observe by default; killing is opt-in.

See [agent-runtime-security.md](agent-runtime-security.md). VM test `agent-runtime-security`.

### Agent identity and authorization (`modules/agent-identity`)

- `nestlo.agentIdentity`: SPIFFE/SPIRE on loopback (x509pop node attestation, Workload API); SPIFFE IDs declared in Nix for the agent user, per-agent units and Nestlo services; `nestlo-svid` and `nestlo-identity` CLIs; JWT bundle export.
- `nestlo.cedar`: Cedar schema, policies and entities rendered and validated at build time; `nestlo-authz check` reports allow or deny with the deciding policy.

See [agent-identity.md](agent-identity.md). VM test `agent-identity`.

### OpenBao (`modules/openbao`)

`nestlo.openbao` runs OpenBao with TLS on loopback, an init and unseal helper, KV v2 for agents, JWT login by SPIFFE identity with a policy per agent, a file audit device and a `/run/secrets` sync for the secrets manager. CLIs `nestlo-bao`, `nestlo-openbao-get`.

See [openbao.md](openbao.md). VM test `openbao`.

## Observability & Local Models

### LLM observability (`modules/llm-observability`)

`nestlo.llmObservability` makes the model gateway emit one OpenTelemetry GenAI span per request (provider, model, usage including cache tokens, error type, plus agent, cost and routing; no prompt or completion text). Exporter to the Nestlo collector, Langfuse, OpenLIT or any OTLP endpoint; Langfuse and OpenLIT are opt-in loopback podman stacks with pinned digests and secrets generated at runtime. Tracing (`[tracing]` in the gateway config) is off by default.

See [llm-observability.md](llm-observability.md). VM test `llm-observability`; unit tests `services/tests/test_genai_trace.py`.

### Beacon (`modules/beacon`)

`nestlo.beacon` runs [Agent Beacon](https://github.com/Asymptote-Labs/agent-beacon), local only: a collector (`beacon-collector`, OTLP on loopback) writes one JSONL log of sessions, prompts, tool calls, file edits and token usage from many agent harnesses; `beacon traces`, `beacon scan` and `beacon token-usage` replay, check and cost it; reviewed memory is served back to agents over MCP and a skill pack. `nestlo-beacon status|log|repair|archive`, optional read-only dashboard, retention and archive.

See [beacon.md](beacon.md). VM test `beacon`.

### LocalAI and vLLM (`modules/local-ai`)

`nestlo.localAI.localai` (container by default) and `nestlo.localAI.vllm` (per-model units with explicit GPUs) run next to Ollama or llama.cpp: loopback servers with a generated API key that only the gateway holds, registered as $0 `openai-compatible` providers so agents keep budgets, DLP and audit.

See [local-ai-backends.md](local-ai-backends.md). VM test `local-ai-backends`.

## Protocols & Tools

### A2A and ACP (`modules/a2a`)

`nestlo.a2a` serves Nestlo agents as A2A (Agent2Agent) agents: Agent Cards, bearer tokens per client with per-agent scoping, a fixed workspace and budget per agent, optional operator approval of each task. `nestlo-acp <agent>` starts an installed agent in its ACP mode for editors, with model calls through the gateway.

See [a2a.md](a2a.md). VM test `a2a`; unit tests `services/tests/test_a2a.py`.

### agentgateway (`modules/agentgateway`)

`nestlo.agentgateway` runs [agentgateway](https://github.com/agentgateway/agentgateway) on loopback as one MCP endpoint in front of Nestlo's MCP servers, with a per-agent API key and tool allow-list, plus an LLM route that forwards only to the Nestlo model gateway as agent `agentgateway`. The package is not built yet (placeholder `cargoHash`) and `tests/agentgateway.nix` is not in the flake checks; see the doc.

See [agentgateway.md](agentgateway.md).

### ToolHive (`modules/toolhive`)

`nestlo.toolhive` runs selected MCP servers with [ToolHive](https://github.com/stacklok/toolhive) in Podman containers with a permission profile (mounts, outbound hosts and ports), registers them with the MCP registry and, with `nestlo.agentgateway`, exposes them through the gateway.

See [toolhive.md](toolhive.md).

## Nestlo Cloud (`modules/cloud`)

`nestlo.cloud` provides the exe.dev feature set on the host.

- Persistent VMs: systemd-nspawn machines with an ext4 disk each, user-namespaced root, pool slices (shared vCPU and memory) and standalone VMs, OCI images or the `nestlo` image (the host's Nix store read-only: agents, dev tools, podman, Shelley).
- The lobby over SSH (`ssh lobby@<host> <command>`) and the HTTPS API (`POST /exec`, SSH-signed `nestlo0.` tokens with command allowlists, expiry and context; `exe0.`/`exe1.` accepted).
- A private HTTPS proxy per VM (Caddy, on-demand TLS): sharing with users or the team (web or root access), share links, public sites, any port, custom domains, login by SSH magic link or OIDC, identity headers, VM tokens.
- Integrations injecting secrets at the edge: http-proxy, GitHub (git, repo allowlist, read-only), LLM (the model gateway per VM, exe.dev's protocol), peer; reflection integration and metadata service.
- Teams, invites, plan quotas with metering, audit events, Prometheus metrics.

See [cloud.md](cloud.md). VM test `cloud`; unit tests `services/tests/test_cloud.py`.

---

## MCP Server Registry (36 servers)

Preconfigured Model Context Protocol servers, written to `/etc/nestlo/mcp-servers.json`. Each entry runs a published npm package (`npx -y`) or PyPI package (`uvx`), fetched on first start. Runtime enable/disable changes are stored in `/var/lib/nestlo/mcp-servers.json`.

### Core (7)
| Server | Description | Package |
|--------|-------------|---------|
| filesystem | Read, write, search files in workspaces | `npx @modelcontextprotocol/server-filesystem` |
| git | Git operations: commit, branch, diff, log, merge | `uvx mcp-server-git` |
| memory | Persistent key-value memory graph | `npx @modelcontextprotocol/server-memory` |
| fetch | Fetch web pages and APIs, convert to markdown | `uvx mcp-server-fetch` |
| sequential-thinking | Step-by-step reasoning with revision and branching | `npx @modelcontextprotocol/server-sequential-thinking` |
| time | Time and timezone tools | `uvx mcp-server-time` |
| everything | Reference server that exercises every MCP feature (for testing clients) | `npx @modelcontextprotocol/server-everything` |

### Database (7)
| Server | Description | Package |
|--------|-------------|---------|
| postgres | PostgreSQL: query, schema, migrations | `npx @modelcontextprotocol/server-postgres` |
| sqlite | SQLite: query, create, manage databases | `uvx mcp-server-sqlite` |
| mysql | MySQL/MariaDB: query and manage | `npx @benborla29/mcp-server-mysql` |
| redis | Redis: key-value, pub/sub, streams | `npx @modelcontextprotocol/server-redis` |
| mongo | MongoDB: CRUD, aggregation, indexes | `npx mongodb-mcp-server` |
| duckdb | DuckDB: in-process analytics SQL | `uvx mcp-server-motherduck` |
| clickhouse | ClickHouse: columnar OLAP queries | `uvx mcp-clickhouse` |

### Cloud (off by default) (4)
| Server | Description | Package |
|--------|-------------|---------|
| aws | AWS: S3, EC2, Lambda, DynamoDB, CloudFormation | `uvx awslabs.aws-api-mcp-server` |
| azure | Azure: Storage, Functions, CosmosDB | `npx @azure/mcp` |
| cloudflare | Cloudflare: Workers, KV, R2, D1, Durable Objects | `npx @cloudflare/mcp-server-cloudflare` |
| supabase | Supabase: database, auth, storage, realtime | `npx @supabase/mcp-server-supabase` |

### Integration (7)
| Server | Description | Package |
|--------|-------------|---------|
| github | GitHub: repos, issues, PRs, actions, gists | `npx @modelcontextprotocol/server-github` |
| gitlab | GitLab: repos, MRs, pipelines | `npx @modelcontextprotocol/server-gitlab` |
| linear | Linear: issues, projects, cycles, sprints | `npx mcp-remote` |
| slack | Slack: channels, messages, threads, files | `npx @modelcontextprotocol/server-slack` |
| notion | Notion: pages, databases, blocks | `npx @notionhq/notion-mcp-server` |
| sentry | Sentry: errors, issues, releases, stack traces | `npx @sentry/mcp-server` |
| pagerduty | PagerDuty: incidents, services, schedules | `uvx pagerduty-mcp` |

### Browser (3)
| Server | Description | Package |
|--------|-------------|---------|
| puppeteer | Puppeteer: headless Chrome automation | `npx @modelcontextprotocol/server-puppeteer` |
| playwright | Playwright: cross-browser automation, screenshots | `npx @playwright/mcp` |
| browserbase | Browserbase: cloud browser sessions at scale | `npx @browserbasehq/mcp` |

### AI/ML (1)
| Server | Description | Package |
|--------|-------------|---------|
| huggingface | HuggingFace: models, datasets, spaces | `npx @llmindset/hf-mcp-server` |

### DevOps (2)
| Server | Description | Package |
|--------|-------------|---------|
| docker | Docker: containers, images, volumes, compose | `uvx mcp-server-docker` |
| kubernetes | Kubernetes: pods, deployments, services | `npx mcp-server-kubernetes` |

### Data / Search (4)
| Server | Description | Package |
|--------|-------------|---------|
| brave-search | Brave Search: web, news, images, videos | `npx @modelcontextprotocol/server-brave-search` |
| tavily | Tavily: AI-optimized web search and extraction | `npx tavily-mcp` |
| exa | Exa: neural web search for AI agents | `npx exa-mcp-server` |
| perplexity | Perplexity: AI-powered web search with citations | `npx @perplexity-ai/mcp-server` |

**CLI:**
```bash
nestlo-mcp list [category]   # List servers
nestlo-mcp enable <name>     # Enable (stored in /var/lib/nestlo)
nestlo-mcp start <name>      # Run a server in the foreground
nestlo-mcp stats
```

