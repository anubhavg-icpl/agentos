<div align="center">

<!-- IMAGE 1: Hero Banner — generate with docs/prompts/IMAGE-PROMPTS.md #1 -->
<!-- Replace with: ![AgentOS](assets/hero.png) -->

<h1>🤖 AgentOS</h1>

**An operating system designed for AI coding agents.**

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="modules/"><img src="https://img.shields.io/badge/Modules-27-blue" alt="Modules"></a>
  <a href="docs/AGENTS.md"><img src="https://img.shields.io/badge/Agents-22-green" alt="Agents"></a>
  <a href="docs/FEATURES.md"><img src="https://img.shields.io/badge/MCP%20Servers-56-purple" alt="MCP"></a>
  <a href="https://github.com/anubhavg-icpl/vibe"><img src="https://img.shields.io/badge/VIBE%20Skills-5340-orange" alt="VIBE"></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/Built%20on-NixOS-7E2F8E" alt="NixOS"></a>
</p>

<h3>22 AI Agents · 5340 Skills · 56 MCP Servers · 27 Modules · 20+ Languages</h3>

[Quick Start](#quick-start) ·
[Agents](#pre-installed-agents-22) ·
[Features](#feature-modules-27) ·
[VIBE](#vibe-integration) ·
[Architecture](#architecture) ·
[Docs](#documentation)

</div>

---

## Why does this exist?

In 2026, AI coding agents write, test, and deploy most of our code. So why are we still running them on operating systems designed for humans clicking around a desktop?

**Agents need:**
- Sandboxed execution environments (not a shared shell)
- Budget caps (so they don't burn $1000 in an hour)
- Git automation (every change tracked, committed, PR'd)
- Tool access (GitHub, databases, browsers, search)
- Observability (traces, metrics, cost dashboards)
- Reproducible environments (bit-for-bit identical)

AgentOS provides all of this, built-in, on a minimal NixOS base.

---

## Quick Start

```bash
# Build the ISO (requires Nix with flakes)
nix build .#iso-image

# Flash to USB
dd if=result/iso/agentos-*.iso of=/dev/sdX bs=4M status=progress

# Or run in a VM
nix build .#vm-image
qemu-system-x86_64 -m 4096 -enable-kvm -hda result/nixos.qcow2

# SSH in and start coding
ssh admin@agentos
claude    # Anthropic Claude Code
codex     # OpenAI Codex CLI
droid     # Factory Droid
aider     # AI pair programmer
```

---

<!-- IMAGE 2: Architecture Diagram — generate with docs/prompts/IMAGE-PROMPTS.md #2 -->

## Pre-installed Agents (22)

<!-- IMAGE 3: Agents Grid — generate with docs/prompts/IMAGE-PROMPTS.md #3 -->

### Tier 1 — Primary (10)

| Command | Agent | Provider |
|---------|-------|----------|
| `claude` | Claude Code | Anthropic |
| `codex` | Codex CLI | OpenAI |
| `droid` | Factory Droid | Factory AI |
| `aider` | Aider | Open source |
| `gemini` | Gemini CLI | Google |
| `qwen-code` | Qwen Code | Alibaba |
| `amp` | Amp | Sourcegraph |
| `goose` | Goose | Block |
| `opencode` | OpenCode | SST |
| `crush` | Crush | Charm |

### Tier 2 — Extended (6)

| Command | Agent | Provider |
|---------|-------|----------|
| `cursor` | Cursor CLI | Cursor |
| `cline` | Cline | Open source |
| `continue` | Continue | Open source |
| `copilot` | GitHub Copilot | GitHub |
| `devin` | Devin | Cognition |
| `roo` | Roo Code | Open source |

### Tier 3 — Research (6)

| Command | Agent | Provider |
|---------|-------|----------|
| `interpreter` | Open Interpreter | Open source |
| `sweagent` | SWE-Agent | Princeton |
| `gpt-engineer` | GPT-Engineer | Open source |
| `devika` | Devika | Open source |
| `autogpt` | AutoGPT | Open source |
| `smol-developer` | smol-developer | Open source |

```bash
agentos agents      # List all 22 agents
agentos spawn claude-code --workspace ./myproject   # Managed mode
```

See [docs/AGENTS.md](docs/AGENTS.md) for complete reference.

---

## Feature Modules (27)

| Module | Description | CLI Command |
|--------|-------------|-------------|
| 🏗️ **runtime** | Containerd isolation, agent daemon | `agentos spawn` |
| 🔒 **security** | AppArmor, default-deny egress, audit | automatic |
| 📊 **observability** | Prometheus + Tempo + Grafana | Grafana `:2342` |
| 💾 **storage** | btrfs snapshots, dedup, workspace GC | `agentos snapshot` |
| 🌐 **networking** | Model API gateway, egress firewall | automatic |
| 🧠 **context** | Qdrant vector DB, persistent memory | `agentos-memory` |
| 🤝 **orchestration** | Multi-agent coordination | `agentos-orchestrate` |
| 🔌 **mcp-registry** | 15+ core MCP tools | `agentos-tools` |
| 🔌 **mcp-servers** | 56 MCP servers (8 categories) | `agentos-mcp` |
| 💰 **budget-controller** | Per-agent cost caps, auto-shutdown | `agentos-budget` |
| ⚡ **circuit-breaker** | Rate limiting, runaway detection | `agentos-breaker` |
| 🔑 **secrets-manager** | sops-nix encrypted API keys | `agentos-secrets` |
| 📝 **git-automation** | Auto-branch, auto-commit, auto-PR | `agentos-git` |
| 📦 **provisioning** | Env detection, Nix dev shells | `agentos-env` |
| ⏰ **scheduler** | Cron-like task scheduling | `agentos-schedule` |
| 🔔 **notifications** | Slack, Discord, email, webhook | `agentos-notify` |
| 🐍 **language-toolchains** | 20+ runtimes pre-installed | `agentos-langs` |
| 🗄️ **databases** | Postgres, Redis, SQLite, DuckDB | `agentos-db` |
| 🛠️ **dev-tools** | 100+ developer utilities | automatic |
| 🛡️ **security-tools** | Semgrep, trivy, nmap, ghidra | `agentos-scan` |
| 🌍 **browser-tools** | Chromium, Playwright, Puppeteer | `agentos-web` |
| 📡 **networking-tools** | nmap, tcpdump, wireshark | automatic |
| ☁️ **cloud-tools** | AWS, GCP, Azure, CF, Vercel CLIs | automatic |
| 📋 **package-managers** | pip, npm, cargo, bundler, maven | automatic |
| ✏️ **editors** | Neovim (LSP configured), Helix | automatic |
| 🤖 **ai-ml** | Ollama, llama.cpp, PyTorch, Jupyter | automatic |
| ✨ **vibe-integration** | 853 modes, 5340 skills from VIBE | `agentos-vibe` |

See [docs/FEATURES.md](docs/FEATURES.md) for detailed documentation.

---

## VIBE Integration

<!-- IMAGE 5: VIBE Integration — generate with docs/prompts/IMAGE-PROMPTS.md #5 -->

On first boot, AgentOS auto-installs the [VIBE library](https://github.com/anubhavg-icpl/vibe) into all 7 agent CLIs:

| Asset | Count |
|-------|-------|
| Expert modes | 853 (52 categories) |
| Skills | 5,340 |
| Subagents | 200 |
| Slash commands | 112 |
| Plugins | 120 |
| Rules | 111 |
| System prompts | 759 |
| Recipes | 18 |

```bash
agentos-vibe install       # Install into all agents
agentos-vibe categories    # Browse 52 categories
vibe search "rag"          # Search the library
vibe list                  # List all assets
```

---

## MCP Server Registry (56 servers)

<!-- IMAGE 4: MCP Network — generate with docs/prompts/IMAGE-PROMPTS.md #4 -->

| Category | Count | Servers |
|----------|-------|---------|
| Core | 10 | filesystem, git, memory, fetch, sequential-thinking, time, everything, exec, fs-watch, clipboard |
| Database | 8 | postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse, surrealdb |
| Cloud | 8 | aws, gcp, azure, cloudflare, vercel, fly, railway, supabase |
| Integration | 12 | github, gitlab, linear, jira, slack, discord, notion, sentry, datadog, pagerduty, asana, trello |
| Browser | 4 | puppeteer, playwright, browserbase, selenium |
| AI/ML | 4 | openai-tools, anthropic-tools, replicate, huggingface |
| DevOps | 6 | docker, kubernetes, terraform, ansible, grafana, prometheus |
| Data/Search | 4 | brave-search, tavily, exa, perplexity |

```bash
agentos-mcp list            # List all 56 servers
agentos-mcp enable puppeteer # Enable a server
agentos-mcp stats           # Show statistics
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         AgentOS Host                                 │
│                    (NixOS minimal + 27 modules)                     │
│                                                                      │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐               │
│  │ Agent A  │ │ Agent B  │ │ Agent C  │ │ Agent D  │  (containerd) │
│  │ claude   │ │ codex    │ │ droid    │ │ aider    │               │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘               │
│       │            │            │            │                       │
│  ┌────┴────────────┴────────────┴────────────┴────────────────┐     │
│  │              AgentOS Daemon + Orchestrator                 │     │
│  └────┬──────────┬──────────┬──────────┬──────────────────────┘     │
│       │          │          │          │                             │
│  ┌────┴───┐ ┌────┴───┐ ┌────┴───┐ ┌────┴──────────┐                │
│  │ Model  │ │  MCP   │ │ Budget │ │ Observability │                │
│  │Gateway │ │ 56 srv │ │ Ctrl.  │ │ (OTel+P+Graf) │                │
│  └────────┘ └────────┘ └────────┘ └───────────────┘                │
│                                                                      │
│  VIBE: 5340 skills · 853 modes · 200 agents · 759 system prompts   │
│  20+ languages · 6 databases · btrfs snapshots · Qdrant · sops      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Configuration

```nix
# Every feature is toggleable:
agentos = {
  runtime = {
    enable = true;
    maxAgents = 8;
  };
  budget-controller = {
    enable = true;
    defaultDailyBudgetUSD = 50.0;
    autoShutdown = true;
  };
  circuit-breaker = {
    enable = true;
    maxConsecutiveFailures = 5;
  };
  vibe-integration = {
    enable = true;
    autoInstallOnBoot = true;
  };
  mcp-servers = {
    enable = true;
    enableCore = true;
    enableDatabases = true;
  };
};
```

---

## Project Structure

```
agentos/
├── flake.nix                      # Top-level Nix flake
├── modules/                       # 27 NixOS modules
│   ├── runtime/                   #   Containerd isolation
│   ├── budget-controller/         #   Cost caps, auto-shutdown
│   ├── circuit-breaker/           #   Rate limiting, loop detection
│   ├── mcp-servers/               #   56 preconfigured MCP servers
│   ├── vibe-integration/          #   5340 skills auto-installer
│   ├── context/                   #   Qdrant vector memory
│   ├── orchestration/             #   Multi-agent coordination
│   ├── git-automation/            #   Auto-branch/commit/PR
│   └── ...                        #   19 more modules
├── agents/                        # 22 coding agent packages
├── nixos/
│   ├── hosts/                     # Host configs (metal + ISO)
│   └── packages/                  # Internal binaries + CLI
├── templates/                     # Agent workspace template
└── docs/                          # Documentation + prompts
```

---

## Comparison

| Feature | Plain Linux | Docker | AgentOS |
|---------|-------------|--------|---------|
| 22 agents pre-installed | ❌ | ❌ | ✅ |
| Budget caps per agent | ❌ | ❌ | ✅ |
| Circuit breakers | ❌ | ❌ | ✅ |
| 56 MCP servers configured | ❌ | ❌ | ✅ |
| 5340 VIBE skills auto-loaded | ❌ | ❌ | ✅ |
| Git auto-commit per session | ❌ | ❌ | ✅ |
| btrfs snapshots per agent | ❌ | ❌ | ✅ |
| Vector memory (Qdrant) | ❌ | ❌ | ✅ |
| Multi-agent orchestration | ❌ | ❌ | ✅ |
| Prometheus + Grafana | Manual | Manual | ✅ Built-in |
| Encrypted secrets (sops) | Manual | Manual | ✅ Built-in |
| 20+ language runtimes | Manual | Manual | ✅ Pre-installed |
| Full reproducibility | ❌ | Partial | ✅ NixOS |

---

## Documentation

- 📖 [AGENTS.md](docs/AGENTS.md) — All 22 agents with usage examples
- 📖 [FEATURES.md](docs/FEATURES.md) — All 27 modules documented
- 📖 [ISO-SIZE.md](docs/ISO-SIZE.md) — ISO size analysis
- 📝 [CHANGELOG.md](CHANGELOG.md) — Version history
- 🤝 [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute
- 🎨 [IMAGE-PROMPTS.md](docs/prompts/IMAGE-PROMPTS.md) — Image generation prompts for assets
- 📣 [SOCIAL-PROMPTS.md](docs/prompts/SOCIAL-PROMPTS.md) — Social media launch content prompts

---

## Roadmap

- [ ] GPU scheduling for local model inference
- [ ] Remote agent fleets (multi-machine)
- [ ] Agent marketplace (community-contributed agents)
- [ ] Web UI dashboard (beyond Grafana)
- [ ] ARM64 / Apple Silicon support
- [ ] Deterministic replay of agent sessions
- [ ] Inter-agent communication protocol
- [ ] Cost optimization (auto-route to cheapest model)

---

<div align="center">

## License

MIT — See [LICENSE](LICENSE)

## Author

**Anubhav Gain** · [GitHub](https://github.com/anubhavg-icpl) · [VIBE](https://github.com/anubhavg-icpl/vibe)

---

⭐ Star this repo if you find it useful!

</div>
