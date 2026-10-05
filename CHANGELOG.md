# Changelog

All notable changes to AgentOS are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- **Software factory** (`agentos.factory`, `agentos-factory`, docs/factory.md): lines that take work items (GitHub issues through `agentos.triggers` rules with `factory = "<line>"`, generated from `intake.github`, or the CLI) through planner, builder, verify, reviewer, fix loop and QA against acceptance criteria to a pull request, or to auto-merge in `dark` mode (refused unless the repository sets `allowAutoMerge`, there is a verify command and a QA role, and a plan approval or `enforceScope` bounds the change). Per-role agent, model, budget and timeout; per-item budget, fix rounds, in-flight and open-PR limits. Prometheus metrics, alerts `AgentOSFactoryBlocked`, `AgentOSFactoryStuck`, `AgentOSFactoryBudgetBurn` with runbooks, VM test `factory`.
- **Community skill collections** (`agentos.skills.collections`, `agentos.skills.enableAll`, docs/skills.md): 22 new opt-in skill packs built from pinned upstream repositories, with skills discovered from the source (`discover.nix`) instead of listed by hand: `superpowers`, `anthropic-skills`, `mattpocock-skills`, `gstack`, `ui-ux-pro-max`, `impeccable`, `taste-skill`, `open-design`, `caveman`, `ponytail`, `pstack`, `cursor-plugins`, `no-ai-slop`, `vibe-security`, `unlazy`, `hyperframes`, `agent-reach`, `ai-job-search`, `composio-awesome-claude-skills`, `composio-automation` (806 app-automation skills that need a Composio account), `everything-claude-code` (274), `scientific-skills` (171). Only skills whose licence allows redistribution are included (Anthropic's docx, pdf, pptx and xlsx, GSAP and Pixabay assets, non-commercial and unknown-licence scientific skills and skills that fail the Agent Skills spec are left out; the reasons are in docs/skills.md and each pack's header). `mkSkillPack` takes `collections` (tags such as `community`, `design`, `security`, `dev-workflow`); `agentos.skills.collections` enables every pack in the listed collections and `enableAll` every pack, both at `mkDefault` priority so `packs.<name>.enable` still wins; evaluation warns when more than 300 skills are enabled (about 100 tokens of context each). All packs together are collision-free (clashing names are prefixed with the pack name; `nixos/packages/skills/collisions.py` checks this). `agentos-skills list --collections` and `--all`. Pack builds copy the upstream LICENSE and NOTICE files to `share/doc/agentos-skills/<pack>`, take the skill list from a file (packs with hundreds of skills no longer overflow the builder environment) and validate all skills of a pack in one process. `skills-eval` also rejects skills that ship an "All rights reserved" LICENSE.
- **herdr** (`agentos.herdr`, `agentos-herdr`, `agentos-herdr-plugins`, docs/herdr.md): [herdr](https://herdr.dev) (nixpkgs-unstable's package, `packages.<system>.herdr`) with a sandboxed headless server for the agent user that rebuilds do not restart, a management bridge (`agentos-herdr status`, per-user loopback Prometheus metrics `agentos_herdr_up|panes|agents{user,state}` scraped by `agentos.observability`, a notification through `agentos.notifications` when an agent stays blocked), and the AgentOS herdr plugin (`integrations/herdr-plugin`: orchestrator tasks, factory items, budgets, approve and cancel for gated tasks). Plugins: declarative `agentos.herdr.plugins` (pinned `source`/`ref`, per-user idempotent oneshot that uninstalls only what it installed), `localPlugins`, and `agentos-herdr-plugins` for the marketplace (`catalog`, `show` with every command a plugin runs, `install` pinned to a commit, `install-all`, `update` with the manifest diff, `list`, `remove`). `marketplace.installAll` (off by default; evaluation warning for the agent user) installs every marketplace plugin daily: unreviewed third-party code that herdr does not sandbox. Skill pack `herdr`. Optional `integrations` install herdr's agent hooks. VM test `herdr` and 56 unit tests with a fake GitHub API and a fake herdr.
- **Agent skill packs** (`agentos.skills`, `agentos-skills`, docs/skills.md): skill packs built from pinned upstream repositories (`mkSkillPack`, `packages.<system>.skills-<pack>`) are linked into the user-level skills directory of Claude Code, Codex, OpenCode, Gemini CLI, Copilot CLI, Cursor, Factory Droid, Amp, Goose, Qwen Code, Crush and the cross-agent `~/.agents/skills`, for the agent user and further users. Per-pack and per-target options; a skill name used by two packs fails the build; a per-user unit manages only its own links, leaves skills the user wrote alone and removes stale links. Pack tools go into `systemPackages` and pack MCP servers into the MCP registry. Packs: `reticle` (19 skills; the `reticle` CLI and MCP server built from source, driving the system Chromium, telemetry off; FSL-1.1 server, enterprise code removed), `ouroboros` (23 skills as `ouroboros-*`, the `ooo` CLI and MCP server, telemetry off), `caliper` (the `caliper` skill evaluator), `anti-slop` (the `anti-slop` command: oxlint with the plugin, offline), `chisle` (opt-in; its Claude Code hooks go into a managed-settings drop-in), `ui-skills` (with the `ui-skills` CLI and its hosted MCP server), `img2threejs`, `fwc-swiftui-skills`, `karpathy-guidelines` and `karpathy-claude-skills`. Every skill is validated against the Agent Skills spec while its pack builds. Checks `skills-eval` (no VM) and `skills` (VM test).
- **MCP registry**: `agentos.mcp-registry.extraToolServers` is now written to `mcp-tools.json` (it was declared but never used).
- **agent-fleet web UIs** (`agentos.dashboard.agentFleetWeb`, docs/agent-fleet-web.md): the in-browser llama.cpp chat and the fleet hub from agent-fleet, packaged as `agent-fleet-web` with wllama 3.6.1 vendored (no CDN JavaScript at runtime; models still download from huggingface.co), served on 127.0.0.1:8484 with COOP/COEP headers by a hardened unit, linked from the dashboard (`/api/links`) and the desktop launcher. Opt-in `deployTool` installs `agent-fleet-deploy`, which publishes Spaces to Hugging Face with your token. VM test `agent-fleet-web`.
- **Agent stack** (`agentos.agentStack`, docs/agent-stack.md): the agent-fleet apps on the host instead of Hugging Face Spaces. n8n (`services.n8n`) and local chat (`agentos.localAI` with Ollama and Open WebUI) run natively; Flowise, Langflow, AnythingLLM and LobeChat run as hardened podman containers pinned by tag and digest, OpenMuse needs an image you build. Loopback ports only, secrets generated at first boot into `/var/lib/agentos-stack/secrets`, and each app gets its own `stack-<app>` gateway agent id, token and daily budget (apps that read the provided environment call LLMs through the gateway automatically; n8n and Flowise need their credentials entered in the UI, see the docs); the gateway also listens on the stack bridge address. VM test `agent-stack`.
- **Verifiable AI-authored code** (`agentos.provenance`, `agentos-provenance`, docs/provenance.md): the task runner signs an in-toto statement (agent, system closure, models and cost, prompt hash, approvals, recording hash) with an Ed25519 key as a DSSE envelope, stores it as a note on the commit, pushes the note with the branch, puts a summary in the PR body and sets the `agentos/provenance` commit status. `verify`, `show` and `replay-check` commands; `requireForPublish` refuses unsigned publishes. Adds the `cryptography` dependency to the services package.
- **Policy-as-code and RBAC** (`agentos.policy`, `agentos.rbac`, docs/policy.md): a typed, versioned policy per repository or workspace (budgets, allowed agents and models, approval mode, `maxParallel`, retries, isolation, publish) that fails at evaluation time on contradictions and is enforced by the orchestrator at submit with 403 errors naming the rule; the applied policy name and version are recorded on each task. Orchestrator roles (viewer, submitter, approver, admin) from unix groups via SO_PEERCRED, optional four-eyes approval (`separateApprover`), `agentos-task policy show` and `whoami`, and `checks.<system>.policy-eval`. Tasks accept an optional `model`.
- **Operations** (docs/operations.md, docs/runbooks/):
  - `/healthz` and `/readyz` on the gateway (TCP and admin socket), daemon, dashboard and orchestrator; `Type=notify` units with `sd_notify` READY and a watchdog fed from each service's main loop (stdlib only, `agentos_services/health.py`).
  - Prometheus alert rules (`agentos.observability.alerts`) for service down, gateway 5xx, budget, open circuit, loop detection, queue age, disk and Redis, plus a 99.5% gateway availability SLO with multi-window burn-rate alerts; each alert links a runbook. Optional Alertmanager (`agentos.observability.alertmanager`, webhook or email, off by default).
  - New metrics: gateway `/metrics` (responses by status, loop detections, circuit opens), daemon `agentos_redis_up`, `agentos_circuit_open`, `agentos_orchestrator_queue_oldest_age_seconds`, `agentos_state_disk_used_ratio`.
  - `agentos.backup` (restic): state, Redis (BGSAVE first), audit and stack directories, sops secrets; `agentos-restore`; VM test `backup`.
  - `agentos.upgrade`: `system.autoUpgrade` with a post-upgrade health gate that rolls back with `nixos-rebuild switch --rollback` and alerts.
  - `SECURITY.md`, `nix run .#sbom` (CycloneDX via sbomnix) and ready-to-copy supply-chain workflows in `ci/proposed-workflows/` (provenance, cosign, SHA256SUMS, SBOM attestation, vulnix, Scorecard, weekly flake.lock update).
- **Tamper-evident audit log** (`agentos.audit`, `agentos-audit`, docs/audit.md): append-only, hash-chained JSONL written only by a dedicated `agentos-audit` writer that receives events over a unix socket (the gateway, orchestrator, daemon and task runner cannot touch the files); Ed25519-signed checkpoints with a first-boot key delivered as a systemd credential; records for gateway requests (never prompt bodies), budget refusals, auth failures, task decisions, agent spawn/kill and publishes; non-blocking client with a drop counter and an optional fail-closed `strict` mode; `agentos-audit verify|tail`; segment rotation and `retentionDays` (default 183). Control mapping for EU AI Act Art. 12/19/26, SOC 2 CC7 and ISO 27001 A.8.15.
- **SIEM export**: syslog (RFC 5424 over TCP+TLS), Splunk HEC and OTLP logs, events mapped to OCSF 1.3.0 API Activity (6003), with retries and a persisted cursor.
- **Gateway DLP** (`agentos.gateway.dlp`, docs/dlp.md): secret and PII detectors (AWS, GitHub, private keys, JWT, provider keys, high-entropy strings; email, Luhn-checked cards, IBAN, phone) with modes `off`, `log`, `mask` and `block`, per-agent-prefix overrides and optional scanning of non-streaming responses. Findings are audited as types and counts only.
- VM test `audit`.
- **Event triggers and issue-to-PR** (`agentos.triggers`, `agentos-triggers`, docs/triggers.md): signed GitHub webhooks (issues, comments, check runs, review comments) start tasks by declarative rules; a `publish` step pushes `agent/<task-id>` and opens a PR with a token the agent never sees. `agentos.git-automation.autoPR` now publishes finished tasks of configured repositories. VM test `triggers`.
- **Per-agent gateway tokens.** `agentos spawn` generates a token and registers its hash through the admin socket; agents call `/agent/<id>:<token>/<provider>/`. An agent can no longer spend under another agent's id, get a fresh budget by inventing ids, or impersonate others on the message bus. Tokens are revoked when the agent is reaped.
- **Container isolation** (`agentos spawn --isolation container`): own root filesystem, PID/IPC/UTS namespaces and a network namespace on the `agentos0` bridge that can only reach the gateway.
- **GPU scheduling** (`agentos spawn --gpu N`, `agentos-gpu`) with exclusive per-device locks, released by the daemon when an agent dies.
- **Orchestrator and scheduler** (`agentos-task`, `agentos-schedule`): queued tasks, pipelines, swarms in git worktrees, and `OnCalendar` schedules.
- **Gateway features**: loop detection, cost routing to cheaper models, request recording and deterministic replay (`agentos-replay`), and an inter-agent message bus over HTTP and MCP (`agentos-msg`, `agentos-mcp-bus`).
- **Web dashboard** (`agentos-dashboard`), **remote fleets over SSH** (`agentos-fleet`) and an **agent marketplace** (`agentos-market`, `marketplace/index.json`); marketplace agents can be spawned by name.
- **Desktop edition** (`agentos.desktop.enable`): i3 with gaps by default, or sway/Hyprland; VS Code, Zed, Firefox; `agentos-desktop` host, desktop VM image and live ISO; `agentos-install --desktop`.
- **ARM64**: `-aarch64` variants of the server, VM, ISO and desktop hosts, and `packages.aarch64-linux.{iso,vm}-image`.
- VM tests `gateway-features`, `orchestration`, `container`, `platform` and `desktop`.

- **Sandbox hardening**: syscall filter, no new namespaces, restricted address families, no capabilities, no swap for agent units; default-deny forwarding from the agent bridge to private ranges and cloud metadata; stale namespace sweep.
- **Local AI** (`agentos.localAI`): Ollama or llama.cpp (CUDA, ROCm or CPU) and Open WebUI on loopback, registered as the gateway provider `local`.
- **Five more agents** (20 in total): Kilo Code, Mistral Vibe, Kiro CLI, Codebuff, Pi; `checks.<system>.agent-inclusion` keeps the runtime map and installed packages in step.
- **Installer**: SSH key validation, typed device confirmation, `--encrypt` (LUKS2). Desktop VM image gets a random first-boot password; the live ISO enforces key-only SSH.

### Changed
- The gateway, daemon, orchestrator and dashboard units are `Type=notify` with `WatchdogSec`; the host's `system.autoUpgrade` settings are now defaults that `agentos.upgrade` overrides.
- The unbuilt MCP gateway, MCP registry service, provisioner and memory manager stubs and `agentos.plannedServices` were removed.
- Unmanaged `/<provider>/` requests are only accepted on the gateway's admin socket.
- The orchestration and scheduler modules were rewritten; `agentos.orchestration.mode`, `resultStrategy` and several `agentos.scheduler.*` options were removed (setting them fails with a pointer to the replacement).

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
