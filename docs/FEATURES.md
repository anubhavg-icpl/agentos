# AgentOS — Feature Reference

Complete documentation of every feature built into AgentOS.

---

## Core Infrastructure

### 1. Container Runtime (`modules/runtime`)
Sandboxes each agent in an isolated container (containerd/podman/docker).
- **Per-agent isolation:** Each agent gets its own filesystem, network namespace, process tree.
- **Resource quotas:** CPU, memory, disk, and PID limits per agent.
- **Snapshotting:** Save and restore agent state mid-run.
- **Config:** `agentos.runtime.enable = true;`

**CLI:**
```bash
agentos spawn claude-code --workspace ./myproject
agentos list
agentos kill <agent-id>
agentos logs <agent-id>
agentos shell <agent-id>
```

### 2. Storage & Snapshots (`modules/storage`)
btrfs-based copy-on-write filesystem for instant branching and snapshots.
- **btrfs subvolumes:** Each workspace is a subvolume; snapshots are instant.
- **Auto-snapshots:** Hourly snapshots with configurable retention.
- **Deduplication:** Daily content-addressed dedup saves disk space.
- **Workspace GC:** Automatically cleans up abandoned workspaces.
- **Config:** `agentos.storage.enable = true;`

### 3. Networking (`modules/networking`)
Internal bridge network for agent containers with NAT and firewalling.
- **Agent subnet:** Containers live on `10.200.0.0/24`.
- **Model API Gateway:** All LLM calls route through a proxy that enforces budget and rate limits.
- **Provider support:** Anthropic, OpenAI, Google, Groq, OpenRouter, DeepSeek.
- **Config:** `agentos.networking.enable = true;`

### 4. Security (`modules/security`)
Capability-based security model designed for agents.
- **Default-deny egress:** Agents can only reach whitelisted domains.
- **AppArmor:** Mandatory access control for all processes.
- **Kernel hardening:** Sysctl tuning, BPF JIT hardening, ASLR enforcement.
- **Audit logging:** Every execve syscall logged; workspace writes watched.
- **Config:** `agentos.security.defaultEgress = "deny";`

### 5. Observability (`modules/observability`)
Full observability stack: Prometheus + Tempo + Grafana.
- **Tracing:** OpenTelemetry traces for every tool call.
- **Metrics:** Per-agent CPU, memory, token usage, cost.
- **Dashboards:** Grafana at `http://<host>:2342` (admin/agentos).
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
Coordinates multiple agents working on the same problem.
- **Planner-worker:** A planner breaks down tasks; workers execute subtasks.
- **Swarm:** N agents tackle the same problem; best result wins.
- **Hierarchical:** Agents spawn sub-agents recursively.
- **Pipeline:** Agents work in sequence (output feeds next).
- **Task queue:** Redis-backed priority queue.
- **Result strategies:** first-success, best-of-n, consensus, all.
- **Config:** `agentos.orchestration.mode = "planner-worker";`

**CLI:**
```bash
agentos-orchestrate run "build a REST API" claude-code
agentos-orchestrate swarm "fix all failing tests" 3
agentos-orchestrate status
agentos-orchestrate results <task-id>
```

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
Prevents runaway spending on LLM APIs.
- **Per-agent budgets:** Daily and session caps in USD.
- **Global budget:** System-wide daily cap.
- **Threshold alerts:** Warn at 50%, 80%, 95%, 100%.
- **Auto-shutdown:** Kill agents that exceed their budget.
- **13 models priced:** Claude, GPT-4o, Gemini, DeepSeek, Qwen, Llama.
- **Cost breakdowns:** By agent, model, project.
- **Config:** `agentos.budget-controller.defaultDailyBudgetUSD = 50.0;`

**CLI:**
```bash
agentos-budget status       # Current spend
agentos-budget history      # 7-day cost history
agentos-budget by-model     # Spend per model
agentos-budget set <id> 25  # Set per-agent budget
agentos-budget alerts       # Recent alerts
```

### 10. Circuit Breaker (`modules/circuit-breaker`)
Protects against runaway and malfunctioning agents.
- **Rate limiting:** Max API calls, file writes, shell commands per minute.
- **Circuit breaker:** N consecutive failures pauses the agent.
- **Resource limits:** Kill agents exceeding CPU/memory limits.
- **Loop detection:** Detects agents stuck repeating the same action.
- **Cooldown:** 5-minute pause after circuit trips.
- **Config:** `agentos.circuit-breaker.maxConsecutiveFailures = 5;`

