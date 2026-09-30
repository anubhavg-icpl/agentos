# Project Status

AgentOS is an early-stage project. The NixOS base, the agent packages and
most of the tooling modules work. The service layer the README describes
(agent daemon, gateways, budget enforcement, orchestration) is designed and
configured but **not implemented yet**. This page says which is which.

Last reviewed: 2026-09-30.

## What builds

| Output | State |
|:---|:---|
| `nixosConfigurations.agentos` | Evaluates. Builds from cache.nixos.org plus a few local wrapper derivations. |
| `nixosConfigurations.agentos-iso` / `packages.x86_64-linux.iso-image` | Evaluates. |
| `packages.x86_64-linux.vm-image` | Evaluates (qcow2, ext4 root, GRUB). |
| `packages.*.<agent>` | 12 agents from nixpkgs, 3 pinned npm launchers. |
| `packages.*.cli`, `installer` | Build; installer passes shellcheck. |
| `nix flake check --no-build` | Passes on x86_64-linux and aarch64-linux. |

Full OS builds are x86_64-only because several pre-installed toolchains are
x86_64-only. Agent packages are also exposed for aarch64-linux.

## Feature status

**Working** means the NixOS configuration sets it up and it runs.
**Config only** means options, config files and CLIs exist, but the service
that would act on them doesn't. **Not implemented** means nothing does it.

| Feature | Status | Notes |
|:---|:---|:---|
| 15 pre-installed agents | Working | See [AGENTS.md](AGENTS.md). |
| `agentos spawn` | Partial | Creates an `agent/*` branch and execs the agent. No container, no tracking. |
| `agentos list` / `logs` / `kill` / `shell` | Not implemented | Read state files that only the daemon would write. |
| Per-agent containers | Not implemented | containerd is installed and enabled, but nothing creates containers. |
| Egress allowlist | Working, host-wide | dnsmasq only resolves allowed domains and adds their IPs to an ipset; iptables rejects other outbound traffic. Applies to the whole host, not per agent. |
| AppArmor, auditd, kernel hardening | Working | |
| btrfs layout, snapshots, dedup | Working | disko layout with a `@workspaces` subvolume; btrbk snapshots it hourly. |
| `agentos snapshot` / `rollback` | Partial | Snapshot works as root; rollback is not implemented. |
| OTel collector, Prometheus, Tempo, Grafana | Working | Grafana listens on localhost:2342 (SSH tunnel). Nothing emits agent traces yet. |
| Qdrant, Postgres, Redis, DuckDB, SQLite | Working | Bound to localhost (Redis and Qdrant have no auth). |
| Language toolchains, dev/security/browser/cloud tools, editors, AI/ML | Working | Plain nixpkgs packages. |
| MCP server registry (`agentos-mcp`) | Working | 35 servers, each pointing at a real npm/PyPI package. They're fetched on first start, not pre-installed. |
| MCP gateway / MCP registry service | Not implemented | Daemon. |
| Model gateway (budget/rate-limit proxy) | Not implemented | Daemon. |
| Budget caps and auto-shutdown | Not implemented | `agentos-budget` reads Redis keys that no component writes. |
| Circuit breaker, resource monitor, loop detection | Not implemented | Needs the daemon and agent cgroups; gated with the daemons. |
| Multi-agent orchestration | Not implemented | Daemon. |
| Scheduler, notifications | Not implemented | Daemons. |
| Git automation | Partial | `agentos-git` wraps git/`gh pr create` and installs hooks. `autoCommit` / `autoPR` are not acted on. |
| Secrets (sops-nix) | Working after setup | Create the encrypted file, then set `agentos.secrets-manager.sopsInitialized = true`. |
| VIBE integration | Working, network-dependent | First boot runs `npx -y github:anubhavg-icpl/vibe` for each agent. Pin `repoUrl` to a tag. |

## The daemons

These packages in `nixos/packages/` are build stubs with no source code:
`daemon`, `mcp-gateway`, `model-gateway`, `budget-controller`,
`circuit-breaker`, `orchestrator`, `scheduler`, `notifier`, `provisioner`,
`memory-manager`, `mcp-registry`. Their systemd units are gated behind:

```nix
agentos.daemons.enable = false;  # default
```

Turning it on before the daemons exist makes the system fail to build.
Implementing them is the main piece of work between this repository and the
feature set in the README.

## Known limitations

- The egress allowlist is host-wide. Agents run as `admin` in the same
  network namespace as everything else. Per-agent policy needs the
  container runtime.
- The npm launchers, MCP servers and VIBE fetch code from npm / GitHub at
  runtime, which is outside Nix's reproducibility guarantees.
- Several `@modelcontextprotocol/*` servers in the registry are archived
  upstream. They still install but no longer get fixes.
- Notification webhook URLs set through module options end up in the
  world-readable Nix store. Deliver them through sops instead.
