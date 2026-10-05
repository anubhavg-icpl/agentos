# Agent skills (`agentos.skills`)

A skill is a directory with a `SKILL.md` (YAML front matter with `name` and
`description`, then instructions) and any files it refers to. Most agent CLIs
load skills from a directory in the user's home. `agentos.skills` builds skill
packs from pinned upstream repositories and links their skills into those
directories for every CLI on the system, so one declaration serves Claude Code,
Codex, OpenCode, Gemini CLI, Copilot CLI, Cursor, Factory Droid, Amp, Goose and
the rest.

Skills are plain Markdown that the agent reads. The packs add no network
service of their own; what needs the network is listed per pack below.

## Enable

```nix
agentos.skills.enable = true;
```

The main host configuration (`nixos/hosts/agentos`) enables it. The minimal
images do not.

| Option | Default | Meaning |
|--------|---------|---------|
| `agentos.skills.enable` | `false` | Install the enabled packs |
| `agentos.skills.packs.<name>.enable` | `true` (see below) | One option per pack in `nixos/packages/skills`; new packs appear automatically |
| `agentos.skills.targets` | all | Which CLI directories get links (table below) |
| `agentos.skills.includeAgentUser` | `agentos.runtime.enable` | Link into the home of `agentos-agent` (`agentos.runtime.agentHome`) |
| `agentos.skills.users` | `[ ]` | More users whose home gets the links |

A pack is on by default unless its derivation sets `passthru.defaultEnable =
false` (`defaultEnable = false;` in `mkSkillPack`). Examples:

```nix
agentos.skills = {
  enable = true;
  packs.img2threejs.enable = false;        # token-heavy, see below
  targets = [ "agents" "claude-code" "codex" ];
  users = [ "admin" ];
};
```

## What gets installed

For all enabled packs together:

- **Skills.** The skills of every pack are flattened into one store directory,
  `agentos-skills-bundle`. Two enabled packs shipping a skill with the same
  name fail evaluation (an assertion naming both packs) and the bundle build.
- **Links.** For each user and each target, `<home>/<dir>/<skill>` is a
  symlink to `<bundle>/skills/<skill>`. A oneshot unit per user,
  `agentos-skills-link-<user>.service`, creates them at boot and again on every
  rebuild that changes the bundle, so skills follow updates.
- **Tools.** Each pack's `bin/` (for example `ui-skills`) goes into
  `environment.systemPackages`.
- **MCP servers.** Each pack's `mcp` servers are added to
  `agentos.mcp-registry.extraToolServers` and appear in
  `/etc/agentos/mcp-tools.json` (category `extra`, shown by `agentos-tools
  list`) when `agentos.mcp-registry.enable` is set. `agentos.mcp-registry` only
  lists them; each agent CLI still needs the server in its own MCP
  configuration.
- **Claude Code hooks.** A pack may set `passthru.claudeHooks` (Claude Code
  `hooks`: event name to a list of entries). The entries of all enabled packs are
  concatenated per event into
  `/etc/claude-code/managed-settings.d/50-agentos-skills.json`, a drop-in of
  Claude Code's system managed settings (path from its managed settings
  documentation for Linux). No file is written when no pack has hooks.
- **`agentos-skills`** (see below) and `/etc/agentos/skills.json`.

The link unit runs as the user it serves, so links and the directories it
creates belong to that user. It only manages links of its own: a symlink whose
target is inside an `agentos-skills-bundle`. A skill directory you wrote
yourself, or a symlink pointing elsewhere, with the same name is left alone and
reported in the unit's log. Links of ours to skills that are gone (a pack
disabled, a skill removed upstream) are deleted on the next run, in all known
target directories including ones you deselected.

## Where skills land

Paths are relative to the user's home. They were checked against the CLIs'
own code or binaries (npm and release packages, or upstream source) in
October 2026, except where marked.

