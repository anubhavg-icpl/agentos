# AgentOS

**An operating system designed for coding agents.**

AgentOS is a minimal NixOS-based operating system that ships with 22+ AI coding agents pre-installed, plus a complete infrastructure layer for running, monitoring, and controlling them safely.

## Why?

Traditional operating systems are designed for human users. AgentOS is designed for AI coding agents. Every layer, from the filesystem to the network, is optimized for programs that read, write, and execute code autonomously.

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
# All 22 agents are pre-installed:
claude        # Anthropic Claude Code
codex         # OpenAI Codex CLI
droid         # Factory Droid
aider         # AI pair programmer
# ... see agentos agents for the full list
```

## Pre-installed Agents (22)

| Tier | Agents |
|------|--------|
| Primary | Claude Code, Codex, Factory Droid, Aider, Gemini CLI, Qwen Code, Amp, Goose, OpenCode, Crush |
| Extended | Cursor CLI, Cline, Continue, GitHub Copilot, Devin, Roo Code |
| Research | Open Interpreter, SWE-Agent, GPT-Engineer, Devika, AutoGPT, smol-developer |

See [docs/AGENTS.md](docs/AGENTS.md) for the full reference.

## Features (15 modules)

| Feature | Description |
|---------|-------------|
| **Container Runtime** | Sandboxed execution per agent (containerd) |
| **Context & Memory** | Qdrant vector DB for persistent agent memory |
| **Multi-Agent Orchestration** | Planner-worker, swarm, pipeline coordination |
| **MCP Tool Registry** | 15+ Model Context Protocol tools (GitHub, Slack, DB, browser) |
| **Budget Controller** | Per-agent cost caps with auto-shutdown |
| **Circuit Breaker** | Rate limiting and runaway agent detection |
| **Secrets Manager** | sops-nix encrypted API key management |
| **Git Automation** | Auto-branch, auto-commit, auto-PR per agent session |
| **Environment Provisioning** | Auto-detect project type, provision Nix dev shells |
| **Scheduler** | Cron-like recurring agent task scheduling |
| **Notifications** | Slack, Discord, email, webhook alerts |
| **Observability** | OpenTelemetry + Prometheus + Grafana |
| **Storage** | btrfs snapshots, dedup, workspace GC |
| **Networking** | Model API gateway with egress firewall |
| **Security** | AppArmor, kernel hardening, default-deny network |

See [docs/FEATURES.md](docs/FEATURES.md) for detailed documentation.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        AgentOS Host                          │
│                    (NixOS minimal + modules)                 │
│                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐        │
│  │ Agent A  │ │ Agent B  │ │ Agent C  │ │ Agent D  │        │
│  │ (ctr)    │ │ (ctr)    │ │ (ctr)    │ │ (ctr)    │        │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘        │
│       │            │            │            │               │
│  ┌────┴────────────┴────────────┴────────────┴────┐         │
│  │              AgentOS Daemon                      │         │
│  │    (lifecycle, scheduling, resource limits)     │         │
│  └────┬───────┬──────────┬──────────┬──────────────┘         │
│       │       │          │          │                         │
│  ┌────┴──┐ ┌─┴───┐ ┌────┴───┐ ┌────┴──────────┐              │
│  │Model  │ │MCP  │ │Budget  │ │Observability   │              │
│  │Gateway│ │Reg. │ │Ctrl.   │ │(OTel+Prom+Graf)│              │
│  └───────┘ └─────┘ └────────┘ └───────────────┘              │
│                                                              │
│  btrfs storage · Qdrant vectors · Redis queues · sops secrets│
└─────────────────────────────────────────────────────────────┘
```

## Project Structure

```
agentos/
├── flake.nix                    # Top-level Nix flake
├── modules/                     # NixOS modules (15 features)
│   ├── runtime/                 # Container runtime + agent daemon
│   ├── security/                # AppArmor, firewall, kernel hardening
│   ├── observability/           # Prometheus, Tempo, Grafana
│   ├── storage/                 # btrfs snapshots, dedup, GC
│   ├── networking/              # Agent bridge, model gateway
│   ├── context/                 # Qdrant vector DB, memory
│   ├── orchestration/           # Multi-agent coordination
│   ├── mcp-registry/            # MCP tool servers
│   ├── budget-controller/       # Cost tracking, auto-shutdown
│   ├── git-automation/          # Auto-branch/commit/PR
│   ├── provisioning/            # Env detection, Nix shells
│   ├── notifications/           # Slack/Discord/email/webhook
│   ├── circuit-breaker/         # Rate limiting, runaway detection
│   ├── secrets-manager/         # sops-nix encrypted secrets
│   └── scheduler/               # Cron-like task scheduling
├── agents/                      # 22 coding agent packages
├── nixos/
│   ├── hosts/                   # Host configs (bare metal + ISO)
│   └── packages/                # Internal Rust binaries
├── templates/                   # Agent workspace template
└── docs/                        # Documentation
```

## Configuration

Every feature is toggleable in the NixOS config:

```nix
agentos = {
  runtime.enable = true;
  context.enable = true;
  budget-controller.defaultDailyBudgetUSD = 50.0;
  circuit-breaker.maxConsecutiveFailures = 5;
  # ... etc
};
```

## License

MIT
