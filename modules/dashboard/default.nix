# Nestlo web dashboard
#
# A read-only status page and JSON API (agents, spend, gateway requests,
# service health). It runs as the `nestlo` user with no write access to
# anything, binds to 127.0.0.1 and requires a token (HTTP basic auth with the
# token as the password, or an `Authorization: Bearer` header). There is no
# unauthenticated mode. Reach it through an SSH tunnel:
#
#   ssh -L 8090:127.0.0.1:8090 admin@host      then open http://127.0.0.1:8090
#
# See docs/dashboard.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.dashboard;
in
{
  options.nestlo.dashboard = {
    enable = lib.mkEnableOption "the Nestlo web dashboard";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "Port of the dashboard";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address to bind. Keep it on loopback and use an SSH tunnel; the token
        is sent in cleartext HTTP, so only change this behind a TLS proxy.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/nestlo-dashboard-token";
      description = ''
        File holding the access token (at least 8 characters, e.g.
        `openssl rand -hex 24`). Required. The file is passed to the service
        as a systemd credential, so it can be root-only (mode 0400).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.nestlo.runtime.enable;
        message = "nestlo.dashboard needs nestlo.runtime.enable";
      }
      {
        assertion = cfg.tokenFile != null;
        message = "nestlo.dashboard.tokenFile must be set: the dashboard is never served without authentication";
      }
    ];

    systemd.services.nestlo-dashboard = {
      description = "Nestlo web dashboard (read-only)";
      after = [ "network.target" "redis-nestlo.service" ];
      wants = [ "redis-nestlo.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];

      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # The service sends READY=1 once listening and WATCHDOG=1 while healthy
        WatchdogSec = 30;
        TimeoutStartSec = 60;
        User = "nestlo";
        Group = "nestlo";
        SupplementaryGroups = [ "redis-nestlo" ];
        LoadCredential = lib.optional (cfg.tokenFile != null) "token:${toString cfg.tokenFile}";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.nestlo.services}/bin/nestlo-dashboard"
          "--listen ${cfg.address}"
          "--port ${toString cfg.port}"
          "--token-file %d/token"
        ];
        Restart = "on-failure";
        RestartSec = 3;

        # Read-only: no ReadWritePaths at all
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
      };
    };
  };
}
