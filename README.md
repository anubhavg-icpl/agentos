<div align="center">

<img src="assets/hero.webp" alt="AgentOS — An OS for AI Coding Agents" width="100%">

<br/>

<h1>AgentOS</h1>

<p><strong>The operating system built for AI coding agents.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="License"></a>
  <a href="modules/"><img src="https://img.shields.io/badge/Modules-27-blue?style=flat-square" alt="Modules"></a>
  <a href="docs/AGENTS.md"><img src="https://img.shields.io/badge/Agents-15-green?style=flat-square" alt="Agents"></a>
  <a href="docs/FEATURES.md"><img src="https://img.shields.io/badge/MCP%20Servers-35-purple?style=flat-square" alt="MCP"></a>
  <a href="https://github.com/anubhavg-icpl/vibe"><img src="https://img.shields.io/badge/VIBE%20Skills-5340-orange?style=flat-square" alt="VIBE"></a>
  <a href="https://nixos.org"><img src="https://img.shields.io/badge/Platform-NixOS-7E2F8E?style=flat-square" alt="NixOS"></a>
</p>

<p>
  <a href="#getting-started"><b>Getting Started</b></a> ·
  <a href="#agents"><b>Agents</b></a> ·
  <a href="#features"><b>Features</b></a> ·
  <a href="#architecture"><b>Architecture</b></a> ·
  <a href="#documentation"><b>Docs</b></a> ·
  <a href="#contributing"><b>Contributing</b></a>
</p>

---

</div>

## Overview

AgentOS is a minimal, NixOS-based operating system where the primary users are **AI coding agents**, not humans. It ships with 15 coding agents pre-installed, 35 MCP tool servers configured, 20+ language toolchains, the VIBE skills library installed on first boot, and a hardened, observable base system.

> [!NOTE]
> **Status (v0.3.0).** The core loop works and is covered by an end-to-end VM test (`nix build .#checks.x86_64-linux.e2e`):
> 1. An agent runs sandboxed.
> 2. Every LLM call goes through a metering gateway.
> 3. The budget is enforced.
> 4. The agent is stopped when it runs out.
> 5. You get notified.
>
> Multi-agent orchestration, the scheduler and container isolation are still planned. [docs/STATUS.md](docs/STATUS.md) lists exactly what works and how it is tested.

<div align="center">
<table>
<tr>
<td align="center"><h3>15</h3><p>Coding Agents</p></td>
<td align="center"><h3>5,340</h3><p>VIBE Skills</p></td>
<td align="center"><h3>35</h3><p>MCP Servers</p></td>
<td align="center"><h3>27</h3><p>NixOS Modules</p></td>
<td align="center"><h3>20+</h3><p>Language Runtimes</p></td>
</tr>
</table>
</div>

---

## The Problem

Run an AI coding agent on a normal machine and you're giving it your shell, your filesystem, and your network with no fence around any of it. There's no spending cap, so a runaway agent can burn real money before anyone notices. Commits happen by hand or not at all. Tool access means installing things yourself, one MCP server at a time. And when something goes wrong, there's no trace of what the agent actually did.

AgentOS puts a fence around each of those problems, on a NixOS base that rebuilds identically every time:

- **Sandbox.** Each agent runs as an unprivileged user in its own systemd sandbox, with memory, CPU and process limits. It can write only to its workspace, and it has no sudo.
- **Metering gateway.** Every LLM call goes through a gateway that prices it, enforces per-agent and global daily budgets, rate-limits the agent, and stops it when it runs out.
- **Credentials.** API keys stay in the gateway; agents only ever see a placeholder.
- **Egress.** Outbound traffic is default-deny: only allowlisted domains resolve, and agents cannot reach model providers except through the gateway.
- **Audit trail.** Every session gets its own git branch, and btrfs snapshots let you roll a workspace back.
- **Tooling and monitoring.** 35 MCP servers come pre-wired, and per-agent spend flows into Prometheus and Grafana.

---

## Getting Started

