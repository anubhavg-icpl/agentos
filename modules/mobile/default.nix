# Nestlo mobile module
#
# Pairs an Android phone with this machine and serves it over TLS
# (protocol: docs/mobile-protocol.md, guide: docs/mobile.md):
#
#   - nestlo-mobile.service: the server (7443, HTTPS and WebSocket) with
#     agents, spend, approvals, live events, terminals and an optional desktop
#   - a plain-HTTP onboarding listener (7080) with the landing page behind the
#     pairing QR code and the app download page
#   - `nestlo-mobile pair|devices|revoke|url` for operators (admin group)
#
# A paired phone gets a full shell as every user in terminal.users. Never
# expose the port to the internet without a VPN.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.mobile;
  rt = config.nestlo.runtime;
  desk = config.nestlo.desktop;
  services = pkgs.nestlo.services;
  agentUser = "nestlo-agent";
  auditOn = config.nestlo.audit.enable;
  tuiosOn = config.nestlo.tuios.enable or false;
  orchOn = config.nestlo.orchestration.enable or false;

  terminalUsers = lib.unique (cfg.terminal.users ++ lib.optional cfg.terminal.includeAgentUser agentUser);

  cli = pkgs.runCommand "nestlo-mobile-cli" { } ''
    mkdir -p $out/bin
    ln -s ${services}/bin/nestlo-mobile $out/bin/nestlo-mobile
  '';

  tn = cfg.tunnel;
  providerNames = [ "cloudflare" "cloudflare-named" "tailscale-funnel" "ngrok" "zrok" "pinggy" "localhost-run" "bore" "frp" ];
  isOn = n: tn.provider == n || tn.providers.${n}.enable;
  # Credentials: name inside the unit's credentials directory -> file on the host
  creds = lib.filterAttrs (_: v: v != null) {
    cf-token = tn.providers.cloudflare-named.tokenFile;
    ngrok-authtoken = tn.providers.ngrok.authtokenFile;
    zrok-token = tn.providers.zrok.tokenFile;
    bore-secret = tn.providers.bore.secretFile;
    frp-token = tn.providers.frp.tokenFile;
  };
  # Tool paths, only for providers in use (the packages of the others, ngrok is unfree, are never evaluated)
  bins = lib.optionalAttrs (isOn "cloudflare" || isOn "cloudflare-named") { cloudflared = "${tn.package}/bin/cloudflared"; }
    // lib.optionalAttrs (isOn "tailscale-funnel") { tailscale = "${tn.providers.tailscale-funnel.package}/bin/tailscale"; }
    // lib.optionalAttrs (isOn "ngrok") { ngrok = "${tn.providers.ngrok.package}/bin/ngrok"; }
    // lib.optionalAttrs (isOn "zrok") { zrok = "${tn.providers.zrok.package}/bin/zrok"; }
    // lib.optionalAttrs (isOn "pinggy" || isOn "localhost-run") {
      ssh = "${(if isOn "pinggy" then tn.providers.pinggy.package else tn.providers.localhost-run.package)}/bin/ssh";
    }
    // lib.optionalAttrs (isOn "bore") { bore = "${tn.providers.bore.package}/bin/bore"; }
    // lib.optionalAttrs (isOn "frp") { frpc = "${tn.providers.frp.package}/bin/frpc"; };
  tunnelConfig = builtins.toJSON {
    default = tn.provider;
    port = cfg.port;
    onboarding_port = cfg.onboarding.port;
    inherit bins;
    providers = {
      cloudflare = { enabled = isOn "cloudflare"; };
      cloudflare-named = {
        enabled = isOn "cloudflare-named";
        tokenCredential = if tn.providers.cloudflare-named.tokenFile != null then "cf-token" else "";
        url = cfg.publicUrl;
      };
      tailscale-funnel = { enabled = isOn "tailscale-funnel"; };
      ngrok = {
        enabled = isOn "ngrok";
        authtokenCredential = if tn.providers.ngrok.authtokenFile != null then "ngrok-authtoken" else "";
        domain = tn.providers.ngrok.domain;
      };
      zrok = {
        enabled = isOn "zrok";
        tokenCredential = if tn.providers.zrok.tokenFile != null then "zrok-token" else "";
        server = tn.providers.zrok.server;
      };
      pinggy = { enabled = isOn "pinggy"; };
      localhost-run = { enabled = isOn "localhost-run"; };
      bore = {
        enabled = isOn "bore";
        server = tn.providers.bore.server;
        secretCredential = if tn.providers.bore.secretFile != null then "bore-secret" else "";
      };
      frp = {
        enabled = isOn "frp";
        server = tn.providers.frp.server;
        serverPort = tn.providers.frp.serverPort;
        remotePort = tn.providers.frp.remotePort;
        tokenCredential = if tn.providers.frp.tokenFile != null then "frp-token" else "";
      };
    };
  };

  providerOpts = {
    enable = lib.mkEnableOption "offering this provider in `nestlo-mobile pair --via tunnel`";
  };
  fileOpt = description: lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    inherit description;
  };
  pkgOpt = default: lib.mkOption {
    type = lib.types.package;
    inherit default;
    defaultText = lib.literalMD "the nixpkgs package";
    description = "Package providing the tool (evaluated only when the provider is in use)";
  };

  # wayvnc has to run inside the desktop session: it needs the compositor's
  # Wayland socket, which exists only after the user logged in
  wayvncStart = pkgs.writeShellScript "nestlo-mobile-wayvnc" ''
    set -eu
    export XDG_RUNTIME_DIR=/run/user/$(${pkgs.coreutils}/bin/id -u)
    for _ in $(${pkgs.coreutils}/bin/seq 1 600); do
      sock=$(${pkgs.findutils}/bin/find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'wayland-[0-9]*' ! -name '*.lock' 2>/dev/null | ${pkgs.coreutils}/bin/head -n1 || true)
      [ -n "$sock" ] && break
      ${pkgs.coreutils}/bin/sleep 2
    done
    [ -n "$sock" ] || { echo "no Wayland session for $(${pkgs.coreutils}/bin/id -un)" >&2; exit 1; }
    export WAYLAND_DISPLAY=$(${pkgs.coreutils}/bin/basename "$sock")
    exec ${pkgs.wayvnc}/bin/wayvnc 127.0.0.1 5900
  '';
