# AgentOS runtime module
#
# The core of the agent service layer:
#   - users: `agentos` runs the services, `agentos-agent` runs sandboxed
#     agents (no sudo, no access to the control plane)
#   - control-plane Redis (unix socket only) shared by gateway and daemon
#   - /etc/agentos/services.toml (config for the gateway and daemon) and
#     /etc/agentos/runtime.json (config for the `agentos` CLI)
#   - the agent daemon: registry, auto-shutdown, notifications, metrics
#   - workspaces shared between the operator and the agent user
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.runtime;
  toml = pkgs.formats.toml { };
  redisSocket = "/run/redis-agentos/redis.sock";

  servicesToml = toml.generate "agentos-services.toml" config.agentos.services.settings;

  runtimeJson = pkgs.writeText "agentos-runtime.json" (builtins.toJSON ({
    agents = cfg.agents;
    max_agents = cfg.maxAgents;
    workspace_root = cfg.workspaceRoot;
    state_dir = "/var/lib/agentos/state";
    log_dir = "/var/lib/agentos/logs";
    agent_user = "agentos-agent";
    agent_home = cfg.agentHome;
    gateway_url = "http://127.0.0.1:${toString config.agentos.networking.modelGatewayPort}";
    admin_socket = config.agentos.services.settings.gateway.admin_socket;
    gateway_enabled = config.agentos.networking.enable;
    limits = cfg.agentLimits;
    default_isolation = cfg.defaultIsolation;
    # `agentos spawn --isolation container`: own mount/net/pid/ipc namespaces
    container = {
      enabled = config.agentos.networking.enable;
      netns_helper = "${pkgs.agentos.services}/bin/agentos-netns";
      bridge = "agentos0";
      bridge_address = config.agentos.networking.bridgeAddress;
      network = config.agentos.networking.agentNetCIDR;
      gateway_url = "http://${config.agentos.networking.bridgeAddress}:${toString config.agentos.networking.modelGatewayPort}";
      shell = "/run/current-system/sw/bin/bash";
    };
    # `agentos spawn --gpu`, `agentos gpu`
    gpu = {
      enabled = config.agentos.gpu.enable;
      helper = "${pkgs.agentos.services}/bin/agentos-gpu";
    };
  } // lib.optionalAttrs config.agentos.pullrun.enable {
    # `agentos spawn --isolation pullrun` (experimental)
    pullrun = {
      enabled = config.agentos.pullrun.agentContainers.enable;
      bin = "${config.agentos.pullrun.package}/bin/pullrun";
      socket = config.agentos.pullrun.socket;
      image = config.agentos.pullrun.agentContainers.image;
      log_dir = "/var/lib/agentos/pullrun-logs";
      # Pullrun's shared bridge; the gateway listens on it
      gateway_url = "http://10.42.0.1:${toString config.agentos.networking.modelGatewayPort}";
    };
  }));
