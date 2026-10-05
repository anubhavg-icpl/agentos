# TUIOS (`nestlo.tuios`)

[TUIOS](https://github.com/Gaurav-Gosain/tuios) (MIT, Go) is a terminal
multiplexer and window manager. A daemon holds the sessions, so they survive
detaching and, through saved state, a reboot. For coding agents it adds the
parts a multiplexer usually lacks: each pane reports its agent's state
(`working`, `needs_input`, `done`, `errored`), an inbox collects approvals and
questions, `fan` starts several agents in git worktrees, a JSON verb protocol
and event stream run over a `0700` unix socket, panes hold grants that limit
what a process in them may do through tuios, and there are an MCP server, an
SSH server (`tuios ssh`) and a web terminal (`tuios-web`).

`nestlo.tuios` makes it part of Nestlo:

| What | How |
|------|-----|
| tuios and tuios-web | `packages.<system>.tuios` (v0.8.5, built from source: nixpkgs has 0.7.0, from before the agent features), installed by the module |
| Declarative config | `settings` (freeform TOML), strict pane grants by default, `hooks`, written to `/etc/xdg/tuios/config.toml` |
| A daemon per user | `nestlo-tuios-<user>` for the operators and the agent user; sandboxed for the agent user |
| Layouts | `layouts.<name>`: sessions created headless at boot by `nestlo-tuios-layouts-<user>` |
| Bridge | `nestlo-tuios-bridge-<user>`: `terminal.tuios` audit events, a notification when an agent waits for input, loopback Prometheus metrics |
| Agent integrations | opt-in `integrations`: hooks in the agents' own settings that report their state to their pane |
| MCP | opt-in `mcp.enable`: `tuios mcp` (read-only) in the Nestlo tool registry |
| SSH and web access | opt-in `ssh` and `web`, key / password required, loopback by default |

## Relation to herdr

[herdr](herdr.md) and TUIOS solve the same problem (persistent panes for
agents, marked by state) and can be enabled together; they are separate
programs with separate daemons and sockets. TUIOS answers herdr's socket API
on a second socket beside its own (`<daemon socket>.herdr`; 77 of herdr's 102
methods) and sets the `HERDR_*` variables in its panes, so agents that report
their state to herdr (and tools written for herdr) work inside a TUIOS pane.
It never listens on herdr's own socket, so a real herdr on the same machine is
untouched. The Nestlo herdr plugin and `nestlo-herdr` talk to herdr's server,
not to TUIOS; for TUIOS use `nestlo-tuios` and the bridge below.

## Enable

```nix
nestlo.runtime = { enable = true; operators = [ "alice" ]; };

nestlo.tuios = {
  enable = true;

  settings.appearance.theme = "dracula";          # any config.toml key

  hooks.after-agent-state = [ "/run/current-system/sw/bin/logger -t tuios \"$TUIOS_AGENT_STATE\"" ];

  layouts.dev.windows = [
    { name = "shell"; }
    { name = "logs"; command = [ "journalctl" "-f" ]; }
  ];

  integrations = [ "claude-code" "codex" ];       # opt-in, edits the agents' settings
  mcp.enable = true;
};
```

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Install tuios and set everything below up |
| `package` | `pkgs.nestlo.tuios` | The tuios package |
| `users` | `nestlo.runtime.operators` that exist | Users who get a daemon and a bridge |
| `includeAgentUser` | `nestlo.runtime.enable` | Also run a sandboxed daemon for `nestlo-agent` |
| `settings` | `{ }` | Freeform `config.toml` contents |
| `agents.permissions.mode` / `grants` | `strict` / `[ read write fan ]` | What a pane may do through tuios |
| `hooks` | `{ }` | Event name to list of shell commands |
| `layouts.<name>` | `{ }` | `{ users; cwd; windows = [ { name; command; cwd; } ]; }` |
| `integrations` | `[ ]` | Harnesses for `tuios integration install` |
| `mcp.enable` / `mcp.scope` | `false` / `own` | Register `tuios mcp` (read-only) in `nestlo.mcp-registry` |
| `ssh.enable` / `listen` / `port` / `authorizedKeys` / `user` | off / `127.0.0.1` / 2222 / `[ ]` / first of `users` | SSH server |
| `web.enable` / `listen` / `port` / `passwordFile` / `tls.certFile` / `tls.keyFile` / `readOnly` / `user` | off / `127.0.0.1` / 7681 / none / none / none / `false` / `ssh.user` | Web terminal |
| `monitor.enable` | `true` | The bridge unit per user |
| `monitor.metrics.enable` / `basePort` | on / 9985 | Loopback exporter; each user takes the next port |
| `monitor.audit.enable` / `commandLines` | on / `false` | `terminal.tuios` audit events (needs `nestlo.audit`); put command lines in them |
| `monitor.notifyNeedsInput` / `notifyCommand` / `graceSeconds` | on / `nestlo-notify test` / 15 | Notification when an agent waits for input |

## Using it

TUIOS finds its daemon through `XDG_RUNTIME_DIR`. The Nestlo daemon of a user
lives in its own directory, `/run/nestlo-tuios-<user>` (mode 0700, with the
saved sessions in `/var/lib/nestlo-tuios-<user>`), so that it exists at boot
without a login session. A plain `tuios` in a login shell reaches a different
daemon, `/run/user/<uid>`. Use the helper, which sets the variables:

```bash
nestlo-tuios                         # your TUIOS (a session on your daemon)
nestlo-tuios new ci --detach         # any tuios command
nestlo-tuios ls
nestlo-tuios --user nestlo-agent attach   # operators: the agent user's daemon (sudo)
```

Inside a pane every `tuios` command already reaches the right daemon: the
panes inherit the daemon's environment (`HOME`, `SHELL`, `XDG_*`, and a `PATH`
of the system profile, so all installed agents are found).

