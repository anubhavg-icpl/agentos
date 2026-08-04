# AgentOS — Social Media & Launch Prompts

Copy-paste these prompts to generate social media posts, blog articles, and launch content.

---

## TWITTER / X THREAD (10 tweets)

```
Write a viral Twitter/X thread announcing "AgentOS" - an operating system designed for AI coding agents. Thread should be 10 tweets. Here are the facts:

- It's built on NixOS (minimal Linux)
- 22 AI coding agents pre-installed (Claude Code, Codex, Factory Droid, Aider, Cursor, Gemini, etc.)
- 5340 skills auto-installed from the VIBE library (anubhavg-icpl/vibe)
- 56 MCP servers preconfigured (GitHub, Slack, Postgres, Playwright, Docker, etc.)
- 27 NixOS modules: budget controller, circuit breaker, git automation, multi-agent orchestration, vector memory (Qdrant), scheduler, notifications
- 20+ language runtimes pre-installed
- Budget caps prevent runaway spending
- Full observability: Prometheus + Grafana + OpenTelemetry
- Open source, MIT license
- GitHub: github.com/anubhavg-icpl/agentos

Tone: excited but technical, like a builder sharing their passion project. Use emojis sparingly. Each tweet should reveal one mind-blowing feature. End with a call to action to star the repo.
```

## LINKEDIN POST

```
Write a professional LinkedIn post announcing the launch of AgentOS, an open-source operating system for AI coding agents. 

Key points to cover:
- The problem: AI coding agents need a proper runtime environment, not just a shell prompt
- The solution: AgentOS is a NixOS-based OS with 22 agents, 5340 skills, 56 MCP servers pre-installed
- Technical highlights: budget control, circuit breakers, git automation, observability
- Who it's for: AI engineers, platform teams, coding agent developers
- Call to action: github.com/anubhavg-icpl/agentos

Tone: professional, thought-provoking, forward-looking. Position it as infrastructure for the agentic AI era. 300-500 words.
```

## HACKER NEWS TITLE + COMMENT

```
Write a Hacker News post for launching AgentOS. 

Title options (pick the best one):
- "AgentOS: A Linux distro where the primary users are AI coding agents"
- "Show HN: I built an OS for AI coding agents (22 agents, 56 MCP servers pre-installed)"
- "AgentOS – NixOS for AI agents, with budget caps and circuit breakers"

Comment body (first comment from the author):
Explain what AgentOS is, why I built it, what makes it different from just running agents in Docker, and ask for feedback. Mention it's MIT licensed and built on NixOS. Technical depth appropriate for HN audience. Include a mention of the VIBE library integration (853 modes, 5340 skills). Be humble, not salesy.
```

## REDDIT POST (r/programming or r/MachineLearning)

```
Write a Reddit post for r/programming announcing AgentOS. 

Title: "AgentOS: An operating system where the primary users are AI coding agents, not humans"

Body should cover:
- What it is: NixOS-based, 22 agents pre-installed, 27 modules
- Why: Agents need sandboxing, budget control, git automation, observability
- Technical deep dive: btrfs snapshots per agent session, Qdrant vector memory, MCP tool registry, circuit breakers, sops-nix secrets
- VIBE integration: 5340 skills auto-installed into all 7 agent CLIs
- How to try it: build the ISO with `nix build .#iso-image`
- Link: github.com/anubhavg-icpl/agentos

Tone: technical, transparent, inviting feedback. Acknowledge what's real vs what's still being built.
```

## DEV.TO / MEDIUM BLOG POST

```
Write a 1500-word technical blog post titled "I Built an Operating System for AI Coding Agents" for dev.to.

Structure:
1. Hook: "In 2026, AI coding agents write most of my code. So why am I still using an OS designed for humans?"

2. The Problem: Agents need sandboxing, reproducible environments, budget caps, and tool access. Traditional OSes give you none of this.

3. The Solution: AgentOS, a NixOS-based OS with 27 modules.

4. Deep dive sections (200 words each):
   - 22 Pre-installed Agents (Claude Code to AutoGPT)
   - The MCP Registry: 56 tool servers (GitHub, Postgres, Playwright, Docker)
   - VIBE Integration: 5340 skills auto-installed
   - Budget Controller: How it prevents $1000 surprise bills
   - Circuit Breaker: Killing runaway agents automatically
   - Git Automation: Every agent gets its own branch, commits, and PRs

5. Architecture: NixOS → modules → containerd → agents

6. Getting Started: 3 commands to try it

7. What's Next: GPU scheduling, remote agent fleets, marketplace

8. Call to action: Star the repo, contribute modules, join the community

Tone: like a senior engineer explaining their weekend project. Technical but accessible. Include code snippets where relevant.
```

## PRODUCT HUNT LAUNCH

```
Write a Product Hunt launch for AgentOS.

Tagline (60 chars max): "An OS where AI coding agents are the primary users"

Description:
AgentOS is a minimal NixOS-based operating system that ships with 22 AI coding agents pre-installed, 5340 expert skills from the VIBE library, and 56 MCP tool servers — all configured and ready to run.

Key features:
🤖 22 agents: Claude Code, Codex, Factory Droid, Aider, Cursor, and 17 more
🧠 5340 VIBE skills: Auto-installed into every agent on first boot
🔌 56 MCP servers: GitHub, Slack, Postgres, Docker, Playwright, Grafana
💰 Budget controller: Per-agent spending caps with auto-shutdown
🛡️ Circuit breaker: Rate limiting and runaway agent detection
📊 Full observability: Prometheus + Grafana + OpenTelemetry
🔒 Git automation: Auto-branch, auto-commit, auto-PR per agent session
💾 btrfs snapshots: Every agent action is snapshotable and rollbackable

Built on NixOS for full reproducibility. MIT licensed.

GitHub: github.com/anubhavg-icpl/agentos

Maker comment: Explain the journey of building AgentOS, why agents need their own OS, and what's coming next.
```

## DISCORD / SLACK ANNOUNCEMENT

```
Write a short, punchy announcement for Discord/Slack communities:

🚀 Just launched AgentOS — an operating system designed for AI coding agents.

Think about it: agents need sandboxing, budget control, tool access, and observability. So I built an OS that has all of that built-in.

22 agents pre-installed. 5340 VIBE skills auto-loaded. 56 MCP servers configured. Budget caps. Circuit breakers. Git automation. Full Grafana dashboards.

It's NixOS-based, MIT licensed, and ready to hack on.

→ github.com/anubhavg-icpl/agentos

Would love feedback and contributors! 🙏
```

## YOUTUBE SHORT / TIKTOK SCRIPT

```
Write a 60-second YouTube Short / TikTok script for AgentOS.

[Visual: terminal typing fast]
"AI agents write most of my code now."

[Visual: split screen showing 22 agent logos]
"So I built them their own operating system."

[Quick cuts showing features]
"22 coding agents. Pre-installed."
"5340 skills. Auto-loaded."
"56 tool servers. Configured."
"Budget caps. So they don't burn my money."
"Circuit breakers. So they don't loop forever."
"Git automation. Every change is a PR."
"btrfs snapshots. Undo anything."

[Hero shot of ISO]
"AgentOS. An OS where the AI is the user."

[Text on screen]
"Link in bio. MIT licensed. Built on NixOS."

Tone: fast-paced, high energy, tech-aesthetic. Background music: electronic/synthwave.
```