**CLI:**
```bash
agentos-breaker status      # Show limits and tripped circuits
agentos-breaker trip <id>   # Manually trip a circuit
agentos-breaker reset [id]  # Reset circuit(s)
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
Makes every agent change tracked and reviewable.
- **Auto-branch:** New branch per agent session (`agent/claude-code-20260104-123456`).
- **Auto-commit:** Commit after each meaningful change.
- **Auto-PR:** Create PR when agent work completes.
- **Quality gates:** Pre-commit hook requires tests to pass.
- **Secret blocking:** Prevents API keys from being committed.
- **Large file blocking:** Blocks files > 10MB.
- **Config:** `agentos.git-automation.autoPR = true;`

**CLI:**
```bash
agentos-git init            # Set up hooks in workspace
agentos-git branch          # Create agent branch
agentos-git commit "msg"    # Auto-commit
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
Cron-like scheduling for recurring agent tasks.
- **Cron format:** Standard cron expressions (`0 2 * * *`, `@hourly`, etc.).
- **Priority queues:** High, normal, low priority tasks.
- **Deadlines:** Tasks can have a max duration.
- **Dependency chains:** Task B starts when task A finishes.
- **Off-hours mode:** Only run during specified hours (e.g., 22:00-06:00).
- **Config:** `agentos.scheduler.maxConcurrent = 4;`

**CLI:**
```bash
agentos-schedule list       # List scheduled tasks
agentos-schedule add nightly-scan "0 2 * * *" claude-code "Run security audit"
agentos-schedule remove nightly-scan
agentos-schedule run-now nightly-scan  # Trigger immediately
agentos-schedule status     # Queue status
```

### 15. Notifications (`modules/notifications`)
Sends alerts when agent events happen.
- **Slack:** Incoming webhook integration.
- **Discord:** Webhook-based messages.
- **Email:** SMTP delivery.
- **Generic webhook:** POST JSON to any URL.
- **Events:** task-completed, approval-needed, budget-threshold, agent-error, pr-created, tests-passed, tests-failed.
- **Config:** `agentos.notifications.enableSlack = true;`

**CLI:**
```bash
agentos-notify test         # Send test notification
agentos-notify send "info" "Hello from AgentOS"
agentos-notify status       # Show configured channels
```

---

## Pre-installed Agents (22 total)

See [AGENTS.md](./AGENTS.md) for the complete list and usage.

| Tier | Agents |
|------|--------|
| Primary (10) | Claude Code, Codex, Factory Droid, Aider, Gemini, Qwen, Amp, Goose, OpenCode, Crush |
| Extended (6) | Cursor, Cline, Continue, GitHub Copilot, Devin, Roo Code |
| Research (6) | Open Interpreter, SWE-Agent, GPT-Engineer, Devika, AutoGPT, smol-developer |

---

## Feature Summary

| Feature | Module | CLI Command | Enabled |
|---------|--------|-------------|---------|
| Container Runtime | runtime | `agentos spawn` | ✅ |
| Storage & Snapshots | storage | (automatic) | ✅ |
| Networking | networking | (automatic) | ✅ |
| Security | security | (automatic) | ✅ |
| Observability | observability | Grafana dashboard | ✅ |
| Context & Memory | context | `agentos-memory` | ✅ |
| Orchestration | orchestration | `agentos-orchestrate` | ✅ |
| MCP Tool Registry | mcp-registry | `agentos-tools` | ✅ |
| Budget Controller | budget-controller | `agentos-budget` | ✅ |
| Circuit Breaker | circuit-breaker | `agentos-breaker` | ✅ |
| Secrets Manager | secrets-manager | `agentos-secrets` | ✅ |
| Git Automation | git-automation | `agentos-git` | ✅ |
| Provisioning | provisioning | `agentos-env` | ✅ |
| Scheduler | scheduler | `agentos-schedule` | ✅ |
| Notifications | notifications | `agentos-notify` | ✅ |
| 22 Coding Agents | agents | `agentos agents` | ✅ |

---

## VIBE Integration (anubhavg-icpl/vibe)

AgentOS ships with the entire VIBE library pre-installed into every agent CLI.

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

## MCP Server Registry (50+ servers)

Preconfigured Model Context Protocol servers extending agent capabilities.

### Core (10 servers)
| Server | Description |
|--------|-------------|
| filesystem | Read, write, search files |
| git | Git operations (commit, branch, diff) |
| memory | Persistent key-value memory graph |
| fetch | Fetch web pages, convert to markdown |
| sequential-thinking | Step-by-step reasoning with branching |
| time | Time and timezone tools |
| everything | All-in-one server |
| exec | Shell command execution |
| filesystem-watch | Watch files for changes |
| clipboard | System clipboard read/write |

### Database (8 servers)
postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse, surrealdb

### Cloud (8 servers)
aws, gcp, azure, cloudflare, vercel, fly, railway, supabase

### Integration (12 servers)
github, gitlab, linear, jira, slack, discord, notion, sentry, datadog, pagerduty, asana, trello

### Browser (4 servers)
puppeteer, playwright, browserbase, selenium

### AI/ML (4 servers)
openai-tools, anthropic-tools, replicate, huggingface

### DevOps (6 servers)
docker, kubernetes, terraform, ansible, grafana, prometheus

### Data/Search (4 servers)
brave-search, tavily, exa, perplexity

**CLI:**
```bash
agentos-mcp list                 # List all servers
agentos-mcp list database        # Filter by category
agentos-mcp enable puppeteer     # Enable a server
agentos-mcp disable sqlite       # Disable a server
agentos-mcp enable-all           # Enable everything
agentos-mcp test github          # Health check
agentos-mcp stats                # Registry statistics
```