`tuios --skill` prints the agent skill embedded in the binary (how an agent
drives TUIOS from a pane: addressing, state reports, the inbox, fan-out);
`tuios --skill all` the complete text.

## Config, grants and hooks

`settings`, `agents.permissions` and `hooks` are rendered to
`/etc/xdg/tuios/config.toml`. TUIOS looks in `~/.config/tuios/` first and then
in `$XDG_CONFIG_DIRS` (`/etc/xdg`), so the declared file applies to every user
who has no file of their own; a user's file replaces it as a whole. The file
is in the Nix store: do not put secrets in `settings`.

For the agent user the daemon sees `/etc/xdg/tuios` mounted read-only at
`~/.config/tuios`, because a process in a pane can write its own
`config.toml` otherwise (and TUIOS applies a change that gives panes more
rights only on `tuios config apply` or restart, but a hostile file should not
be there at all).

**Grants.** Under TUIOS's own default (`open`) every pane holds `admin`.
Nestlo sets `strict` with `read`, `write`, `fan`: a process in a pane may read
its session and fan group, type into panes of its own session and start agents
in its group, and report about itself, but may not use `run-command`, answer
prompts or approvals (`respond`), or change other sessions. Add `respond` only
for a pane that is meant to approve for another. The `admin` grant is
everything else.

**Hooks** are shell commands (`sh -c`) that the daemon runs on events, with
`TUIOS_*` variables, whether or not a client is attached
(`tuios list-hooks` shows what ran). They run as the user with the daemon's
environment: use full paths. The daemon reads hooks only when it starts.

**Applying changes.** A rebuild never restarts a daemon (`restartIfChanged =
false`): that would end the shells and the agents in the panes. The unit is
reloaded instead (`tuios config apply`), which applies changed settings such
as grants and notification targets. Changed hooks, a new package or a new
environment need `systemctl restart nestlo-tuios-<user>`; saved sessions come
back with fresh shells in the same directories, and an agent whose harness
reported its conversation id (see `integrations`) is offered a resume.

## Layouts

