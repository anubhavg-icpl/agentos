# AgentOS Cloud: persistent VMs for people and agents (the exe.dev feature
# set, self-hosted). docs/cloud.md.
#
#   - agentos-cloudd (user agentos-cloud): the control plane: POST /exec,
#     the proxy auth gate, login (SSH magic links, OIDC), share links,
#     custom domains, the integrations proxy and metadata service on the VM
#     bridge, metering
#   - agentos-cloud-vmd (root): runs VMs as systemd-nspawn machines with
#     persistent ext4 disks, user namespaces, pool slices and an isolated
#     bridge port each
#   - sshd: `ssh lobby@<host> <command>` (AuthorizedKeysCommand + forced
#     command), `ssh lobby@<host> ssh <vm>` for a shell in a VM
#   - Caddy: https://<domain> and https://<vm>.<domain> (and custom domains)
#     with on-demand certificates, forward_auth to agentos-cloudd
#   - dnsmasq on the bridge: VMs resolve the internet and *.int.<domain>
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.cloud;
  net = config.agentos.networking;

  octets = lib.splitString "." (lib.head (lib.splitString "/" cfg.vmNetwork));
  prefixLength = lib.toInt (lib.last (lib.splitString "/" cfg.vmNetwork));
  gatewayIp = lib.concatStringsSep "." (lib.take 3 octets ++ [ "1" ]);
  bridge = "agentoscl0";
  metadataIp = "169.254.169.254";
  intPort = cfg.integrationsPort;

  image = pkgs.callPackage ../../nixos/packages/cloud/image.nix {
    packages = cfg.image.packages ++ lib.optional cfg.agentUi.enable pkgs.agentos.shelley;
  };
  initScript = ../../nixos/packages/cloud/init.sh;

  llmEnabled = cfg.llm.enable && net.enable;
  scheme = if cfg.tls.mode == "off" then "http" else "https";
  lobbyCmd = "${pkgs.agentos.services}/bin/agentos-cloud-lobby";
  web = "127.0.0.1:${toString cfg.webPort}";

  userType = lib.types.submodule {
    options = {
      email = lib.mkOption { type = lib.types.str; description = "Login email (the user's identity)"; };
      admin = lib.mkOption { type = lib.types.bool; default = false; description = "May run the `admin` commands"; };
      plan = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "personal" "work" "enterprise" ]);
        default = null;
        description = "Plan (null: agentos.cloud.defaultPlan)";
      };
      keys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "SSH public keys (`ssh-ed25519 AAAA... comment`)";
      };
    };
  };

  integrationType = lib.types.submodule {
    options = {
      name = lib.mkOption { type = lib.types.str; description = "Reached from VMs as http://<name>.int.<domain>"; };
      type = lib.mkOption { type = lib.types.enum [ "http-proxy" "github" ]; description = "Integration type"; };
      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Upstream base URL (http-proxy)";
      };
      repositories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "owner/name or owner/* (github)";
      };
      readOnly = lib.mkOption { type = lib.types.bool; default = false; description = "Refuse git pushes (github)"; };
      bearerFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "File with the token sent as the bearer credential (read by agentos-cloud at request time)";
      };
      headerFiles = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = { };
        description = "Header name -> file holding its value";
      };
      attach = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "auto:all" ];
        description = "vm:<name>, tag:<tag> or auto:all";
      };
      comment = lib.mkOption { type = lib.types.str; default = ""; description = "Shown to VMs by the reflection integration"; };
    };
  };

  vmSite = ''
    handle /__agentos/* {
      reverse_proxy ${web}
    }
    handle {
      route {
        request_header -X-AgentOS-Upstream
        request_header -X-AgentOS-Email
        request_header -X-AgentOS-UserID
        request_header -X-AgentOS-Token-Ctx
        request_header -X-ExeDev-Email
        request_header -X-ExeDev-UserID
        request_header -X-ExeDev-Token-Ctx
        forward_auth ${web} {
          uri /__auth
          header_up X-Forwarded-Host {host}
          header_up X-Forwarded-Port {http.request.port}
          copy_headers X-AgentOS-Upstream X-AgentOS-Email X-AgentOS-UserID X-AgentOS-Token-Ctx X-ExeDev-Email X-ExeDev-UserID X-ExeDev-Token-Ctx
        }
        request_header -X-AgentOS-Authorization
        request_header -X-Exedev-Authorization
        reverse_proxy {http.request.header.X-AgentOS-Upstream} {
          header_up -X-AgentOS-Upstream
          flush_interval -1
          transport http {
            dial_timeout 10s
          }
        }
      }
    }
  '';
  tlsDirective = {
    internal = "tls internal {\n  on_demand\n}";
    acme = "tls {\n  on_demand\n}";
    off = "";
  }.${cfg.tls.mode};
  site = addr: body: ''
    ${addr} {
      ${tlsDirective}
      ${body}
    }
  '';
  prefix = if cfg.tls.mode == "off" then "http://" else "https://";
in
{
  options.agentos.cloud = {
    enable = lib.mkEnableOption "AgentOS Cloud: persistent VMs with an HTTPS proxy, sharing and integrations (docs/cloud.md)";

    domain = lib.mkOption {
      type = lib.types.str;
      example = "cloud.example.com";
      description = ''
        The lobby's domain. VMs are served at <vm>.<domain> (and
        <vm>-<port>.<domain>), integrations at <name>.int.<domain>. Point
        <domain> and *.<domain> at this host.
      '';
    };
    sshHost = lib.mkOption {
      type = lib.types.str;
      default = cfg.domain;
      defaultText = lib.literalExpression "config.agentos.cloud.domain";
      description = "Host name users ssh to (`ssh lobby@<sshHost>`)";
    };
    lobbyUser = lib.mkOption { type = lib.types.str; default = "lobby"; description = "SSH user of the control plane"; };
    region = lib.mkOption { type = lib.types.str; default = "local"; description = "Region name of this host"; };
    regionDisplay = lib.mkOption { type = lib.types.str; default = cfg.region; defaultText = lib.literalExpression "region"; description = "Display name of the region"; };

    tls = {
      mode = lib.mkOption {
        type = lib.types.enum [ "internal" "acme" "off" ];
        default = "internal";
        description = ''
          internal: Caddy's own CA (LAN, tests); acme: public certificates
          issued on demand (for <domain>, each VM host and each custom
          domain; the host must be reachable on ports 80 and 443); off: plain
          HTTP (behind another TLS terminator)
        '';
      };
      email = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "ACME account email"; };
    };
    extraPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      example = [ 8000 8080 ];
      description = "Also serve https://<vm>.<domain>:<port>/ for these ports (always available: https://<vm>-<port>.<domain>/)";
    };
    openFirewall = lib.mkOption { type = lib.types.bool; default = true; description = "Open 80, 443 and extraPorts"; };

    vmNetwork = lib.mkOption {
      type = lib.types.str;
      default = "10.210.0.0/16";
      description = "Private network of the VMs (the host is .1)";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/agentos-cloud-vms";
      description = "Where VM disks live (sparse ext4 images)";
    };
    defaultPlan = lib.mkOption {
      type = lib.types.enum [ "personal" "work" "enterprise" ];
      default = "work";
      description = "Plan of new users (quotas; docs/cloud.md#plans)";
    };
    planOverrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.oneOf [ lib.types.int lib.types.bool ]));
      default = { };
      example = { personal.pool_vms = 10; };
      description = "Per-plan limit overrides (keys as in services/agentos_services/cloud/plans.py)";
    };
    defaultDiskGB = lib.mkOption { type = lib.types.ints.positive; default = 20; description = "Disk of a new VM without --disk"; };
    defaultPort = lib.mkOption { type = lib.types.port; default = 80; description = "Port the proxy forwards to without `share port`"; };
    allowOciImages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow `new --image <registry image>` (pulled with skopeo; the host needs registry access)";
    };
    verifyDns = lib.mkOption { type = lib.types.bool; default = true; description = "`domain add` checks that the domain points here"; };
    publicAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "This host's public addresses, for the DNS check (empty: resolve <vm>.<domain>)";
    };
    users = lib.mkOption { type = lib.types.listOf userType; default = [ ]; description = "Declared users (added, never removed)"; };
    usersCreateTeams = lib.mkOption { type = lib.types.bool; default = true; description = "Users may `team create`"; };
    usersInvite = lib.mkOption { type = lib.types.bool; default = true; description = "Users may `invite create`"; };
    integrations = lib.mkOption {
      type = lib.types.listOf integrationType;
      default = [ ];
      description = "System integrations (visible to every user's VMs they are attached to)";
    };
    llm = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          The `llm` integration: VMs reach the AgentOS model gateway at
          http://llm.int.<domain> (Anthropic /v1/messages, OpenAI
          /v1/chat/completions and /v1/responses, /models.json), metered
          and budgeted per VM, with no provider key in the VM. Needs
          agentos.networking.enable.
        '';
      };
      attach = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "auto:all" ]; description = "Where the llm integration is attached"; };
    };
    oidc = {
      issuer = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; example = "https://accounts.google.com"; description = "OIDC issuer for browser login (team SSO)"; };
      name = lib.mkOption { type = lib.types.str; default = "single sign-on"; description = "Button label"; };
      clientId = lib.mkOption { type = lib.types.str; default = ""; description = "OIDC client id"; };
      clientSecretFile = lib.mkOption { type = lib.types.nullOr lib.types.path; default = null; description = "File with the client secret"; };
      allowedDomains = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Email domains that may sign up through OIDC (empty: any)"; };
      createUsers = lib.mkOption { type = lib.types.bool; default = true; description = "Create an account on the first OIDC login"; };
    };
    image.packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        coreutils findutils gnugrep gnused gawk gnutar gzip xz zstd unzip which less file procps psmisc
        iproute2 iputils curl wget openssh rsync git gh jq ripgrep fd tmux htop vim nano
        python3 nodejs uv gnumake gcc podman docker-client
      ] ++ lib.filter (p: p != null) (map (n: pkgs.agentos.${n} or null) [ "claude-code" "codex" "gemini-cli" "opencode" "goose" ]);
      defaultText = lib.literalExpression "common developer tools, podman, Claude Code, Codex, Gemini CLI, OpenCode, Goose";
      description = ''
        Tools of the `agentos` VM image, from the host's Nix store (VMs see it
        read-only, so they cost no disk per VM). Agents in VMs use the llm
        integration, so they need no API keys.
      '';
    };
    agentUi.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run Shelley (exe.dev's web agent) in VMs on port 9999: https://<vm>-9999.<domain>/";
    };
    promptCommand = lib.mkOption {
      type = lib.types.str;
      default = "claude --dangerously-skip-permissions -p";
      description = "What `new --prompt <text>` runs in the new VM (the prompt is the last argument)";
    };
    webPort = lib.mkOption { type = lib.types.port; default = 9940; description = "Loopback port of agentos-cloudd's web listener"; };
    metricsPort = lib.mkOption { type = lib.types.port; default = 9941; description = "Loopback Prometheus port"; };
    integrationsPort = lib.mkOption {
      type = lib.types.port;
      default = 9942;
      description = "Port of the integrations proxy on the bridge address (VMs use port 80; the host redirects it)";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.tls.mode != "acme" || cfg.tls.email != null;
          message = "agentos.cloud.tls.mode = \"acme\" needs agentos.cloud.tls.email";
        }
        {
          assertion = cfg.oidc.issuer == null || (cfg.oidc.clientId != "" && cfg.oidc.clientSecretFile != null);
          message = "agentos.cloud.oidc needs clientId and clientSecretFile";
        }
        {
          assertion = builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.0/(1[6-9]|2[0-4])" cfg.vmNetwork != null;
          message = "agentos.cloud.vmNetwork must be an IPv4 network a.b.c.0/16 to /24";
        }
        {
          assertion = !(config.agentos.factory.enable or false) || !(lib.elem (config.agentos.factory.metricsPort or 0) [ cfg.webPort cfg.metricsPort ]);
          message = "agentos.cloud web or metrics port collides with agentos.factory.metricsPort";
        }
      ];
      warnings = lib.optional (cfg.llm.enable && !net.enable)
        "agentos.cloud.llm needs agentos.networking.enable (the model gateway); VMs get no llm integration";

      users.groups.agentos-cloud = { };
      users.users.agentos-cloud = {
        isSystemUser = true;
        group = "agentos-cloud";
        home = "/var/lib/agentos-cloud";
        extraGroups = [ "redis-agentos" ] ++ lib.optional llmEnabled "agentos";
      };
      users.users.${cfg.lobbyUser} = {
        isSystemUser = true;
        group = "agentos-cloud";
        home = "/var/empty";
        shell = pkgs.bashInteractive;
        description = "AgentOS Cloud lobby (ssh ${cfg.lobbyUser}@${cfg.sshHost})";
      };

      agentos.services.settings.cloud = {
        inherit (cfg) domain region;
        region_display = cfg.regionDisplay;
        ssh_host = cfg.sshHost;
        lobby_user = cfg.lobbyUser;
        tls = cfg.tls.mode;
        vm_network = cfg.vmNetwork;
        gateway_ip = gatewayIp;
        metadata_ip = metadataIp;
        integrations_port = intPort;
        default_port = cfg.defaultPort;
        default_plan = cfg.defaultPlan;
        default_disk_gb = cfg.defaultDiskGB;
        plan_overrides = cfg.planOverrides;
        allow_oci_images = cfg.allowOciImages;
        verify_dns = cfg.verifyDns;
        public_addresses = cfg.publicAddresses;
        extra_ports = cfg.extraPorts;
        images.agentos = "${image}";
        default_image = "agentos";
        users_create_teams = cfg.usersCreateTeams;
        users_invite = cfg.usersInvite;
        web_port = cfg.webPort;
        metrics_port = cfg.metricsPort;
        lobby_command = lobbyCmd;
        lobby_socket = "/run/agentos-cloud/lobby.sock";
        secret_key_file = "/var/lib/agentos-cloud/secret.key";
        pricing_file = "/etc/agentos/pricing.json";
        agent_ui_port = 9999;
        users = map (u: { inherit (u) email admin keys; } // lib.optionalAttrs (u.plan != null) { inherit (u) plan; }) cfg.users;
        integrations = map
          (i: {
            inherit (i) name type repositories attach comment;
            read_only = i.readOnly;
            header_files = lib.mapAttrs (_: toString) i.headerFiles;
          } // lib.optionalAttrs (i.target != null) { inherit (i) target; }
            // lib.optionalAttrs (i.bearerFile != null) { bearer_file = toString i.bearerFile; })
          cfg.integrations
        ++ lib.optional llmEnabled { name = "llm"; type = "llm"; attach = cfg.llm.attach; comment = "AgentOS model gateway"; };
        oidc = lib.optionalAttrs (cfg.oidc.issuer != null) {
          inherit (cfg.oidc) issuer name;
          client_id = cfg.oidc.clientId;
          client_secret_file = toString cfg.oidc.clientSecretFile;
          allowed_domains = cfg.oidc.allowedDomains;
          create_users = cfg.oidc.createUsers;
        };
        vmd = {
          socket = "/run/agentos-cloud-vmd/vmd.sock";
          socket_group = "agentos-cloud";
          allowed_users = [ "agentos-cloud" ];
          state_dir = cfg.stateDir;
          bridge = bridge;
          gateway_ip = gatewayIp;
          prefix_len = prefixLength;
          images.agentos = "${image}";
          profile = "${image.profile}";
          init = "${initScript}";
          prompt_command = cfg.promptCommand;
          nix_store = "/nix/store";
        };
      } // lib.optionalAttrs llmEnabled {
        gateway_url = "http://127.0.0.1:${toString net.modelGatewayPort}";
        gateway_admin_socket = config.agentos.services.settings.gateway.admin_socket;
      };

      # ─ the VM helper (root) ─────────────────────────────────────────
      boot.kernelModules = [ "loop" "bridge" ];
      systemd.services.agentos-cloud-vmd = {
        description = "AgentOS Cloud VM helper";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-addresses-${bridge}.service" "local-fs.target" ];
        wants = [ "network-addresses-${bridge}.service" ];
        restartTriggers = [ config.environment.etc."agentos/services.toml".source ];
        path = with pkgs; [ systemd util-linux e2fsprogs iproute2 nftables coreutils skopeo umoci gnutar gzip ];
        serviceConfig = {
          Type = "notify";
          ExecStart = "${pkgs.agentos.services}/bin/agentos-cloud-vmd";
          Restart = "on-failure";
          RestartSec = 2;
          RuntimeDirectory = "agentos-cloud-vmd";
          RuntimeDirectoryMode = "0750";
          RuntimeDirectoryPreserve = "yes";
          # VMs are units of their own: restarting the helper leaves them running
          KillMode = "process";
        };
      };
      systemd.tmpfiles.rules = [
        "d ${cfg.stateDir} 0700 root root -"
        "d ${cfg.stateDir}/vms 0700 root root -"
        "z /run/agentos-cloud-vmd 0750 root agentos-cloud -"
      ];

      # ─ the control plane ────────────────────────────────────────────
      systemd.services.agentos-cloud = {
        description = "AgentOS Cloud control plane";
        wantedBy = [ "multi-user.target" ];
        after = [ "redis-agentos.service" "agentos-cloud-vmd.service" "network-addresses-${bridge}.service" ]
          ++ lib.optional llmEnabled "agentos-gateway.service";
        requires = [ "redis-agentos.service" ];
        wants = [ "agentos-cloud-vmd.service" ];
        restartTriggers = [ config.environment.etc."agentos/services.toml".source ];
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "all";
          User = "agentos-cloud";
          Group = "agentos-cloud";
          ExecStart = "${pkgs.agentos.services}/bin/agentos-cloudd";
          Restart = "on-failure";
          RestartSec = 3;
          StateDirectory = "agentos-cloud";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "agentos-cloud";
          RuntimeDirectoryMode = "0750";
          UMask = "0007";
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
        };
      };

      # ─ the lobby over SSH ───────────────────────────────────────────
      # sshd wants the AuthorizedKeysCommand in root-owned directories that
      # no group can write (unlike /nix/store): a copied file in /etc/ssh
      environment.etc."ssh/agentos-cloud-keys" = {
        mode = "0755";
        text = ''
          #!${pkgs.runtimeShell}
          exec ${lobbyCmd} keys "$@"
        '';
      };
      services.openssh.enable = true;
      services.openssh.extraConfig = ''
        Match User ${cfg.lobbyUser}
          AuthorizedKeysFile none
          AuthorizedKeysCommand /etc/ssh/agentos-cloud-keys %t %k
          AuthorizedKeysCommandUser ${cfg.lobbyUser}
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          AllowTcpForwarding no
          AllowStreamLocalForwarding no
          AllowAgentForwarding no
          X11Forwarding no
          PermitTunnel no
          PermitTTY yes
          SetEnv AGENTOS_CLOUD_LOBBY_SOCKET=/run/agentos-cloud/lobby.sock
      '';

      # ─ the VM network ───────────────────────────────────────────────
      networking.bridges.${bridge}.interfaces = [ ];
      networking.interfaces.${bridge}.ipv4.addresses = [{ address = gatewayIp; inherit prefixLength; }];
      # Port 80 of the bridge address and of the metadata address go to the
      # integrations proxy (Caddy has port 80 on every other address)
      systemd.services.agentos-cloud-redirect = {
        description = "AgentOS Cloud: redirect VM port 80 to the integrations proxy";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-addresses-${bridge}.service" "firewall.service" "nat.service" ];
        wants = [ "network-addresses-${bridge}.service" ];
        path = [ pkgs.iptables ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          iptables -w -t nat -N agentos-cloud-pre 2>/dev/null || iptables -w -t nat -F agentos-cloud-pre
          iptables -w -t nat -C PREROUTING -i ${bridge} -j agentos-cloud-pre 2>/dev/null \
            || iptables -w -t nat -I PREROUTING 1 -i ${bridge} -j agentos-cloud-pre
          for dst in ${gatewayIp} ${metadataIp}; do
            iptables -w -t nat -A agentos-cloud-pre -d "$dst" -p tcp --dport 80 -j DNAT --to-destination ${gatewayIp}:${toString intPort}
          done
        '';
        preStop = ''
          iptables -w -t nat -D PREROUTING -i ${bridge} -j agentos-cloud-pre 2>/dev/null || true
          iptables -w -t nat -F agentos-cloud-pre 2>/dev/null || true
          iptables -w -t nat -X agentos-cloud-pre 2>/dev/null || true
        '';
      };
      networking.nat = {
        enable = true;
        internalInterfaces = [ bridge ];
      };
      # VMs reach the host only for DNS, the integrations proxy and the
      # metadata service; everything else of the host is closed to them
      networking.firewall.extraCommands = ''
        iptables -D INPUT -i ${bridge} -j agentos-cloud-in 2>/dev/null || true
        iptables -F agentos-cloud-in 2>/dev/null || iptables -N agentos-cloud-in
        iptables -I INPUT 1 -i ${bridge} -j agentos-cloud-in
        iptables -A agentos-cloud-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A agentos-cloud-in -d ${gatewayIp} -p tcp --dport ${toString intPort} -j ACCEPT
        iptables -A agentos-cloud-in -d ${gatewayIp} -p udp --dport 53 -j ACCEPT
        iptables -A agentos-cloud-in -d ${gatewayIp} -p tcp --dport 53 -j ACCEPT
        iptables -A agentos-cloud-in -p icmp --icmp-type echo-request -j ACCEPT
        iptables -A agentos-cloud-in -j REJECT
        ip6tables -D INPUT -i ${bridge} -j DROP 2>/dev/null || true
        ip6tables -I INPUT 1 -i ${bridge} -j DROP
      '';
      networking.firewall.extraStopCommands = ''
        iptables -D INPUT -i ${bridge} -j agentos-cloud-in 2>/dev/null || true
        iptables -F agentos-cloud-in 2>/dev/null || true
        iptables -X agentos-cloud-in 2>/dev/null || true
        ip6tables -D INPUT -i ${bridge} -j DROP 2>/dev/null || true
      '';
      networking.firewall.allowedTCPPorts = lib.optionals cfg.openFirewall ([ 80 443 ] ++ cfg.extraPorts);
      networking.nftables.enable = lib.mkDefault false;
      environment.systemPackages = [ pkgs.nftables ];

      # VMs resolve through the host; integration hosts point at the bridge
      systemd.services.agentos-cloud-dns = {
        description = "AgentOS Cloud resolver for VMs";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-addresses-${bridge}.service" ];
        wants = [ "network-addresses-${bridge}.service" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=/dev/null --bind-interfaces"
            "--listen-address=${gatewayIp} --except-interface=lo --no-dhcp-interface=${bridge}"
            "--address=/int.${cfg.domain}/${gatewayIp} --address=/team.${cfg.domain}/${gatewayIp}"
            "--resolv-file=/etc/resolv.conf --cache-size=1000 --user=dnsmasq --group=dnsmasq"
          ];
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
      users.users.dnsmasq = lib.mkDefault { isSystemUser = true; group = "dnsmasq"; };
      users.groups.dnsmasq = lib.mkDefault { };
      services.dnsmasq.settings.bind-interfaces = lib.mkIf config.services.dnsmasq.enable (lib.mkDefault true);

      # ─ HTTPS: Caddy in front of the lobby and every VM ──────────────
      services.caddy = {
        enable = true;
        email = cfg.tls.email;
        globalConfig = lib.optionalString (cfg.tls.mode != "off") ''
          on_demand_tls {
            ask http://${web}/__agentos/tls-ask
          }
        '' + lib.optionalString (cfg.tls.mode == "off") ''
          auto_https off
        '';
        extraConfig = lib.concatStringsSep "\n" ([
          (site "${prefix}${cfg.domain}" "respond /__auth 404\nreverse_proxy ${web}")
          (site "${prefix}*.${cfg.domain}" vmSite)
          # custom domains (`domain add`), certificates on demand
          (site prefix vmSite)
        ]
        ++ map (p: site "${prefix}*.${cfg.domain}:${toString p}" vmSite) cfg.extraPorts);
      };
    }

    (lib.mkIf config.agentos.observability.enable {
      services.prometheus.scrapeConfigs = [{
        job_name = "agentos-cloud";
        static_configs = [{ targets = [ "127.0.0.1:${toString cfg.metricsPort}" ]; }];
      }];
    })
  ]);
}
