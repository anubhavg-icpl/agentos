# AgentOS runtime module
# Handles: container runtime, agent daemon, tool registry, MCP gateway,
#          workspace management, agent lifecycle
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.runtime;
in
{
  # ── Options ─────────────────────────────────────────────────────────
  options.agentos.runtime = {
    enable = lib.mkEnableOption "AgentOS runtime";

    containerRuntime = lib.mkOption {
      type = lib.types.enum [ "containerd" "podman" "docker" ];
      default = "containerd";
      description = "Which container runtime to use for agent isolation";
    };

    maxAgents = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "Maximum number of concurrent agents";
    };

    workspaceRoot = lib.mkOption {
      type = lib.types.path;
      default = /var/lib/agentos/workspaces;
      description = "Root directory for agent workspaces";
    };

    enableMCPGateway = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the MCP gateway for tool routing";
    };

    mcpGatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 9944;
      description = "Port for the MCP gateway";
    };
  };

  # ── Configuration ───────────────────────────────────────────────────
  config = lib.mkIf cfg.enable {

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

    # ─ Agent workspace directories ───────────────────────────────────
    systemd.tmpfiles.rules = [
      # group-writable so members of the agentos group (e.g. admin) can
      # create workspaces with `agentos workspace create`
      "d ${toString cfg.workspaceRoot} 2775 agentos agentos"
      "d /var/lib/agentos/state 0755 agentos agentos"
      "d /var/lib/agentos/logs 0755 agentos agentos"
      "d /var/lib/agentos/cache 0755 agentos agentos"
    ];

    # ─ AgentOS user ──────────────────────────────────────────────────
    users.users.agentos = {
      isSystemUser = true;
      group = "agentos";
      home = "/var/lib/agentos";
      createHome = true;
      shell = pkgs.bash;
      extraGroups = lib.optional (cfg.containerRuntime == "docker") "docker"
        ++ lib.optional (cfg.containerRuntime == "podman") "podman";
    };
    users.groups.agentos = { };

    # ─ AgentOS daemon (manages agent lifecycle) ──────────────────────
    systemd.services.agentos-daemon = lib.mkIf config.agentos.daemons.enable {
      description = "AgentOS Agent Daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.daemon}/bin/agentos-daemon --workspace-root ${toString cfg.workspaceRoot} --max-agents ${toString cfg.maxAgents}";
        Restart = "on-failure";
        RestartSec = 5;

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/agentos" (toString cfg.workspaceRoot) ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        LockPersonality = true;
        MemoryDenyWriteExecute = false;  # agents need JIT
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    # ─ MCP Gateway (routes tool calls to agents) ─────────────────────
    systemd.services.agentos-mcp-gateway = lib.mkIf (cfg.enableMCPGateway && config.agentos.daemons.enable) {
      description = "AgentOS MCP Gateway";
      after = [ "network.target" "agentos-daemon.service" ];
      wants = [ "agentos-daemon.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.mcp-gateway}/bin/agentos-mcp-gateway --port ${toString cfg.mcpGatewayPort}";
        Restart = "on-failure";
        RestartSec = 3;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Firewall rules for internal services ──────────────────────────
    networking.firewall.interfaces."agentos+" = {
      allowedTCPPorts = [ cfg.mcpGatewayPort ];
    };

    # ─ Environment setup ─────────────────────────────────────────────
    environment = {
      etc."agentos/config.toml".text = ''
        [runtime]
        container_runtime = "${cfg.containerRuntime}"
        max_agents = ${toString cfg.maxAgents}
        workspace_root = "${toString cfg.workspaceRoot}"

        [mcp]
        enabled = ${lib.boolToString cfg.enableMCPGateway}
        port = ${toString cfg.mcpGatewayPort}
      '';

      # Make agent management tools available system-wide
      systemPackages = with pkgs; [
        agentos.cli
      ] ++ lib.optionals config.agentos.daemons.enable [
        agentos.daemon
        agentos.mcp-gateway
      ] ++ [
        git
        jq
        curl
        ripgrep
        fd
      ];
    };
  };
}