in
{
  # ── Options ─────────────────────────────────────────────────────────
  options.agentos.services.settings = lib.mkOption {
    type = toml.type;
    default = { };
    description = ''
      Contents of /etc/agentos/services.toml, read by the model gateway and
      the agent daemon. Filled in by the AgentOS modules; see
      services/agentos_services/config.py for all keys.
    '';
  };

  imports = [
    (lib.mkRemovedOptionModule [ "agentos" "runtime" "enableMCPGateway" ]
      "The MCP gateway was a stub with no implementation and is removed; see docs/ROADMAP.md.")
    (lib.mkRemovedOptionModule [ "agentos" "runtime" "mcpGatewayPort" ]
      "The MCP gateway was a stub with no implementation and is removed; see docs/ROADMAP.md.")
  ];

  options.agentos.runtime = {
    enable = lib.mkEnableOption "AgentOS runtime";

    containerRuntime = lib.mkOption {
      type = lib.types.enum [ "containerd" "podman" "docker" ];
      default = "containerd";
      description = "Container runtime installed for agent tooling";
    };

    defaultIsolation = lib.mkOption {
      type = lib.types.enum [ "sandbox" "container" ];
      default = "sandbox";
      description = ''
        How `agentos spawn` isolates agents unless told otherwise with
        `--isolation`. "sandbox" runs the agent in the host's namespaces with
        a hardened systemd unit. "container" also gives it its own root
        filesystem, PID/IPC/UTS namespaces and a network namespace on the
        agentos0 bridge (needs agentos.networking.enable).
      '';
    };

    maxAgents = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Maximum number of concurrently running agents (enforced by `agentos spawn`)";
    };

    workspaceRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agentos/workspaces";
      description = "Root directory for agent workspaces";
    };

    agentHome = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agentos/agent-home";
      description = "Home directory of the agentos-agent user (agent logins and settings)";
    };

    operators = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "admin" ];
      description = ''
        Users who manage agents. They join the `agentos` group (budgets,
        state, logs) and the `agentos-agent` group (shared workspaces).
        `agentos spawn` also needs sudo to start the agent's systemd unit.
      '';
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { claude = "claude"; };
      description = "Agent names accepted by `agentos spawn`, mapped to the command they run";
    };

    agentLimits = lib.mkOption {
      type = lib.types.attrsOf lib.types.int;
      default = { };
      description = "Per-agent resource limits applied by `agentos spawn` (set by the circuit-breaker module)";
    };
  };

  # ── Configuration ───────────────────────────────────────────────────
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = cfg.defaultIsolation != "container" || config.agentos.networking.enable;
      message = "agentos.runtime.defaultIsolation = \"container\" needs agentos.networking.enable (agent bridge and gateway)";
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
    users.users.agentos = {
      isSystemUser = true;
      group = "agentos";
      home = "/var/lib/agentos";
      extraGroups = [ "redis-agentos" ];
    };
    users.groups.agentos.members = cfg.operators;

    users.users.agentos-agent = {
      isSystemUser = true;
      group = "agentos-agent";
      home = cfg.agentHome;
      createHome = true;
      homeMode = "700";
      shell = pkgs.bashInteractive;
    };
    users.groups.agentos-agent.members = cfg.operators;

    agentos.runtime.agents = {
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
      "d /var/lib/agentos 0755 root root"
      # Workspaces: operators and the agent user share files through the
      # agentos-agent group; default ACLs keep new files group-writable.
      "d ${cfg.workspaceRoot} 2775 root agentos-agent"
      "A+ ${cfg.workspaceRoot} - - - - group:agentos-agent:rwx,default:group:agentos-agent:rwx,default:mask::rwx"
      # Agent registry: written by operators (`agentos spawn`) and the daemon
      "d /var/lib/agentos/state 2770 agentos agentos"
      "d /var/lib/agentos/state/history 2770 agentos agentos"
      # Gateway request logs, readable by operators
      "d /var/lib/agentos/logs 2750 agentos agentos"
      "d /var/lib/agentos/cache 0755 agentos agentos"
      "d /var/lib/agentos/snapshots 0755 root root"
    ];

    # Workspaces hold files owned by both the operator and agentos-agent;
    # trust repositories there (and only there) regardless of owner.
    programs.git = {
      enable = true;
      config.safe.directory = "${cfg.workspaceRoot}/*";
    };

    # ─ Control-plane Redis ────────────────────────────────────────────
    # Unix socket only, so the agent user cannot read or change spend and
    # budgets (only members of redis-agentos can connect).
    services.redis.servers.agentos = {
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
    agentos.services.settings = {
      redis.url = "unix://${redisSocket}?db=2";
      daemon = {
        state_dir = "/var/lib/agentos/state";
        metrics_listen = "127.0.0.1";
        metrics_port = 9950;
        reap_interval_sec = 5;
      };
      gateway = {
        admin_socket = lib.mkDefault "/run/agentos-gateway/admin.sock";
        log_dir = "/var/lib/agentos/logs";
      };
    };

    environment.etc."agentos/services.toml".source = servicesToml;
    environment.etc."agentos/runtime.json".source = runtimeJson;

    # ─ Agent daemon ───────────────────────────────────────────────────
    systemd.services.agentos-daemon = {
      description = "AgentOS agent daemon (registry, auto-shutdown, notifications, metrics)";
      after = [ "network.target" "redis-agentos.service" ];
      requires = [ "redis-agentos.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ servicesToml ];
      path = [ config.systemd.package ];

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        SupplementaryGroups = [ "redis-agentos" ];
        ExecStart = "${pkgs.agentos.services}/bin/agentos-daemon";
        Restart = "on-failure";
        RestartSec = 3;
        UMask = "0002";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/agentos/state" ];
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
            subject.user == "agentos") {
          var unit = action.lookup("unit") || "";
          var verb = action.lookup("verb") || "";
          if (unit.indexOf("agentos-agent-") == 0 &&
              (verb == "stop" || verb == "kill")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.systemPackages = with pkgs; [
      agentos.cli
      agentos.services
      acl
      git
      jq
      curl
      ripgrep
      fd
    ];
  };
}
