# AgentOS networking module
# Model API gateway, agent bridge network and NAT
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.networking;
  cidrParts = lib.splitString "/" cfg.agentNetCIDR;
  octets = lib.splitString "." (lib.head cidrParts);
  hostAddress = lib.concatStringsSep "." (lib.take 3 octets ++ [ "1" ]);
  prefixLength = lib.toInt (lib.last cidrParts);

  hostOf = url:
    let m = builtins.match "[a-z]+://([^/:]+).*" url;
    in if m == null then null else lib.head m;
in
{
  options.agentos.networking = {
    enable = lib.mkEnableOption "AgentOS networking and the model gateway";

    agentNetCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.200.0.0/24";
      description = "Subnet for agent containers";
    };

    natExternalInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp1s0";
      description = "Uplink interface for NAT of the agent subnet (null: any)";
    };

    modelGatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port of the LLM model gateway. It listens on 127.0.0.1 and on the
        agent bridge address, so container-isolated agents can reach it.
      '';
    };

    bridgeAddress = lib.mkOption {
      type = lib.types.str;
      default = hostAddress;
      readOnly = true;
      description = "Address of the host on the agent bridge (agentos0): the .1 of agentNetCIDR";
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          baseUrl = lib.mkOption {
            type = lib.types.str;
            description = "Upstream API base URL";
          };
          api = lib.mkOption {
            type = lib.types.enum [ "anthropic" "openai" ];
            description = "Wire format, used to read token usage from responses";
          };
          keyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              File holding the provider API key. When readable by the gateway,
              agents get the placeholder key "agentos-managed" and the gateway
              injects the real one, so agents never see it.
            '';
          };
        };
      });
      default = { };
      description = "LLM providers routed through the gateway at /agent/<id>/<name>/...";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.agentos.runtime.enable;
      message = "agentos.networking (the model gateway) needs agentos.runtime.enable";
    }];

    agentos.networking.providers = {
      anthropic = {
        baseUrl = lib.mkDefault "https://api.anthropic.com";
        api = "anthropic";
        keyFile = lib.mkDefault "/run/secrets/ANTHROPIC_API_KEY";
      };
      openai = {
        baseUrl = lib.mkDefault "https://api.openai.com";
        api = "openai";
        keyFile = lib.mkDefault "/run/secrets/OPENAI_API_KEY";
      };
    };

    # Only the gateway may reach the provider APIs from the agent user
    agentos.security.gatewayOnlyDomains =
      lib.filter (h: h != null && h != "localhost" && builtins.match "[0-9.]+" h == null)
        (lib.mapAttrsToList (_: p: hostOf p.baseUrl) cfg.providers);

    agentos.services.settings = {
      gateway = {
        listen = [ "127.0.0.1" hostAddress ];
        port = cfg.modelGatewayPort;
        pricing_file = "/etc/agentos/pricing.json";
      };
      providers = lib.mapAttrs (_: p: {
        base_url = p.baseUrl;
        inherit (p) api;
      } // lib.optionalAttrs (p.keyFile != null) { key_file = p.keyFile; }) cfg.providers;
    };

    environment.etc."agentos/pricing.json".source = lib.mkDefault ../budget-controller/pricing.json;

    # ─ Model gateway ──────────────────────────────────────────────────
    systemd.services.agentos-model-gateway = {
      description = "AgentOS model gateway (LLM proxy with budgets and rate limits)";
      # The bridge address must exist to bind to it (Restart retries otherwise)
      after = [ "network.target" "redis-agentos.service" "network-addresses-agentos0.service" ];
      requires = [ "redis-agentos.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        config.environment.etc."agentos/services.toml".source
        config.environment.etc."agentos/pricing.json".source
      ];

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        SupplementaryGroups = [ "redis-agentos" ];
        ExecStart = "${pkgs.agentos.services}/bin/agentos-model-gateway";
        Restart = "on-failure";
        RestartSec = 3;
        # Admin socket: reachable by the agentos group (operators), not agents
        RuntimeDirectory = "agentos-gateway";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/agentos/logs" ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    # ─ Bridge + NAT for agent containers ──────────────────────────────
    networking.bridges.agentos0.interfaces = [ ];
    networking.interfaces.agentos0.ipv4.addresses = [{
      address = hostAddress;
      inherit prefixLength;
    }];

    # Container-isolated agents reach the host only through the gateway and
    # the resolver. This chain comes before the global allowed ports (e.g.
    # SSH), which would otherwise apply to the bridge as well.
    networking.firewall.extraCommands = ''
      iptables -D INPUT -i agentos0 -j agentos-in 2>/dev/null || true
      iptables -F agentos-in 2>/dev/null || iptables -N agentos-in
      iptables -I INPUT 1 -i agentos0 -j agentos-in
      iptables -A agentos-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -A agentos-in -d ${hostAddress} -p tcp --dport ${toString cfg.modelGatewayPort} -j ACCEPT
      iptables -A agentos-in -d ${hostAddress} -p udp --dport 53 -j ACCEPT
      iptables -A agentos-in -d ${hostAddress} -p tcp --dport 53 -j ACCEPT
      iptables -A agentos-in -d ${hostAddress} -p icmp --icmp-type echo-request -j ACCEPT
      iptables -A agentos-in -j REJECT
      ip6tables -D INPUT -i agentos0 -j DROP 2>/dev/null || true
      ip6tables -I INPUT 1 -i agentos0 -j DROP
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D INPUT -i agentos0 -j agentos-in 2>/dev/null || true
      iptables -F agentos-in 2>/dev/null || true
      iptables -X agentos-in 2>/dev/null || true
      ip6tables -D INPUT -i agentos0 -j DROP 2>/dev/null || true
    '';

    # The resolver answers on the bridge for containers (and, with egress
    # denied, only resolves allowed domains and fills the egress ipsets)
    services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
      settings.listen-address = [ hostAddress ];
    };
    systemd.services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
      after = [ "network-addresses-agentos0.service" ];
      wants = [ "network-addresses-agentos0.service" ];
      serviceConfig.Restart = lib.mkDefault "on-failure";
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ "agentos0" ];
      externalInterface = cfg.natExternalInterface;
    };
  };
}
