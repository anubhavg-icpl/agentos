# AgentOS — Feature Reference

Complete documentation of every feature built into AgentOS.

> [!NOTE]
> The orchestrator, scheduler, MCP gateway/registry service, provisioner and
> memory manager are designed but not implemented yet; their modules install
> configuration only. [STATUS.md](STATUS.md) lists exactly what works and how
> it is tested.

---

## Core Infrastructure

### 1. Runtime (`modules/runtime`)
Runs each agent in its own sandbox and keeps track of it.
- **Sandboxed agents:** `agentos spawn` starts the agent as a transient systemd unit (`agentos-agent-<id>.service`) running as the unprivileged `agentos-agent` user: no sudo, read-only system, private /tmp, home directories hidden, write access only to its workspace and its own home.
- **Resource limits:** memory, CPU quota and process count per agent (from `agentos.circuit-breaker`).
- **Shared workspaces:** `/var/lib/agentos/workspaces/<name>`, shared between the operator and the agent user through group ACLs. Every run gets its own `agent/<id>` git branch.
- **Agent daemon:** tracks running agents, stops agents that exceed their budget, sends notifications, and exports Prometheus metrics on `127.0.0.1:9950`.
- **Control-plane Redis:** unix socket only; agents cannot read or change spend or budgets.
- **Config:** `agentos.runtime.enable = true;` (`maxAgents`, `operators`, `agents`)

**CLI:**
```bash
agentos workspace create api --from https://github.com/me/api.git
agentos spawn claude --workspace api --budget 5
agentos list                  # running + recent agents, spend today
agentos logs <agent-id> [-f]  # every model API call: model, tokens, cost
agentos kill <agent-id>
agentos shell <agent-id>      # shell inside the agent's sandbox
agentos status
```

### 2. Storage & Snapshots (`modules/storage`)
btrfs-based copy-on-write filesystem for instant branching and snapshots.
- **btrfs subvolumes:** Each workspace is a subvolume; snapshots are instant.
- **Auto-snapshots:** Hourly snapshots with configurable retention.
- **Deduplication:** Daily content-addressed dedup saves disk space.
- **Workspace GC:** Automatically cleans up abandoned workspaces.
- **Config:** `agentos.storage.enable = true;`

### 3. Networking & Model Gateway (`modules/networking`)
Every LLM call from a sandboxed agent goes through the model gateway on `127.0.0.1:8080`.
- **Per-agent routing:** agents get `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` pointing at `/agent/<id>/<provider>`, so each request is attributed to the agent that made it.
- **Metering:** token usage is read from JSON and streaming (SSE) responses of the Anthropic Messages API and the OpenAI Chat Completions and Responses APIs, then priced with `pricing.json`.
- **Key injection:** with a provider `keyFile` (e.g. a sops secret), agents only see the placeholder key `agentos-managed`; the gateway adds the real key upstream.
- **Enforcement:** budgets (402), per-agent rate limit (429), circuit breaker (503).
- **Admin socket:** `/run/agentos-gateway/admin.sock` for budget changes, writable by operators only.
- **Config:** `agentos.networking.providers.<name> = { baseUrl; api; keyFile; };`

### 4. Security (`modules/security`)
- **Egress allowlist:** with `defaultEgress = "deny"`, dnsmasq only resolves allowlisted domains and records their addresses in an ipset; iptables rejects every other outbound connection (host-wide).
- **Gateway-only provider APIs:** the `agentos-agent` user cannot connect to provider API hosts directly, use a DNS server other than the local one, or use IPv6. Budgets cannot be bypassed.
- **AppArmor, auditd, kernel hardening** (sysctl, BPF JIT hardening, protected links/FIFOs).
- **Config:** `agentos.security.defaultEgress = "deny";`

