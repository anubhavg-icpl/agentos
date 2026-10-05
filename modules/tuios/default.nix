# Nestlo TUIOS module
#
# TUIOS (https://github.com/Gaurav-Gosain/tuios, MIT) is a terminal
# multiplexer and window manager for coding agents: a daemon keeps sessions
# across detach and reboot, panes report agent state (working / needs input /
# done), there is an inbox for approvals, `fan` runs agents in git worktrees,
# a JSON protocol and event stream on a 0700 socket, an MCP server, an SSH
# server and a web terminal. This module makes it part of Nestlo:
#
#   - installs tuios, tuios-web and the `nestlo-tuios` helper
#   - declarative config: a freeform TOML `settings`, strict pane grants by
#     default, hooks, in /etc/xdg/tuios/config.toml
#   - a daemon per user (nestlo-tuios-<user>), sandboxed for the agent user
#   - a bridge per user (nestlo-tuios-bridge-<user>): audit events, a
#     notification when an agent waits for input, nestlo_tuios_* metrics
#   - declared session layouts, applied headless by a oneshot
#   - opt-in: agent integrations (hooks), the MCP server in the Nestlo tool
#     registry, an SSH server and a web terminal
#
# The daemon, the SSH server and the web terminal all give a full shell as
# the user they run as. Read docs/tuios.md before enabling ssh or web.
{ config, pkgs, lib, utils, ... }:

