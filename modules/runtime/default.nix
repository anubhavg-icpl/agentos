# Nestlo runtime module
#
# The core of the agent service layer:
#   - users: `nestlo` runs the services, `nestlo-agent` runs sandboxed
#     agents (no sudo, no access to the control plane)
#   - control-plane Redis (unix socket only) shared by gateway and daemon
#   - /etc/nestlo/services.toml (config for the gateway and daemon) and
#     /etc/nestlo/runtime.json (config for the `nestlo` CLI)
#   - the agent daemon: registry, auto-shutdown, notifications, metrics
#   - workspaces shared between the operator and the agent user
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.runtime;
  toml = pkgs.formats.toml { };
  redisSocket = "/run/redis-nestlo/redis.sock";

  servicesToml = toml.generate "nestlo-services.toml" config.nestlo.services.settings;

  runtimeJson = pkgs.writeText "nestlo-runtime.json" (builtins.toJSON ({
    agents = cfg.agents;
    max_agents = cfg.maxAgents;
    workspace_root = cfg.workspaceRoot;
    state_dir = "/var/lib/nestlo/state";
    log_dir = "/var/lib/nestlo/logs";
    agent_user = "nestlo-agent";
    agent_home = cfg.agentHome;
    gateway_url = "http://127.0.0.1:${toString config.nestlo.networking.modelGatewayPort}";
    admin_socket = config.nestlo.services.settings.gateway.admin_socket;
    gateway_enabled = config.nestlo.networking.enable;
    limits = cfg.agentLimits;
    default_isolation = cfg.defaultIsolation;
    # `nestlo spawn --isolation container`: own mount/net/pid/ipc namespaces
    container = {
      enabled = config.nestlo.networking.enable;
      netns_helper = "${pkgs.nestlo.services}/bin/nestlo-netns";
      bridge = "nestlo0";
      bridge_address = config.nestlo.networking.bridgeAddress;
      network = config.nestlo.networking.agentNetCIDR;
      gateway_url = "http://${config.nestlo.networking.bridgeAddress}:${toString config.nestlo.networking.modelGatewayPort}";
      shell = "/run/current-system/sw/bin/bash";
    };
    # `nestlo spawn --gpu`, `nestlo gpu`
    gpu = {
      enabled = config.nestlo.gpu.enable;
      helper = "${pkgs.nestlo.services}/bin/nestlo-gpu";
    };
  } // lib.optionalAttrs config.nestlo.pullrun.enable {
    # `nestlo spawn --isolation pullrun` (experimental)
    pullrun = {
      enabled = config.nestlo.pullrun.agentContainers.enable;
      bin = "${config.nestlo.pullrun.package}/bin/pullrun";
      socket = config.nestlo.pullrun.socket;
      image = config.nestlo.pullrun.agentContainers.image;
      log_dir = "/var/lib/nestlo/pullrun-logs";
      # Pullrun's shared bridge; the gateway listens on it
      gateway_url = "http://10.42.0.1:${toString config.nestlo.networking.modelGatewayPort}";
    };
  }));
