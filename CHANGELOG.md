# Changelog

All notable changes to AgentOS are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

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
