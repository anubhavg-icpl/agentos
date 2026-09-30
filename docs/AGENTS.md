# AgentOS — Pre-installed Coding Agents

The 15 agents below are pre-installed on every AgentOS system through the
`all-agents` package (`agents/default.nix`). Each one has the same base tools
(git, gh, ripgrep, fd, jq, …) on its `PATH`.

Agents come in three flavours:

- **Nix-packaged (11).** Built from nixpkgs-unstable and pinned by
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
| `droid` | Factory Droid | Factory AI | `factory-droid` | npm `@factory/cli` |
| `cline` | Cline | Open source | `cline` | npm `cline` |
| `cn` / `continue` | Continue CLI | Open source | `continue-cli` | npm `@continuedev/cli` |
| `interpreter` | Open Interpreter | Open source | `open-interpreter` | PyPI `open-interpreter` |

Claude Code, Amp, Cursor CLI and Copilot CLI are unfree; the flake sets
`allowUnfree = true`.

Upstream has deprecated Gemini CLI for unpaid and Google AI Pro/Ultra users
in favour of Antigravity CLI (nixpkgs prints a warning when evaluating it).

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

### Through `agentos spawn` (sandboxed, metered)

```bash
agentos workspace create api --from https://github.com/me/api.git
agentos spawn claude --workspace api --budget 5
agentos spawn aider --workspace api -- --model sonnet   # args after -- go to the agent
agentos list
agentos logs <agent-id>
```

`agentos spawn` does the following:

1. It creates an `agent/<agent-id>` branch in the workspace and registers the
   agent with the daemon.
2. It starts the agent as the `agentos-agent` user in a transient systemd unit
   (`agentos-agent-<id>.service`). The agent can write only to its workspace
   and its own home. It runs under memory, CPU and process limits, has no
   sudo, and cannot reach the control plane.
3. It points `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` at the model gateway,
   which meters every call and enforces the agent's budget. The agent user
   cannot reach those providers any other way.
4. It passes the placeholder key `agentos-managed` when the gateway holds the
   provider key. Otherwise it passes your `ANTHROPIC_API_KEY` /
   `OPENAI_API_KEY` through.

Agents keep their logins and settings in `/var/lib/agentos/agent-home`, which
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

With `agentos.secrets-manager` set up (see [FEATURES.md](FEATURES.md)), keys
are decrypted to `/run/secrets/<NAME>`, readable by the `agentos` group. The
gateway reads `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` from there by default,
so sandboxed agents never see them.

---

## Installing agents elsewhere

```bash
nix profile install github:anubhavg-icpl/agentos#claude-code
nix run github:anubhavg-icpl/agentos#codex

# Every agent
nix profile install github:anubhavg-icpl/agentos#all-agents

# Only the 11 reproducible, Nix-built agents
nix profile install github:anubhavg-icpl/agentos#nix-agents
```
