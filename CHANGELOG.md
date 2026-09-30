# Changelog

All notable changes to AgentOS are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [0.3.0] - 2026-09-30

The first release where the agent service layer works end to end: sandboxed
agents, a metering model gateway, budget enforcement with auto-shutdown and
notifications. All of it is covered by a NixOS VM test (`checks.x86_64-linux.e2e`).

### Added
- **Model gateway** (`agentos-model-gateway`, `services/`), an HTTP proxy between agents and LLM providers.
  - Attributes every request to the agent that made it.
  - Reads token usage from Anthropic and OpenAI responses, JSON and streaming (SSE), and prices it with `pricing.json`.
  - Enforces per-agent and global daily budgets (HTTP 402), a per-agent rate limit (429) and a circuit breaker (503).
  - Injects the provider API key, so agents only ever see a placeholder.
- **Agent daemon** (`agentos-daemon`).
  - Keeps the agent registry.
  - Stops agents that exceed their budget.
  - Sends Slack/Discord/webhook notifications.
  - Exports per-agent Prometheus metrics on 127.0.0.1:9950.
- **Sandboxed `agentos spawn`.** Agents run as the unprivileged `agentos-agent` user in a transient systemd unit.
  - Memory, CPU and process limits; a read-only system and private /tmp.
  - Writes allowed only to the workspace; no sudo.
  - Workspaces are shared with operators through group ACLs.
- **`agentos list`, `logs`, `kill`, `shell`, `status`, `rollback`** now work.
- **Gateway-only provider access.** The agent user cannot reach provider APIs, other DNS servers, or IPv6 except through the gateway, so budgets cannot be bypassed.
- **Control-plane isolation.** Redis is reachable only over a unix socket, and budget changes go through an admin socket limited to operators.
- **End-to-end VM test** (`checks.x86_64-linux.e2e`) and 36 service unit tests.
- **CI and release workflows** (`ci/github-workflows/`, to be moved into `.github/workflows/`). The release workflow attaches the installer ISO.
- **Pricing** for current Claude models (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 4.5 and earlier), including cache reads and writes.
- **`flake.lock`** pinning all inputs.

### Changed
- **nixpkgs 24.11 → 26.05.** 24.11 has been end-of-life since mid-2025.
- **nixos-generators removed.** The VM image uses nixpkgs' own disk-image module.
- **15 agents instead of 22.** Devin, Roo Code, SWE-Agent, GPT-Engineer, Devika, AutoGPT and smol-developer had no buildable package. Open Interpreter is now a pinned PyPI launcher, because nixpkgs marks it broken.
- **Planned services gated.** Orchestrator, scheduler, MCP gateway/registry service, provisioner and memory manager are behind `agentos.plannedServices.enable`, together with their CLIs.
- **Notifications** read webhook URLs from files (secrets), not from the Nix store. Email support was removed.
- **Ollama** no longer downloads models at boot (`agentos.ai-ml.ollamaModels`).
- **Circuit breaker** no longer sets system-wide `DefaultTasksMax=256` / `DefaultLimitNOFILE=4096`.
- **Redis split in two:** the control plane (socket-only) and a separate `redis-dev` for agents' projects.

### Fixed
- **The flake now evaluates.** Five modules had syntax errors, and many options and packages didn't exist.
- **Agent packages** no longer run `npx`, `go run …@latest` or `curl | bash` on every invocation, and no longer use placeholder source hashes.
- **Egress allowlist.** dnsmasq resolved every allowed domain to 1.1.1.1, which broke the very APIs it was meant to allow.
- **Security:**
  - removed the live ISO's fixed password with SSH password login;
  - removed the hardcoded Grafana password (Grafana is now localhost-only, with a generated secret key);
  - closed public firewall openings for Redis, Qdrant, nix-serve and the model gateway;
  - narrowed git's `safe.directory = *`;
  - `agentos-secrets set` no longer writes plaintext.
