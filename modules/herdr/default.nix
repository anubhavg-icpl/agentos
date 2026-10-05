# Nestlo herdr module
#
# herdr (https://herdr.dev, Apache-2.0) is a persistent terminal workspace for
# coding agents: panes marked working / blocked / idle, a socket API and CLI
# that agents can drive, and plugins. This module makes it part of Nestlo:
#
#   - installs herdr and the `nestlo-herdr` / `nestlo-herdr-plugins` CLIs
#   - a headless herdr server for the agent user (nestlo-herdr-server-<user>),
#     so what the agent user runs persists and operators can attach
#     (`nestlo-herdr attach`), and a loopback exporter per user that serves
#     nestlo_herdr_* Prometheus metrics and tells nestlo.notifications when
#     an agent has been blocked on a question
#   - the Nestlo herdr plugin (integrations/herdr-plugin: orchestrator
#     tasks, factory items, budgets, approve/cancel) linked for every user
#   - declarative plugins (`plugins`, pinned to a commit) and the dynamic
#     marketplace CLI; an opt-in daily install of every marketplace plugin
#
# herdr does not sandbox plugins: they run as the user and see everything the
# user sees. Read docs/herdr.md before listing plugins or enabling
# marketplace.installAll.
{ config, pkgs, lib, utils, ... }:

let
  cfg = config.nestlo.herdr;
  rt = config.nestlo.runtime;
  agentUser = "nestlo-agent";

  herdr = cfg.package;
  services = pkgs.nestlo.services;

  allUsers = lib.unique (cfg.users ++ lib.optional cfg.includeAgentUser agentUser);
  homeOf = u: if u == agentUser then rt.agentHome else config.users.users.${u}.home;
  shellOf = u: utils.toShellPath (if u == agentUser then pkgs.bashInteractive else config.users.users.${u}.shell);
  portOf = u: cfg.monitor.basePort + (lib.lists.findFirstIndex (x: x == u) 0 allUsers);
  isServerUser = u: lib.elem u cfg.server.users;

  # The Nestlo plugin: manifest and script, copied into the store so that
  # `herdr plugin link` points at an immutable path
  nestloPlugin = pkgs.runCommand "nestlo-herdr-plugin" { } ''
    mkdir -p $out
    cp ${../../integrations/herdr-plugin/herdr-plugin.toml} $out/herdr-plugin.toml
    cp ${../../integrations/herdr-plugin/panel.sh} $out/panel.sh
  '';

  cli = pkgs.runCommand "nestlo-herdr-cli" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
    mkdir -p $out/bin
    for b in nestlo-herdr nestlo-herdr-plugins; do
      makeWrapper ${services}/bin/$b $out/bin/$b \
        --set-default NESTLO_HERDR_BIN ${herdr}/bin/herdr \
        --prefix PATH : ${lib.makeBinPath [ pkgs.git ]}
    done
  '';

  desktopItem = pkgs.makeDesktopItem {
    name = "herdr";
    desktopName = "herdr";
    comment = "Persistent terminal workspaces for coding agents";
    exec = "${pkgs.alacritty}/bin/alacritty --title herdr -e ${herdr}/bin/herdr";
    categories = [ "Development" "System" ];
  };

  localLinks = lib.optional cfg.nestloPlugin.enable "${nestloPlugin}" ++ cfg.localPlugins;
  pluginUsers = cfg.pluginUsers;

  syncConfig = u: pkgs.writeText "nestlo-herdr-sync-${u}.json" (builtins.toJSON {
    plugins = map (p: { inherit (p) source ref enable; }) cfg.plugins;
    links = localLinks;
    server_managed = isServerUser u;
  });

  # PATH for the oneshots: git for installs, the usual toolchains for plugin
  # build commands (herdr runs them as the user and reports missing tools)
  buildPath = [ pkgs.git pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.bash pkgs.nodejs_22 pkgs.python3 pkgs.curl ];

  oneshotHardening = u: {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ReadWritePaths = "-${homeOf u}";
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
  };

  mkServer = u: lib.nameValuePair "nestlo-herdr-server-${u}" {
    description = "herdr server for ${u}";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    # A rebuild must not kill the agents that live in the panes
    restartIfChanged = false;
    environment = {
      HOME = homeOf u;
      USER = u;
      LOGNAME = u;
      SHELL = shellOf u;
      # the agents installed on the system, not a service-sized PATH
      PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin";
    };
    serviceConfig = {
      User = u;
      WorkingDirectory = homeOf u;
      ExecStart = "${herdr}/bin/herdr server";
      ExecStop = "${herdr}/bin/herdr server stop";
      Restart = "on-failure";
      RestartSec = 3;
      TimeoutStopSec = 30;
      UMask = "0002";
    } // lib.optionalAttrs (u == agentUser) {
      # What the agent user runs here is as contained as in `nestlo spawn`
      # (sandbox): the workspaces and its own home are the only writable paths
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
  };

  notifyEnabled = cfg.monitor.notifyBlocked && config.nestlo.notifications.enable;

  mkMonitor = u: lib.nameValuePair "nestlo-herdr-monitor-${u}" {
    description = "Nestlo herdr monitor for ${u} (metrics and blocked-agent notifications)";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ] ++ lib.optional (isServerUser u) "nestlo-herdr-server-${u}.service";
    environment.PATH = lib.mkForce "/run/wrappers/bin:/run/current-system/sw/bin";
    serviceConfig = {
      User = u;
      ExecStart = lib.escapeShellArgs ([
        "${cli}/bin/nestlo-herdr"
        "monitor"
        "--listen"
        "127.0.0.1"
        "--port"
        (toString (portOf u))
        "--interval"
        (toString cfg.monitor.intervalSeconds)
        "--grace"
        (toString cfg.monitor.blockedGraceSeconds)
      ] ++ lib.optionals notifyEnabled [
        "--notify-json"
        (builtins.toJSON cfg.monitor.notifyCommand)
      ]);
      Restart = "on-failure";
      RestartSec = 5;
      RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      CapabilityBoundingSet = "";
    } // oneshotHardening u;
  };

  mkSync = u: lib.nameValuePair "nestlo-herdr-plugins-${u}" {
    description = "Apply the declared herdr plugins for ${u}";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ] ++ lib.optional (isServerUser u) "nestlo-herdr-server-${u}.service";
    after = [ "network-online.target" "local-fs.target" ]
      ++ lib.optional (isServerUser u) "nestlo-herdr-server-${u}.service";
    restartTriggers = [ (syncConfig u) nestloPlugin ];
    path = buildPath;
    environment.NESTLO_HERDR_BIN = "${herdr}/bin/herdr";
    unitConfig = {
      StartLimitBurst = 5;
      StartLimitIntervalSec = 3600;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = u;
      ExecStart = "${cli}/bin/nestlo-herdr-plugins sync --config ${syncConfig u}";
      # No network at boot, a ref that does not exist yet: try again later
      Restart = "on-failure";
      RestartSec = 120;
      TimeoutStartSec = "30min";
    } // oneshotHardening u;
  };

  mkIntegrations = u: lib.nameValuePair "nestlo-herdr-integrations-${u}" {
    description = "Install the herdr agent integrations for ${u}";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    restartTriggers = [ (builtins.toJSON cfg.integrations) ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = u;
      ExecStart = pkgs.writeShellScript "nestlo-herdr-integrations" ''
        rc=0
        for agent in ${lib.escapeShellArgs cfg.integrations}; do
          ${herdr}/bin/herdr integration install "$agent" || { echo "herdr integration $agent failed" >&2; rc=1; }
        done
        exit $rc
      '';
    } // oneshotHardening u;
  };

  mkMarketplace = u: {
    services.${"nestlo-herdr-marketplace-${u}"} = {
      description = "Install every herdr marketplace plugin for ${u} (unreviewed third-party code)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      path = buildPath;
      environment.NESTLO_HERDR_BIN = "${herdr}/bin/herdr";
      serviceConfig = {
        Type = "oneshot";
        User = u;
        TimeoutStartSec = "3h";
        LoadCredential = lib.optional (cfg.marketplace.githubTokenFile != null)
          "github-token:${toString cfg.marketplace.githubTokenFile}";
        ExecStart = pkgs.writeShellScript "nestlo-herdr-marketplace" ''
          if [ -n "''${CREDENTIALS_DIRECTORY:-}" ] && [ -r "$CREDENTIALS_DIRECTORY/github-token" ]; then
            GITHUB_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/github-token")
            export GITHUB_TOKEN
          fi
          exec ${cli}/bin/nestlo-herdr-plugins install-all --yes --min-stars ${toString cfg.marketplace.minStars} \
            ${lib.concatMapStringsSep " " (e: "--exclude ${lib.escapeShellArg e}") cfg.marketplace.exclude}
        '';
      } // oneshotHardening u;
    };
    timers.${"nestlo-herdr-marketplace-${u}"} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.marketplace.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };

  marketplaceUnits = map mkMarketplace cfg.marketplace.users;
  sourceRe = "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.@+-]+)*";