in
{
  options.nestlo.mobile = {
    enable = lib.mkEnableOption "the phone app server (pairing, agents, terminals, desktop)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 7443;
      description = "Port of the HTTPS and WebSocket API";
    };

    listen = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to bind";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open the API port and the onboarding port in the firewall. Reach the
        machine from your phone on the same LAN or over a VPN (Tailscale,
        WireGuard); never expose these ports to the internet.
      '';
    };

    advertisedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "nestlo.tailnet.ts.net" "192.168.1.20" ];
      description = "Hosts put into pairing links after `domain`, before the detected addresses";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "nestlo.example.org";
      description = "A name for this machine: the first host in pairing links and their entry host";
    };

    publicHost = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "A fixed public address or name, listed after the private addresses";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "https://nestlo.example.org";
      description = "Base URL of the landing page when it sits behind a reverse proxy (replaces http://host:7080)";
    };

    discoverPublicIp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Look up the public IP at https://api.ipify.org once per `nestlo-mobile pair` (the lookup sends this machine's address to that service)";
    };

    onboarding = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 7080;
        description = "Plain-HTTP port of the landing page (/pair) and the app page (/app)";
      };
      apk = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "An APK to serve at /app/nestlo.apk. Without it /app links to the GitHub release.";
      };
    };

    connect.default = lib.mkOption {
      type = lib.types.enum [ "lan" "tunnel" "tailscale" "url" ];
      default = "lan";
      description = "How `nestlo-mobile pair` connects the phone when it cannot ask (no terminal) and what it suggests";
    };

    tunnel = {
      enable = lib.mkEnableOption ''
        the `nestlo-mobile-tunnel` unit, so that `nestlo-mobile pair --via tunnel` can reach this machine from
        outside the network. The unit runs only while a tunnel is wanted, unless `persistent` is set.
        A tunnel exposes the API to the internet: pairing codes and device tokens remain the only protection'';

      persistent = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start the tunnel at boot (the address of a quick tunnel changes on every start)";
      };

      provider = lib.mkOption {
        type = lib.types.enum providerNames;
        default = "cloudflare";
        description = ''
          The provider used by `nestlo-mobile tunnel start` and `pair --via tunnel` without `--provider`.
          See docs/mobile.md for what each needs. `tailscale` (address only) needs no tunnel: use `--via tailscale`.
        '';
      };

      package = pkgOpt pkgs.cloudflared;

      providers = {
        cloudflare = providerOpts;
        cloudflare-named = providerOpts // {
          tokenFile = fileOpt "File with the token of a named Cloudflare tunnel (needs `publicUrl`)";
        };
        tailscale-funnel = providerOpts // { package = pkgOpt pkgs.tailscale; };
        ngrok = providerOpts // {
          authtokenFile = fileOpt "File with the ngrok authtoken";
          domain = lib.mkOption { type = lib.types.str; default = ""; description = "A reserved ngrok domain"; };
          package = pkgOpt pkgs.ngrok;
        };
        zrok = providerOpts // {
          tokenFile = fileOpt "File with the zrok account token (the unit runs `zrok enable` once)";
          server = lib.mkOption { type = lib.types.str; default = ""; description = "API endpoint of a self-hosted zrok (empty: zrok.io)"; };
          package = pkgOpt pkgs.zrok;
        };
        pinggy = providerOpts // { package = pkgOpt pkgs.openssh; };
        localhost-run = providerOpts // { package = pkgOpt pkgs.openssh; };
        bore = providerOpts // {
          server = lib.mkOption { type = lib.types.str; default = ""; description = "Your own bore server (empty: bore.pub)"; };
          secretFile = fileOpt "File with the secret of your bore server";
          package = pkgOpt pkgs.bore-cli;
        };
        frp = providerOpts // {
          server = lib.mkOption { type = lib.types.str; default = ""; description = "Address of your frps server"; };
          serverPort = lib.mkOption { type = lib.types.port; default = 7000; description = "Port of frps"; };
          remotePort = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; description = "Public TCP port on the frps server for 7443"; };
          tokenFile = fileOpt "File with the frps auth token";
          package = pkgOpt pkgs.frp;
        };
      };
    };

    adminGroup = lib.mkOption {
      type = lib.types.str;
      default = "wheel";
      description = "Group that may run `nestlo-mobile` (it owns the admin socket)";
    };

    terminal = {
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = lib.filter (u: config.users.users ? ${u}) rt.operators;
        defaultText = lib.literalExpression "the nestlo.runtime.operators that exist";
        description = "Users whose login shell (and TUIOS sessions) a paired phone may open";
      };
      includeAgentUser = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also allow terminals of the sandboxed agent user (nestlo-agent)";
      };
    };

    desktop = {
      enable = lib.mkEnableOption "streaming the desktop (wayvnc + noVNC) to the phone";
      user = lib.mkOption {
        type = lib.types.str;
        default = desk.autologin.user;
        defaultText = lib.literalExpression "config.nestlo.desktop.autologin.user";
        description = "The user whose desktop session is shared";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = rt.enable;
          message = "nestlo.mobile needs nestlo.runtime.enable";
        }
        {
          assertion = !tn.enable || !isOn "cloudflare-named" || (tn.providers.cloudflare-named.tokenFile != null && cfg.publicUrl != "");
          message = "nestlo.mobile.tunnel: cloudflare-named needs providers.cloudflare-named.tokenFile and nestlo.mobile.publicUrl";
        }
        {
          assertion = !cfg.desktop.enable || (desk.enable && desk.windowManager != "i3" && desk.autologin.enable);
          message = "nestlo.mobile.desktop needs nestlo.desktop with sway or hyprland (wayvnc captures wlroots compositors, not X11) and autologin";
        }
      ];

      environment.systemPackages = [ cli pkgs.qrencode ];
      networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port cfg.onboarding.port ];

      systemd.services.nestlo-mobile = {
        description = "Nestlo mobile server (phone pairing, agents, terminals)";
        after = [ "network-online.target" "redis-nestlo.service" ] ++ lib.optional auditOn "nestlo-audit.service";
        wants = [ "network-online.target" "redis-nestlo.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];
        environment.PATH = lib.mkForce (lib.concatStringsSep ":" [
          (lib.makeBinPath [ pkgs.util-linux pkgs.iproute2 pkgs.systemd pkgs.coreutils ])
          "/run/wrappers/bin"
          "/run/current-system/sw/bin"
        ]);

        serviceConfig = {
          # Root: terminals start as other users (runuser) and agents are stopped
          # with systemctl. Sessions inherit this unit's restrictions, so the
          # sandbox is limited to what a login shell can live with: no
          # ProtectSystem/ProtectHome/PrivateTmp (the phone's shell would not be
          # able to write anywhere) and no NoNewPrivileges (sudo must work).
          ExecStart = lib.escapeShellArgs ([
            "${services}/bin/nestlo-mobile-server"
            "--name" config.networking.hostName
            "--listen" cfg.listen
            "--port" (toString cfg.port)
            "--admin-group" cfg.adminGroup
            "--runuser" "${pkgs.util-linux}/bin/runuser"
            "--tuios-bin" (if tuiosOn then "/run/current-system/sw/bin/nestlo-tuios" else "/nonexistent/nestlo-tuios")
            "--onboarding-port" (toString cfg.onboarding.port)
          ]
          ++ lib.concatMap (u: [ "--terminal-user" u ]) terminalUsers
          ++ lib.concatMap (h: [ "--advertise-host" h ]) cfg.advertisedHosts
          ++ lib.optionals (cfg.domain != "") [ "--domain" cfg.domain ]
          ++ lib.optionals (cfg.publicHost != "") [ "--public-host" cfg.publicHost ]
          ++ lib.optionals (cfg.publicUrl != "") [ "--public-url" cfg.publicUrl ]
          ++ lib.optional cfg.discoverPublicIp "--discover-public-ip"
          ++ lib.optionals (cfg.onboarding.apk != null) [ "--onboarding-apk" (toString cfg.onboarding.apk) ]
          ++ [ "--connect-default" cfg.connect.default ]
          ++ lib.optionals tn.enable [
            "--tunnel-unit" "nestlo-mobile-tunnel"
            "--tunnel-dir" "/run/nestlo-mobile"
            "--tunnel-config" "/etc/nestlo/mobile-tunnel.json"
          ]
          ++ lib.optionals cfg.desktop.enable [ "--desktop-dir" "${pkgs.novnc}/share/webapps/novnc" ]
          ++ lib.optionals orchOn [ "--orchestrator-socket" "/run/nestlo-orchestrator/orchestrator.sock" ]
          ++ lib.optionals auditOn [ "--audit-socket" "/run/nestlo-audit/audit.sock" ]);
          Restart = "on-failure";
          RestartSec = 3;
          StateDirectory = "nestlo-mobile";
          StateDirectoryMode = "0700";
          RuntimeDirectory = "nestlo-mobile";
          RuntimeDirectoryMode = "0755";
          # tunnel.json is written by the tunnel unit and must survive a restart of the server
          RuntimeDirectoryPreserve = "yes";
          SupplementaryGroups = [ "redis-nestlo" ] ++ lib.optional auditOn "nestlo-audit";

          CapabilityBoundingSet = [
            "CAP_SETUID" "CAP_SETGID" # runuser
            "CAP_CHOWN" # group of the admin socket
            "CAP_DAC_OVERRIDE" "CAP_FOWNER" # agent state files, redis socket
            "CAP_KILL" # hang up sessions of other users
            "CAP_AUDIT_WRITE" # PAM
          ];
          NoNewPrivileges = false;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectClock = true;
          LockPersonality = true;
          RestrictRealtime = true;
          UMask = "0077";
        };
      };
    }

    (lib.mkIf tn.enable {
      environment.etc."nestlo/mobile-tunnel.json".text = tunnelConfig;
      systemd.services.nestlo-mobile.restartTriggers = [ (builtins.hashString "sha256" tunnelConfig) ];

      # One tunnel at a time. `nestlo-mobile pair --via tunnel` writes the provider's name to
      # /run/nestlo-mobile/tunnel-provider and (re)starts this unit; the adapter publishes the endpoint in
      # /run/nestlo-mobile/tunnel.json. Root, because tailscale funnel needs the tailscaled socket; everything
      # else is locked down: no capabilities, a read-only system, outbound network only.
      systemd.services.nestlo-mobile-tunnel = {
        description = "Nestlo mobile tunnel (${tn.provider} unless pair asks for another)";
        after = [ "network-online.target" "nestlo-mobile.service" ];
        wants = [ "network-online.target" ];
        partOf = [ "nestlo-mobile.service" ];
        wantedBy = lib.optional tn.persistent "multi-user.target";
        restartTriggers = [ (builtins.hashString "sha256" tunnelConfig) ];
        serviceConfig = {
          ExecStart = lib.escapeShellArgs [
            "${services}/bin/nestlo-mobile" "tunnel-run"
            "--config" "/etc/nestlo/mobile-tunnel.json"
            "--run-dir" "/run/nestlo-mobile"
            "--state-dir" "/var/lib/nestlo-mobile-tunnel"
          ];
          Restart = if tn.persistent then "on-failure" else "no";
          RestartSec = 10;
          StateDirectory = "nestlo-mobile-tunnel";
          StateDirectoryMode = "0700";
          LoadCredential = lib.mapAttrsToList (name: file: "${name}:${toString file}") creds;
          ReadWritePaths = [ "/run/nestlo-mobile" ];
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
          UMask = "0077";
        };
      };
    })

    (lib.mkIf cfg.desktop.enable {
      environment.systemPackages = [ pkgs.wayvnc ];
      systemd.services.nestlo-mobile-wayvnc = {
        description = "wayvnc for the Nestlo mobile app (loopback only)";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-user-sessions.service" ];
        serviceConfig = {
          User = cfg.desktop.user;
          ExecStart = wayvncStart;
          Restart = "always";
          RestartSec = 5;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        };
      };
    })
  ]);
}
