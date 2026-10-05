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
| `agy` | Antigravity CLI | Google | `antigravity-cli` | nixpkgs (vendor release archive, pinned hash) |
| `gemini` | Gemini CLI (deprecated) | Google | `gemini-cli` | nixpkgs |
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
| `grok` | Grok CLI | superagent-ai | `grok-cli` | nixpkgs |
| `droid` | Factory Droid | Factory AI | `factory-droid` | npm `@factory/cli` |
| `cline` | Cline | Open source | `cline` | npm `cline` |
| `cn` / `continue` | Continue CLI | Open source | `continue-cli` | npm `@continuedev/cli` |
| `interpreter` | Open Interpreter | Open source | `open-interpreter` | PyPI `open-interpreter` |

Claude Code, Amp, Cursor CLI, Copilot CLI, Kiro CLI and Antigravity CLI are unfree; the flake sets
`allowUnfree = true`.

**Gemini CLI is deprecated.** Google retired it on 2026-06-18 in favour of
Antigravity CLI (`agy`). `gemini-cli` stays installable so existing setups keep
working (nixpkgs prints a warning when evaluating it), but new work should use
`agy`. Migrate extensions with `agy plugin import gemini`.

### Antigravity CLI (`agy`)

`agy` is a compiled Go binary. Nestlo does not run the vendor's
`curl -fsSL https://antigravity.google/cli/install.sh | bash` installer: the
pinned nixpkgs revision packages the same release archive
(`https://storage.googleapis.com/antigravity-public/antigravity-cli/<version>-<build>/linux-x64/cli_linux_x64.tar.gz`)
as a fixed-output fetch with a SHA-256 hash, so the binary is reproducible,
needs no network at run time other than the model API, and there is nothing to
install on first boot or on every invocation. The packaged version follows the
flake's `nixpkgs-unstable` input (`nix flake update nixpkgs-unstable`); it can
trail the upstream changelog by a few releases.

Authentication, either one:

* `agy` signs in with Google (browser, or an authorization URL over SSH) and
  keeps the session in the system keyring. `/logout` clears it.
* `GEMINI_API_KEY` for the Gemini API without a sign-in. Also set
  `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json`
  (or via `/config`). `nestlo spawn` passes `GEMINI_API_KEY` through.

Headless: `agy -p "<prompt>"`; failures print an `AGY_ERROR: {...}` JSON line on
stderr and exit with code 3. The orchestrator runs it as
`agy --mode accept-edits -p {prompt}` (`nestlo.orchestration.taskCommands.agy`).

Configuration lives in `~/.gemini/config` (`config.json`, `rules/`, `AGENTS.md`,
`GEMINI.md`, `skills.json`, `plugins.json`, `mcp_config.json`) and
`~/.gemini/antigravity-cli/settings.json`. Nestlo writes none of these; manage
MCP servers with `agy mcp add|remove|list`. The public changelog documents no
switch for auto-update or usage data collection, so Nestlo cannot set one;
Google's data-use terms apply (opt out in the CLI's settings). With the default
egress policy `agy` works as is: sign-in and model traffic go to Google domains
(`googleapis.com` is allowlisted); add any further host it reports in
`nestlo.security.allowedEgressDomains`.

Pinning a release newer than the packaged one (maintainers who can reach
`storage.googleapis.com`; the build id after the version is only known from the
vendor installer or nixpkgs' `update.sh`):

```nix
# overlay or module
antigravity-cli = pkgs.antigravity-cli.overrideAttrs (_: rec {
  version = "<version>";
  src = pkgs.fetchurl {
    url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-<build-id>/linux-x64/cli_linux_x64.tar.gz";
    hash = pkgs.lib.fakeHash; # replace with the hash nix prints
  };
});
```

### Gateway routing per agent

`nestlo spawn` exports `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` (see
`nixos/packages/cli.nix`); an agent is metered only if it honours one of them.

| Agent | Base URL variable | Notes |
|:---|:---|:---|
| Claude Code, Aider, Open Interpreter | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` | metered |
| Codex, OpenCode, Goose, Crush | `OPENAI_BASE_URL` (OpenAI-compatible providers) | metered |
| Kilo Code, Pi | `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` where the configured provider reads them; otherwise set the provider's base URL in its config file | not verified against the gateway |
| Mistral Vibe | none: provider `api_base` is set in `~/.vibe/config.toml`; it speaks Mistral's API, which the gateway does not proxy | unmetered |
| Antigravity CLI (`agy`), Gemini CLI | `GOOGLE_GEMINI_BASE_URL` plus `GEMINI_API_KEY`, set by `nestlo spawn` only when the gateway has a `gemini` provider (`nestlo.networking.providers`). `agy` honours it only in `GEMINI_API_KEY` mode (`modelProvider: "gemini"`); with a Google sign-in it talks to Google directly | metered through the gateway with a `gemini` provider; sign-in mode unmetered |
| Grok CLI | none: it talks to xAI with its own key | unmetered |
| Kiro CLI, Codebuff | none: they use their own login and hosted backend | unmetered, not gateway-routable |

The Kilo Code package comes from the stable channel because the unstable
`kilocode-cli` is currently marked broken (`agents/default.nix` falls back
automatically). Mistral Vibe and Kiro CLI are not in cache.nixos.org for the
pinned revision (Kiro is an unfree binary fetch, Vibe builds from source), so
the first build of `all-agents` compiles or fetches them.

Considered and not added: `kiro` (the Kiro IDE; the CLI is `kiro-cli`), `happy-coder`
(mobile relay), `amazon-q-cli` (superseded by Kiro CLI), `aichat`,
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
| `GEMINI_API_KEY` | Antigravity CLI (`agy`; or sign in with `agy`) |
| `GEMINI_API_KEY` / `GOOGLE_API_KEY` | Gemini CLI (deprecated) |
| xAI key (see `grok --help` for the variable) | Grok CLI |
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
