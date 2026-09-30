# AgentOS — Pre-installed Coding Agents

The 15 agents below are pre-installed on every AgentOS system through the
`all-agents` package (`agents/default.nix`). Each one has the same base tools
(git, gh, ripgrep, fd, jq, …) on its `PATH`.

Agents come in two flavours:

- **Nix-packaged (12).** Built from nixpkgs-unstable and pinned by
  `flake.lock`. Reproducible, available offline once installed.
- **npm launchers (3).** Not in nixpkgs yet. The command runs
  `npx -y <package>@<pinned version>`, so the first run downloads the agent
  from registry.npmjs.org. They need egress to the npm registry and are not
  content-addressed like the Nix-built agents.

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
| `interpreter` | Open Interpreter | Open source | `open-interpreter` | nixpkgs |
| `droid` | Factory Droid | Factory AI | `factory-droid` | npm `@factory/cli` |
| `cline` | Cline | Open source | `cline` | npm `cline` |
| `cn` / `continue` | Continue CLI | Open source | `continue-cli` | npm `@continuedev/cli` |

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

### Through `agentos spawn`

```bash
agentos spawn claude --workspace ./myproject
agentos spawn aider -- --model sonnet   # args after -- go to the agent
```

`agentos spawn` switches the workspace to a fresh `agent/<name>-<timestamp>`
branch (running `git init` first if needed). It exports `AGENTOS_AGENT_ID`,
`AGENTOS_WORKSPACE`, `AGENTOS_BRANCH` and, with `--model`, `AGENTOS_MODEL`,
then `exec`s the agent in the current terminal.

It does **not** yet run the agent in a container, apply budget limits, or
register it with `agentos list` / `logs` / `kill`. Those depend on the
AgentOS daemon, which isn't implemented yet. See [STATUS.md](STATUS.md).

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
are decrypted to `/run/secrets/<NAME>`, readable by the `agentos` group.

---

## Installing agents elsewhere

```bash
nix profile install github:anubhavg-icpl/agentos#claude-code
nix run github:anubhavg-icpl/agentos#codex

# Every agent
nix profile install github:anubhavg-icpl/agentos#all-agents

# Only the 12 reproducible, Nix-built agents
nix profile install github:anubhavg-icpl/agentos#nix-agents
```