in
{
  # ── Options ─────────────────────────────────────────────────────────
  options.nestlo.services.settings = lib.mkOption {
    type = toml.type;
    default = { };
    description = ''
      Contents of /etc/nestlo/services.toml, read by the model gateway and
      the agent daemon. Filled in by the Nestlo modules; see
      services/nestlo_services/config.py for all keys.
    '';
  };

  imports = [
    (lib.mkRemovedOptionModule [ "nestlo" "runtime" "enableMCPGateway" ]
      "The MCP gateway was a stub with no implementation and is removed; see docs/ROADMAP.md.")
    (lib.mkRemovedOptionModule [ "nestlo" "runtime" "mcpGatewayPort" ]
      "The MCP gateway was a stub with no implementation and is removed; see docs/ROADMAP.md.")
  ];

  options.nestlo.runtime = {
    enable = lib.mkEnableOption "Nestlo runtime";

    containerRuntime = lib.mkOption {
      type = lib.types.enum [ "containerd" "podman" "docker" ];
      default = "containerd";
      description = "Container runtime installed for agent tooling";
    };

    defaultIsolation = lib.mkOption {
      type = lib.types.enum [ "sandbox" "container" ];
      default = "sandbox";
      description = ''
        How `nestlo spawn` isolates agents unless told otherwise with
        `--isolation`. "sandbox" runs the agent in the host's namespaces with
        a hardened systemd unit. "container" also gives it its own root
        filesystem, PID/IPC/UTS namespaces and a network namespace on the
        nestlo0 bridge (needs nestlo.networking.enable).
      '';
    };

    maxAgents = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Maximum number of concurrently running agents (enforced by `nestlo spawn`)";
    };

    workspaceRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nestlo/workspaces";
      description = "Root directory for agent workspaces";
    };

    agentHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nestlo/agent-home";
      description = "Home directory of the nestlo-agent user (agent logins and settings)";
    };

    operators = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "admin" ];
      description = ''
        Users who manage agents. They join the `nestlo` group (budgets,
        state, logs) and the `nestlo-agent` group (shared workspaces).
        `nestlo spawn` also needs sudo to start the agent's systemd unit.
      '';
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { claude = "claude"; };
      description = "Agent names accepted by `nestlo spawn`, mapped to the command they run";
    };

    agentLimits = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
      description = "Per-agent resource limits applied by `nestlo spawn` (set by the circuit-breaker module)";
    };
  };

  # ── Configuration ───────────────────────────────────────────────────
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.defaultIsolation != "container" || config.nestlo.networking.enable;
      message = "nestlo.runtime.defaultIsolation = \"container\" needs nestlo.networking.enable (agent bridge and gateway)";
    }];

    # ─ Container runtime ──────────────────────────────────────────────
    virtualisation = lib.mkMerge [
      (lib.mkIf (cfg.containerRuntime == "containerd") {
        containerd.enable = true;
      })
      (lib.mkIf (cfg.containerRuntime == "podman") {
        podman = {
          enable = true;
          defaultNetwork.settings.dns_enabled = true;
        };
      })
      (lib.mkIf (cfg.containerRuntime == "docker") {
        docker.enable = true;
      })
    ];

    # ─ Users ──────────────────────────────────────────────────────────
    users.users.nestlo = {
      isSystemUser = true;
      group = "nestlo";
      home = "/var/lib/nestlo";
      extraGroups = [ "redis-nestlo" ];
    };
    users.groups.nestlo.members = cfg.operators;

    users.users.nestlo-agent = {
      isSystemUser = true;
      group = "nestlo-agent";
      home = cfg.agentHome;
      createHome = true;
      homeMode = "700";
      shell = pkgs.bashInteractive;
    };
    users.groups.nestlo-agent.members = cfg.operators;

    nestlo.runtime.agents = {
      claude = "claude";
      claude-code = "claude";
      codex = "codex";
      aider = "aider";
      gemini = "gemini";
      gemini-cli = "gemini";
      qwen = "qwen";
      qwen-code = "qwen";
      amp = "amp";
      goose = "goose";
      opencode = "opencode";
      crush = "crush";
      cursor = "cursor-agent";
      cursor-agent = "cursor-agent";
      copilot = "copilot";
      github-copilot-cli = "copilot";
      kilocode = "kilocode";
      kilocode-cli = "kilocode";
      kilo-code = "kilocode";
      vibe = "vibe";
      mistral-vibe = "vibe";
      kiro = "kiro-cli";
      kiro-cli = "kiro-cli";
      codebuff = "codebuff";
      pi = "pi";
      pi-coding-agent = "pi";
      interpreter = "interpreter";
      open-interpreter = "interpreter";
      droid = "droid";
      factory-droid = "droid";
      cline = "cline";
      cn = "cn";
      continue = "cn";
    };

    # ─ Directories ────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/nestlo 0755 root root"
      # Workspaces: operators and the agent user share files through the
      # nestlo-agent group; default ACLs keep new files group-writable.
      "d ${cfg.workspaceRoot} 2775 root nestlo-agent"
      "A+ ${cfg.workspaceRoot} - - - - group:nestlo-agent:rwx,default:group:nestlo-agent:rwx,default:mask::rwx"
      # Agent registry: written by operators (`nestlo spawn`) and the daemon
      "d /var/lib/nestlo/state 2770 nestlo nestlo"
      "d /var/lib/nestlo/state/history 2770 nestlo nestlo"
      # Gateway request logs, readable by operators
      "d /var/lib/nestlo/logs 2750 nestlo nestlo"
      "d /var/lib/nestlo/cache 0755 nestlo nestlo"
      "d /var/lib/nestlo/snapshots 0755 root root"
    ];

    # Workspaces hold files owned by both the operator and nestlo-agent;
    # trust repositories there (and only there) regardless of owner.
    programs.git = {
      enable = true;
      config.safe.directory = "${cfg.workspaceRoot}/*";
    };

    # ─ Control-plane Redis ────────────────────────────────────────────
    # Unix socket only, so the agent user cannot read or change spend and
    # budgets (only members of redis-nestlo can connect).
    services.redis.servers.nestlo = {
      enable = true;
      port = 0;
      unixSocket = redisSocket;
      unixSocketPerm = 660;
      settings = {
        maxmemory = "256mb";
        maxmemory-policy = "noeviction";
        appendonly = "yes";
      };
    };

    # ─ Services config ────────────────────────────────────────────────
    nestlo.services.settings = {
      redis.url = "unix://${redisSocket}?db=2";
      daemon = {
        state_dir = "/var/lib/nestlo/state";
        metrics_listen = "127.0.0.1";
        metrics_port = 9950;
        reap_interval_sec = 5;
      };
      gateway = {
        admin_socket = lib.mkDefault "/run/nestlo-gateway/admin.sock";
        log_dir = "/var/lib/nestlo/logs";
      };
    };

    environment.etc."nestlo/services.toml".source = servicesToml;
    environment.etc."nestlo/runtime.json".source = runtimeJson;

    # ─ Agent daemon ───────────────────────────────────────────────────
    systemd.services.nestlo-daemon = {
      description = "Nestlo agent daemon (registry, auto-shutdown, notifications, metrics)";
      after = [ "network.target" "redis-nestlo.service" ];
      requires = [ "redis-nestlo.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ servicesToml ];
      path = [ config.systemd.package ];

      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # The service sends READY=1 once listening and WATCHDOG=1 while healthy
        WatchdogSec = 60;
        TimeoutStartSec = 60;
        User = "nestlo";
        Group = "nestlo";
        SupplementaryGroups = [ "redis-nestlo" ];
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-daemon";
        Restart = "on-failure";
        RestartSec = 3;
        UMask = "0002";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/nestlo/state" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    # The daemon may stop sandboxed agent units (auto-shutdown), nothing else
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "nestlo") {
          var unit = action.lookup("unit") || "";
          var verb = action.lookup("verb") || "";
          if (unit.indexOf("nestlo-agent-") == 0 &&
              (verb == "stop" || verb == "kill")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.systemPackages = with pkgs; [
      nestlo.cli
      nestlo.services
      acl
      git
      jq
      curl
      ripgrep
      fd
    ];
  };
}