| Target | Directory | Read by | How it was checked |
|--------|-----------|---------|--------------------|
| `agents` | `.agents/skills` | Codex, Gemini CLI, OpenCode, Amp, Goose, Qwen Code, Crush (the cross-agent location) | each of those, below |
| `claude-code` | `.claude/skills` | Claude Code; also read by OpenCode, Copilot CLI, Goose, Crush, Amp | Claude Code skills documentation |
| `codex` | `.codex/skills` | Codex | strings in the `codex` 0.160.0 binary (`$CODEX_HOME/skills`, `~/.codex/skills`; user scope `~/.agents/skills`) |
| `opencode` | `.config/opencode/skills` | OpenCode | strings in the `opencode` 1.18.34 binary (`~/.config/opencode/skill(s)/`; it also loads `~/.claude/skills` and `~/.agents/skills`) |
| `gemini` | `.gemini/skills` | Gemini CLI | bundle of `@google/gemini-cli` 0.62.0 (`getUserSkillsDir`, `getUserAgentSkillsDir`: `~/.gemini/skills`, `~/.agents/skills`) |
| `copilot` | `.copilot/skills` | Copilot CLI | `@github/copilot` 0.0.420 (`~/.copilot/skills`, `~/.claude/skills`). The 1.0.x release is a compiled binary whose strings could not be read, so this was not re-checked there |
| `cursor` | `.cursor/skills` | Cursor CLI | Cursor documentation from memory; the binary could not be downloaded here, so **not verified** |
| `factory-droid` | `.factory/skills` | Factory Droid | Factory documentation from memory; the `@factory/cli` package only downloads a binary, so **not verified** |
| `amp` | `.config/agents/skills` | Amp; also Goose and Crush | strings in the `amp` binary (`~/.config/agents/skills/`, `~/.agents/skills/`, `~/.config/amp/skills/`, `~/.claude/skills/`) |
| `goose` | `.config/goose/skills` | Goose | `crates/goose/src/skills` upstream (`Paths::config_dir()/skills`, `~/.agents/skills`, `~/.claude/skills`, `~/.config/agents/skills`) |
| `qwen` | `.qwen/skills` | Qwen Code | `@qwen-code/qwen-code` 0.24.7 (`SKILL_PROVIDER_CONFIG_DIRS = [".qwen", ".agents"]`) |
| `crush` | `.config/crush/skills` | Crush | `GlobalSkillsDirs` in `internal/config/load.go` upstream (also `.config/agents`, `.agents`, `.claude`) |

Several CLIs read more than one of these directories and so find a skill
under the same name twice; both links resolve to the same files. Set `targets` to a shorter list
if you prefer, for example `[ "agents" "claude-code" "gemini" "copilot"
"cursor" "factory-droid" ]`.

The sandboxed `agentos-agent` user has its own home (`agentos.runtime.agentHome`,
default `/var/lib/agentos/agent-home`, mode 0700), which is where agents started
with `agentos spawn` look. Your own login needs `agentos.skills.users = [ "you" ]`.

## `agentos-skills`

```
agentos-skills list            # packs, skills, tools, MCP servers, licenses, notes
agentos-skills doctor          # per user and target: ok / missing / broken links; exit 1 on a problem
agentos-skills path <skill>    # store path of a skill
```

`doctor` reports links that are missing or dangling as problems. A
user-created skill or a link pointing elsewhere is listed as "other" and does
not fail the check. Reading another user's home needs root. If `doctor`
reports missing links, `systemctl restart 'agentos-skills-link-*'` re-runs the
link units.

## Packs

Each pack is a package `skills-<name>` (`nix build .#skills-ui-skills`)
defined in `nixos/packages/skills/packs/` with `mkSkillPack`
(`nixos/packages/skills/lib.nix`) from a source pinned by commit and hash in
`nixos/packages/skills/sources.nix`. A pack builds `share/agentos/skills/<pack>/<skill>/`
and a `pack.json`.