let
  cfg = config.nestlo.tuios;
  rt = config.nestlo.runtime;
  agentUser = "nestlo-agent";

  tuios = cfg.package;
  services = pkgs.nestlo.services;
  toml = pkgs.formats.toml { };

  allUsers = lib.unique (cfg.users ++ lib.optional cfg.includeAgentUser agentUser);
  homeOf = u: if u == agentUser then rt.agentHome else config.users.users.${u}.home;
  shellOf = u: utils.toShellPath (if u == agentUser then pkgs.bashInteractive else config.users.users.${u}.shell);
  portOf = u: cfg.monitor.metrics.basePort + (lib.lists.findFirstIndex (x: x == u) 0 allUsers);

  # One directory each for the socket (RuntimeDirectory) and the saved
  # sessions (StateDirectory); flat names, so that systemd owns exactly them
  runName = u: "nestlo-tuios-${u}";
  runDir = u: "/run/${runName u}";
  stateDir = u: "/var/lib/${runName u}";

  isLoopback = h: h == "localhost" || h == "::1" || lib.hasPrefix "127." h;

  events = [
    "after-new-window" "after-close-window" "after-focus-change" "after-workspace-switch"
    "after-agent-state" "after-command-finished" "after-attach" "after-detach"
    "after-resize" "after-layout-change"
  ];
  harnesses = [
    "claude-code" "codex" "gemini-cli" "opencode" "amp" "antigravity" "copilot" "crush"
    "cursor-agent" "devin" "droid" "grok" "hermes" "kilo" "kimi" "omp" "pi" "qoder" "qwen"
  ];
  grants = [ "read" "write" "fan" "respond" "admin" ];

  # config.toml: the freeform settings, with the options below on top
  finalSettings = lib.recursiveUpdate cfg.settings (
    {
      agents.permissions = {
        inherit (cfg.agents.permissions) mode grants;
      };
    }
    // lib.optionalAttrs (cfg.hooks != { }) { hooks = cfg.hooks; }
  );
  settingsFile = toml.generate "tuios-config.toml" finalSettings;

  cli = pkgs.writeShellApplication {
    name = "nestlo-tuios";
    runtimeInputs = [ pkgs.coreutils pkgs.getent pkgs.util-linux ];
    text = ''
      # nestlo-tuios [--user USER] [TUIOS ARGS...]
      # Runs tuios against the daemon nestlo.tuios manages for USER (default:
      # you). A plain `tuios` in a login shell reaches a different daemon
      # (under /run/user/<uid>); this one lives in /run/nestlo-tuios-<user>.
      me=$(id -un)
      user=$me
      if [ "''${1:-}" = "--user" ]; then
        user=''${2:?usage: nestlo-tuios [--user USER] [TUIOS ARGS...]}
        shift 2
      fi
      case "$user" in
        "" | *[!a-z0-9_.-]*) echo "nestlo-tuios: invalid user name '$user'" >&2; exit 2 ;;
      esac
      home=$(getent passwd "$user" | cut -d: -f6)
      if [ -z "$home" ]; then
        echo "nestlo-tuios: unknown user $user" >&2
        exit 2
      fi
      run="/run/nestlo-tuios-$user"
      state="/var/lib/nestlo-tuios-$user"
      if [ "$user" = "$me" ]; then
        exec env XDG_RUNTIME_DIR="$run" XDG_STATE_HOME="$state" ${tuios}/bin/tuios "$@"
      fi
      if [ "$(id -u)" = 0 ]; then
        exec runuser -u "$user" -- env HOME="$home" XDG_RUNTIME_DIR="$run" XDG_STATE_HOME="$state" ${tuios}/bin/tuios "$@"
      fi
      exec sudo -n -u "$user" env HOME="$home" XDG_RUNTIME_DIR="$run" XDG_STATE_HOME="$state" ${tuios}/bin/tuios "$@"
    '';
  };

  bridgeCli = pkgs.runCommand "nestlo-tuios-bridge-cli" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    makeWrapper ${services}/bin/nestlo-tuios-bridge $out/bin/nestlo-tuios-bridge \
      --set-default NESTLO_TUIOS_BIN ${tuios}/bin/tuios
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "tuios";
    desktopName = "TUIOS";
    comment = "Terminal multiplexer and window manager for coding agents";
    exec = "${pkgs.alacritty}/bin/alacritty --title TUIOS -e ${cli}/bin/nestlo-tuios";
    categories = [ "Development" "System" ];
  };

  # What every tuios process of a user needs to find the same daemon, and
  # what the panes inherit: the agents installed on the system, not a
  # service-sized PATH
  envOf = u: {
    HOME = homeOf u;
    USER = u;
    LOGNAME = u;
    SHELL = shellOf u;
    PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin";
    XDG_RUNTIME_DIR = runDir u;
    XDG_STATE_HOME = stateDir u;
    COLORTERM = "truecolor";
  } // lib.optionalAttrs (config.i18n.defaultLocale != null) { LANG = config.i18n.defaultLocale; };

  # What the agent user runs here is as contained as in `nestlo spawn`
  # (sandbox): the workspaces and its own home are the only writable paths
  agentHardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ReadWritePaths = [ "-${rt.agentHome}" "-${rt.workspaceRoot}" ];
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
  };

  # Auxiliary processes (they do not run the user's panes)
  lightHardening = u: {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = if u == agentUser then true else "read-only";
    ReadWritePaths = "-${homeOf u}";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    CapabilityBoundingSet = "";
  };

  # The socket and the saved sessions of a user's daemon; the other units of
  # the user declare the runtime directory too (and keep it when they stop)
  dirs = u: {
    RuntimeDirectory = runName u;
    RuntimeDirectoryMode = "0700";
    RuntimeDirectoryPreserve = "yes";
  };

  waitForDaemon = u: pkgs.writeShellScript "nestlo-tuios-wait-${u}" ''
    # `tuios ls` exits 3 while no daemon answers
    for _ in $(${pkgs.coreutils}/bin/seq 1 150); do
      if ${tuios}/bin/tuios ls >/dev/null 2>&1; then exit 0; fi
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    echo "tuios daemon did not come up" >&2
    exit 1
  '';

  mkDaemon = u: lib.nameValuePair "nestlo-tuios-${u}" {
    description = "TUIOS daemon for ${u}";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    # A rebuild must not kill the agents that live in the panes. A change to
    # config.toml is applied with `tuios config apply` (reload); a new
    # package, new hooks or new environment take effect at the next
    # `systemctl restart`, which ends the panes (sessions come back with fresh
    # shells in the same directories).
    restartIfChanged = false;
    reloadIfChanged = true;
    environment = envOf u;
    serviceConfig = {
      User = u;
      WorkingDirectory = homeOf u;
      ExecStart = "${tuios}/bin/tuios daemon";
      ExecStartPost = waitForDaemon u;
      ExecReload = "${tuios}/bin/tuios config apply";
      # kill-server saves every session while the shells are alive and
      # returns once the socket is gone
      ExecStop = "${tuios}/bin/tuios kill-server";
      # SIGTERM only to the daemon, which saves its sessions; then the rest
      KillMode = "mixed";
      Restart = "on-failure";
      RestartSec = 3;
      TimeoutStartSec = 60;
      TimeoutStopSec = 30;
      UMask = "0002";
      StateDirectory = runName u;
      StateDirectoryMode = "0700";
    } // dirs u // lib.optionalAttrs (u == agentUser) (agentHardening // {
      # The declared config, read-only: a process in a pane could otherwise
      # write ~/.config/tuios/config.toml, which wins over /etc/xdg
      BindReadOnlyPaths = [ "/etc/xdg/tuios:${rt.agentHome}/.config/tuios" ];
    });
  };

  auditOn = cfg.monitor.audit.enable && config.nestlo.audit.enable;
  notifyOn = cfg.monitor.notifyNeedsInput && config.nestlo.notifications.enable;

  mkBridge = u: lib.nameValuePair "nestlo-tuios-bridge-${u}" {
    description = "Nestlo TUIOS bridge for ${u} (audit events, needs-input notifications, metrics)";
    wantedBy = [ "multi-user.target" ];
    after = [ "nestlo-tuios-${u}.service" ] ++ lib.optional auditOn "nestlo-audit.service";
    wants = [ "nestlo-tuios-${u}.service" ];
    environment = {
      inherit (envOf u) HOME XDG_RUNTIME_DIR PATH;
    };
    serviceConfig = {
      User = u;
      ExecStart = lib.escapeShellArgs ([
        "${bridgeCli}/bin/nestlo-tuios-bridge"
        "--listen"
        "127.0.0.1"
        "--grace"
        (toString cfg.monitor.graceSeconds)
      ] ++ lib.optionals cfg.monitor.metrics.enable [ "--port" (toString (portOf u)) ]
      ++ lib.optionals auditOn [ "--audit-socket" "/run/nestlo-audit/audit.sock" ]
      ++ lib.optional (auditOn && cfg.monitor.audit.commandLines) "--command-lines"
      ++ lib.optionals notifyOn [ "--notify-json" (builtins.toJSON cfg.monitor.notifyCommand) ]);
      Restart = "always";
      RestartSec = 5;
      SupplementaryGroups = lib.optional auditOn "nestlo-audit";
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    } // lightHardening u;
  };

  mkIntegrations = u: lib.nameValuePair "nestlo-tuios-integrations-${u}" {
    description = "Install the TUIOS agent integrations for ${u}";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    restartTriggers = [ (builtins.toJSON cfg.integrations) tuios ];
    environment = { inherit (envOf u) HOME PATH; };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = u;
      # The hooks run the tuios of this system by its store path: the
      # agents' PATH need not contain it
      ExecStart = pkgs.writeShellScript "nestlo-tuios-integrations" ''
        rc=0
        for agent in ${lib.escapeShellArgs cfg.integrations}; do
          ${tuios}/bin/tuios integration install "$agent" --command ${tuios}/bin/tuios \
            || { echo "tuios integration $agent failed" >&2; rc=1; }
        done
        exit $rc
      '';
    } // lightHardening u;
  };

  # ── layouts ────────────────────────────────────────────────────────────
  layoutsOf = u: lib.filterAttrs (_: l: lib.elem u l.users) cfg.layouts;

  layoutScript = u: name: l:
    let
      cwd = if l.cwd != null then l.cwd else if u == agentUser then rt.workspaceRoot else homeOf u;
      winCwd = w: if w.cwd != null then w.cwd else cwd;
      windowCmds = lib.concatMapStringsSep "\n" (w: ''
        tuios new-window -s ${lib.escapeShellArg name} --no-focus --cwd ${lib.escapeShellArg (winCwd w)} \
          ${lib.escapeShellArg w.name}${lib.optionalString (w.command != [ ]) " -- ${lib.escapeShellArgs w.command}"} >/dev/null
      '') l.windows;
    in
    ''
      if tuios ls --json | jq -e --arg n ${lib.escapeShellArg name} 'any(.[]; .name == $n)' >/dev/null; then
        echo "session ${name} exists, leaving it as it is"
      else
        echo "creating session ${name}"
        tuios new ${lib.escapeShellArg name} --detach --cwd ${lib.escapeShellArg cwd} >/dev/null
        ${lib.optionalString (l.windows != [ ]) ''
          initial=$(tuios list-windows -s ${lib.escapeShellArg name} --json | jq -r '.windows[0].window_id')
          ${windowCmds}
          # the shell the session starts with is not part of the layout
          tuios close-window -s ${lib.escapeShellArg name} "$initial" >/dev/null
        ''}
      fi
    '';

  mkLayouts = u: lib.nameValuePair "nestlo-tuios-layouts-${u}" {
    description = "Create the declared TUIOS sessions for ${u}";
    wantedBy = [ "multi-user.target" ];
    after = [ "nestlo-tuios-${u}.service" ];
    requires = [ "nestlo-tuios-${u}.service" ];
    restartTriggers = [ (builtins.toJSON (layoutsOf u)) ];
    environment = { inherit (envOf u) HOME XDG_RUNTIME_DIR XDG_STATE_HOME PATH; };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = u;
      # A failing step fails the unit; the sessions already created stay
      ExecStart = "${pkgs.writeShellApplication {
        name = "nestlo-tuios-layouts-${u}";
        runtimeInputs = [ tuios pkgs.jq ];
        text = lib.concatStringsSep "\n" (lib.mapAttrsToList (layoutScript u) (layoutsOf u));
      }}/bin/nestlo-tuios-layouts-${u}";
      Restart = "on-failure";
      RestartSec = 10;
    } // lightHardening u;
  };

  layoutUsers = lib.filter (u: layoutsOf u != { }) allUsers;

  # ── ssh and web ────────────────────────────────────────────────────────
  authorizedKeysFile = pkgs.writeText "nestlo-tuios-authorized_keys"
    (lib.concatStringsSep "\n" cfg.ssh.authorizedKeys + "\n");
  keyRe = "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/=]+( .*)?";

  sshUnit = {
    description = "TUIOS SSH server (a full shell as ${cfg.ssh.user}, public keys only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "nestlo-tuios-${cfg.ssh.user}.service" ];
    wants = [ "nestlo-tuios-${cfg.ssh.user}.service" ];
    environment = envOf cfg.ssh.user;
    serviceConfig = {
      User = cfg.ssh.user;
      WorkingDirectory = homeOf cfg.ssh.user;
      ExecStart = lib.escapeShellArgs [
        "${tuios}/bin/tuios"
        "ssh"
        "--host"
        cfg.ssh.listen
        "--port"
        (toString cfg.ssh.port)
        "--authorized-keys"
        "${authorizedKeysFile}"
        "--key-path"
        "/var/lib/nestlo-tuios-ssh/host_key"
      ];
      Restart = "on-failure";
      RestartSec = 5;
      # the host key, and the user's saved sessions (the client side may log there)
      StateDirectory = [ "nestlo-tuios-ssh" (runName cfg.ssh.user) ];
      StateDirectoryMode = "0700";
      UMask = "0077";
    } // dirs cfg.ssh.user
    // (if cfg.ssh.user == agentUser then agentHardening else lightHardening cfg.ssh.user);
  };

  webUnit = {
    description = "TUIOS web terminal (a full shell as ${cfg.web.user}, password required)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "nestlo-tuios-${cfg.web.user}.service" ];
    wants = [ "nestlo-tuios-${cfg.web.user}.service" ];
    environment = envOf cfg.web.user;
    serviceConfig = {
      User = cfg.web.user;
      WorkingDirectory = homeOf cfg.web.user;
      LoadCredential = lib.optional (cfg.web.passwordFile != null) "password:${toString cfg.web.passwordFile}"
        ++ lib.optionals (cfg.web.tls.certFile != null) [
        "tls-cert:${toString cfg.web.tls.certFile}"
        "tls-key:${toString cfg.web.tls.keyFile}"
      ];
      # %d is the credentials directory
      ExecStart = lib.escapeShellArgs ([
        "${tuios}/bin/tuios-web"
        "--host"
        cfg.web.listen
        "--port"
        (toString cfg.web.port)
      ] ++ lib.optionals (cfg.web.passwordFile != null) [ "--password-file" "%d/password" ]
      ++ lib.optionals (cfg.web.tls.certFile != null) [ "--cert" "%d/tls-cert" "--key" "%d/tls-key" ]
      ++ lib.optional cfg.web.readOnly "--read-only");
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = runName cfg.web.user;
      StateDirectoryMode = "0700";
      UMask = "0077";
    } // dirs cfg.web.user
    // (if cfg.web.user == agentUser then agentHardening else lightHardening cfg.web.user);
  };

  mcpEnv = lib.optionalAttrs (cfg.includeAgentUser && cfg.mcp.scope == "all") {
    XDG_RUNTIME_DIR = runDir agentUser;
  };

  userNames = lib.unique (allUsers ++ lib.optional cfg.ssh.enable cfg.ssh.user ++ lib.optional cfg.web.enable cfg.web.user
    ++ lib.concatMap (l: l.users) (lib.attrValues cfg.layouts));
  nameRe = "[A-Za-z0-9][A-Za-z0-9._-]{0,63}";