```nix
nestlo.tuios.layouts.dev = {
  cwd = "/home/alice/src/app";      # default: home, the workspace root for the agent user
  windows = [
    { name = "shell"; }
    { name = "tests"; command = [ "cargo" "watch" "-x" "test" ]; cwd = "/home/alice/src/app/tests"; }
  ];
};
```

`nestlo-tuios-layouts-<user>` runs after the daemon: `tuios new <name>
--detach`, `tuios new-window` per window (the argv runs directly, with no
shell), then closes the session's initial shell. A step that fails fails the
unit (it retries every ten seconds). A session that exists already, running or
restored from saved state, is left as it is.

Layouts are not tape scripts. `tuios tape exec` plays a tape in an attached
client, and a headless daemon has none (it answers "tape scripts need an
attached client"), so a boot-time unit cannot use it. Use `tuios tape exec`
from an attached session, or `tuios layout export`, for tapes.

## Bridge

`nestlo-tuios-bridge-<user>` (`nestlo-tuios-bridge`, services/nestlo_services/
tuios_bridge.py) follows `tuios subscribe` as the user, reconnects with
`--after-seq` / `--boot-id` after a break, and:

- **Audit.** For `nestlo.audit`: one `terminal.tuios` event per window created
  or closed, command finished (exit code and duration; the command line only
  with `monitor.audit.commandLines`, and only for shells with OSC 133 marks),
  agent state change (`state`, `previous`) and session created or closed. The
  event kind is in `data.event`, the user in `actor`. Text that comes from
  TUIOS is stripped of control characters and cut. The audit writer's
  `nestlo-audit` group is added to the unit.
- **Notification.** When an agent has been on `needs_input` for
  `graceSeconds`, `nestlo-notify test <message>` runs once per wait (needs
  `nestlo.notifications.enable`; the sending runs as the monitored user, so
  that user must read the webhook files, see the herdr notes).
- **Metrics** on `127.0.0.1:<9985 + index>` and the Prometheus job
  `nestlo-tuios` when `nestlo.observability` is on:

```
nestlo_tuios_up{user}                                    1 while the event stream is connected
nestlo_tuios_agents{user,state}                          agent panes per state
nestlo_tuios_events_total{user,type}                     events handled
nestlo_tuios_needs_input_notifications_total{user}       notifications sent
nestlo_tuios_stream_gaps_total{user}                     gaps the daemon reported
nestlo_tuios_stream_reconnects_total{user}
nestlo_tuios_audit_dropped_total{user}                   audit events lost (writer unreachable)
```

Labels carry only user names, event types and the fixed state names.

## Agent integrations and MCP

`integrations = [ "claude-code" ... ]` runs `tuios integration install
<harness> --command <store path of tuios>` for every user and the agent user.
That writes hook entries into the harness's own settings (for Claude Code
`~/.claude/settings.json`) so it reports its state and conversation id to the
pane it runs in; without them TUIOS relies on screen rules. Valid harnesses:
`claude-code codex gemini-cli opencode amp antigravity copilot crush
cursor-agent devin droid grok hermes kilo kimi omp pi qoder qwen`. The `antigravity`
harness is Antigravity CLI (`agy`; configuration in `~/.gemini/config`, which Nestlo
creates before installing the integration); `gemini-cli` is the deprecated Gemini CLI. TUIOS
leaves entries it did not write alone. It is opt-in because it edits files the
agent's own software reads.

