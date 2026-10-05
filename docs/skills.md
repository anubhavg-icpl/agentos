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
| `agentos.skills.packs.<name>.enable` | `true` (see below) | One option per pack in `nixos/packages/skills`; new packs appear automatically. An explicit value always wins over `enableAll` and `collections` |
| `agentos.skills.enableAll` | `false` | Enable every pack, including the opt-in ones (see [Community collections](#community-collections)) |
| `agentos.skills.collections` | `[ ]` | Enable every pack that belongs to one of these collections (`community`, `design`, `security`, `writing`, `research`, `dev-workflow`, `productivity`, `science`, `automation`, `large`) |
| `agentos.skills.targets` | all | Which CLI directories get links (table below) |
| `agentos.skills.includeAgentUser` | `agentos.runtime.enable` | Link into the home of `agentos-agent` (`agentos.runtime.agentHome`) |
| `agentos.skills.users` | `[ ]` | More users whose home gets the links |

A pack is on by default unless its derivation sets `passthru.defaultEnable =
false` (`defaultEnable = false;` in `mkSkillPack`); all the community packs
below are opt-in. Examples:

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
agentos-skills list            # packs, skills, tools, MCP servers, licenses, notes (long skill lists cut at 40)
agentos-skills list --all      # the same with every skill name
agentos-skills list --collections   # enabled packs grouped by collection, with skill counts
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
| `caliper` | `grill-skill`, `evaluate-skill` | `caliper` | none | MIT | runs agent CLIs, which call their model APIs |
| `ouroboros` | 23 skills, `ouroboros-*` | `ooo`, `ouroboros`, `ozo` | `ouroboros` | MIT | drives the `claude` CLI; telemetry off |
| `herdr` | `herdr` | none (`agentos.herdr` installs the CLI) | none | Apache-2.0 | none |

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

### caliper

Tests whether a skill actually helps. Caliper runs the agent on the same tasks with and without the skill (it also works for MCP servers and other instructions), judges the results and compares them. Source: edonadei/caliper 0.17.0 (MIT).

- Skills: `grill-skill`, `evaluate-skill`.
- Tool: `caliper` on PATH (`caliper run my-skill.eval.yaml`, `caliper report`, `caliper compare`).
- Caliper drives agent CLIs (`claude`, `codex`, `pi`, `hermes`) that it finds on PATH; it is not wrapped and brings none of them. Enable the agent you want to evaluate.
- Network and keys: the unit tests are offline, but every real evaluation calls the agent's model, so the agent CLI must be logged in or keyed (an Anthropic or OpenAI key, or a subscription login), and it costs tokens. Git skill sources (`git:` entries in a spec) need `git` on PATH and network access. Nothing else phones home.
- Build: `python3Packages.buildPythonApplication` from the pinned source with nixpkgs dependencies, no patches. The full upstream test suite (1035 tests) runs during the build.

### ouroboros

Works through an app's details before building, asks about the decisions that change behavior, then checks the finished app against the plan and sends problems back (interview, seed, run, evaluate, evolve). Source: Q00/ouroboros 0.55.4 (MIT).

- Skills: all 23 upstream skills, installed as `ouroboros-<name>` (for example `ouroboros-seed`, `ouroboros-interview`, `ouroboros-evaluate`, `ouroboros-run`, `ouroboros-unstuck`). The prefix keeps them from colliding with other packs (`evaluate`, `config`, `update`, `publish`, `cancel`, ...). Upstream skills call each other by relative path (`../setup/SKILL.md`), so the pack rewrites those paths and each skill's front matter `name` to match the new directory. Text such as `ooo seed` (the CLI command) is unchanged; `/ouroboros:seed` is the upstream plugin-namespaced spelling and becomes `/ouroboros-seed` here. The CLI keeps its own bundled copy of the skills and does not depend on directory names.
- Tools: `ooo`, `ouroboros` and `ozo` on PATH. The optional native Rust monitor (`crates/ouroboros-tui`, started by `ouroboros tui monitor --backend slt`) is not built; the Python `ouroboros tui` is included.
- MCP: registers `ouroboros` as `ouroboros mcp serve --runtime claude-cli --llm-backend claude_code` (36 tools). The runtime is the upstream default and drives the `claude` CLI; point it at another runtime with `ouroboros mcp serve --runtime <name>`. The server needs the MCP 2 SDK, which nixpkgs lacks, so the pack builds `mcp` 2.0.0 plus `mcp-types`, `httpcore2` and `httpx2` from the pinned PyPI wheels.
- Telemetry: upstream sends anonymous usage events (install, daily command and workflow outcomes; no code, prompts or paths; see its TELEMETRY.md) by default. The wrapper sets `DO_NOT_TRACK=1` and `OUROBOROS_TELEMETRY=0`, so it is off. Both are defaults: export `DO_NOT_TRACK=0` together with `OUROBOROS_TELEMETRY=1` to opt in.
- Network and keys: the interview, seed, run and evaluate steps call a model through the selected agent CLI (logged in) or, for the `litellm` backend, a provider API key. Some skills use `gh` and `git` (starring the repo, publishing); the CLI otherwise needs no network.
- Known gap: httpx2 asks for idna 3.18 and nixpkgs has 3.15, so the dependency check for that single bound is skipped. Only internationalized host names in the HTTP MCP transport allow-list are affected (two upstream tests for that are disabled). The stdio MCP server used by agents is unaffected.
- Build: version set with `SETUPTOOLS_SCM_PRETEND_VERSION` (CHANGELOG.md stops at 0.41.0; the plugin manifests and the pinned source say 0.55.4). `tests/unit` runs in the build (23323 pass); files that need `/bin/bash`, the codex/ourocode/dsh agent CLIs, a nested sandbox, Windows behavior or a non-UTF-8 locale are disabled in `tools/ouroboros.nix`.

### herdr

The skill from [herdrdev/herdr](https://github.com/herdrdev/herdr) (0.9.3, Apache-2.0) that teaches an agent running inside herdr to inspect and drive panes, tabs, workspaces and other agents through the `herdr` CLI (`herdr pane list`, `herdr agent prompt`, `herdr agent wait`, ...).

- The skill describes itself as active only when the user mentions herdr, and requires `HERDR_ENV=1`, which herdr sets in every pane, so it costs a short description in the context elsewhere and nothing else.
- The pack ships no tools: the `herdr` binary, the agent-user server, the status bridge and the plugin management come from `agentos.herdr` ([herdr.md](herdr.md)). Enabling the pack without the module leaves the skill with no CLI to call.
- No network use.

<!-- Entries for further packs go here, in the same form. -->

## Community collections

Twenty-two further packs bring in popular community skill collections. All
of them are **opt-in** (`defaultEnable = false`): nothing here is installed
unless you enable it. Each is built from a source pinned in `sources.nix`, and
only skills whose licence allows redistribution are included (see "What is
left out" below). Skills are discovered from the pinned source with
`builtins.readDir` (`nixos/packages/skills/discover.nix`), not listed by hand,
so a pin update picks up new skills; the build still fails on a skill that
breaks the Agent Skills spec.

```nix
agentos.skills = {
  enable = true;
  collections = [ "community" "security" ];   # every pack tagged with one of these
  packs.gstack.enable = false;                # an explicit value always wins
  packs.scientific-skills.enable = true;      # or pick packs one by one
  # enableAll = true;                         # every pack, see the cost below
};
```

`agentos.skills.collections` takes any of these names; a pack can be in
several. `agentos-skills list --collections` shows the enabled packs grouped
by collection.

| Collection | Contents |
|------------|----------|
| `community` | The general-purpose community packs of moderate size (about 240 skills together) |
| `design` | UI and design: ui-skills, ui-ux-pro-max, impeccable, taste-skill, open-design, hyperframes, anthropic-skills, img2threejs, fwc-swiftui-skills |
| `security` | vibe-security |
| `writing` | no-ai-slop, caveman, mattpocock-skills, pstack |
| `research` | agent-reach |
| `productivity` | composio-awesome-claude-skills, ai-job-search |
| `dev-workflow` | Engineering workflows: superpowers, gstack, mattpocock-skills, pstack, cursor-plugins, ponytail, unlazy, caveman, anthropic-skills and the existing karpathy-*, anti-slop, reticle, caliper, ouroboros packs |
| `science` | scientific-skills |
| `automation` | composio-automation (needs a Composio account) |
| `large` | Packs with more than 150 skills: everything-claude-code, scientific-skills |

`chisle` is in no collection because it installs Claude Code hooks; only
`enableAll` or its own `enable` turns it on.

### Context cost

An agent lists every installed skill's name and description in each session.
That is roughly **100 tokens per skill** before it has done anything, and a
long list also makes the right skill harder to pick. `enableAll = true` installs
about 1,600 skills (around 160k tokens), which exceeds many models' useful
context. When more than **300** skills are enabled, evaluation prints a warning
that names the largest packs. It is a warning, not an error. Prefer
collections or single packs; the three largest are `composio-automation` (806
skills), `everything-claude-code` (274) and `scientific-skills` (171).

### Pack table

Skill counts are what the pinned sources give now. Every pack's `notes` field
(shown by `agentos-skills list`) has the full list of runtimes, keys and
caveats. None of the packs installs a dependency: scripts inside skills are
shipped as they are.

| Pack | Source | Licence | Skills | Collections | Needs / notes |
|------|--------|---------|--------|-------------|---------------|
| `superpowers` | [obra/superpowers](https://github.com/obra/superpowers) | MIT | 15 | community, dev-workflow | Markdown plus small Node/shell helpers; the plugin's session hook that forces `using-superpowers` is not packaged |
| `anthropic-skills` | [anthropics/skills](https://github.com/anthropics/skills) | Apache-2.0 (per skill) | 13 | community, design, dev-workflow | Python helpers need Pillow, Playwright and similar (not provided). docx, pdf, pptx, xlsx are not shipped (all rights reserved) |
| `mattpocock-skills` | [mattpocock/skills](https://github.com/mattpocock/skills) | MIT | 27 | community, dev-workflow, writing | `gh` and `git`; `retro` is installed as `mattpocock-skills-retro` |
| `gstack` | [garrytan/gstack](https://github.com/garrytan/gstack) | MIT | 54 | community, dev-workflow | Skills call upstream's Bun-built helpers and `browse` tool, which are not packaged (planning and review skills work as prose); `ios-*` need macOS and Xcode |
| `ui-ux-pro-max` | [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | MIT (ui-styling Apache-2.0) | 7 | community, design | Python 3 scripts (no packages); `design` needs a Gemini, Atlas Cloud or MuAPI key; scripts are addressed through `CLAUDE_PLUGIN_ROOT` |
| `impeccable` | [pbakaus/impeccable](https://github.com/pbakaus/impeccable) | Apache-2.0 | 1 | community, design | The skill runs a launcher that downloads upstream's compiled binary on first use (network) |
| `taste-skill` | [Leonxlnx/taste-skill](https://github.com/Leonxlnx/taste-skill) | MIT | 12 | community, design | Image-direction skills expect an image-generation tool |
| `open-design` | [nexu-io/open-design](https://github.com/nexu-io/open-design) | Apache-2.0 (web-clone MIT) | 8 | community, design | Small, hand-vetted selection from a large repository (below) |
| `caveman` | [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | Apache-2.0 | 16 | community, writing, dev-workflow | `caveman-compress` calls the Anthropic API or the `claude` CLI; the six Caveman Cloud skills are not shipped |
| `ponytail` | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) | MIT | 6 | community, dev-workflow | Markdown only; hooks and MCP server not packaged |
| `pstack` | [cursor/plugins](https://github.com/cursor/plugins) `pstack/` | MIT (pstack/LICENSE) | 50 | community, dev-workflow, writing | Markdown; `tdd` and `teach` are installed as `pstack-tdd`, `pstack-teach` |
| `no-ai-slop` | [petergyang/no-ai-slop](https://github.com/petergyang/no-ai-slop) | MIT | 1 | community, writing | Markdown only |
| `vibe-security` | [raroque/vibe-security-skill](https://github.com/raroque/vibe-security-skill) | MIT | 1 | community, security | Markdown only |
| `unlazy` | [Leonxlnx/unlazy](https://github.com/Leonxlnx/unlazy) | MIT | 1 | community, dev-workflow | Node 16+ for the gate scripts; no network |
| `composio-awesome-claude-skills` | [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) | Apache-2.0 (README only, see below) | 18 | community, productivity | `connect`, `connect-apps` need a Composio account; `langsmith-fetch` a LangSmith key; `video-downloader` yt-dlp |
| `agent-reach` | [Panniantong/Agent-Reach](https://github.com/Panniantong/Agent-Reach) | MIT | 1 | community, research | Router for the `agent-reach` CLI (not packaged) and per-platform tools; some channels need cookies or logins |
| `ai-job-search` | [MadsLorentzen/ai-job-search](https://github.com/MadsLorentzen/ai-job-search) | MIT | 5 | community, productivity | Meant for a forked project checkout; the search skills run with Bun |
| `hyperframes` | [heygen-com/hyperframes](https://github.com/heygen-com/hyperframes) | Apache-2.0 | 19 | design | `npx hyperframes` (npm, Node 22+), FFmpeg, Chromium; optional HeyGen, ElevenLabs or Gemini keys |
| `cursor-plugins` | [cursor/plugins](https://github.com/cursor/plugins) (all plugins with their own MIT LICENSE except pstack) | MIT (per plugin) | 48 | dev-workflow | Many assume Cursor features; the Google Workspace and X skills need MCP servers and accounts |
| `everything-claude-code` | [affaan-m/everything-claude-code](https://github.com/affaan-m/everything-claude-code) | MIT | 274 | large | Large; some skills need service accounts; agents, commands and hooks are not packaged |
| `scientific-skills` | [K-Dense-AI/scientific-agent-skills](https://github.com/K-Dense-AI/scientific-agent-skills) | MIT | 171 | science, large | Python packages and public databases, some with API keys; none installed |
| `composio-automation` | [ComposioHQ/awesome-claude-skills](https://github.com/ComposioHQ/awesome-claude-skills) `composio-skills/` | Apache-2.0 (README only) | 806 | automation | **Needs a Composio account**: every skill drives the hosted Rube MCP server (https://rube.app/mcp) and a login or key per app; useless without it; about 80k tokens of descriptions |

### What is left out

Only material that may be redistributed is packaged. Everything below is
excluded on purpose; the reasons are also in the header of each pack file.

- **Licence.** Anthropic's `docx`, `pdf`, `pptx` and `xlsx` (including the
  copies under awesome-claude-skills' `document-skills/`) are "© Anthropic,
  PBC. All rights reserved." `doc-coauthoring` (anthropic-skills) has no licence
  file of its own and the repository README only says "many skills" are
  Apache-2.0, so it is out. Scientific skills with a restrictive or unknown
  `license:` field are out (`deepspot-m` PolyForm Noncommercial, `what-if-oracle`
  CC BY-NC-SA, `rowan` proprietary, `glycoengineering`, `phylogenetics`,
  `primekg` unknown). hyperframes' `talking-head-recut` and `music-to-video`
  bundle GSAP (GreenSock, all rights reserved, Standard License); the 19
  Pixabay sound effects of `media-use` are removed from that skill (Pixabay
  licence). open-design keeps only its own skills and one MIT skill
  (`web-clone`); copies of other projects' skills (Anthropic, Leonxlnx's taste
  skills, GreenSock, Vercel, Emil Kowalski, OpenAI) are not repeated there.
- **No licence file at the root.** `awesome-claude-skills` has none; its README
  states Apache-2.0 (and that individual skills may differ), which is what the
  pack records. `cursor/plugins` has none either: only plugin directories with
  their own MIT `LICENSE` are used.
- **Not valid under the Agent Skills spec** (the build would fail):
  `claude-api` (anthropic-skills; description 1,068 characters),
  `cursor-sdk` (cursor-plugins; 1,045 characters), `check-agent-compatibility`
  (cursor-plugins; the description is not valid YAML), and four Danish job-board
  skills of ai-job-search (`jobbank-search`, `jobdanmark-search`,
  `jobindex-search`, `jobnet-search`; 1,122 to 1,241 characters).
- **Test fixtures, templates, examples, repo-internal skills.** Template skills
  (`template-skill`), `examples/` and `test/` trees, the per-agent copies of
  skills that repositories generate (`.claude/`, `.cursor/`, `.openclaw/`, ...),
  translations (everything-claude-code's `docs/*/skills`), hyperframes'
  `registry/` blocks and its own `.claude` development skills, open-design's
  `design-templates/`, plugin catalogue and its 85 catalogue stubs, gstack's
  OpenClaw variants, mattpocock's `misc` and `in-progress`, pstack's
  `automations/`, and the 19 everything-claude-code skills that exist only to
  operate ECC itself.
- **Duplicates.** The older copies of Anthropic skills in awesome-claude-skills
  (they ship in anthropic-skills from the original repository), 26
  underscore-named composio directories that duplicate the hyphen-named ones,
  and `taste-skill-v1`.
- **Needs a vendor's service, not just an account:** the six Caveman Cloud
  skills, gstack's router skill `gstack`, and `gstack-upgrade`.
- **Hooks, MCP servers, CLIs and plugin agents** that these repositories also
  ship are not packaged. Pack notes say which skills depend on them.

### Name clashes

`agentos.skills` fails when two enabled packs install a skill with the same
directory name, and `enableAll` enables all of them, so the whole set is kept
collision-free. `python3 nixos/packages/skills/collisions.py` evaluates every
pack and reports name clashes and identical `SKILL.md` text; it currently
finds none among 32 packs and 1,618 skills. Where different skills shared a
name, the later or less canonical one is prefixed with its pack name (the way
`ouroboros-*` already was): `everything-claude-code-benchmark`,
`everything-claude-code-design-system`, `everything-claude-code-exa-search`,
`mattpocock-skills-retro` (with the one reference to it in `ask-matt`
updated), `pstack-tdd` and `pstack-teach` (with the reference in pstack's
poteto-mode bug-fix playbook updated), and `cursor-pr-review-canvas`. Other
installed names differ from the upstream directory only where the spec
requires it (`Make Bot UI` becomes `make-bot-ui`, taste-skill's `*-skill`
directories take the `name:` from their front matter, two Composio
directories lose a leading hyphen).

### Licences and notices

Each pack keeps its upstream licence in `pack.json`, and the build copies the
upstream `LICENSE`/`NOTICE` files of the source into
`share/doc/agentos-skills/<pack>/` of the pack. `agentos-skills list` prints
the licence and notes of every enabled pack.

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
| `caliper` | MIT |
| `ouroboros` | MIT |
| `superpowers`, `gstack`, `mattpocock-skills`, `ponytail`, `pstack`, `cursor-plugins`, `no-ai-slop`, `vibe-security`, `unlazy`, `agent-reach`, `ai-job-search`, `everything-claude-code`, `scientific-skills`, `taste-skill`, `ui-ux-pro-max` | MIT (`ui-ux-pro-max`'s `ui-styling` Apache-2.0; `cursor-plugins` MIT per plugin directory) |
| `anthropic-skills`, `hyperframes`, `impeccable`, `caveman`, `open-design` | Apache-2.0 (`open-design`'s `web-clone` MIT; `anthropic-skills` per skill) |
| `composio-awesome-claude-skills`, `composio-automation` | Apache-2.0 as stated in the repository README (no LICENSE file) |
| `herdr` | Apache-2.0 |

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

The community packs add no network access of their own either, but many of
their skills send the agent to the network or to hosted services (Composio's
Rube MCP server, HeyGen, Caveman, ui-ux-pro-max's image APIs, `npx hyperframes`,
the launcher of impeccable); each pack's notes list them.

When `agentos.security` restricts egress, allow these hosts or leave the
affected pack's tools unused.

## Adding or updating a pack

1. Pin the source in `sources.nix` (`rev`, and `hash = lib.fakeHash` first to
   read the real hash from the build error).
2. Add `packs/<name>.nix` calling `mkSkillPack` and list it in
   `nixos/packages/skills/default.nix`. `skills` maps the skill name to its
   directory in the source; every directory needs a `SKILL.md` with front matter.
   For a large source use `discover.findSkills { src; roots; exclude; filter; }`
   (`nixos/packages/skills/discover.nix`) instead of a list, and
   `discover.renameSkills` to install a clashing skill under a prefixed name.
   Set `collections = [ ... ]` and, for anything that should not be on by
   default, `defaultEnable = false;`.
3. If the pack discovers its skills (`discover.findSkills`), run
   `nixos/packages/skills/update-locks.sh <pack>` and commit
   `nixos/packages/skills/locks/<pack>.json`: evaluation reads the lock, never
   the source (no import from derivation), and fails if the lock is missing.
4. `nix build .#checks.x86_64-linux.skills-eval` builds every pack and the
   bundle and checks front matter, name collisions and `pack.json`. Every
   skill is also checked against the Agent Skills spec while its pack builds
   (`validate.py`): the name is 1-64 characters of a-z, 0-9 and single
   hyphens and equals the directory name, and the description is present and
   at most 1024 characters.
5. `python3 nixos/packages/skills/collisions.py` lists name clashes between
   all packs (it must report none) and identical `SKILL.md` text installed
   twice.

`checks.x86_64-linux.skills` is a VM test of the module: links in the agent
user's `.claude`, `.codex` and `.agents` directories, user-created skills left
alone, stale links removed, `agentos-skills doctor`, and the MCP entry.