**Prerequisites:** [Nix](https://nixos.org) with flakes enabled, on x86_64-linux.

```bash
# 1a. Build the installer ISO (also attached to each GitHub release) and write it to a USB stick
nix build .#iso-image
sudo dd if=result/iso/agentos-*.iso of=/dev/sdX bs=4M status=progress

# 1b. Boot it, then install (erases the disk). The installed system only
#     allows SSH key login for `admin`, so pass your public key:
sudo agentos-install /dev/nvme0n1 --ssh-key "ssh-ed25519 AAAA... you@host"

# 2. Or try it in a VM instead
nix build .#vm-image
cp result/*.qcow2 agentos.qcow2 && chmod u+w agentos.qcow2
qemu-system-x86_64 -m 8192 -enable-kvm -bios OVMF.fd -drive file=agentos.qcow2,if=virtio
#    (add your key to users.users.admin.openssh.authorizedKeys.keys first)

# 3. SSH in and give the gateway your API key (sops, see docs/FEATURES.md)
ssh admin@agentos

# 4. Run an agent in a sandbox with a $5/day budget
agentos workspace create api --from https://github.com/me/api.git
agentos spawn claude --workspace api --budget 5
agentos list            # agents, status, spend today
agentos logs <id>       # every model call with tokens and cost
agentos agents          # all 15 agents
```

<div align="center">
<img src="assets/boot-screen.webp" alt="AgentOS Boot Screen" width="88%">

<sub><i>AgentOS boots into a minimal terminal. SSH in and start coding.</i></sub>
</div>

---

## Agents

<div align="center">
<img src="assets/agents-grid.webp" alt="Pre-installed AI Coding Agents" width="92%">
</div>

<br/>

15 coding agents ship pre-installed, and each gets the same base tools (git, ripgrep, fd, gh). Eleven are built from nixpkgs and pinned by `flake.lock`. Four that nixpkgs doesn't package yet are pinned npm/PyPI launchers, which download the agent on first run.

| Command | Agent | Provider | Source |
|:---|:---|:---|:---|
| `claude` | Claude Code | Anthropic | nixpkgs |
| `codex` | Codex CLI | OpenAI | nixpkgs |
| `aider` | Aider | Open Source | nixpkgs |
| `gemini` | Gemini CLI | Google | nixpkgs |
| `qwen` | Qwen Code | Alibaba | nixpkgs |
| `amp` | Amp | Sourcegraph | nixpkgs |
| `goose` | Goose | Block | nixpkgs |
| `opencode` | OpenCode | SST | nixpkgs |
| `crush` | Crush | Charm | nixpkgs |
| `cursor-agent` | Cursor CLI | Cursor | nixpkgs |
| `copilot` | GitHub Copilot CLI | GitHub | nixpkgs |
| `droid` | Factory Droid | Factory AI | npm launcher |
| `cline` | Cline | Open Source | npm launcher |
| `cn` | Continue CLI | Open Source | npm launcher |
| `interpreter` | Open Interpreter | Open Source | PyPI launcher |

<details>
<summary><b>Run agents (click to expand)</b></summary>

```bash
# Sandboxed and metered (as agentos-agent, through the gateway)
agentos spawn claude --workspace api --budget 5
agentos spawn aider --workspace api -- --model sonnet   # args after -- go to the agent
agentos kill <id>

# Direct, as yourself (no sandbox, no metering)
claude
codex "fix the bug"
```

</details>

Full reference: [docs/AGENTS.md](docs/AGENTS.md)

---

## Features

<div align="center">
<table>
<tr>
<td valign="top" width="33%">

**Infrastructure**
- Container runtime (containerd)
- btrfs snapshots + dedup
- Metering model gateway
- AppArmor + egress allowlist
- Prometheus + Tempo + Grafana

</td>
<td valign="top" width="33%">

**Agent Intelligence**
- Vector memory (Qdrant)
- Multi-agent orchestration †
- 35 MCP tool servers
- VIBE: 5,340 skills
- Cron task scheduler †

</td>
<td valign="top" width="33%">

**Safety & Control**
- Budget caps + auto-shutdown
- Rate limit + circuit breaker
- sops-nix secrets
- Git helpers
- Slack/Discord/webhook alerts

</td>
</tr>
</table>

<sub>† Planned: configured, but the service isn't built yet. See <a href="docs/STATUS.md">docs/STATUS.md</a>.</sub>
</div>

### Budget Control & Safety

<div align="center">
<img src="assets/security-shield.webp" alt="Budget Controller and Security Shield" width="92%">
</div>

<br/>

| Safety Feature | What It Does |
|:---|:---|
| **Budget caps** | Per-agent daily/session spending limits (default: $50/day) |
| **Auto-shutdown** | Agents that exceed budget are killed automatically |
| **Rate limiting** | Max LLM calls per agent per minute |
| **Circuit breaker** | N consecutive upstream failures pause the agent for a cooldown |
| **Resource limits** | Memory, CPU and process limits per agent sandbox |
| **Egress firewall** | Default-deny network; only whitelisted domains allowed |

Budgets are enforced in the model gateway, and the gateway meters every sandboxed agent's calls. The firewall doesn't let the agent user reach model providers any other way. A request over budget gets HTTP 402 before it reaches the provider, and the agent daemon then stops the agent's unit. Loop detection is still planned.

```bash
agentos-budget status       # spend per agent today, limits, requests
agentos-budget set <id> 25  # daily budget for one agent
agentos-budget history      # 7-day cost breakdown
agentos-breaker reset <id>  # close an open circuit
```

### Multi-Agent Orchestration (planned)

<div align="center">
<img src="assets/swarm.webp" alt="Multi-Agent Collaboration" width="92%">

<sub><i>Planned: agents collaborate through planner-worker, swarm, and pipeline modes (needs the orchestrator daemon).</i></sub>
</div>

<br/>

### Observability Dashboard

<div align="center">
<img src="assets/dashboard.webp" alt="AgentOS Monitoring Dashboard" width="92%">

<sub><i>Grafana on localhost:2342 (<code>ssh -L 2342:localhost:2342 admin@agentos</code>). Agent-level metrics arrive with the daemon.</i></sub>
</div>

---

## VIBE Integration

<div align="center">
<img src="assets/vibe-integration.webp" alt="VIBE Library Integration" width="92%">
</div>

<br/>

On first boot, AgentOS installs the [VIBE library](https://github.com/anubhavg-icpl/vibe) into the supported agent CLIs. It is fetched from GitHub with `npx` at that point; pin `agentos.vibe-integration.repoUrl` to a tag for repeatable installs.

| VIBE Asset | Count |
|:---|:---|
| Expert modes | **853** (52 categories) |
| Skills | **5,340** |
| Subagents | **200** |
| Slash commands | **112** |
| Plugins | **120** |
| Rules | **111** |
| System prompts | **759** |
| Recipes | **18** |

```bash
agentos-vibe install       # Install into all agents
agentos-vibe categories    # Browse 52 categories
vibe search "rag"          # Search the library
```

---

## MCP Server Registry

<div align="center">
<img src="assets/mcp-network.webp" alt="MCP Servers" width="92%">
</div>

<br/>

35 Model Context Protocol servers, pre-configured across 8 categories. Each one points at a real npm (`npx -y`) or PyPI (`uvx`) package and is downloaded the first time it starts.

| Category | Count | Servers |
|:---|:---:|:---|
| **Core** | 7 | filesystem, git, memory, fetch, sequential-thinking, time, everything |
| **Database** | 7 | postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse |
| **Cloud** (opt-in) | 4 | aws, azure, cloudflare, supabase |
| **Integration** | 7 | github, gitlab, linear, slack, notion, sentry, pagerduty |
| **Browser** | 3 | puppeteer, playwright, browserbase |
| **AI/ML** | 1 | huggingface |
| **DevOps** | 2 | docker, kubernetes |
| **Data/Search** | 4 | brave-search, tavily, exa, perplexity |

```bash
agentos-mcp list            # List all servers
agentos-mcp enable puppeteer # Enable a server
agentos-mcp stats           # Registry statistics
```

---

## Architecture

<div align="center">
<img src="assets/architecture.webp" alt="AgentOS Architecture" width="95%">
</div>

<br/>

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
│  │Gateway │ │ 35 srv │ │ Ctrl.  │ │ (OTel+P+Graf) │                │
│  └────────┘ └────────┘ └────────┘ └───────────────┘                │
│                                                                      │
│  VIBE: 5340 skills · 853 modes · 200 agents · 759 system prompts   │
│  20+ languages · 6 databases · btrfs snapshots · Qdrant · sops      │
└─────────────────────────────────────────────────────────────────────┘
```

The daemon, model gateway, budget and circuit-breaker boxes are implemented (`services/`). Agents run in systemd sandboxes rather than containers, and the orchestrator is still planned.

---

## Full Feature Matrix

<details>
<summary><b>All 27 modules (click to expand)</b></summary>

| Module | Description | CLI Command |
|:---|:---|:---|
| runtime | Agent sandbox, daemon, workspaces, control-plane Redis | `agentos spawn` |
| security | AppArmor, default-deny egress allowlist, auditd | automatic |
| observability | Prometheus + Tempo + Grafana | Grafana `:2342` |
| storage | btrfs snapshots, dedup, workspace GC | `agentos snapshot` |
| networking | Metering model gateway, agent bridge, NAT | automatic |
| context | Qdrant vector DB, persistent memory | `agentos-memory` |
| orchestration | Multi-agent coordination † | `agentos-orchestrate` |
| mcp-registry | 14 core MCP tools | `agentos-tools` |
| mcp-servers | 35 MCP servers (8 categories) | `agentos-mcp` |
| budget-controller | Per-agent and global daily caps, auto-shutdown | `agentos-budget` |
| circuit-breaker | Rate limit, circuit breaker, resource limits | `agentos-breaker` |
| secrets-manager | sops-nix encrypted API keys | `agentos-secrets` |
| git-automation | Branch/commit/PR helpers, hooks (auto-commit †) | `agentos-git` |
| provisioning | Env detection, Nix dev shells | `agentos-env` |
| scheduler | Cron-like task scheduling † | `agentos-schedule` |
| notifications | Slack, Discord, webhook | `agentos-notify` |
| language-toolchains | 20+ runtimes pre-installed | `agentos-langs` |
| databases | Postgres, Redis, SQLite, DuckDB | `agentos-db` |
| dev-tools | 100+ developer utilities | automatic |
| security-tools | Semgrep, trivy, nmap, ghidra | `agentos-scan` |
| browser-tools | Chromium, Playwright, Puppeteer | `agentos-web` |
| networking-tools | nmap, tcpdump, wireshark | automatic |
| cloud-tools | AWS, GCP, Azure, CF, Vercel CLIs | automatic |
| package-managers | pip, npm, cargo, bundler, maven | automatic |
| editors | Neovim (LSP configured), Helix | automatic |
| ai-ml | Ollama, llama.cpp, PyTorch, Jupyter | automatic |
| vibe-integration | 853 modes, 5340 skills from VIBE | `agentos-vibe` |

† Planned service, not implemented yet ([status](docs/STATUS.md)).

</details>

Detailed docs: [docs/FEATURES.md](docs/FEATURES.md)

---

## Configuration

Every feature is a toggle:

```nix
agentos = {
  runtime = {
    enable = true;
    maxAgents = 8;
    containerRuntime = "containerd";
  };

  budget-controller = {
    enable = true;
    defaultDailyBudgetUSD = 50.0;
    globalDailyBudgetUSD = 500.0;
    autoShutdown = true;
  };

  circuit-breaker = {
    enable = true;
    maxConsecutiveFailures = 5;
    cooldownPeriodSec = 300;
  };

  vibe-integration = {
    enable = true;
    autoInstallOnBoot = true;
  };

  mcp-servers = {
    enable = true;
    enableCore = true;
    enableDatabases = true;
    enableBrowser = true;
    enableAI = true;
  };

  git-automation = {
    enable = true;
    autoBranch = true;
    autoCommit = true;
    autoPR = true;
  };
};
```

---

## Comparison

Most of what AgentOS is building toward (budget caps, circuit breakers, MCP servers, snapshots, vector memory, orchestration) doesn't exist on plain Linux at all; you'd build it yourself. Docker gets you isolation and not much else. The pieces that do exist elsewhere (Prometheus/Grafana, encrypted secrets, language runtimes) are manual setup on both; AgentOS ships them wired in. The one Docker gets partial credit for is reproducibility — a Dockerfile is repeatable, but not bit-for-bit the way a NixOS derivation is.

---

## Project Structure

```
agentos/
├── flake.nix                       # Top-level Nix flake
├── modules/                        # 27 NixOS modules
│   ├── runtime/                    #   Containerd isolation + daemon
│   ├── budget-controller/          #   Cost tracking + auto-shutdown
│   ├── circuit-breaker/            #   Rate limiting + loop detection
│   ├── mcp-servers/                #   35 preconfigured MCP servers
│   ├── vibe-integration/           #   5340 skills auto-installer
│   ├── context/                    #   Qdrant vector memory
│   ├── orchestration/              #   Multi-agent coordination
│   ├── git-automation/             #   Branch/commit/PR helpers
│   ├── language-toolchains/        #   20+ language runtimes
│   ├── databases/                  #   Postgres, Redis, SQLite, DuckDB
│   └── ...                         #   17 more modules
├── agents/                         # 15 coding agent packages
├── nixos/
│   ├── hosts/                      # Host configs (bare metal + ISO)
│   └── packages/                   # CLI, installer, daemon stubs
├── templates/                      # Agent workspace template
├── assets/                         # WebP images
└── docs/                           # Documentation
```

---

## Documentation

| Document | Description |
|:---|:---|
| [docs/STATUS.md](docs/STATUS.md) | What works today and what is still planned |
| [docs/AGENTS.md](docs/AGENTS.md) | All 15 agents with usage examples and API key setup |
| [docs/FEATURES.md](docs/FEATURES.md) | Detailed documentation of all 27 modules |
| [docs/ISO-SIZE.md](docs/ISO-SIZE.md) | ISO size analysis by configuration |
| [CHANGELOG.md](CHANGELOG.md) | Version history and release notes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute: add modules, agents, and more |

---

## Roadmap

- [x] Agent sandbox, daemon, `agentos list/logs/kill` (v0.3.0)
- [x] Metering model gateway with budget caps and auto-shutdown (v0.3.0)
- [x] Rate limit, circuit breaker, notifications (v0.3.0)
- [ ] Container isolation per agent
- [ ] Orchestrator and scheduler
- [ ] Loop detection in the gateway
- [ ] GPU scheduling for local model inference
- [ ] Remote agent fleets (multi-machine orchestration)
- [ ] Agent marketplace (community-contributed agents)
- [ ] Web dashboard (beyond Grafana)
- [ ] Full OS images for ARM64 (agent packages already build there)
- [ ] Deterministic replay of agent sessions
- [ ] Inter-agent communication protocol
- [ ] Cost optimization (auto-route to cheapest model)

---

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for:

- How to add a new module
- How to add a new agent
- Commit conventions
- Testing guidelines

```bash
git clone https://github.com/anubhavg-icpl/agentos.git
cd agentos
nix develop                                   # Enter dev shell
nix flake check --no-build --all-systems      # Evaluate everything
nix build .#services                          # Service unit tests
nix build .#checks.x86_64-linux.e2e           # End-to-end VM test (needs KVM for speed)
```

---

<div align="center">

<img src="assets/social-preview.webp" alt="AgentOS" width="50%">

<br/>

## License

**MIT** — See [LICENSE](LICENSE)

## Author

**Anubhav Gain**
[GitHub](https://github.com/anubhavg-icpl) · [VIBE Library](https://github.com/anubhavg-icpl/vibe)

<br/>

---

If AgentOS is useful to you, consider ⭐ starring the repository.

</div>