### 5. Observability (`modules/observability`)
Full observability stack: Prometheus + Tempo + Grafana.
- **Tracing:** OpenTelemetry collector → Tempo pipeline (agents don't emit traces yet).
- **Dashboards:** Grafana on `localhost:2342` (reach it with `ssh -L 2342:localhost:2342`); set `grafanaAdminPasswordFile`.
- **Agent metrics:** the daemon exports spend, budgets, tokens and request counts per agent; Prometheus scrapes it.
- **Retention:** 30 days by default.
- **Config:** `agentos.observability.enable = true;`

---

## Agent Intelligence

### 6. Context & Memory (`modules/context`)
Persistent vector memory for agents.
- **Vector database:** Qdrant for semantic search over past context.
- **Per-agent memory:** Each agent remembers past sessions.
- **Shared knowledge base:** Agents share learnings about a project.
- **Embedding service:** Text → vectors using `text-embedding-3-small`.
- **Memory GC:** Old memories auto-expired after 90 days.
- **Config:** `agentos.context.enable = true;`

**CLI:**
```bash
agentos-memory stats        # Show vector counts
agentos-memory search       # Browse collections
agentos-memory forget       # Clear all memories
```

### 7. Multi-Agent Orchestration (`modules/orchestration`)
Queued tasks, pipelines, swarms with verify and judge steps, DAG workflows,
approval gates, retries and priorities, driven by `agentos-task`. GitHub
webhooks can create tasks and publish pull requests. See
[orchestration.md](orchestration.md) and [triggers.md](triggers.md).

---

## Tool Ecosystem

### 8. MCP Tool Registry (`modules/mcp-registry`)
Manages MCP (Model Context Protocol) tool servers that extend agent capabilities.
- **15+ built-in tools:** filesystem, git, github, postgres, sqlite, fetch, memory, puppeteer, brave-search, sequential-thinking, slack, linear, sentry, semgrep, mermaid.
- **Per-agent permissions:** Control which tools each agent can use.
- **Auto-discovery:** Tools register themselves on startup.
- **Health checking:** Registry monitors tool server health.
- **Config:** `agentos.mcp-registry.enable = true;`

**CLI:**
```bash
agentos-tools list                           # List all tools
agentos-tools enable puppeteer               # Enable a tool
agentos-tools disable sqlite                 # Disable a tool
agentos-tools add my-tool "npx @my/tool"     # Add custom tool
agentos-tools test github                    # Health check
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
- **Config:** `agentos.budget-controller.defaultDailyBudgetUSD = 50.0;`

**CLI:**
```bash
agentos-budget status       # spend per agent today, limits, request counts
agentos-budget set <id> 25  # daily budget for one agent
agentos-budget reset <id>   # back to the default
agentos-budget history      # 7-day global spend
agentos-budget by-model
```

### 10. Circuit Breaker (`modules/circuit-breaker`)
- **Rate limit:** max LLM requests per agent per minute (HTTP 429 with Retry-After).
- **Circuit breaker:** after N consecutive upstream failures an agent's requests are refused for a cooldown (HTTP 503).
- **Resource limits:** memory, CPU share and process count for each sandboxed agent.
- **Config:** `agentos.circuit-breaker.maxConsecutiveFailures = 5;`

**CLI:**
```bash
agentos-breaker status
agentos-breaker reset <id>  # close an open circuit
```

### 11. Secrets Manager (`modules/secrets-manager`)
Secure API key management.
- **Encrypted at rest:** sops-nix with age encryption.
- **Per-agent access:** Agents only see their allowed keys.
- **Never in logs:** Secrets injected at spawn, not persisted in env.
- **Auto-rotation:** Optional periodic key rotation.
- **9 pre-configured keys:** Anthropic, OpenAI, Google, GitHub, Factory, Slack, Linear, Sentry, Brave.
- **Config:** `agentos.secrets-manager.backend = "sops";`

**CLI:**
```bash
agentos-secrets list        # Show configured keys (values hidden)
agentos-secrets set KEY     # Set a secret (prompted, hidden)
agentos-secrets edit        # Edit secrets file in $EDITOR
agentos-secrets check       # Show access mapping
```

---

## Developer Experience

### 12. Git Automation (`modules/git-automation`)
- **Branch per agent session:** `agentos spawn` creates `agent/<agent-id>` in the workspace.
- **Hooks:** pre-commit checks for secrets, large files and failing tests (`agentos-git init`).
- **Helpers** for commits, checkpoints and PRs via the GitHub CLI.
- `autoCommit` is not acted on yet. `autoPR` pushes `agent/<task-id>` and opens a PR for successful orchestrator tasks of workspaces listed in `publish.repos` (see docs/triggers.md).

**CLI:**
```bash
agentos-git init            # Set up hooks in workspace
agentos-git commit "msg"
agentos-git pr "title"      # Create PR via GitHub CLI
agentos-git snapshot        # Checkpoint commit
agentos-git undo            # Undo last commit, keep changes
```

### 13. Environment Provisioning (`modules/provisioning`)
Auto-detects project type and provisions the right environment.
- **Auto-detection:** Reads package.json, requirements.txt, go.mod, Cargo.toml, etc.
- **8+ templates:** Python 3.11/3.12, Node 20/22, Go 1.23, Rust stable, C++, Java 21.
- **Nix dev shells:** Reproducible environments per project.
- **Local cache:** Binary cache for fast environment creation.
- **Pre-build:** Pre-build common environments at install time.
- **Config:** `agentos.provisioning.enable = true;`

**CLI:**
```bash
agentos-env detect          # Detect project type
agentos-env list            # List available environments
agentos-env shell           # Launch detected environment
agentos-env shell python-3.11  # Launch specific environment
agentos-env init            # Create shell.nix for current project
agentos-env prebuild        # Pre-build environments
```

---

## Automation

### 14. Scheduler (`modules/scheduler`)
Recurring tasks on systemd `OnCalendar` schedules, managed with
`agentos-schedule` or declared in Nix. See [orchestration.md](orchestration.md).

### 15. Notifications (`modules/notifications`)
The agent daemon forwards events to Slack, Discord or a generic JSON webhook.
- **Events:** `agent-started`, `task-completed`, `budget-threshold` (thresholds, budget exceeded), `agent-error` (agent stopped, circuit opened).
- **Secret URLs** are read from files (`slackWebhookFile`, `discordWebhookFile`, `webhookUrlFile`), e.g. sops secrets, never the Nix store.
- **Config:** `agentos.notifications.slackWebhookFile = "/run/secrets/SLACK_WEBHOOK";`

**CLI:**
```bash
agentos-notify status
agentos-notify test "hello"
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
| Sandboxed agents, registry, daemon | runtime | `agentos spawn` | ✅ (VM-tested) |
| Model gateway | networking | (automatic) | ✅ (VM-tested) |
| Budget controller | budget-controller | `agentos-budget` | ✅ (VM-tested) |
| Circuit breaker, rate limit, resource limits | circuit-breaker | `agentos-breaker` | ✅ |
| Notifications | notifications | `agentos-notify` | ✅ (VM-tested) |
| Egress allowlist, gateway-only provider access | security | (automatic) | ✅ (VM-tested) |
| Storage & snapshots | storage | `agentos snapshot` | ✅ |
| Observability | observability | Grafana | ✅ |
| Secrets manager | secrets-manager | `agentos-secrets` | ✅ (after sops setup) |
| Git automation | git-automation | `agentos-git` | Helpers ✅, auto-PR for orchestrator tasks ✅, auto-commit planned |
| Context & memory | context | `agentos-memory` | Qdrant ✅, memory manager planned |
| MCP servers | mcp-servers | `agentos-mcp` | ✅ (config) |
| Provisioning | provisioning | `agentos-env` | ✅ (provisioner service planned) |
| Orchestration | orchestration | `agentos-task` | ✅ |
| Scheduler | scheduler | `agentos-schedule` | ✅ |
| 20 coding agents | agents | `agentos agents` | ✅ |

---

## VIBE Integration (anubhavg-icpl/vibe)

AgentOS installs the VIBE library into the supported agent CLIs on first boot, fetching it from GitHub with `npx`.

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
agentos-vibe install     # Install into all agents
agentos-vibe status      # Check installation
agentos-vibe categories  # List 52 categories
agentos-vibe search rag  # Search library
agentos-vibe add <name>  # Install specific asset

# Direct VIBE CLI also available:
vibe                     # Interactive picker
vibe list                # List all assets
vibe search "security"   # Search
```

---

## Agent Skills (`modules/skills`)

`agentos.skills` links skill packs (nixos/packages/skills, pinned sources) into every agent CLI's user-level skills directory, for the agent user and `agentos.skills.users`.

- Packs: `fwc-swiftui-skills`, `ui-skills`, `img2threejs`; one `agentos.skills.packs.<name>.enable` option per pack.
- Targets (`agentos.skills.targets`): `.agents/skills`, `.claude/skills`, `.codex/skills`, `.config/opencode/skills`, `.gemini/skills`, `.copilot/skills`, `.cursor/skills`, `.factory/skills`, `.config/agents/skills` (Amp), `.config/goose/skills`, `.qwen/skills`, `.config/crush/skills`.
- A name used by two packs fails the build. Skills a user wrote are not overwritten; stale links of ours are removed.
- Pack tools are added to the PATH; pack MCP servers to `agentos.mcp-registry.extraToolServers`.

```bash
agentos-skills list
agentos-skills doctor
agentos-skills path <skill>
```

See [skills.md](skills.md). Checks: `skills-eval` (no VM) and the VM test `skills`.

---

## MCP Server Registry (36 servers)

Preconfigured Model Context Protocol servers, written to `/etc/agentos/mcp-servers.json`. Each entry runs a published npm package (`npx -y`) or PyPI package (`uvx`), fetched on first start. Runtime enable/disable changes are stored in `/var/lib/agentos/mcp-servers.json`.

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
agentos-mcp list [category]   # List servers
agentos-mcp enable <name>     # Enable (stored in /var/lib/agentos)
agentos-mcp start <name>      # Run a server in the foreground
agentos-mcp stats
```

