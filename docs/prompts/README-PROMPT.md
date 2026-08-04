# AgentOS — README Generation Prompt

Paste this prompt into Claude/GPT to generate a world-class README:

```
Write a world-class GitHub README for "AgentOS" — an open-source operating system designed for AI coding agents. The README should be visually stunning, technically precise, and make developers want to star the repo immediately.

Here are the facts:

PROJECT: AgentOS
REPO: github.com/anubhavg-icpl/agentos
LICENSE: MIT
AUTHOR: Anubhav Gain

DESCRIPTION:
AgentOS is a minimal NixOS-based operating system where AI coding agents are the primary users. It ships with 22 agents pre-installed, 5340 skills auto-loaded from the VIBE library, and 56 MCP tool servers configured.

STATS:
- 22 pre-installed coding agents
- 5340 VIBE skills (auto-installed on boot)
- 56 MCP servers (8 categories)
- 27 NixOS modules
- 20+ language runtimes
- 853 VIBE expert modes

PRE-INSTALLED AGENTS (22):
Tier 1: Claude Code, Codex, Factory Droid, Aider, Gemini CLI, Qwen Code, Amp, Goose, OpenCode, Crush
Tier 2: Cursor CLI, Cline, Continue, GitHub Copilot, Devin, Roo Code
Tier 3: Open Interpreter, SWE-Agent, GPT-Engineer, Devika, AutoGPT, smol-developer

KEY MODULES:
- Container Runtime: containerd isolation per agent
- Budget Controller: per-agent cost caps with auto-shutdown
- Circuit Breaker: rate limiting, runaway detection, resource limits
- MCP Server Registry: 56 servers (GitHub, Postgres, Docker, Playwright, etc.)
- Git Automation: auto-branch, auto-commit, auto-PR per agent session
- Context & Memory: Qdrant vector DB for persistent agent memory
- Multi-Agent Orchestration: planner-worker, swarm, pipeline modes
- Observability: Prometheus + Tempo + Grafana
- Secrets Manager: sops-nix encrypted API keys
- Storage: btrfs snapshots, dedup, workspace GC
- Security: AppArmor, default-deny egress, kernel hardening
- VIBE Integration: 853 modes, 5340 skills from anubhavg-icpl/vibe

QUICK START:
nix build .#iso-image → flash to USB → boot → SSH in → `claude` or `codex` or `droid`

ARCHITECTURE:
Linux kernel → NixOS base → 27 modules → containerd → agents
Each agent runs in its own container with budget caps, git tracking, and tool access.

INCLUDE IN THE README:
1. Hero section with badges and a one-sentence pitch
2. "Why does this exist?" section (agents need their own OS, not a human OS)
3. Quick start (3 commands maximum)
4. Feature showcase with a table
5. All 22 agents listed with commands
6. All 27 modules listed with descriptions
7. Architecture diagram (ASCII art)
8. VIBE integration section
9. MCP server registry section
10. Project structure tree
11. Configuration example (Nix code block)
12. Comparison table (AgentOS vs plain Docker vs plain Linux)
13. Roadmap section
14. Contributing section
15. License and author

TONE: Technical, confident, exciting. Like Linear, Vercel, or Firecracker's READMEs.
FORMAT: Heavy use of tables, code blocks, emoji section headers, and badges.
Make it feel like a real product, not a hobby project.
```
