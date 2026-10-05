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

<!-- Entries for further packs go here, in the same form. -->

## Licenses

Each pack keeps its upstream license; `agentos-skills list` prints it.

| Pack | License |
|------|---------|
| `fwc-swiftui-skills` | MIT |
| `ui-skills` | MIT |
| `img2threejs` | Apache-2.0 |

<!-- Licenses with conditions, such as the Reticle FSL note, go here. -->

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
   bundle and checks front matter, name collisions and `pack.json`.

`checks.x86_64-linux.skills` is a VM test of the module: links in the agent
user's `.claude`, `.codex` and `.agents` directories, user-created skills left
alone, stale links removed, `agentos-skills doctor`, and the MCP entry.
