# herdr (`agentos.herdr`)

[herdr](https://herdr.dev) (Apache-2.0, Rust) is a persistent terminal
workspace for coding agents. Panes, tabs and workspaces live in a background
server and survive detaching. herdr recognizes the agent in each pane and
marks it `working`, `blocked` (waiting for an approval or an answer), `idle`
or `done`. It has a socket API and a CLI that agents can drive, and plugins.

`agentos.herdr` makes it part of AgentOS:

| What | How |
|------|-----|
| herdr and its skill | `packages.<system>.herdr` (nixpkgs-unstable's, 0.9.x), installed by the module; skill pack `herdr` ([skills.md](skills.md)) |
| A server for the agent user | `agentos-herdr-server-agentos-agent`: everything the agent user runs in herdr persists; operators attach with `agentos-herdr attach` |
| Management bridge | `agentos-herdr status`, a loopback Prometheus exporter per user, a notification when an agent stays blocked |
| AgentOS plugin | orchestrator tasks, factory items, budgets and approve/cancel for gated tasks inside herdr |
| Declarative plugins | `agentos.herdr.plugins = [ { source; ref; } ]`, pinned, installed per user, idempotent |
| Dynamic plugins | `agentos-herdr-plugins`: browse the marketplace, review, install pinned, update with a manifest diff |
| Marketplace sweep | opt-in, off by default: install every marketplace plugin daily. Read the security section first |

## Enable

```nix
agentos.runtime = { enable = true; operators = [ "alice" ]; };

agentos.herdr = {
  enable = true;

  # Reviewed plugins, pinned (see "Declarative plugins")
  plugins = [
    { source = "ogulcancelik/herdr-plugin-examples/agent-telegram-notify";
      ref = "0123456789abcdef0123456789abcdef01234567"; }
  ];

  # Optional: let the agents report their state and session to herdr
  integrations = [ "claude" "codex" ];
};
```

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Install herdr and the two CLIs, set everything below up |
| `package` | `pkgs.agentos.herdr` | The herdr package |
| `users` | `agentos.runtime.operators` that exist | Users who get the AgentOS plugin, the declared plugins and an exporter |
| `includeAgentUser` | `agentos.runtime.enable` | Also set up the sandboxed `agentos-agent` |
| `server.users` | the agent user | Users with a systemd-run headless server |
| `integrations` | `[ ]` | herdr's built-in agent integrations (`herdr integration install <agent>`) for all users. They edit the agents' own settings files, so they are opt-in |
| `agentosPlugin.enable` | `true` | Link the AgentOS plugin |
| `plugins` | `[ ]` | `{ source; ref; enable = true; }`: GitHub plugins, pinned |
| `localPlugins` | `[ ]` | Directories with a `herdr-plugin.toml`, linked (store paths are ideal) |
| `pluginUsers` | all users | Who gets `plugins`, `localPlugins` and the AgentOS plugin |
| `monitor.enable` / `basePort` / `intervalSeconds` | on / 9970 / 10 | The per-user exporter; each user takes the next port, loopback only |
| `monitor.notifyBlocked` / `notifyCommand` / `blockedGraceSeconds` | on / `agentos-notify test` / 15 | Notification on a blocked agent |
| `marketplace.installAll` | `false` | See "Marketplace sweep" |
| `marketplace.users` / `exclude` / `minStars` / `schedule` / `githubTokenFile` | operators / `[ ]` / 0 / `daily` / none | Scope of the sweep |

The package is nixpkgs-unstable's `herdr` (0.9.1 at the pinned flake.lock),
built and cached by Hydra, so no Rust or Zig build runs on your machine. The
skill pack pins herdr 0.9.3's `skills/herdr` (the skill is a text file that
only uses the CLI, which is stable across 0.9.x). When nixpkgs moves to a
newer herdr, `nix flake update nixpkgs-unstable` picks it up; AgentOS needs
herdr 0.8.2 or newer (plugin manifest and marketplace support).

## Agents inside herdr

herdr runs as the user, so each user has their own server, socket and
sessions (`~/.config/herdr/`). The agent user's server is started by systemd
as `agentos-herdr-server-agentos-agent`, so orchestrator and factory agents
that you start inside it keep running when nobody is attached:

```bash
sudo agentos-herdr attach                 # the full herdr UI of agentos-agent
sudo agentos-herdr attach -- agent list   # any herdr command against that server
agentos-herdr status                      # panes and agents per user, one line each
```

Inside any herdr pane, agents can use the `herdr` CLI (`herdr pane list`,
`herdr agent prompt`, `herdr agent wait`, ...). The `herdr` skill pack teaches
them how; the skill is only active when `HERDR_ENV=1`, which herdr sets in
every pane.

Notes on the server unit:

- It is sandboxed like `agentos spawn` units for the agent user (strict file
  system, only the agent home and the workspaces writable, no privileges, no
  new capabilities), because what the agent user starts in a pane inherits it.
  An operator's server is not confined.
- A rebuild does not restart it (`restartIfChanged = false`): that would end
  the panes and the agents in them. A new herdr package takes effect at the next
  `systemctl restart agentos-herdr-server-<user>`. herdr's own `update --handoff`
  does not apply to Nix installs.
- `HOME`, `SHELL` and a `PATH` of the system profile (all agents) are set.

## Management bridge

`agentos-herdr` reads herdr's socket API through its CLI
(`herdr pane list`, `herdr agent list`) for each configured user. A user other
than the caller is queried through `runuser` (as root) or `sudo -n -u`.

```bash
agentos-herdr status                 # all configured users
agentos-herdr status --user alice --json
agentos-herdr metrics                # Prometheus text, once
agentos-herdr attach --user agentos-agent
```

A user whose herdr server is not running is reported as such, not as an error.

**Metrics.** Per user, `agentos-herdr monitor` (the unit
`agentos-herdr-monitor-<user>`, running as that user) serves on
`127.0.0.1:<9970 + index>`:

```
agentos_herdr_up{user}                         1 when the server answers
agentos_herdr_panes{user,state}                panes per state: idle working blocked done unknown
agentos_herdr_agents{user,state}               detected agents per state
agentos_herdr_blocked_notifications_total      notifications sent
```

`/status` returns the same data as JSON and `/healthz` answers `ok`. With
`agentos.observability.enable`, the module adds the Prometheus job
`agentos-herdr` for these ports. Labels carry only user names and the fixed
state names, never text an agent could choose.

**Blocked agents.** When a pane has been `blocked` for `blockedGraceSeconds`
(default 15, to ignore flicker) the monitor runs `agentos-notify test <message>`
once per blocked episode. The message names the agent, the pane and the user;
control characters and escape sequences in herdr-supplied names are removed
first. It needs `agentos.notifications.enable`, and the sending runs as the
monitored user, so that user must be able to read the webhook secrets
(`agentos.notifications.*File`). Use `webhookUrl`, or secrets readable by the
`agentos-agent` group, for the agent user. Set `monitor.notifyBlocked = false`
to turn it off, or `monitor.notifyCommand` to use another command (the text is
appended as the last argument).

**Dashboard.** The AgentOS web dashboard has no mechanism for links to other
local services yet, so herdr is not listed there; the metrics are the way to
chart it in Grafana, and `agentos-herdr status` the quick look.

## The AgentOS plugin

`integrations/herdr-plugin/` (plugin id `agentos.dashboard`) is linked from
the Nix store for every user in `pluginUsers`. It adds panes and actions to
herdr, all of them plain calls of the AgentOS CLIs as the herdr user:

| Pane / action | Shows or does |
|---------------|---------------|
| `tasks` | `agentos-task list`, refreshed every 5 s |
| `factory` | `agentos-factory list` (a message if the factory is not installed) |
| `budget` | `agentos-budget status` |
| `approve` | lists tasks `awaiting_approval`, asks for an id, runs `agentos-task approve <id>` |
| `cancel` | lists running and queued tasks, asks for an id and a confirmation, runs `agentos-task cancel <id>` |

Open one from herdr's action list (`AgentOS: orchestrator tasks`, ...) or with
`herdr plugin pane open --plugin agentos.dashboard --entrypoint tasks`. Bind a
key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+t"
type = "plugin_action"
command = "agentos.dashboard.tasks"
description = "AgentOS tasks"
```

The plugin does what the user can do on the command line, no more: the agent
user is not in the `agentos` group and sees the permission errors of the CLIs
in the pane; an operator with the `approver` role (when `agentos.rbac` is on)
can approve. Task ids are checked against the orchestrator's id syntax before
they reach a CLI.

## Declarative plugins

```nix
agentos.herdr.plugins = [
  { source = "owner/repo/subdir"; ref = "<full commit sha>"; enable = true; }
];
```

For each user in `pluginUsers`, `agentos-herdr-plugins-<user>.service` (a
oneshot at boot and on every rebuild that changes the list) runs
`agentos-herdr-plugins sync`:

- `herdr plugin install <source> --ref <ref> --yes` for each entry, then
  `herdr plugin enable|disable` to match `enable`.
- **Idempotent.** A plugin that is installed at the wanted commit (or whose
  recorded ref is the one wanted, for tags) is not touched, so a normal boot
  makes no network request. A plugin you removed by hand comes back.
- **Ownership.** What the unit installed is recorded in
  `~/.local/state/agentos-herdr/plugins.json`. A plugin removed from the list
  is uninstalled. A plugin you installed yourself (with `herdr plugin install`
  or `agentos-herdr-plugins install`) is never touched by the unit, even if
  its name matches one on the list.
- `ref` is required and is a commit sha or a tag; a sha is better because tags
  can be moved. `agentos-herdr-plugins show <source> --ref <ref>` prints the
  manifest and every command it will run, which is the review step.
- `enable = false` and unlinking need a running herdr server; for a user
  without a systemd-run server (an operator), the unit starts herdr's server
  briefly and stops it again. The unit retries every two minutes (five times an
  hour) when the network is not up yet or the ref does not exist.
- `localPlugins` (and the AgentOS plugin) go through `herdr plugin link`,
  which needs no network. herdr cannot install from a local path or a
  `file://` URL, so a plugin that you vendor or build in Nix is linked.

## Dynamic plugins: `agentos-herdr-plugins`

The marketplace is every public GitHub repository with the topic
`herdr-plugin` and a parseable `herdr-plugin.toml` (the same index as
herdr.dev/plugins, but read directly). It is not reviewed.

```bash
agentos-herdr-plugins catalog [--refresh] [--min-stars N] [--json]
agentos-herdr-plugins show owner/repo[/subdir] [--ref REF]
agentos-herdr-plugins install owner/repo[/subdir] [--ref REF] [--yes]
agentos-herdr-plugins install-all [--yes] [--exclude GLOB]... [--min-stars N] [--dry-run]
agentos-herdr-plugins update [owner/repo[/subdir]|plugin-id] [--yes]
agentos-herdr-plugins list [--json]
agentos-herdr-plugins remove owner/repo[/subdir]|plugin-id
```

- `catalog` uses the GitHub search API (`topic:herdr-plugin`, forks and
  archived repositories excluded, paginated) with `$GITHUB_TOKEN` if set, and
  shows name, stars, licence, description and the default branch's head
  commit (from `git ls-remote`, which is not rate limited). The result is
  cached for six hours under `~/.cache/agentos-herdr/`.
- `show` prints each manifest at the commit: id, version, platforms, the
  minimum herdr version and **every command** the plugin will run, grouped
  into `build`, `startup`, `action`, `event` and `pane`.
- `install` pins to the repository's current default-branch commit when you
  give no `--ref`, shows the same review, and asks before installing (`--yes`
  skips the question; a non-interactive run without `--yes` refuses, exit 2).
  A repository whose manifests are all in subdirectories installs each.
- `install-all` takes the whole catalog, drops plugins whose `platforms` do not
  include linux or whose `min_herdr_version` is newer than the installed herdr
  and later duplicates of a plugin id, prints every plugin with the commands it
  runs, and asks for confirmation unless `--yes`. Each plugin is pinned to the
  head commit seen in the plan. A failure of one does not stop the others
  (exit 1 at the end). `--exclude` takes `owner/repo[/subdir]` globs
  (`owner/*` works).
- `update` moves plugins this tool installed to the new head commit, printing
  the diff of `herdr-plugin.toml` and the new command list first. A plugin you
  installed by other means is not touched; there is no `herdr plugin update`.
- Sources are `owner/repo[/subdir]` only (the same GitHub shorthand herdr
  takes), refs are validated, and nothing from a manifest is put into a shell.

Without `$GITHUB_TOKEN`, GitHub allows 60 API calls per hour; the catalog needs a
few, but `install-all` needs one per repository, so use a token (no scopes) for
it. Tree and manifest fetches are cached by commit, so a rerun is cheap.

## Marketplace sweep (`marketplace.installAll`)

```nix
agentos.herdr.marketplace = {
  installAll = true;                       # off by default
  users = [ "alice" ];                     # operators only; see below
  minStars = 5;
  exclude = [ "someowner/*" ];
  githubTokenFile = "/run/secrets/github-token";
};
```

A timer per user (`agentos-herdr-marketplace-<user>.timer`, `daily`, randomized
by up to an hour) runs `agentos-herdr-plugins install-all --yes`. This installs
and **runs unreviewed third-party code as that user, every day, at commits you
have not read**. herdr does not sandbox plugins. It is off by default and not
recommended for the agent user: the module prints an evaluation warning when
the agent user is in `marketplace.users`. Use it on a throw-away or
single-purpose account, and keep `minStars` and `exclude` tight.

## Security model of plugins

A herdr plugin is ordinary code. Its build commands, `[[startup]]` hooks,
`[[events]]` hooks, actions and panes run as the user that runs herdr, inherit
that environment (including `GITHUB_TOKEN`, API keys and the SSH agent) and can
call the whole herdr CLI, which includes sending keystrokes to every pane
and agent of that user. herdr validates manifests and keeps plugin state in
separate directories, but it does not review or sandbox anything.

What AgentOS does about it:

- Nothing floats: declarative plugins require a `ref`, the CLI pins every
  install to a commit and records it. `update` is an explicit act that shows
  what changed in the manifest.
- Review before install: `show` and the confirmation list the commands each
  plugin runs (a manifest can still start a script that does more; read the
  repository for plugins you rely on).
- The AgentOS plugin and `localPlugins` come from the Nix store and the
  configuration you reviewed.
- Ownership: the declarative unit never changes plugins you installed by hand.
- The agent user is the sensitive one: it runs orchestrator and factory work.
  Do not give it a marketplace sweep; if it needs a plugin, pin and review it in
  `plugins` (or vendor it in `localPlugins`) and consider `pluginUsers`
  without the agent user.
- Plugins installed by the sweep are installed at the user's privilege, not
  root's; the units are hardened (`ProtectSystem=strict`, home writable only).
  The plugin's later runtime is inside herdr's server, which for the agent user
  is the sandboxed `agentos-herdr-server-agentos-agent`.

## Limits

- herdr installs plugins from GitHub shorthand only, so declarative installs
  need the network at first boot and the GitHub repositories to stay available;
  vendor critical plugins with `localPlugins`.
- The nixpkgs package follows nixpkgs-unstable (0.9.1 at the pinned lock),
  not herdr's latest release; `herdr update` is disabled for Nix installs.
- Pane state is herdr's: `blocked` means herdr recognized an approval or
  question UI; `unknown` is not an error.
- The VM test `herdr` (`nix build .#checks.x86_64-linux.herdr`) covers the
  server, the bridge and linked plugins offline. GitHub installs are covered by
  unit tests against a fake GitHub API and a fake `herdr`
  (`services/tests/test_herdr_*.py`).
