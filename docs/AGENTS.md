# AgentOS — Pre-installed Coding Agents

All agents below are **pre-installed** on every AgentOS system. No additional installation required. Each agent has the same shared base tools (git, ripgrep, fd, gh, jq, etc.) so they behave identically.

## Quick Reference

| Command           | Agent              | Provider     | Type            |
|-------------------|--------------------|--------------|-----------------|
| `claude`          | Claude Code        | Anthropic    | CLI agent       |
| `codex`           | Codex CLI          | OpenAI       | CLI agent       |
| `droid`           | Factory Droid      | Factory AI   | CLI agent       |
| `aider`           | Aider              | Open source  | Pair programmer |
| `gemini`          | Gemini CLI         | Google       | CLI agent       |
| `qwen-code`       | Qwen Code          | Alibaba      | CLI agent       |
| `amp`             | Amp                | Sourcegraph  | CLI agent       |
| `goose`           | Goose              | Block        | CLI agent       |
| `opencode`        | OpenCode           | SST          | CLI agent       |
| `crush`           | Crush              | Charm        | CLI agent       |
| `cursor`          | Cursor CLI         | Cursor       | Headless agent  |
| `cline`           | Cline              | Open source  | Autonomous      |
| `continue`        | Continue           | Open source  | Assistant       |
| `copilot`         | GitHub Copilot     | GitHub       | CLI             |
| `devin`           | Devin              | Cognition    | CLI agent       |
| `roo`             | Roo Code           | Open source  | Autonomous      |
| `interpreter`     | Open Interpreter   | Open source  | Code execution  |
| `sweagent`        | SWE-Agent          | Princeton    | Research        |
| `gpt-engineer`    | GPT-Engineer       | Open source  | Project builder |
| `devika`          | Devika             | Open source  | Research        |
| `autogpt`         | AutoGPT            | Open source  | Autonomous      |
| `smol-developer`  | smol-developer     | Open source  | Minimal         |

---

## Tier 1 — Primary Agents

These are the main production-ready coding agents. Use these for real work.

### Claude Code (`claude`)
- **Provider:** Anthropic
- **Install:** Pre-installed
- **API Key:** `ANTHROPIC_API_KEY`
- **Usage:**
  ```bash
  claude                    # interactive mode
  claude "fix the bug"      # one-shot
  agentos spawn claude-code # managed mode (sandboxed)
  ```
- **Docs:** https://docs.anthropic.com/en/docs/claude-code

### Codex CLI (`codex`)
- **Provider:** OpenAI
- **Install:** Pre-installed
- **API Key:** `OPENAI_API_KEY`
- **Usage:**
  ```bash
  codex                     # interactive
  codex "implement auth"    # one-shot
  agentos spawn codex
  ```
- **Docs:** https://github.com/openai/codex

### Factory Droid (`droid`)
- **Provider:** Factory AI
- **Install:** Pre-installed
- **Auth:** Factory account login
- **Usage:**
  ```bash
  droid                     # interactive
  droid "build a REST API"  # task mode
  agentos spawn factory-droid
  ```
- **Docs:** https://docs.factory.ai

### Aider (`aider`)
- **Provider:** Open source (aider.chat)
- **Install:** Pre-installed
- **API Key:** `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`
- **Usage:**
  ```bash
  aider                      # interactive pair programming
  aider --model claude-sonnet-4-20250514
  agentos spawn aider
  ```
- **Docs:** https://aider.chat

### Gemini CLI (`gemini`)
- **Provider:** Google
- **API Key:** `GOOGLE_API_KEY`
- **Usage:**
  ```bash
  gemini
  agentos spawn gemini-cli
  ```

### Qwen Code (`qwen-code`)
- **Provider:** Alibaba
- **Usage:**
  ```bash
  qwen-code
  agentos spawn qwen-code
  ```

### Amp (`amp`)
- **Provider:** Sourcegraph
- **Usage:**
  ```bash
  amp
  agentos spawn amp
  ```

### Goose (`goose`)
- **Provider:** Block (Square)
- **Usage:**
  ```bash
  goose
  agentos spawn goose
  ```

### OpenCode (`opencode`)
- **Provider:** SST
- **Usage:**
  ```bash
  opencode
  agentos spawn opencode
  ```

### Crush (`crush`)
- **Provider:** Charm (makers of Bubble Tea)
- **Usage:**
  ```bash
  crush
  agentos spawn crush
  ```

---

## Tier 2 — Extended Agents

### Cursor CLI (`cursor`)
Headless mode of the Cursor editor's agent.
```bash
cursor
agentos spawn cursor-cli
```

### Cline (`cline`)
Autonomous coding agent (VS Code extension with CLI).
```bash
cline
agentos spawn cline
```

### Continue (`continue`)
Open-source AI code assistant.
```bash
continue
agentos spawn continue-cli
```

### GitHub Copilot CLI (`copilot`)
```bash
copilot
gh copilot suggest "how to parse JSON in python"
agentos spawn github-copilot-cli
```

### Devin CLI (`devin`)
Cognition's Devin via CLI.
```bash
devin
agentos spawn devin-cli
```

### Roo Code (`roo`)
Cline fork with additional features.
```bash
roo
agentos spawn roo-code
```

---

## Tier 3 — Research / Experimental

### Open Interpreter (`interpreter`)
Let LLMs run code directly.
```bash
interpreter
interpreter "plot a sine wave"
```

### SWE-Agent (`sweagent`)
Princeton's software engineering agent, designed for issue resolution.
```bash
sweagent
```

### GPT-Engineer (`gpt-engineer`)
Specify what you want, it builds the project.
```bash
gpt-engineer "a todo app in React"
```

### Devika (`devika`)
Open-source Devin alternative.
```bash
devika
```

### AutoGPT (`autogpt`)
Autonomous AI agents that chain tasks.
```bash
autogpt
```

### smol-developer (`smol-developer`)
Minimal AI developer (1000 lines).
```bash
smol-developer "create a CLI tool"
```

---

## Installing Additional Agents

```bash
# Install a specific agent package
nix profile install .#claude-code
nix profile install .#aider

# Install ALL agents (meta-package)
nix profile install .#all-agents

# Install Tier 1 only
nix profile install .#tier1-agents

# Search for any nix package
agentos search python311
agentos search rustc

# Install any nix package
agentos install go_1_23
agentos install cargo
```

## Running Agents

### Direct (standalone)
```bash
claude
aider --model claude-sonnet-4-20250514
codex "refactor this function"
```

### Managed (sandboxed, tracked)
```bash
agentos spawn claude-code --workspace ./myproject
agentos spawn aider --model claude-sonnet-4-20250514
agentos list          # see running agents
agentos logs agent-1234
agentos kill agent-1234
```

### Environment Variables
All agents respect these:
- `ANTHROPIC_API_KEY` — for Claude, Aider, others
- `OPENAI_API_KEY` — for Codex, GPT-Engineer, others
- `GOOGLE_API_KEY` — for Gemini
- `AGENTOS_MODEL` — default model override
- `AGENTOS_BUDGET_USD` — per-session budget cap