- **Observability:** the OTel collector and Tempo both bound :4317, and Tempo retention was set in hours instead of days.
- **Disk layout:** the disko layout conflicted with `hardware.nix`.
- **Installer:** it now works on NVMe drives and installs an SSH key for `admin`, who could not log in before.
- **CLI:** fixed `agentos spawn` argument parsing and path traversal in `agentos workspace rm`.
- **MCP registry:** 21 entries pointed at npm packages that don't exist. Also fixed jq and write-to-/etc bugs in `agentos-mcp` / `agentos-tools`.
- **sops secrets** no longer break activation before the secrets file exists.

## [0.2.0] - 2026-08-05

### Added
- **VIBE integration**: 853 modes, 5340 skills, 200 agents, 112 commands, 120 plugins, 111 rules, 759 system prompts from anubhavg-icpl/vibe. Auto-installs into all 7 agent CLIs on first boot.
- **MCP server registry**: 50+ preconfigured MCP servers across 8 categories (core, database, cloud, integration, browser, AI/ML, DevOps, data/search).
- **Language toolchains**: 20+ programming language runtimes pre-installed (Python, Node, Go, Rust, C/C++, Java, Kotlin, Scala, Ruby, PHP, Haskell, Elixir, OCaml, Zig, Lua, R, Julia, Swift, Dart, Clojure, Perl, Nim, Nix).
- **Database services**: PostgreSQL 16, Redis, SQLite, DuckDB with auto-created databases.
- **Developer tools**: 100+ utilities (eza, bat, fd, ripgrep, neovim, helix, tmux, kubectl, terraform, ansible, bazel, lazygit, fzf, etc.).
- **Security tools**: semgrep, trivy, osv-scanner, gitleaks, nmap, radare2, ghidra, etc.
- **Browser tools**: Chromium, Playwright, Puppeteer, pandoc, ffmpeg, yt-dlp.
- **AI/ML tools**: Ollama, llama.cpp, Whisper, PyTorch, Transformers, Jupyter.
- **Editors module**: Neovim with LSP/treesitter/telescope pre-configured, Helix.
- **Cloud tools**: AWS CLI, gcloud, az, cloudflared, vercel, flyctl, doctl.
- **Networking tools**: nmap, tcpdump, wireshark, dig, mtr, mitmproxy.
- **Package managers**: pip, npm, cargo, go, bundler, composer, maven, conan, vcpkg.
- ISO size analysis document.

### Changed
- `modules/default.nix` now imports 27 modules (was 15).
- Host config enables all new modules by default.
- Updated FEATURES.md with VIBE and MCP documentation.

## [0.1.0] - 2026-08-04

### Added
- Initial AgentOS release.
- **22 pre-installed coding agents**: Claude Code, Codex, Factory Droid, Aider, Gemini CLI, Qwen Code, Amp, Goose, OpenCode, Crush, Cursor CLI, Cline, Continue, GitHub Copilot, Devin, Roo Code, Open Interpreter, SWE-Agent, GPT-Engineer, Devika, AutoGPT, smol-developer.
- **Core modules (5)**: Container runtime (containerd), Security (AppArmor + egress firewall), Observability (Prometheus + Tempo + Grafana), Storage (btrfs snapshots + dedup), Networking (model API gateway).
- **Agent intelligence (2)**: Context & memory (Qdrant vector DB), Multi-agent orchestration (planner-worker, swarm, pipeline).
- **Safety (3)**: Budget controller (per-agent cost caps), Circuit breaker (rate limiting + runaway detection), Secrets manager (sops-nix).
- **Developer experience (2)**: Git automation (auto-branch/commit/PR), Environment provisioning (Nix dev shells).
- **Automation (2)**: Scheduler (cron tasks), Notifications (Slack/Discord/email/webhook).
- **MCP tool registry (1)**: 15+ MCP tools (filesystem, git, github, sqlite, fetch, memory, etc.).
- NixOS flake with ISO and VM image outputs.
- Live ISO with `agentos-install` command.
- Agent workspace template.
- `agentos` CLI with spawn, list, kill, budget, workspace management.
- Documentation: README, AGENTS.md, FEATURES.md.