`mcp.enable = true` adds `tuios mcp --scope own` as server `tuios` to
`/etc/nestlo/mcp-tools.json`. The tools read panes and agent state, wait on
panes, report the caller's own state and send agent mail; none types into a
pane (`--write` is not used). Scope `own` reaches only the session of the pane
the harness runs in and its fan group, so a harness outside every pane reaches
nothing. `scope = "all"` reaches every session of the daemon the server finds
(the registry entry points it at the agent user's).

## SSH and web access

```nix
nestlo.tuios.ssh = {
  enable = true;
  listen = "0.0.0.0";                         # default 127.0.0.1
  authorizedKeys = [ "ssh-ed25519 AAAA... alice@laptop" ];
  user = "alice";                             # the shell every connection gets
};
nestlo.tuios.web = {
  enable = true;
  user = "alice";
  passwordFile = "/run/secrets/tuios-web";    # first line; browsers log in as `tuios`
  listen = "0.0.0.0";                         # needs passwordFile and tls
  tls = { certFile = "/run/secrets/tuios.crt"; keyFile = "/run/secrets/tuios.key"; };
};
```

- **SSH.** `tuios ssh --host <listen> --port <port> --authorized-keys <file>
  --key-path /var/lib/nestlo-tuios-ssh/host_key`, as `ssh.user`. Public keys
  only; `--no-auth` is never used. The module refuses an empty
  `authorizedKeys` and keys with options (`command=`, `from=`, `restrict`),
  which TUIOS cannot apply and refuses. The firewall is opened only for a
  `listen` address that is not loopback. This is a TUIOS session, not a login
  shell: it needs a terminal (`ssh -t`), and the user name picks the session
  (`ssh -t alice@host` attaches to the session `alice`; `tuios`, `root` and
  `anonymous` get the default).
- **Web.** `tuios-web --host <listen> --port <port> --password-file
  $CREDENTIALS_DIRECTORY/password`, as `web.user`; the password file is handed
  over as a systemd credential, so it can be root-only. Browsers log in as the
  user `tuios`. Without `passwordFile` a loopback server lets every user on the
  machine in (an evaluation warning says so). A non-loopback `listen` needs
  `passwordFile` and `tls`; the module asserts it.

## Security model

- **Whoever reaches the daemon, SSH server or web terminal has a shell as the
  user they run as.** The daemon socket is `0700` and has no application-level
  authentication; the SSH server and the web terminal are doors to the same
  shells. Treat `ssh.authorizedKeys` and the web password like a login for
  `ssh.user` / `web.user`. Do not run them as the agent user unless you mean to
  give those keys the agent's account (an evaluation warning says so).
- Keep sshd (or the [Cloud](cloud.md) lobby) as the front door: it has the
  audit trail, rate limits and key management you already run. Use the
  loopback defaults and reach `tuios ssh` / `tuios-web` through a tunnel or a
  reverse proxy you control when you want them, and prefer
  `nestlo-tuios --user <user>` over SSH for operators.
- Panes are the attack surface: a process in a pane talks to the daemon. The
  `strict` grants limit what it can do through tuios; they do not sandbox the
  process (use the sandbox of `nestlo spawn`, or run agents in the agent user's
  daemon, which is confined like a `nestlo spawn` unit: strict file system, only
  the agent home and the workspaces writable, no capabilities, no new
  privileges, private `/tmp`).
- The MCP server is read-only and scoped; `--write` is not offered by the
  module. `tuios mcp --write` types into panes, which is code execution in a
  shell; enable it by hand only for a harness you trust.
- Hooks, `settings` and the layouts are in the world-readable Nix store.
- `integrations` and `mcp` change what agents run; both are off by default.
- TUIOS's `[hosts]` (links to other machines) and `[notify]` (push) tables are
  yours to set through `settings`; links use ssh with your keys.

## Limits

- Under the default `restartIfChanged = false` a TUIOS upgrade is applied at
  the next manual restart of the daemon units (which ends the shells; sessions
  come back from saved state).
- Saved sessions restore layout and working directories, not running programs.
- Gateway variables (`ANTHROPIC_BASE_URL` with an agent token) are per agent
  and are not set by this module; agents started with `nestlo spawn` keep
  theirs.
- Events that happen while the bridge is down are replayed when the daemon
  still holds them (its last 4096); otherwise a `gap` is counted in
  `nestlo_tuios_stream_gaps_total` and the agent counts start again from the
  next state report.
- Tests: the VM test `tuios` (`nix build .#checks.x86_64-linux.tuios`) covers
  the daemons, layouts, the CLI round trip, grants, the bridge, SSH and web;
  `services/tests/test_tuios_bridge.py` covers the bridge against canned event
  lines.