in
{
  options.nestlo.tuios = {
    enable = lib.mkEnableOption "TUIOS, a terminal multiplexer and window manager for coding agents, with the Nestlo management bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.tuios;
      defaultText = lib.literalExpression "pkgs.nestlo.tuios";
      description = "The tuios package (`tuios` and `tuios-web`), built from source by Nestlo.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.filter (u: config.users.users ? ${u}) rt.operators;
      defaultText = lib.literalExpression "the nestlo.runtime.operators that exist as users";
      example = [ "alice" ];
      description = "Users who get a TUIOS daemon (`nestlo-tuios-<user>`) and a bridge.";
    };

    includeAgentUser = lib.mkOption {
      type = lib.types.bool;
      default = rt.enable;
      defaultText = lib.literalExpression "config.nestlo.runtime.enable";
      description = "Also run a sandboxed TUIOS daemon for the agent user (nestlo-agent).";
    };

    settings = lib.mkOption {
      type = toml.type;
      default = { };
      example = lib.literalExpression ''
        {
          appearance.theme = "dracula";
          notify = { /* see docs/CONFIGURATION.md of tuios */ };
        }
      '';
      description = ''
        Freeform contents of TUIOS's `config.toml`, written to
        `/etc/xdg/tuios/config.toml` for every user (TUIOS searches
        `$XDG_CONFIG_DIRS` after `~/.config`, so a user's own file replaces
        it entirely). `agents.permissions` and `hooks` set by the options
        below win over the same keys here. The file is in the world-readable
        Nix store: no secrets (use `[notify]` providers that read a file, see
        TUIOS's CONFIGURATION.md).
      '';
    };

    agents.permissions = {
      mode = lib.mkOption {
        type = lib.types.enum [ "strict" "open" ];
        default = "strict";
        description = ''
          `[agents.permissions] mode`. Under `strict` a process in a pane holds
          only `grants` (what it may do through the tuios CLI, MCP server and
          socket: read its own session, type into its own panes, start agents
          in its fan group). Under `open`, TUIOS's own default, every pane
          holds `admin`.
        '';
      };
      grants = lib.mkOption {
        type = lib.types.listOf (lib.types.enum grants);
        default = [ "read" "write" "fan" ];
        description = ''
          What a pane holds under `strict`. `respond` lets a pane answer
          prompts and approvals for the person: leave it out unless an agent
          is meant to approve for another. `admin` is everything else.
        '';
      };
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = lib.literalExpression ''{ after-agent-state = [ "/run/current-system/sw/bin/logger -t tuios \"$TUIOS_AGENT_STATE\"" ]; }'';
      description = ''
        The `[hooks]` table: events (${lib.concatStringsSep ", " events}) to
        lists of shell commands (`sh -c`, with `TUIOS_*` variables, see TUIOS's
        HOOKS.md). Hooks the daemon runs get the daemon's environment and fire
        with nobody attached. TUIOS reads hooks only when the daemon starts, so
        a change needs `systemctl restart nestlo-tuios-<user>` (a reload does
        not apply it; a restart ends the panes' processes). Use full paths.
      '';
    };

    layouts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          users = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = allUsers;
            defaultText = lib.literalExpression "users plus the agent user";
            description = "Users who get this session.";
          };
          cwd = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Directory the windows start in (default: the user's home, the workspace root for the agent user).";
          };
          windows = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                name = lib.mkOption {
                  type = lib.types.strMatching nameRe;
                  description = "Window name, to address it with `-w`.";
                };
                command = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "htop" ];
                  description = "argv the window runs, with no shell in between. Empty: the user's shell.";
                };
                cwd = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Directory of this window (default: the layout's).";
                };
              };
            });
            default = [ ];
            description = "Windows of the session, in order.";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          dev = {
            windows = [
              { name = "shell"; }
              { name = "logs"; command = [ "journalctl" "-f" ]; }
            ];
          };
        }
      '';
      description = ''
        Sessions to create (headless) at boot, by a per-user oneshot
        (`nestlo-tuios-layouts-<user>`): `tuios new <name> --detach`, then
        `tuios new-window` for each window. A failing step fails the unit. A
        session that exists already (running, or restored from saved state)
        is left as it is. Layouts are not tape scripts: `tuios tape exec`
        needs an attached client to play a tape, and a headless daemon has
        none.
      '';
    };

    integrations = lib.mkOption {
      type = lib.types.listOf (lib.types.enum harnesses);
      default = [ ];
      example = [ "claude-code" "codex" ];
      description = ''
        Agent harnesses to wire to TUIOS (`tuios integration install`): hook
        entries in the harness's own configuration that report its state and
        conversation id to its pane, so the rail, inbox and `needs_input`
        alerts are exact, and a restored pane can resume the conversation.
        They edit settings files in the home of every user in `users` and the
        agent user, so they are opt-in. The hooks call this package by its
        store path.
      '';
    };

    mcp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Register `tuios mcp` in the Nestlo MCP tool registry
          (`nestlo.mcp-registry`) as server `tuios`: read panes, wait on them,
          report the agent's own state, send agent mail. No tool types into a
          pane (`--write` is not used).
        '';
      };
      scope = lib.mkOption {
        type = lib.types.enum [ "own" "all" ];
        default = "own";
        description = ''
          `own`: the session of the pane the harness runs in, its fan group
          and the sessions a fan from it started (a harness outside every
          pane reaches nothing). `all`: every session of the agent user's
          daemon, for a harness that runs outside TUIOS.
        '';
      };
    };

    ssh = {
      enable = lib.mkEnableOption "the TUIOS SSH server (`tuios ssh`): a TUIOS session over SSH, public keys only. Every connection gets a shell as `ssh.user`";
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address to listen on. The firewall is opened only for an address that is not loopback.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "TCP port (above 1023: the unit holds no capabilities).";
      };
      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "ssh-ed25519 AAAAC3Nza... alice@laptop" ];
        description = ''
          Public keys that may connect, one per entry, without options
          (`command=`, `from=`, `restrict` are not honoured by TUIOS, which
          refuses such keys). Must not be empty when the server is enabled;
          the server never runs with `--no-auth`.
        '';
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = if cfg.users != [ ] then lib.head cfg.users else agentUser;
        defaultText = lib.literalExpression "the first of users, else the agent user";
        description = "The user the server runs as, and so the user of the shell every connection gets. Must have a daemon (`users` or the agent user).";
      };
    };

    web = {
      enable = lib.mkEnableOption "the TUIOS web terminal (`tuios-web`): the full interface in a browser, password required. Every browser that logs in (user name `tuios`) gets a shell as `web.user`";
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address to listen on. A non-loopback address needs `passwordFile` and `tls`.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 7681;
        description = "TCP port (above 1023: the unit holds no capabilities).";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/tuios-web";
        description = ''
          File whose first line is the password (the user name is `tuios`).
          Given to the service as a systemd credential, so root-only files
          work. Required for a non-loopback `listen`. Without it, a loopback
          server lets every user on this machine in.
        '';
      };
      tls = {
        certFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "TLS certificate (PEM). Required with a non-loopback `listen`; read as a systemd credential.";
        };
        keyFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "TLS private key (PEM), with `certFile`.";
        };
      };
      readOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "View only: browsers cannot type (`--read-only`).";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = cfg.ssh.user;
        defaultText = lib.literalExpression "nestlo.tuios.ssh.user";
        description = "The user the web server runs as, and so the user of the shell a browser gets. Must have a daemon.";
      };
    };

    monitor = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run the bridge per user (`nestlo-tuios-bridge-<user>`): it follows
          `tuios subscribe` and does what the options below enable.
        '';
      };
      metrics = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Serve nestlo_tuios_up, nestlo_tuios_agents{user,state},
            nestlo_tuios_events_total{user,type} and more on 127.0.0.1, scraped
            by nestlo.observability when that is enabled.
          '';
        };
        basePort = lib.mkOption {
          type = lib.types.port;
          default = 9985;
          description = "Loopback port of the first user's exporter; each further user takes the next port.";
        };
      };
      audit = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Write `terminal.tuios` events (windows opened and closed, commands
            finished, agent state changes, sessions created and closed) to the
            audit log. Only when `nestlo.audit` is enabled.
          '';
        };
        commandLines = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Include the command line of finished commands (cut to 200
            characters; TUIOS masks likely secrets in them, which is a
            heuristic). Off: only the exit code and duration are recorded. A
            command line needs a shell with OSC 133 prompt marks.
          '';
        };
      };
      notifyNeedsInput = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Send a notification through nestlo.notifications (when that is
          enabled) when an agent has waited for input for `graceSeconds`. The
          sending runs as the monitored user, so that user must be able to
          read the webhook files (`nestlo.notifications.*File`); use
          `webhookUrl` or group-readable secrets for the agent user.
        '';
      };
      notifyCommand = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nestlo-notify" "test" ];
        description = "Command that sends a message to the configured notification targets (the text is appended).";
      };
      graceSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 15;
        description = "How long an agent must wait for input before a notification is sent (filters flicker).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (u: u == agentUser || config.users.users ? ${u}) userNames;
        message = "nestlo.tuios: unknown user(s): "
          + lib.concatStringsSep ", " (lib.filter (u: u != agentUser && !(config.users.users ? ${u})) userNames);
      }
      {
        assertion = !(lib.elem agentUser userNames) || rt.enable;
        message = "nestlo.tuios: the agent user needs nestlo.runtime.enable (or nestlo.tuios.includeAgentUser = false and no layout, ssh or web for it)";
      }
      {
        assertion = lib.all (u: lib.elem u allUsers)
          ([ ] ++ lib.optional cfg.ssh.enable cfg.ssh.user ++ lib.optional cfg.web.enable cfg.web.user
            ++ lib.concatMap (l: l.users) (lib.attrValues cfg.layouts));
        message = "nestlo.tuios: ssh.user, web.user and the users of layouts must have a daemon (be in nestlo.tuios.users or be the agent user)";
      }
      {
        assertion = !cfg.ssh.enable || cfg.ssh.authorizedKeys != [ ];
        message = "nestlo.tuios.ssh.enable needs nestlo.tuios.ssh.authorizedKeys: the server never runs without authentication";
      }
      {
        assertion = lib.all (k: builtins.match keyRe k != null) cfg.ssh.authorizedKeys;
        message = "nestlo.tuios.ssh.authorizedKeys: every entry must be a plain public key line (ssh-ed25519 AAAA... comment) without options; TUIOS refuses keys with command=, from= or restrict";
      }
      {
        assertion = !cfg.web.enable || isLoopback cfg.web.listen || (cfg.web.passwordFile != null && cfg.web.tls.certFile != null);
        message = "nestlo.tuios.web: a listen address that is not loopback needs passwordFile and tls.certFile/tls.keyFile";
      }
      {
        assertion = (cfg.web.tls.certFile == null) == (cfg.web.tls.keyFile == null);
        message = "nestlo.tuios.web.tls: set certFile and keyFile together";
      }
      {
        assertion = !(cfg.ssh.enable && cfg.web.enable) || cfg.ssh.port != cfg.web.port;
        message = "nestlo.tuios: ssh.port and web.port are the same";
      }
      {
        assertion = lib.all (e: lib.elem e events) (lib.attrNames cfg.hooks);
        message = "nestlo.tuios.hooks: unknown event(s) " + lib.concatStringsSep ", " (lib.filter (e: !(lib.elem e events)) (lib.attrNames cfg.hooks))
          + "; the events are " + lib.concatStringsSep ", " events;
      }
      {
        assertion = !(config.nestlo.factory.enable or false) || !cfg.monitor.metrics.enable
          || !(lib.elem (config.nestlo.factory.metricsPort or 9960) (map portOf allUsers));
        message = "nestlo.tuios.monitor.metrics.basePort range collides with nestlo.factory.metricsPort; move one of them";
      }
    ];

    warnings =
      lib.optional (cfg.ssh.enable && cfg.ssh.user == agentUser) ''
        nestlo.tuios.ssh runs as the agent user (${agentUser}): every key in ssh.authorizedKeys gets a shell
        as the account the orchestrator and factory agents use. Prefer sshd (or the Cloud lobby) as the
        front door and `nestlo-tuios --user ${agentUser}` for operators.
      ''
      ++ lib.optional (cfg.web.enable && cfg.web.passwordFile == null) ''
        nestlo.tuios.web is enabled without passwordFile: every user on this machine can open a shell as
        ${cfg.web.user} through http://${cfg.web.listen}:${toString cfg.web.port}/. Set nestlo.tuios.web.passwordFile.
      ''
      ++ lib.optional (cfg.ssh.enable && !isLoopback cfg.ssh.listen) ''
        nestlo.tuios.ssh listens on ${cfg.ssh.listen}:${toString cfg.ssh.port} and the firewall is open for it:
        every key in ssh.authorizedKeys gets a shell as ${cfg.ssh.user}.
      '';

    environment.systemPackages = [ tuios cli ] ++ lib.optional config.nestlo.desktop.enable desktopItem;

    # The declared config for every user; ~/.config/tuios/config.toml, when a
    # user has one, replaces it
    environment.etc."xdg/tuios/config.toml".source = settingsFile;

    # The agent user's daemon sees /etc/xdg/tuios at ~/.config/tuios, read-only
    systemd.tmpfiles.rules = lib.optionals (lib.elem agentUser allUsers) [
      "d ${rt.agentHome}/.config 0700 ${agentUser} ${agentUser} -"
      "d ${rt.agentHome}/.config/tuios 0700 ${agentUser} ${agentUser} -"
    ];

    systemd.services = lib.mkMerge [
      (lib.listToAttrs (map mkDaemon allUsers))
      (lib.optionalAttrs cfg.monitor.enable (lib.listToAttrs (map mkBridge allUsers)))
      (lib.optionalAttrs (cfg.integrations != [ ]) (lib.listToAttrs (map mkIntegrations allUsers)))
      (lib.listToAttrs (map mkLayouts layoutUsers))
      (lib.optionalAttrs cfg.ssh.enable { nestlo-tuios-ssh = sshUnit; })
      (lib.optionalAttrs cfg.web.enable { nestlo-tuios-web = webUnit; })
    ];

    networking.firewall.allowedTCPPorts =
      lib.optional (cfg.ssh.enable && !isLoopback cfg.ssh.listen) cfg.ssh.port
      ++ lib.optional (cfg.web.enable && !isLoopback cfg.web.listen) cfg.web.port;

    nestlo.mcp-registry.extraToolServers = lib.mkIf cfg.mcp.enable {
      tuios = {
        description = "TUIOS: read panes and agent state, wait on panes, report state, agent mail (read-only, scope ${cfg.mcp.scope})";
        command = "${tuios}/bin/tuios";
        args = [ "mcp" "--scope" cfg.mcp.scope ];
        env = mcpEnv;
      };
    };

    services.prometheus.scrapeConfigs = lib.mkIf (cfg.monitor.enable && cfg.monitor.metrics.enable && config.nestlo.observability.enable) [{
      job_name = "nestlo-tuios";
      static_configs = [{ targets = map (u: "127.0.0.1:${toString (portOf u)}") allUsers; }];
    }];
  };
}
