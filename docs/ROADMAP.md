# Roadmap

Where Nestlo is going after v0.3.0, and why. It is based on an audit of the
code and on research into agent sandbox platforms (E2B, Daytona, Modal,
Cloudflare and Vercel sandboxes), coding-agent protocols (MCP, A2A, ACP),
LLM gateways (LiteLLM, Portkey, Helicone) and agent security guidance
(OWASP Top 10 for LLM and agentic applications). Items move between
releases as work lands; [CHANGELOG.md](../CHANGELOG.md) records what shipped.

## Done since v0.3.0 (unreleased)

- Orchestrator: approval gates, DAG workflows, retries with backoff,
  verify-then-judge for swarms, priorities, concurrency keys, dedupe keys
  ([orchestration.md](orchestration.md)).
- GitHub triggers and issue → pull request publishing, with the token held
  by root and never visible to the agent ([triggers.md](triggers.md)).
- OpenClaw as an opt-in chat front end that submits Nestlo tasks through a
  policy bridge and spends through the gateway ([openclaw.md](openclaw.md)).
- Agent stack: n8n, Open WebUI + Ollama, Flowise, Langflow, AnythingLLM and
  LobeChat from the agent-fleet repo on the host, each with its own gateway
  agent id and budget ([agent-stack.md](agent-stack.md)). OpenMuse waits for
  an upstream image.
- Pullrun packaged, with an experimental `--isolation pullrun` mode
  ([pullrun.md](pullrun.md)).

## v0.4.0 — Hardened

Finish and secure what is merged before adding more.

- Sandbox: `SystemCallFilter`, `RestrictNamespaces`,
  `RestrictAddressFamilies`, `ProtectProc`, `MemorySwapMax=0` for the
  sandbox and container modes; a default-deny FORWARD policy on `agentos0`.
- Gateway: reserve estimated cost before a request so concurrent requests
  cannot overshoot a budget; keep agent tokens out of logs; throttle 401s.
- Desktop: no fixed password in the desktop VM image; fail clearly when
  `/etc/agentos/admin-password` is missing; assert SSH is off on the live ISO.
- Remove the four planned-service stubs (MCP gateway, MCP registry,
  provisioner, memory manager) or implement them.
- CI: run every VM test (a matrix job), add a binary cache, weekly
  `flake.lock` updates. Bump the version everywhere it is written.

## v0.5.0 — Local AI and providers

- `agentos.localAI`: Ollama or llama.cpp (`services.ollama`,
  `services.llama-cpp`) and Open WebUI, chosen by GPU, registered in the
  gateway as zero-cost providers so cost routing can use them.
- Gateway providers: Gemini, Bedrock, Vertex, Azure, vLLM; prompt-cache
  aware pricing; provider fallbacks and retries; virtual keys with
  per-project budgets.
- More agents from nixpkgs (Kilo Code, Mistral Vibe, GitHub Copilot CLI,
  Kiro CLI), or adopt numtide/llm-agents.nix for the long tail.
- LLM tracing with the OpenTelemetry GenAI conventions into Tempo, with
  Langfuse or Phoenix as an option.

## v0.6.0 — Sandboxes

- MicroVM isolation: Pullrun's Firecracker backend once it can mount or
  sync the workspace, or microvm.nix with a read-only `/nix/store` share.
- Pause, resume and fork of a running agent, tied to record/replay so a
  fork can start from a recorded step.
- Per-agent btrfs workspaces with snapshots, rollback and send/receive to
  fleet hosts.
- Preview URLs for ports an agent opens, behind authentication.
- Headless browser and computer-use desktop inside the sandbox, exposed
  over MCP.
- A sandbox API (create, exec, upload, stream, TTL) with Python and
  TypeScript clients.

## v0.7.0 — Agent security

- Approvals bound to the exact diff: the orchestrator shows the diff and
  only that diff can be pushed.
- Taint tracking: a session that read untrusted content (issues, web pages,
  third-party repositories) gets a stricter egress policy and needs
  approval for any network write.
- MCP proxy that pins tool descriptions by hash (tool poisoning, rug
  pulls) and strips hidden Unicode.
- Dependency firewall: npm and PyPI through a mirror that blocks very new
  packages and install scripts (slopsquatting, worm-style attacks).
- Secret scanning on gateway egress, with canary credentials.
- A hash-chained, append-only audit log.

## v0.8.0 — Protocols and ecosystem

- MCP 2025-11-25 authorization, elicitation and Tasks bridged to the
  message bus.
- Agent Client Protocol so editors (Zed, JetBrains) can drive Nestlo
  agents; A2A agent cards for the bus; a system-wide `AGENTS.md`.
- Signed marketplace index with per-entry integrity hashes; an MCP
  registry mirror.
- Dashboard controls (start, stop, approve) with per-user identity, RBAC
  and an audit trail; TLS required for non-loopback binds.
- Fleet-wide task queue with leases, so a dead host's tasks are requeued.

## v0.9.0 — Platform

- Secure Boot (lanzaboote), TPM2 LUKS unlock, optional impermanence.
- nixos-anywhere installs, auto-upgrade with rollback, image-based
  updates (`systemd.sysupdate`).
- COSMIC and niri desktops; ARM boards; aarch64 builds in CI.
