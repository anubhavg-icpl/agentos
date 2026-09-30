# Project Status

What works in AgentOS today, how it is tested, and what is still planned.

Last reviewed: 2026-09-30 (v0.3.0).

## How it is tested

| Test | Command | Covers |
|:---|:---|:---|
| Evaluation of every output | `nix flake check --no-build --all-systems` | Host, VM image, ISO, packages, checks on x86_64 and aarch64 |
| Service unit tests (36) | `nix build .#services` | Gateway proxying (JSON + SSE), key injection, pricing, budgets, alerts, rate limit, circuit breaker, admin socket; daemon reaping, auto-shutdown, notifications, metrics |
| End-to-end VM test | `nix build .#checks.x86_64-linux.e2e` | Boots a VM and drives a real agent run: spawn → sandbox → gateway → priced spend → budget exceeded → daemon stops the agent → webhook; plus sandbox, control-plane isolation and egress checks |
| Shell linting | `nix build .#cli .#installer` | `agentos` and `agentos-install` pass shellcheck |

The GitHub Actions workflow in `ci/github-workflows/ci.yml` runs all of these on every push and pull request once it is moved into `.github/workflows/` (see the README there).

## Feature status

| Feature | Status | Notes |
|:---|:---|:---|
| 15 pre-installed agents | Working | 11 from nixpkgs, 3 pinned npm launchers, 1 pinned PyPI launcher. See [AGENTS.md](AGENTS.md). |
| `agentos spawn` sandbox | Working | Transient systemd unit as `agentos-agent`: read-only system, private /tmp, hidden homes, memory/CPU/process limits, workspace-only writes. |
| Agent registry: `list`, `logs`, `kill`, `shell`, `status` | Working | |
| Model gateway | Working | Anthropic Messages, OpenAI Chat Completions and Responses; JSON and streaming. |
| Budgets and auto-shutdown | Working | Per-agent and global daily caps; 402 before the provider is called; the daemon stops the agent. |
| Rate limit, circuit breaker | Working | Per agent, in the gateway. |
| Key injection | Working | Agents see `agentos-managed`; the real key stays in a file readable by the gateway. |
| Notifications | Working | Slack, Discord, generic webhook; URLs read from secret files. |
| Egress allowlist | Working | Host-wide; the agent user additionally cannot reach provider APIs except via the gateway. |
| Metrics | Working | Daemon exports per-agent spend, tokens and requests; Prometheus scrapes it. |
| AppArmor, auditd, kernel hardening | Working | |
| btrfs layout, snapshots, rollback | Working | disko layout with a `@workspaces` subvolume; btrbk hourly snapshots; `agentos rollback <snapshot> <workspace>`. |
| OTel collector, Prometheus, Tempo, Grafana | Working | Grafana on localhost:2342. Agents don't emit traces yet. |
| Qdrant, Postgres, dev Redis, DuckDB, SQLite | Working | Bound to localhost. |
| Toolchains, dev/security/browser/cloud tools, editors, AI/ML | Working | nixpkgs packages. |
| MCP server registry (`agentos-mcp`) | Working | 35 servers pointing at real npm/PyPI packages, fetched on first start. |
| Secrets (sops-nix) | Working after setup | Create the encrypted file, then set `agentos.secrets-manager.sopsInitialized = true`. |
| VIBE integration | Working, network-dependent | First boot runs `npx github:anubhavg-icpl/vibe`; pin `repoUrl` to a tag. |
| Git automation | Partial | Branch per agent session and hooks work; `autoCommit` / `autoPR` are not acted on. |
| Container isolation | Planned | Agents run in systemd sandboxes, not containers. containerd is installed for agents' own use. |
| Orchestrator, scheduler, MCP gateway, MCP registry service, provisioner, memory manager | Planned | Units and CLIs are gated behind `agentos.plannedServices.enable` (off); enabling it fails the build until they exist. |

## Known limitations

- **Unsandboxed runs are unmetered.** `agentos spawn --unsandboxed`, or running an agent binary directly, runs as the operator. Those runs have no resource limits and can reach providers without going through the gateway.
- **Subscription logins.** An agent logged in with a subscription (e.g. Claude Code with a Claude account) still goes through the gateway when sandboxed. Its usage is priced at API rates for budgeting.
- **Egress allowlist is host-wide** and IPv4 only (AAAA records are filtered).
- **The npm/PyPI launchers, MCP servers and VIBE fetch code at runtime**, outside Nix's reproducibility guarantees.
- **Several `@modelcontextprotocol/*` servers are archived upstream.** They still install but get no fixes.
- **Kill latency.** The gateway refuses requests the moment the budget is exceeded. The daemon stops the agent's unit a few seconds later.
