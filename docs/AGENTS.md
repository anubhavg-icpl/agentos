# Nestlo — Pre-installed Coding Agents

The 20 agents below are pre-installed on every Nestlo system through the
`all-agents` package (`agents/default.nix`). Each one has the same base tools
(git, gh, ripgrep, fd, jq, …) on its `PATH`.

Agents come in three flavours:

- **Nix-packaged (16).** Built from nixpkgs-unstable and pinned by
  `flake.lock`. Reproducible, available offline once installed.
- **npm launchers (3).** Not in nixpkgs yet. The command runs
  `npx -y <package>@<pinned version>`, so the first run downloads the agent
  from registry.npmjs.org. They need egress to the npm registry and are not
  content-addressed like the Nix-built agents.
- **PyPI launcher (1).** Open Interpreter runs through
  `uvx --from open-interpreter==<pinned version>` for the same reason.

## Quick Reference

| Command | Agent | Provider | Package | Source |
|:---|:---|:---|:---|:---|
| `claude` | Claude Code | Anthropic | `claude-code` | nixpkgs |
| `codex` | Codex CLI | OpenAI | `codex` | nixpkgs |
| `aider` | Aider | Open source | `aider` | nixpkgs |
| `gemini` | Gemini CLI | Google | `gemini-cli` | nixpkgs |
| `qwen` / `qwen-code` | Qwen Code | Alibaba | `qwen-code` | nixpkgs |
| `amp` | Amp | Sourcegraph | `amp` | nixpkgs |
| `goose` | Goose | Block | `goose` | nixpkgs |
| `opencode` | OpenCode | SST | `opencode` | nixpkgs |
| `crush` | Crush | Charm | `crush` | nixpkgs |
| `cursor-agent` / `cursor` | Cursor CLI | Cursor | `cursor-cli` | nixpkgs |
| `copilot` | GitHub Copilot CLI | GitHub | `github-copilot-cli` | nixpkgs |
| `kilocode` | Kilo Code CLI | Kilo | `kilocode-cli` | nixpkgs |
| `vibe` | Mistral Vibe | Mistral | `mistral-vibe` | nixpkgs |
| `kiro-cli` | Kiro CLI | AWS | `kiro-cli` | nixpkgs |
| `codebuff` | Codebuff | Codebuff | `codebuff` | nixpkgs |
| `pi` | Pi coding agent | pi-mono | `pi-coding-agent` | nixpkgs |
| `droid` | Factory Droid | Factory AI | `factory-droid` | npm `@factory/cli` |
| `cline` | Cline | Open source | `cline` | npm `cline` |
| `cn` / `continue` | Continue CLI | Open source | `continue-cli` | npm `@continuedev/cli` |
| `interpreter` | Open Interpreter | Open source | `open-interpreter` | PyPI `open-interpreter` |

Claude Code, Amp, Cursor CLI, Copilot CLI and Kiro CLI are unfree; the flake sets
`allowUnfree = true`.

Upstream has deprecated Gemini CLI for unpaid and Google AI Pro/Ultra users
in favour of Antigravity CLI (nixpkgs prints a warning when evaluating it).

### Gateway routing per agent

`nestlo spawn` exports `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` (see
`nixos/packages/cli.nix`); an agent is metered only if it honours one of them.

| Agent | Base URL variable | Notes |
|:---|:---|:---|
| Claude Code, Aider, Open Interpreter | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` | metered |
| Codex, OpenCode, Goose, Crush | `OPENAI_BASE_URL` (OpenAI-compatible providers) | metered |
| Kilo Code, Pi | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` where the configured provider reads them; otherwise set the provider's base URL in its config file | not verified against the gateway |
| Mistral Vibe | none: provider `api_base` is set in `~/.vibe/config.toml`; it speaks Mistral's API, which the gateway does not proxy | unmetered |
| Kiro CLI, Codebuff | none: they use their own login and hosted backend | unmetered, not gateway-routable |

The Kilo Code package comes from the stable channel because the unstable
`kilocode-cli` is currently marked broken (`agents/default.nix` falls back
automatically). Mistral Vibe and Kiro CLI are not in cache.nixos.org for the
pinned revision (Kiro is an unfree binary fetch, Vibe builds from source), so
the first build of `all-agents` compiles or fetches them.

Considered and not added: `amazon-q-cli` (superseded by Kiro CLI), `aichat`,
`llm`, `shell-gpt`, `mods`, `fabric-ai` (chat/prompt tools, not coding
agents), `claude-code-router` (a proxy), `gptme`, `plandex` and `forge` (not in
the pinned nixpkgs, or not evaluating).

### Removed agents

Earlier versions listed Devin CLI, Roo Code, SWE-Agent, GPT-Engineer, Devika,
AutoGPT and smol-developer. None of them builds: Devin and Roo Code have no
public CLI package, Devika and AutoGPT aren't distributed as CLIs, and the
rest pointed at placeholder source hashes. They were removed rather than
shipped broken.

---

## Usage

```bash
claude                    # interactive
claude -p "fix the bug"   # one-shot
codex "implement auth"
aider --model sonnet
droid                     # first run downloads @factory/cli from npm
```

### Through `nestlo spawn` (sandboxed, metered)

```bash
nestlo workspace create api --from https://github.com/me/api.git
nestlo spawn claude --workspace api --budget 5
nestlo spawn aider --workspace api -- --model sonnet   # args after -- go to the agent
nestlo list
nestlo logs <agent-id>
```

`nestlo spawn` does the following:

1. It creates an `agent/<agent-id>` branch in the workspace and registers the
   agent with the daemon.
2. It starts the agent as the `nestlo-agent` user in a transient systemd unit
   (`nestlo-agent-<id>.service`). The agent can write only to its workspace
   and its own home. It runs under memory, CPU and process limits, has no
   sudo, and cannot reach the control plane.
3. It points `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` at the model gateway,
   which meters every call and enforces the agent's budget. The agent user
   cannot reach those providers any other way.
4. It passes the placeholder key `nestlo-managed` when the gateway holds the
   provider key. Otherwise it passes your `ANTHROPIC_API_KEY` /
   `OPENAI_API_KEY` through.

Agents keep their logins and settings in `/var/lib/nestlo/agent-home`, which
is shared by every sandboxed run. The interactive `claude` login works there.

`--unsandboxed` runs the agent as you, in any directory. That run has no
limits and no metering guarantee.

---

## API keys

Each agent reads its provider's usual environment variable or login flow:

| Variable | Used by |
|:---|:---|
| `ANTHROPIC_API_KEY` | Claude Code, Aider, Open Interpreter, others |
| `OPENAI_API_KEY` | Codex, Aider, Open Interpreter, others |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Gemini CLI |
| `GITHUB_TOKEN` | Copilot CLI |
| `FACTORY_API_KEY` | Factory Droid |

With `nestlo.secrets-manager` set up (see [FEATURES.md](FEATURES.md)), keys
are decrypted to `/run/secrets/<NAME>`, readable by the `nestlo` group. The
gateway reads `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` from there by default,
so sandboxed agents never see them.

---

## Installing agents elsewhere

```bash
nix profile install github:anubhavg-icpl/nestlo#claude-code
nix run github:anubhavg-icpl/nestlo#codex

# Every agent
nix profile install github:anubhavg-icpl/nestlo#all-agents

# Only the 16 reproducible, Nix-built agents
nix profile install github:anubhavg-icpl/nestlo#nix-agents
```
