# OpenClaw

[OpenClaw](https://github.com/openclaw/openclaw) is a Node daemon that connects chat channels (Telegram, Slack, Discord, WhatsApp, ...) to an LLM agent with skills, cron and memory. The `agentos.openclaw` module (`modules/openclaw/`) runs it as a hardened systemd service and connects it to AgentOS in two directions:

```
 chat user ──DM (allowlist)──▶ OpenClaw (user openclaw, 127.0.0.1:18789)
                                   │ LLM calls                          │ exec: agentos-task-chat
                                   ▼                                    ▼
          model gateway  /agent/openclaw:<token>/anthropic      task bridge (socket, group openclaw)
          (real key injected, daily budget for "openclaw")                │ allowlisted agent + workspace,
                                                                          │ fixed budget and timeout
                                                                          ▼
                                                              orchestrator ──▶ sandboxed coding agents
```

nixpkgs has the package (`pkgs.openclaw`) but no NixOS module; this one is AgentOS's own.

## Enabling

```nix
agentos = {
  runtime.enable = true;
  networking = {
    enable = true;                       # the model gateway; holds the real API key
    providers.anthropic.keyFile = "/run/secrets/ANTHROPIC_API_KEY";
  };
  orchestration.enable = true;           # only needed for `workspaces` below

  openclaw = {
    enable = true;
    acceptPromptInjectionRisk = true;    # required, see "Security model"
    budgetUsd = 5;                       # per day, for the LLM calls of OpenClaw itself
    model = "claude-sonnet-5-5";

    channels.telegram = {
      enable = true;
      tokenFile = "/run/secrets/telegram-bot-token";
      allowFrom = [ "123456789" ];       # numeric Telegram user ids
    };

    # Let OpenClaw hand work to coding agents (omit both to make it a plain chat bot)
    agents = [ "claude" ];
    workspaces = [ "main-project" ];
  };
};
```

| Option | Default | Meaning |
|:---|:---|:---|
| `enable` | `false` | Run the service. Nothing else is on by default. |
| `acceptPromptInjectionRisk` | `false` | Must be `true`; nixpkgs marks the package insecure (see below). |
| `package` | `pkgs.openclaw` | The package, with nixpkgs' insecure flag cleared behind the option above. |
| `port` | `18789` | Gateway and Control UI port. Always bound to loopback. |
| `model` | `claude-sonnet-5-5` | Model id sent through the AgentOS gateway. |
| `budgetUsd` | `5` | Daily budget (UTC day) of the gateway agent id `openclaw`, set on every start. |
| `memoryMax` | `2G` | `MemoryMax` of the service. |
| `channels.telegram.{enable,tokenFile,allowFrom}` | off | See [Channels](#channels). |
| `channels.slack.{enable,tokenFile,appTokenFile,allowFrom}` | off | See [Channels](#channels). |
| `agents` | `["claude"]` | Agents OpenClaw may start tasks with (each needs `agentos.orchestration.taskCommands`). |
| `workspaces` | `[]` | Workspaces OpenClaw may start tasks in. Empty disables the task bridge, the skill and the exec tool. |
| `taskBudgetUsd` / `taskTimeoutSec` / `maxActiveTasks` | `2` / `1800` / `3` | Fixed limits for the tasks it submits. |

The service is `openclaw.service`; the state (config copy, tokens, workspace, sessions, memory) is in `/var/lib/openclaw`. Operators run the CLI as the service user, with the service's environment, through `sudo agentos-openclaw <args>`, for example:

```
sudo agentos-openclaw config validate
sudo agentos-openclaw doctor --non-interactive
sudo agentos-openclaw channels status
```

The Control UI is on `http://127.0.0.1:18789/`. It asks for the gateway token, which is generated on first start into `/var/lib/openclaw/gateway-token` (read it as root). To reach it from another machine use an SSH tunnel (`ssh -L 18789:127.0.0.1:18789 host`); the module never opens the port.

## How it is wired

- **Config.** `openclaw.json` is rendered from a Nix attrset and copied (not linked) to `/var/lib/openclaw/.openclaw/openclaw.json` by an `ExecStartPre` on every start, because OpenClaw rewrites its config with atomic renames. The schema is strict (an unknown key stops the gateway), so every key was checked against the package's own schema. The file only contains `${VAR}` references; the start script fills them from files in the state directory and from systemd credentials.
- **LLM access.** The provider `agentos` points at `http://127.0.0.1:8080/agent/openclaw:<token>/anthropic` with the placeholder key `agentos-managed`. A root `ExecStartPre` generates the token on first start, registers its SHA-256 with the gateway admin socket (`PUT /_agentos/agents/openclaw`, the same call `agentos spawn` makes) and sets the budget (`PUT /_agentos/budget/openclaw`). The gateway injects the real key, meters and prices every call, applies routing, loop detection and the circuit breaker, and answers `402` once the daily budget is used up. OpenClaw never sees the provider key. This needs `agentos.networking` with a managed key; without one the placeholder is forwarded as is and the provider refuses it.
- **Tasks.** The skill `agentos` (vendored in the Nix store, installed root-owned and read-only into the workspace) tells the model to run `agentos-task-chat submit|status|list|cancel`. See below.

## Channels

Only Telegram and Slack are wired (their plugins ship with the package). Each is off by default and, when enabled, is configured as an allowlist:

- `dmPolicy = "allowlist"` with your `allowFrom` ids: direct messages from anyone else are ignored. There is no pairing flow and `allowFrom` must not be empty.
- `groupPolicy = "disabled"`: group chats and channels are ignored.
- `configWrites = false`: nobody can change the config from chat. `/config`, `/plugins`, `/mcp`, `/debug`, `!` shell and `/restart` are off globally.
- `session.dmScope = "per-channel-peer"`: every sender has their own conversation.

Tokens come from files outside the Nix store (sops-nix, agenix, a root-owned file) through systemd `LoadCredential`, and reach OpenClaw as `TELEGRAM_BOT_TOKEN`, `SLACK_BOT_TOKEN` and `SLACK_APP_TOKEN` in its environment.

**Telegram:** create a bot with @BotFather, put the token in `tokenFile`, and list the numeric user ids (ask @userinfobot) in `allowFrom`.
**Slack:** create an app with Socket Mode; the bot token (`xoxb-...`) goes in `tokenFile`, the app-level token (`xapp-...`) in `appTokenFile`, member ids (`U...`) in `allowFrom`.

Other channels (Discord, WhatsApp, ...) are not supported by the module. They would need their own allowlist handling; do not add them to the generated config by hand without it.

## Running AgentOS tasks from chat

With `workspaces` set, OpenClaw can start coding agents, but only through one command, `agentos-task-chat`:

```
agentos-task-chat submit --agent <agent> --workspace <workspace> --prompt "<text>"
agentos-task-chat status <task-id>
agentos-task-chat list
agentos-task-chat cancel <task-id>
```

The orchestrator socket is group `agentos`, which is also the group of the gateway admin socket (it can register tokens for any agent, set budgets and read recordings). Giving the `openclaw` user that group would hand all of it to a chat session, so it does not have it. Instead a small service, `agentos-openclaw-bridge` (user `openclaw-bridge`, group `agentos` only for itself, with `/run/agentos-gateway`, `/run/redis-agentos` and `/var/lib/agentos` hidden), listens on `/run/agentos-openclaw/bridge.sock` (group `openclaw`) and enforces the policy server-side:

- the agent and workspace must be in `agents` and `workspaces` (names only, no paths);
- the only fields accepted are `agent`, `workspace` and `prompt`; budget, timeout and `origin = "openclaw"` are set by the bridge, and `--after`, `--swarm`, `--group`, `--isolate` do not exist;
- at most `maxActiveTasks` queued or running tasks;
- `status`, `list` and `cancel` only see tasks with `origin = "openclaw"`: OpenClaw cannot read or cancel operators' or the scheduler's tasks;
- nothing but those four endpoints is forwarded.

The tasks themselves run as any orchestrator task does: sandboxed, on their own branch `agent/<task-id>`, metered and budgeted by the gateway under their own id. `agentos-task show <id>` and `agentos list` show them to operators.

OpenClaw's exec tool is restricted to that wrapper: `tools.exec.security = "allowlist"`, `ask = "off"`, `askFallback = "deny"`, `safeBins = []`, `strictInlineEval = true`, and `~/.openclaw/exec-approvals.json` allowlists exactly the store path of `agentos-task-chat`. Anything else is denied without a prompt.

## Security model

- **Loopback only.** `gateway.bind = "loopback"`, token auth, `tailscale.mode = "off"`, mDNS discovery off; the service may only open `AF_UNIX`, `AF_INET`, `AF_INET6` sockets and nothing in the module opens a firewall port. The channels connect outwards. The test checks the listener addresses.
- **No self-modification, no ClawHub.** `OPENCLAW_NIX_MODE=1` (no auto-installs), `OPENCLAW_NO_AUTO_UPDATE=1`, `update.checkOnStart = false`, `update.auto.enabled = false`, `models.pricing.enabled = false` (no catalog fetches). The only skill the agent may use is the vendored `agentos` one (`agents.defaults.skills`), the skill directory is root-owned and read-only, and the agent has no file-write tools, no `gateway` tool, no browser, web, canvas, node or cron tools, no sub-agents and no elevated mode. OpenClaw's config has no switch for ClawHub itself (`openclaw skills install`, `openclaw plugins install clawhub:...`); the controls are that these are CLI commands that need a shell, which only operators have, `/plugins` and `/config` are off, and exec is allowlisted. Operators running `sudo agentos-openclaw skills install ...` bypass that on purpose; third-party skills and plugins are untrusted code, do not install them.
- **Allowlisted DMs.** Only the ids you list can talk to the bot; groups are off.
- **Systemd hardening.** `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `RestrictAddressFamilies`, `SystemCallFilter=@system-service`, empty `CapabilityBoundingSet`, `MemoryMax`, no namespaces, writes only to `/var/lib/openclaw`. The gateway has no `MemoryDenyWriteExecute` (V8 needs executable memory).
- **Secrets.** Provider keys stay in the model gateway. The `openclaw` agent token (which only works against the gateway, for agent id `openclaw`, within its budget), the Control UI token and the channel tokens are files outside the store (`0400` in the state directory, systemd credentials) and are read into the process environment. A process that can run code as `openclaw` can read them, which is why the model gets no shell beyond the wrapper.
- **Budget.** `budgetUsd` caps what OpenClaw's own LLM use can cost per day; each task it submits has `taskBudgetUsd` on top, and at most `maxActiveTasks` run at once. Heartbeats (periodic background model calls) are off.

### Prompt injection

This is the risk the module cannot remove, and the reason nixpkgs marks the package insecure and the module asks you to acknowledge it. The model reads text it does not control (chat messages, quoted replies, task output) and can act on it. What is limited here is what it can do when that happens: it can start tasks in the listed workspaces with the listed agents, within the task budget and the cap, and it can talk to the people on the allowlist. It cannot touch the host, other workspaces, other agents' tasks, the config, or the provider key. A task, however, is a coding agent with write access to its workspace on its own branch: treat what it produces like any untrusted contribution, review the branch before merging, and do not list a workspace whose branches get deployed automatically. Keep `allowFrom` to people you trust with that.

### CVE-2026-25253

CVE-2026-25253 is an OpenClaw vulnerability that is fixed in the version nixpkgs ships (2026.5.7). The module relies on that fix and adds no mitigation of its own, beyond the Control UI being loopback-only and token-protected. Do not point `package` at an older release. (The details of the CVE are not reproduced here; see the OpenClaw advisory.)

## Testing

`nix build .#checks.x86_64-linux.openclaw` boots a VM with the real package and checks: loopback-only listening; the config being a copy that passes `openclaw config validate` and holds no secret; the service sandbox; the gateway registration (the token reaches a mock LLM through the model gateway with the real key injected, a wrong token is refused, the budget is enforced); the exec allowlist and read-only skill; and `agentos-task-chat` creating a task through the bridge, the bridge's refusals, the cap, task isolation between submitters, and the `openclaw` user having no path to the orchestrator or admin sockets. It does not drive a chat or a real model.
