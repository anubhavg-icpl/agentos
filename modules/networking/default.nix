# AgentOS networking module
# Internal bridge for agent containers, model API gateway, DNS
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.networking;
in
{
  options.agentos.networking = {
    enable = lib.mkEnableOption "AgentOS networking";

    agentNetCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.200.0.0/24";
      description = "Subnet for agent containers";
    };

    modelGatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port for the LLM model gateway (budget/rate-limit proxy)";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Network bridge for agent containers ────────────────────────────
    networking.bridges.agentos0.interfaces = [ ];

    networking.interfaces.agentos0.ipv4.addresses = [{
      address = lib.head (lib.splitString "." (lib.head (lib.splitString "/" cfg.agentNetCIDR)));
      # Use .1 as the host on the agent subnet
      address = "10.200.0.1";
      prefixLength = 24;
    }];

    # ─ NAT for agent subnet ───────────────────────────────────────────
    networking.nat = {
      enable = true;
      internalInterfaces = [ "agentos0" ];
      externalInterface = "eth0";  # adjust per host
    };

    # ─ IP forwarding ──────────────────────────────────────────────────
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
    };

    # ─ Model API Gateway ─────────────────────────────────────────────
    # A proxy that sits between agents and LLM APIs.
    # Enforces: budget caps, rate limits, per-agent quotas, logging,
    #           fallback models, provider health checks.
    systemd.services.agentos-model-gateway = {
      description = "AgentOS LLM Model Gateway";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        GATEWAY_PORT = toString cfg.modelGatewayPort;
        GATEWAY_CONFIG = "/var/lib/agentos/model-gateway.toml";
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.model-gateway}/bin/agentos-model-gateway";
        Restart = "on-failure";
        RestartSec = 3;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Model gateway config ──────────────────────────────────────────
    environment.etc."agentos/model-gateway.toml".text = ''
      [gateway]
      port = ${toString cfg.modelGatewayPort}

      [providers.anthropic]
      base_url = "https://api.anthropic.com"
      env_key = "ANTHROPIC_API_KEY"
      default_model = "claude-sonnet-4-20250514"
      rate_limit_rpm = 50

      [providers.openai]
      base_url = "https://api.openai.com/v1"
      env_key = "OPENAI_API_KEY"
      default_model = "gpt-4o"
      rate_limit_rpm = 50

      [providers.google]
      base_url = "https://generativelanguage.googleapis.com/v1beta"
      env_key = "GOOGLE_API_KEY"
      default_model = "gemini-2.0-flash"
      rate_limit_rpm = 60

      [budget]
      default_daily_budget_usd = 50.0
      alert_threshold_pct = 80

      [logging]
      log_dir = "/var/lib/agentos/logs/model-gateway"
      log_requests = true
      log_responses = false  # set true for debugging only
    '';

    networking.firewall.allowedTCPPorts = [ cfg.modelGatewayPort ];
  };
}
