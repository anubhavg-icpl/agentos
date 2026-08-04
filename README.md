# AgentOS

**An operating system designed for coding agents.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Modules](https://img.shields.io/badge/Modules-27-blue)](modules/)
[![Agents](https://img.shields.io/badge/Agents-22-green)](docs/AGENTS.md)
[![MCP Servers](https://img.shields.io/badge/MCP%20Servers-50%2B-purple)](docs/FEATURES.md)
[![VIBE Skills](https://img.shields.io/badge/VIBE%20Skills-5340-orange)](https://github.com/anubhavg-icpl/vibe)

---

## What is AgentOS?

AgentOS is a minimal NixOS-based operating system that ships with **22 AI coding agents** pre-installed, **5340 expert skills** from the VIBE library, **50+ MCP tool servers**, **20+ language runtimes**, and a complete infrastructure layer for running, monitoring, and controlling agents safely.

Traditional operating systems are designed for human users. AgentOS is designed for AI coding agents. Every layer, from the filesystem to the network, is optimized for programs that read, write, and execute code autonomously.

## Numbers

| What | Count |
|------|-------|
| Pre-installed coding agents | **22** |
| NixOS feature modules | **27** |
| MCP tool servers | **50+** |
| VIBE expert modes | **853** |
| VIBE installable skills | **5340** |
| VIBE subagents | **200** |
| VIBE slash commands | **112** |
| VIBE plugins | **120** |
| Language runtimes | **20+** |
| Database services | **6** |
| Dev tools pre-installed | **100+** |
| Security tools | **30+** |

## Quick Start

### Build the ISO

```bash
nix build .#iso-image
# Flash to USB:
dd if=result/iso/agentos-*.iso of=/dev/sdX bs=4M status=progress
```

### Or run in a VM

```bash
nix build .#vm-image
qemu-system-x86_64 -m 4096 -enable-kvm -hda result/nixos.qcow2
```

### SSH in and start coding

```bash
ssh admin@agentos
claude        # Anthropic Claude Code
codex         # OpenAI Codex CLI
droid         # Factory Droid
aider         # AI pair programmer
# Run 'agentos agents' for the full list of 22 agents
```

## Pre-installed Agents (22)

### Tier 1 — Primary (10)
Claude Code, Codex, Factory Droid, Aider, Gemini CLI, Qwen Code, Amp, Goose, OpenCode, Crush

### Tier 2 — Extended (6)
Cursor CLI, Cline, Continue, GitHub Copilot, Devin, Roo Code

### Tier 3 — Research (6)
Open Interpreter, SWE-Agent, GPT-Engineer, Devika, AutoGPT, smol-developer

See [docs/AGENTS.md](docs/AGENTS.md) for complete reference.

## Feature Modules (27)

| Module | Description | CLI |
|--------|-------------|-----|
| **runtime** | Containerd isolation, agent daemon | `agentos spawn` |
| **security** | AppArmor, default-deny egress, audit | (automatic) |
| **observability** | OpenTelemetry + Prometheus + Grafana | Grafana dashboard |
| **storage** | btrfs snapshots, dedup, GC | `agentos snapshot` |
| **networking** | Model API gateway, egress firewall | (automatic) |
| **context** | Qdrant vector DB, agent memory | `agentos-memory` |
| **orchestration** | Multi-agent coordination | `agentos-orchestrate` |
| **mcp-registry** | 15+ MCP tool servers | `agentos-tools` |
| **mcp-servers** | 50+ MCP servers (8 categories) | `agentos-mcp` |
| **budget-controller** | Per-agent cost caps | `agentos-budget` |
| **circuit-breaker** | Rate limiting, runaway detection | `agentos-breaker` |
| **secrets-manager** | sops-nix encrypted keys | `agentos-secrets` |
| **git-automation** | Auto-branch/commit/PR | `agentos-git` |
| **provisioning** | Env detection, Nix shells | `agentos-env` |
| **scheduler** | Cron-like task scheduling | `agentos-schedule` |
| **notifications** | Slack/Discord/email/webhook | `agentos-notify` |
| **language-toolchains** | 20+ runtimes pre-installed | `agentos-langs` |
| **databases** | Postgres, Redis, SQLite, DuckDB | `agentos-db` |
| **dev-tools** | 100+ developer utilities | (automatic) |
| **security-tools** | Semgrep, trivy, nmap, ghidra | `agentos-scan` |
| **browser-tools** | Chromium, Playwright, Puppeteer | `agentos-web` |
| **networking-tools** | nmap, tcpdump, wireshark | (automatic) |
| **cloud-tools** | AWS, GCP, Azure, CF, Vercel CLIs | (automatic) |
| **package-managers** | pip, npm, cargo, go, bundler | (automatic) |
| **editors** | Neovim (LSP pre-configured), Helix | (automatic) |
| **ai-ml** | Ollama, llama.cpp, PyTorch | (automatic) |
| **vibe-integration** | 853 modes, 5340 skills | `agentos-vibe` |

See [docs/FEATURES.md](docs/FEATURES.md) for detailed documentation.

## VIBE Integration

On first boot, AgentOS auto-installs the [VIBE library](https://github.com/anubhavg-icpl/vibe) into all 7 supported agent CLIs:

- **853 expert modes** (RAG, LLM training, design systems, engineer personas, Mythos security, modern web, Android, data platforms)
- **5340 skills** reusable across agents
- **200 subagents** in 10 categories
- **112 slash commands**, **120 plugins**, **111 rules**
- **759 system prompts**, **106 prompts**, **18 recipes**

```bash
agentos-vibe install      # Install into all agents
agentos-vibe categories   # Browse 52 categories
vibe search "rag"         # Search the library
vibe list                 # List all 5340+ assets
```

## MCP Server Registry (50+ servers)

```bash
agentos-mcp list                    # List all servers
agentos-mcp list database           # Filter by category
agentos-mcp enable puppeteer        # Enable a server
agentos-mcp stats                   # Show statistics
```

Categories: core (10), database (8), cloud (8), integration (12), browser (4), AI/ML (4), DevOps (6), data/search (4).

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         AgentOS Host                             │
│                    (NixOS minimal + 27 modules)                 │
│                                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐           │
│  │ Agent A  │ │ Agent B  │ │ Agent C  │ │ Agent D  │  (ctr)    │
│  │claude-code│ │codex    │ │droid     │ │aider     │           │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘           │
│       │            │            │            │                   │
│  ┌────┴────────────┴────────────┴────────────┴────────────┐     │
│  │              AgentOS Daemon + Orchestrator             │     │
│  └────┬──────────┬──────────┬──────────┬──────────────────┘     │
│       │          │          │          │                         │
│  ┌────┴───┐ ┌────┴───┐ ┌────┴───┐ ┌────┴──────────┐            │
│  │ Model  │ │  MCP   │ │ Budget │ │ Observability │            │
│  │Gateway │ │Reg 50+ │ │Ctrl.   │ │(OTel+Prom+Gr) │            │
│  └────────┘ └────────┘ └────────┘ └───────────────┘            │
│                                                                  │
│  VIBE 5340 skills · 20+ languages · 6 DBs · 50+ MCP servers     │
│  btrfs snapshots · Qdrant vectors · Redis · sops secrets        │
└─────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
agentos/
├── flake.nix                      # Top-level Nix flake
├── modules/                       # 27 NixOS modules
│   ├── runtime/                   # Containerd isolation
│   ├── security/                  # AppArmor, firewall, kernel
│   ├── observability/             # Prometheus, Tempo, Grafana
│   ├── storage/                   # btrfs, dedup, GC
│   ├── networking/                # Model gateway, egress
│   ├── context/                   # Qdrant vector memory
│   ├── orchestration/             # Multi-agent coordination
│   ├── mcp-registry/              # MCP tool management
│   ├── mcp-servers/               # 50+ preconfigured MCP servers
│   ├── budget-controller/         # Cost tracking, auto-shutdown
│   ├── circuit-breaker/           # Rate limiting, loops
│   ├── secrets-manager/           # sops-nix encryption
│   ├── git-automation/            # Auto-branch/commit/PR
│   ├── provisioning/              # Env detection, Nix shells
│   ├── scheduler/                 # Cron task scheduling
│   ├── notifications/             # Multi-channel alerts
│   ├── language-toolchains/       # 20+ runtimes
│   ├── databases/                 # Postgres, Redis, SQLite
│   ├── dev-tools/                 # 100+ utilities
│   ├── security-tools/            # Semgrep, nmap, ghidra
│   ├── browser-tools/             # Chromium, Playwright
│   ├── networking-tools/          # nmap, tcpdump, wireshark
│   ├── cloud-tools/               # AWS, GCP, Azure CLIs
│   ├── package-managers/          # pip, npm, cargo, etc.
│   ├── editors/                   # Neovim, Helix
│   ├── ai-ml/                     # Ollama, llama.cpp, PyTorch
│   └── vibe-integration/          # VIBE 853 modes, 5340 skills
├── agents/                        # 22 coding agent packages
├── nixos/
│   ├── hosts/                     # Host configs (metal + ISO)
│   └── packages/                  # Internal binaries + CLI
├── templates/                     # Agent workspace template
└── docs/                          # Documentation
```

## Documentation

- [AGENTS.md](docs/AGENTS.md) — All 22 pre-installed agents
- [FEATURES.md](docs/FEATURES.md) — All 27 modules documented
- [ISO-SIZE.md](docs/ISO-SIZE.md) — ISO size analysis
- [CHANGELOG.md](CHANGELOG.md) — Version history
- [CONTRIBUTING.md](CONTRIBUTING.md) — How to contribute

## License

MIT — See [LICENSE](LICENSE)

## Author

**Anubhav Gain** — [github.com/anubhavg-icpl](https://github.com/anubhavg-icpl)

Related: [VIBE](https://github.com/anubhavg-icpl/vibe) — 853 AI agent modes