| Pack | Skills | Tools | MCP | License | Network |
|------|--------|-------|-----|---------|---------|
| `fwc-swiftui-skills` | `swiftui-liquid-glass`, `swiftui-iphone-duo` | none | none | MIT | none |
| `ui-skills` | `baseline-ui`, `create-design-md`, `fixing-accessibility`, `fixing-metadata`, `fixing-motion-performance`, `improve-ui`, `ui-skills-root` | `ui-skills` | `ui-skills` | MIT | CLI and MCP use ui-skills.com |
| `img2threejs` | `img2threejs` | `img2threejs` | none | Apache-2.0 | installer subcommands only |
| `karpathy-guidelines` | `karpathy-guidelines` | none | none | MIT | none |
| `karpathy-claude-skills` | `karpathy-coding-loop`, `karpathy-context-engineering`, `karpathy-task-routing`, `karpathy-verification` | none | none | MIT | none |
| `chisle` (opt-in) | `chisle`, `chisle-review`, `chisle-audit`, `chisle-help` | Claude Code hooks | none | MIT | none |
| `anti-slop` | `install-anti-slop` | `anti-slop` | none | MIT | none (the upstream skill's `pnpm add` path uses npm) |
| `reticle` | 19 skills (see below) | `reticle` | `reticle` | FSL-1.1-ALv2 (skills Apache-2.0) | none; drives the local Chromium |

### fwc-swiftui-skills

[FloWritesCode/fwc-swiftui-skills](https://github.com/FloWritesCode/fwc-swiftui-skills):
SwiftUI Liquid Glass buttons and menus (iOS 26) and layouts for the foldable
iPhone. Markdown only.

### ui-skills

[ibelick/ui-skills](https://github.com/ibelick/ui-skills): skills for design
engineers. Cleaning up spacing and hierarchy, fixing accessibility, metadata
and animation performance, writing a `DESIGN.md`, auditing an interface, and a
routing skill (`ui-skills-root`) that tells the agent which of the others to
load.

- The skills are bundled and work offline.
- `ui-skills` CLI (`start`, `categories`, `list`, `get <slug>`) prints skills
  from the project's registry. It is packaged from `bin/ui-skills.ts`, run by
  Node's built-in type stripping, so it needs no npm install. It fetches
  `https://www.ui-skills.com/skills/registry.json` on each call; set
  `UI_SKILLS_SITE_URL` to point it elsewhere.
- The MCP server `ui-skills` is the project's hosted endpoint
  `https://www.ui-skills.com/mcp` (tools `list_skills` and `get_skill`),
  bridged to stdio with `npx -y mcp-remote`, which downloads `mcp-remote` from
  the npm registry on first use. It sends requests to a third-party service.

### img2threejs

[img2threejs/img2threejs](https://github.com/img2threejs/img2threejs): rebuilds
an object or character from a reference image as a procedural Three.js model,
through a staged pipeline with quality gates and an AI-vision self-correction
loop.

- The skill directory is the whole repository, because `SKILL.md` refers to
  `forge/` (Python stage scripts) and `grimoire/` (reference notes) by relative
  path.
- Token-heavy: expect long sessions that read many reference files. Disable it
  with `agentos.skills.packs.img2threejs.enable = false` if you do not want it in
  every agent's skill list.
- The scripts need Python, and the screenshot helpers need Playwright; the pack
  provides neither.
- The `img2threejs` command is the project's installer. `install` and `update`
  fetch with `npx` and write into agent skill directories, which duplicates
  this module; use `doctor` and `version` only.

### karpathy-guidelines

[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(MIT): one skill, `karpathy-guidelines`, with coding guidelines drawn from
Andrej Karpathy's notes on how LLMs go wrong when coding: state assumptions,
keep changes surgical, avoid overcomplication, define success criteria that
can be checked. Markdown only.

### karpathy-claude-skills

[benfngu/karpathy-claude-skills](https://github.com/benfngu/karpathy-claude-skills)
(MIT): four skills from Karpathy's talks and posts: `karpathy-coding-loop`
(plan, small diffs, verify before reporting done), `karpathy-context-engineering`,
`karpathy-task-routing` (how much autonomy, which tool or model) and
`karpathy-verification` (judging AI output). Markdown only. Upstream treats
`karpathy-guidelines` as superseded by this set; both packs are on by default
and either can be turned off. Upstream's `install.sh` also appends an
`@KARPATHY.md` import to `~/.claude/CLAUDE.md`; that edits a file you own, so
it is not done here and the skills load when their descriptions match a task.

### chisle

Makes the agent use fewer words and skip code the task does not need. Source: [JayPokale/Chisle](https://github.com/JayPokale/Chisle) (MIT).

Skills: `chisle` (the terse-prose and YAGNI-first ruleset), `chisle-review` (flag over-engineering in a diff), `chisle-audit` (ranked bloat report across code and prose), `chisle-help` (command card). They load in every agent CLI like any other skill.

In Claude Code the pack also installs three hooks: a session-start hook that injects the ruleset, a prompt hook that re-states it each turn and handles `/chisle` on/off, and a post-tool hook that trims oversized tool output (long `Bash`, `Grep`, `WebFetch` and MCP results) before the agent reads it. Elided text is kept under `~/.claude/chisle-spill/` so the agent can grep it back.

Because the hooks change what every Claude Code session sees, the pack is not enabled by default (`defaultEnable = false`). Enable it explicitly:

```nix
agentos.skills.packs.chisle.enable = true;
```

The module merges the pack's `passthru.claudeHooks` into the Claude Code managed settings drop-in (`/etc/claude-code/managed-settings.d/50-agentos-skills.json`, see above), pointing at the node scripts in the Nix store. Nothing is written to `~/.claude` at build time.

Runtime switches (environment): `CHISLE_DEFAULT_MODE=off` disables the ruleset, `CHISLE_COMPRESS=0` disables output trimming, `CHISLE_COMPRESS_TOOLS=Bash,Grep` narrows which tools are trimmed. Inside a session, `/chisle off` and `/chisle` toggle it.

The upstream installer (`npx chisle`) is not exposed: it edits `~/.claude` and other agents' config files, which Nix manages.

### anti-slop

Oxlint rules that catch specific coding mistakes in JavaScript and TypeScript projects (array `filter().map()` chains, widening then asserting types, `Reflect.get`, object-shaped parameters, `typeof` at runtime, and more), so the agent fixes them. Source: [dmmulroy/anti-slop](https://github.com/dmmulroy/anti-slop) (MIT). Skill: `install-anti-slop`.

The plugin is built from the pinned source and shipped with the pack. Run it in any project:

```console
$ anti-slop                 # lint the current directory with every anti-slop rule
$ anti-slop src/ --fix      # any oxlint arguments work
$ anti-slop -c my.json .    # use your own oxlint config instead of the built-in one
```

`anti-slop` runs oxlint from nixpkgs and loads the plugin from the Nix store through oxlint's `jsPlugins`, so it works offline and needs no `pnpm add`. The upstream `install-anti-slop` skill instead copies the plugin into a repository and installs `oxlint` and `@oxlint/plugins` from npm; use that when the project should own and customise the rules. The plugin is pinned upstream against oxlint 1.78.0, and nixpkgs may carry a different oxlint version.

### reticle

Reticle stops an agent from calling an app finished when it is not. It opens the
app in a browser, uses it, and marks each check worked, did not work, or not
enough information, with an explanation for every failure. Source:
https://github.com/reticlehq/reticle (pinned in `sources.nix`).

**Skills (19).** `reticle` (install, instrument and verify), `agentic-tdd`,
`audit-my-app`, `debug-broken-ui`, `design-system-compliance`,
`drive-desktop-app`, `false-green-tests`, `fix-what-i-pointed-at`,
`install-and-verify`, `replay-user-flows`, `test-error-states`,
`verify-cli-run`, `verify-form-validation`, `verify-keyboard-access`,
`verify-login-logout`, `verify-optimistic-update`, `verify-pagination`,
`verify-ui-change`, `verify-unattended`.

**Tools.** `reticle` (the CLI) is on PATH. The pack registers one MCP server,
`reticle` (`reticle mcp`). The CLI is built from the pinned source with pnpm:
only `@reticlehq/server` and the workspace packages it depends on are built, on
Node 22. Nothing is downloaded when it runs. The wrapper sets
`RETICLE_CHROMIUM_PATH` to nixpkgs' Chromium (so Playwright never installs a
browser), `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and `RETICLE_TELEMETRY=0`; all
three can be overridden from the environment.

Licence:

| Part | Licence |
| --- | --- |
| The 19 skills, `@reticlehq/core`, `engine`, `browser`, `open-verification` | Apache-2.0 |
| `@reticlehq/server` (the `reticle` CLI and MCP server), `@reticlehq/init` | FSL-1.1-ALv2 |
| `server/src/features/ee` | Reticle Enterprise License |

FSL-1.1-ALv2 allows internal use, development and evaluation. The one
restriction is offering Reticle itself as a competing product or service. Each
version becomes Apache-2.0 two years after its release. The enterprise code is
audit-log functionality that nothing else imports; the build deletes it, so it is
not in the output. The pack's `license` field is `FSL-1.1-ALv2` because that is
the most restrictive licence of what ships.

<!-- Entries for further packs go here, in the same form. -->

## Licenses

Each pack keeps its upstream license; `agentos-skills list` prints it.

| Pack | License |
|------|---------|
| `fwc-swiftui-skills` | MIT |
| `ui-skills` | MIT |
| `img2threejs` | Apache-2.0 |
| `karpathy-guidelines` | MIT |
| `karpathy-claude-skills` | MIT |
| `chisle` | MIT |
| `anti-slop` | MIT |
| `reticle` | FSL-1.1-ALv2 (CLI and MCP server); skills and SDK Apache-2.0 |

Reticle's server package, which provides the `reticle` CLI and MCP server, is
under the Functional Source License 1.1 (Apache-2.0 future): internal use,
development and evaluation are allowed; offering Reticle itself as a competing
product or service is not. Each release becomes Apache-2.0 two years later.
Its enterprise-licensed code (`server/src/features/ee`) is removed at build
time. Anthropic's `docx`, `pdf`, `pptx` and `xlsx` skills are "all rights
reserved" and are not shipped.

## Network use

Building the packs needs only the pinned source tarballs. At run time:

| What | Where it connects |
|------|-------------------|
| `ui-skills` CLI | `www.ui-skills.com` |
| `ui-skills` MCP server | `www.ui-skills.com` (through `npx mcp-remote`, which also needs the npm registry once) |
| `img2threejs install` / `update` | npm registry and GitHub (through `npx`) |

When `agentos.security` restricts egress, allow these hosts or leave the
affected pack's tools unused.

## Adding or updating a pack

1. Pin the source in `sources.nix` (`rev`, and `hash = lib.fakeHash` first to
   read the real hash from the build error).
2. Add `packs/<name>.nix` calling `mkSkillPack` and list it in
   `nixos/packages/skills/default.nix`. `skills` maps the skill name to its
   directory in the source; every directory needs a `SKILL.md` with front matter.
3. `nix build .#checks.x86_64-linux.skills-eval` builds every pack and the
   bundle and checks front matter, name collisions and `pack.json`. Every
   skill is also checked against the Agent Skills spec while its pack builds
   (`validate.py`): the name is 1-64 characters of a-z, 0-9 and single
   hyphens and equals the directory name, and the description is present and
   at most 1024 characters.

`checks.x86_64-linux.skills` is a VM test of the module: links in the agent
user's `.claude`, `.codex` and `.agents` directories, user-created skills left
alone, stale links removed, `agentos-skills doctor`, and the MCP entry.