in
{
  options.nestlo.herdr = {
    enable = lib.mkEnableOption "herdr, persistent terminal workspaces for coding agents, with the Nestlo management bridge";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.herdr;
      defaultText = lib.literalExpression "pkgs.nestlo.herdr";
      description = "The herdr package (nixpkgs-unstable's herdr, exposed as packages.<system>.herdr).";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.filter (u: config.users.users ? ${u}) rt.operators;
      defaultText = lib.literalExpression "the nestlo.runtime.operators that exist as users";
      example = [ "alice" ];
      description = "Users who get the Nestlo plugin, the declared plugins and a metrics exporter.";
    };

    includeAgentUser = lib.mkOption {
      type = lib.types.bool;
      default = rt.enable;
      defaultText = lib.literalExpression "config.nestlo.runtime.enable";
      description = "Also set herdr up for the sandboxed agent user (nestlo-agent).";
    };

    server.users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.optional cfg.includeAgentUser agentUser;
      defaultText = lib.literalExpression "[ \"nestlo-agent\" ] when the agent user is included";
      description = ''
        Users with a headless herdr server run by systemd
        (`nestlo-herdr-server-<user>`). Their panes and agents keep running
        when nobody is attached; attach with `nestlo-herdr attach --user <user>`.
        A rebuild does not restart the server (that would end the panes), so
        a herdr update takes effect at the next `systemctl restart`.
      '';
    };

    integrations = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "pi" "omp" "claude" "codex" "copilot" "devin" "droid" "kimi" "opencode" "kilo" "hermes"
        "qodercli" "qwen" "letta" "cursor" "mastracode" "grok"
      ]);
      default = [ ];
      example = [ "claude" "codex" ];
      description = ''
        herdr's built-in agent integrations (`herdr integration install`):
        hooks in the agent's own configuration that report its state and
        session precisely, which also lets herdr resume the agent's session
        after a server restart. They edit the agent's settings files in the
        home of every user in `users`, so they are opt-in.
      '';
    };

    nestloPlugin.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Link the Nestlo herdr plugin (orchestrator tasks, factory items,
        budgets, approve and cancel for gated tasks) for every user.
      '';
    };

    plugins = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          source = lib.mkOption {
            type = lib.types.strMatching sourceRe;
            example = "ogulcancelik/herdr-plugin-examples/agent-telegram-notify";
            description = "GitHub owner/repo[/subdir] that holds a herdr-plugin.toml.";
          };
          ref = lib.mkOption {
            type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._/@+-]{0,127}";
            example = "0123456789abcdef0123456789abcdef01234567";
            description = ''
              Commit sha or tag to install. Required: a plugin is code that
              runs as the user, so nothing floats. Prefer a full commit sha
              (a tag can be moved by its owner).
            '';
          };
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the plugin is enabled once installed.";
          };
        };
      });
      default = [ ];
      description = ''
        herdr plugins to install, for every user in `pluginUsers`, by a
        per-user oneshot (`herdr plugin install <source> --ref <ref> --yes`,
        then enable or disable). It is idempotent: a plugin already at the
        wanted ref is left alone. Plugins this option installed earlier and
        that are no longer listed are uninstalled; plugins a user installed by
        hand are never touched. Review the manifest first:
        `nestlo-herdr-plugins show <source> --ref <ref>`.
      '';
    };

    localPlugins = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Local plugin directories (containing herdr-plugin.toml) linked with
        `herdr plugin link` for every user in `pluginUsers`. Store paths are
        ideal: they are immutable and reviewed with the configuration.
      '';
    };

    pluginUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = allUsers;
      defaultText = lib.literalExpression "users plus the agent user";
      description = "Users that get `plugins`, `localPlugins` and the Nestlo plugin.";
    };

    monitor = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Run `nestlo-herdr monitor` per user: it serves nestlo_herdr_up,
          nestlo_herdr_panes{user,state} and nestlo_herdr_agents{user,state}
          on 127.0.0.1 and is scraped by nestlo.observability when that is
          enabled.
        '';
      };
      basePort = lib.mkOption {
        type = lib.types.port;
        default = 9970;
        description = "Loopback port of the first user's exporter; each further user takes the next port.";
      };
      intervalSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "How often herdr is polled.";
      };
      notifyBlocked = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Send a notification through nestlo.notifications (when that is
          enabled) when an agent has been blocked on a question or approval
          for `blockedGraceSeconds`. The sending runs as the monitored user,
          so that user must be able to read the webhook files
          (`nestlo.notifications.*File`); use `webhookUrl` or group-readable
          secrets for the agent user.
        '';
      };
      notifyCommand = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nestlo-notify" "test" ];
        description = "Command that sends a message to the configured notification targets (the text is appended).";
      };
      blockedGraceSeconds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 15;
        description = "How long an agent must stay blocked before a notification is sent (filters flicker).";
      };
    };

    marketplace = {
      installAll = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          DANGEROUS. Once a day install every plugin of the herdr marketplace
          (public GitHub repositories with the topic `herdr-plugin`), each
          pinned to its current head commit, and move them to new commits.
          Nobody reviews these plugins, herdr does not sandbox them, and they
          run build commands, startup hooks and event hooks as the user.
          Off by default; not recommended for the agent user; use
          `nestlo-herdr-plugins catalog`, `show` and `install` for plugins
          you have read.
        '';
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = cfg.users;
        defaultText = lib.literalExpression "nestlo.herdr.users (not the agent user)";
        description = "Users whose timer runs `install-all`.";
      };
      exclude = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "someowner/*" "owner/repo/subdir" ];
        description = "owner/repo[/subdir] globs that are never installed.";
      };
      minStars = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 0;
        description = "Only repositories with at least this many GitHub stars.";
      };
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "systemd OnCalendar expression of the install-all timer.";
      };
      githubTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File with a GitHub token (no scopes needed) for the search and tree
          API. Without it GitHub allows 60 requests per hour, far too few for
          a full marketplace run.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Each monitored user takes basePort + index; the factory exporter must
        # not sit inside that range
        assertion = !(config.nestlo.factory.enable or false) || !cfg.monitor.enable
          || !(lib.elem (config.nestlo.factory.metricsPort or 9960) (map portOf allUsers));
        message = "nestlo.herdr.monitor.basePort range collides with nestlo.factory.metricsPort; move one of them";
      }
      {
        assertion = lib.all (u: config.users.users ? ${u}) (lib.filter (u: u != agentUser) (allUsers ++ pluginUsers ++ cfg.marketplace.users ++ cfg.server.users));
        message = "nestlo.herdr: unknown user(s): "
          + lib.concatStringsSep ", " (lib.filter (u: u != agentUser && !(config.users.users ? ${u})) (allUsers ++ pluginUsers ++ cfg.marketplace.users ++ cfg.server.users));
      }
      {
        assertion = !(lib.elem agentUser allUsers) || rt.enable;
        message = "nestlo.herdr: the agent user needs nestlo.runtime.enable (or nestlo.herdr.includeAgentUser = false)";
      }
      {
        assertion = lib.all (u: lib.elem u allUsers) (cfg.server.users ++ pluginUsers ++ cfg.marketplace.users);
        message = "nestlo.herdr: server.users, pluginUsers and marketplace.users must be among users (or the agent user)";
      }
    ];

    warnings =
      lib.optional (cfg.marketplace.installAll && lib.elem agentUser cfg.marketplace.users) ''
        nestlo.herdr.marketplace.installAll is enabled for the agent user (${agentUser}). herdr does not
        sandbox plugins: every unreviewed marketplace plugin will run build commands, startup hooks and
        event hooks as the account the orchestrator and factory agents use. Remove ${agentUser} from
        nestlo.herdr.marketplace.users, or install reviewed plugins with nestlo.herdr.plugins instead.
      ''
      ++ lib.optional (cfg.marketplace.installAll && cfg.marketplace.githubTokenFile == null) ''
        nestlo.herdr.marketplace.installAll without nestlo.herdr.marketplace.githubTokenFile: unauthenticated
        GitHub API calls are limited to 60 per hour, so the daily install-all will stop at the rate limit.
      '';

    environment.systemPackages = [ herdr cli ] ++ lib.optional config.nestlo.desktop.enable desktopItem;

    environment.etc."nestlo/herdr.json".text = builtins.toJSON {
      herdr = "${herdr}/bin/herdr";
      users = map
        (u: {
          name = u;
          home = homeOf u;
          server = isServerUser u;
          metrics_port = portOf u;
        })
        allUsers;
    };

    systemd.services = lib.mkMerge [
      (lib.listToAttrs (map mkServer cfg.server.users))
      (lib.optionalAttrs cfg.monitor.enable (lib.listToAttrs (map mkMonitor allUsers)))
      (lib.listToAttrs (map mkSync pluginUsers))
      (lib.optionalAttrs (cfg.integrations != [ ]) (lib.listToAttrs (map mkIntegrations allUsers)))
      (lib.mkIf cfg.marketplace.installAll (lib.foldl' (acc: m: acc // m.services) { } marketplaceUnits))
    ];

    systemd.timers = lib.mkIf cfg.marketplace.installAll (lib.foldl' (acc: m: acc // m.timers) { } marketplaceUnits);

    services.prometheus.scrapeConfigs = lib.mkIf (cfg.monitor.enable && config.nestlo.observability.enable) [{
      job_name = "nestlo-herdr";
      static_configs = [{ targets = map (u: "127.0.0.1:${toString (portOf u)}") allUsers; }];
    }];
  };
}
