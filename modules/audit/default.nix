# ═══════════════════════════════════════════════════════════════════════
# Nestlo Audit Module
# ═══════════════════════════════════════════════════════════════════════
#
# Tamper-evident audit log (services/nestlo_services/audit.py,
# docs/audit.md): EU AI Act Art. 12 record-keeping, SOC 2 CC7.2,
# ISO 27001 A.8.15.
#
#   nestlo-audit.service   the only writer of /var/lib/nestlo-audit, a
#                           dedicated user (nestlo-audit). The gateway,
#                           orchestrator, daemon and task runner send events
#                           over /run/nestlo-audit/audit.sock and cannot
#                           open, rewrite or delete the log files.
#   nestlo-audit-keygen    creates the Ed25519 checkpoint-signing key on
#                           first boot (root only); the writer receives it as
#                           the systemd credential `audit-signing-key`.
#
# Members of the group nestlo-audit can read the log (`nestlo-audit verify`
# and `tail`); `nestlo.audit.readers` defaults to the runtime operators.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.audit;
  stateDir = "/var/lib/nestlo-audit";
  credDir = "/run/credentials/nestlo-audit.service";
  exp = cfg.export;

  nonEmpty = lib.mkOption {
    type = lib.types.str;
    default = "";
  };
in
{
  options.nestlo.audit = {
    enable = lib.mkEnableOption "the tamper-evident audit log";

    retentionDays = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 183;
      description = ''
        Days to keep audit segments. Whole segments older than this are
        deleted (and the deletion is itself recorded in the chain). The
        default of 183 days is the six months that EU AI Act Art. 26(6)
        requires deployers of high-risk systems to keep automatically
        generated logs; a lower value triggers a warning, 0 keeps everything.
      '';
    };

    strict = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Fail closed: while the audit writer is unreachable the gateway
        answers 503 (audit_unavailable) and the orchestrator refuses to
        submit, approve or cancel tasks. When false the producers buffer
        events in memory (nestlo.audit.bufferEvents) and, if the writer
        stays down, drop and count them (the loss is written to the log once
        the writer returns).
      '';
    };

    bufferEvents = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1000;
      description = "Events each producer holds in memory while the writer is unreachable";
    };

    segmentSizeMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 64;
      description = "Start a new segment file at this size (and at every UTC midnight)";
    };

    checkpointEvery = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "Append a signed checkpoint after this many records (and every five minutes)";
    };

    readers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = config.nestlo.runtime.operators;
      defaultText = lib.literalExpression "config.nestlo.runtime.operators";
      description = "Users added to the group nestlo-audit, which may read the log";
    };

    export = {
      intervalSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Seconds between export polls when nothing is pending";
      };

      syslog = {
        enable = lib.mkEnableOption "export over syslog (RFC 5424, octet-counted, TCP)";
        host = nonEmpty;
        port = lib.mkOption {
          type = lib.types.port;
          default = 6514;
          description = "6514 is the registered port for syslog over TLS";
        };
        tls = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Wrap the connection in TLS and verify the server certificate";
        };
        caFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "CA certificate for the syslog server (null: the system store)";
        };
        hostname = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "HOSTNAME field of the messages (null: this machine's name)";
        };
      };

      splunk = {
        enable = lib.mkEnableOption "export to Splunk HTTP Event Collector";
        url = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "https://splunk.example.org:8088/services/collector/event";
        };
        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding the HEC token (read as a systemd credential)";
        };
        caFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
        index = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        sourcetype = lib.mkOption {
          type = lib.types.str;
          default = "nestlo:audit:ocsf";
        };
      };

      otlp = {
        enable = lib.mkEnableOption "export to an OTLP/HTTP logs endpoint";
        endpoint = lib.mkOption {
          type = lib.types.str;
          default = "";
          example = "http://otel-collector:4318/v1/logs";
        };
        tokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding a bearer token (read as a systemd credential)";
        };
        caFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.nestlo.runtime.enable;
        message = "nestlo.audit needs nestlo.runtime.enable (the services that produce audit events)";
      }
      {
        assertion = !exp.syslog.enable || exp.syslog.host != "";
        message = "nestlo.audit.export.syslog.host must be set";
      }
      {
        assertion = !exp.splunk.enable || (exp.splunk.url != "" && exp.splunk.tokenFile != null);
        message = "nestlo.audit.export.splunk needs url and tokenFile";
      }
      {
        assertion = !exp.otlp.enable || exp.otlp.endpoint != "";
        message = "nestlo.audit.export.otlp.endpoint must be set";
      }
    ];

    warnings = lib.optional (cfg.retentionDays != 0 && cfg.retentionDays < 183)
      "nestlo.audit.retentionDays = ${toString cfg.retentionDays} is below 183 days (six months), the minimum EU AI Act Art. 26(6) asks deployers of high-risk systems to keep logs";

    # The services read this to find the socket and decide between buffering and failing closed
    nestlo.services.settings.audit = {
      enabled = true;
      dir = stateDir;
      socket = "/run/nestlo-audit/audit.sock";
      inherit (cfg) strict;
      buffer = cfg.bufferEvents;
      retention_days = cfg.retentionDays;
      segment_bytes = cfg.segmentSizeMB * 1024 * 1024;
      checkpoint_every = cfg.checkpointEvery;
      export = {
        interval_sec = exp.intervalSec;
      } // lib.optionalAttrs exp.syslog.enable {
        syslog = {
          enabled = true;
          inherit (exp.syslog) host port tls;
        } // lib.optionalAttrs (exp.syslog.caFile != null) { ca_file = toString exp.syslog.caFile; }
        // lib.optionalAttrs (exp.syslog.hostname != null) { hostname = exp.syslog.hostname; };
      } // lib.optionalAttrs exp.splunk.enable {
        splunk = {
          enabled = true;
          inherit (exp.splunk) url sourcetype;
          token_file = "${credDir}/hec-token";
        } // lib.optionalAttrs (exp.splunk.caFile != null) { ca_file = toString exp.splunk.caFile; }
        // lib.optionalAttrs (exp.splunk.index != null) { index = exp.splunk.index; };
      } // lib.optionalAttrs exp.otlp.enable {
        otlp = {
          enabled = true;
          inherit (exp.otlp) endpoint;
        } // lib.optionalAttrs (exp.otlp.tokenFile != null) { token_file = "${credDir}/otlp-token"; }
        // lib.optionalAttrs (exp.otlp.caFile != null) { ca_file = toString exp.otlp.caFile; };
      };
    };

    # ─ Users ──────────────────────────────────────────────────────────
    users.users.nestlo-audit = {
      isSystemUser = true;
      group = "nestlo-audit";
      home = stateDir;
      description = "Nestlo audit log writer";
    };
    # Group members can read the log and connect to the socket. The services
    # (user nestlo) are members, so they can send events but, with the log
    # directory 0750 and owned by nestlo-audit, not write files.
    users.groups.nestlo-audit.members = cfg.readers;
    users.users.nestlo.extraGroups = [ "nestlo-audit" ];

    environment.systemPackages = [ pkgs.nestlo.services ];

    # ─ Signing key, created on first boot ─────────────────────────────
    systemd.services.nestlo-audit-keygen = {
      description = "Generate the Nestlo audit checkpoint signing key (first boot)";
      before = [ "nestlo-audit.service" ];
      requiredBy = [ "nestlo-audit.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "nestlo-audit-key";
        StateDirectoryMode = "0700";
        UMask = "0077";
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-audit keygen --out /var/lib/nestlo-audit-key/signing.key";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
      };
    };

    # ─ The writer ─────────────────────────────────────────────────────
    systemd.services.nestlo-audit = {
      description = "Nestlo audit log writer (hash-chained, signed checkpoints, SIEM export)";
      after = [ "network.target" "nestlo-audit-keygen.service" ];
      requires = [ "nestlo-audit-keygen.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];

      serviceConfig = {
        Type = "simple";
        User = "nestlo-audit";
        Group = "nestlo-audit";
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-audit serve";
        Restart = "on-failure";
        RestartSec = 3;
        StateDirectory = "nestlo-audit";
        StateDirectoryMode = "0750";
        RuntimeDirectory = "nestlo-audit";
        RuntimeDirectoryMode = "0750";
        UMask = "0027";
        LoadCredential = [ "audit-signing-key:/var/lib/nestlo-audit-key/signing.key" ]
          ++ lib.optional (exp.splunk.enable && exp.splunk.tokenFile != null) "hec-token:${toString exp.splunk.tokenFile}"
          ++ lib.optional (exp.otlp.enable && exp.otlp.tokenFile != null) "otlp-token:${toString exp.otlp.tokenFile}";

        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
      };
    };
  };
}
