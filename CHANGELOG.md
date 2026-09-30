# Changelog

All notable changes to AgentOS are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Fixed
- The flake now evaluates. `nixosConfigurations.agentos`, the ISO, the VM image and `nix flake check` all pass. Previously five modules had syntax errors and many options and packages didn't exist in nixpkgs 24.11.
- Agents are built from nixpkgs instead of wrappers that ran `npx`, `go run …@latest` or `curl | bash` on every invocation, or used placeholder source hashes.
- Egress allowlist: dnsmasq resolved every allowed domain to 1.1.1.1. It now forwards only allowed domains, fills an ipset, and iptables rejects everything else, in its own chain.
- Security: removed the live ISO's fixed `agentos` password, the hardcoded Grafana password, public firewall openings for Redis, Qdrant, nix-serve and the model gateway, and git's `safe.directory = *`.
- OTel collector and Tempo both bound :4317; Tempo retention was hours instead of days.
- disko layout, which conflicted with `hardware.nix` and used nonexistent options; added a `@workspaces` subvolume for btrbk.
- Installer uses `disko-install`, supports NVMe disks, and installs an SSH key for `admin`.
- `agentos spawn` argument parsing; `agentos workspace rm` path traversal.
- MCP registry: 21 entries pointed at npm packages that don't exist. They are fixed where a real package exists and removed otherwise. `agentos-mcp` / `agentos-tools` jq and write-to-/etc bugs.
- sops secrets no longer break activation before the secrets file exists, and `agentos-secrets set` no longer writes plaintext.

### Changed
- 15 agents instead of 22. Devin, Roo Code, SWE-Agent, GPT-Engineer, Devika, AutoGPT and smol-developer had no buildable package.
- The service daemons have no source yet. Their units are gated behind `agentos.daemons.enable` (default off).
- Docs describe what is implemented; see docs/STATUS.md.

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
