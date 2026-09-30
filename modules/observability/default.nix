# AgentOS observability module
# OpenTelemetry, tracing, cost tracking, decision logs
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.observability;
in
{
  options.agentos.observability = {
    enable = lib.mkEnableOption "AgentOS observability";

    otelCollectorPort = lib.mkOption {
      type = lib.types.port;
      default = 4317;
      description = "OTLP gRPC port for the collector";
    };

    grafanaPort = lib.mkOption {
      type = lib.types.port;
      default = 2342;
      description = "Port for the Grafana dashboard";
    };

    tempoOtlpPort = lib.mkOption {
      type = lib.types.port;
      default = 4417;
      description = "Local OTLP gRPC port Tempo receives traces on from the collector";
    };

    grafanaAdminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/grafana-admin-password";
      description = ''
        File containing the Grafana admin password. When null, Grafana's
        built-in default (admin/admin) applies and must be changed on first
        login. Grafana only listens on localhost; reach it with an SSH tunnel.
      '';
    };

    retentionDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "How long to keep trace/metric data";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ OpenTelemetry Collector ────────────────────────────────────────
    services.opentelemetry-collector = {
      enable = true;
      settings = {
        receivers = {
          otlp = {
            protocols = {
              grpc.endpoint = "0.0.0.0:${toString cfg.otelCollectorPort}";
              http.endpoint = "0.0.0.0:4318";
            };
          };
        };
        processors = {
          batch = { };
          memory_limiter = {
            check_interval = "1s";
            limit_mib = 256;
          };
        };
        exporters = {
          # Send traces to Tempo, metrics to Prometheus
          "otlp/tempo" = {
            endpoint = "127.0.0.1:${toString cfg.tempoOtlpPort}";
            tls.insecure = true;
          };
          prometheus = {
            endpoint = "0.0.0.0:8889";
          };
        };
        service = {
          pipelines = {
            traces = {
              receivers = [ "otlp" ];
              processors = [ "memory_limiter" "batch" ];
              exporters = [ "otlp/tempo" ];
            };
            metrics = {
              receivers = [ "otlp" ];
              processors = [ "memory_limiter" "batch" ];
              exporters = [ "prometheus" ];
            };
          };
        };
      };
    };

    # ─ Prometheus (metrics) ──────────────────────────────────────────
    services.prometheus = {
      enable = true;
      port = 9001;
      retentionTime = "${toString cfg.retentionDays}d";
      scrapeConfigs = [
        {
          job_name = "agentos-daemon";
          static_configs = [{
            targets = [ "localhost:9950" ];
          }];
        }
        {
          job_name = "otel-collector";
          static_configs = [{
            targets = [ "localhost:8889" ];
          }];
        }
      ];
    };

    # ─ Tempo (distributed tracing) ───────────────────────────────────
    services.tempo = {
      enable = true;
      settings = {
        server.http_listen_port = 3200;
        server.grpc_listen_port = 9096;
        # The OTel collector owns :4317; Tempo receives from it on its own port
        distributor.receivers.otlp.protocols.grpc.endpoint = "127.0.0.1:${toString cfg.tempoOtlpPort}";
        storage = {
          trace.backend = "local";
          trace.local.path = "/var/lib/tempo/traces";
          trace.wal.path = "/var/lib/tempo/wal";
        };
        compactor.compaction.block_retention = "${toString (cfg.retentionDays * 24)}h";
      };
    };

    # ─ Grafana (dashboards) ──────────────────────────────────────────
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = cfg.grafanaPort;
        };
        security = {
          admin_user = "admin";
          disable_gravatar = true;
          # Generated per machine on first boot (agentos-grafana-secret)
          secret_key = "$__file{/var/lib/agentos-grafana/secret_key}";
        } // lib.optionalAttrs (cfg.grafanaAdminPasswordFile != null) {
          admin_password = "$__file{${cfg.grafanaAdminPasswordFile}}";
        };
        analytics.reporting_enabled = false;
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            url = "http://localhost:9001";
            isDefault = true;
          }
          {
            name = "Tempo";
            type = "tempo";
            url = "http://localhost:3200";
          }
        ];
      };
    };

    systemd.services.agentos-grafana-secret = {
      description = "Generate the Grafana secret key";
      wantedBy = [ "grafana.service" ];
      before = [ "grafana.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "agentos-grafana";
        StateDirectoryMode = "0750";
      };
      script = ''
        f=/var/lib/agentos-grafana/secret_key
        if [ ! -s "$f" ]; then
          umask 077
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "$f"
        fi
        chown grafana:grafana "$f" /var/lib/agentos-grafana
      '';
    };

    # Grafana is bound to localhost and not opened in the firewall:
    #   ssh -L 2342:localhost:2342 admin@agentos
  };
}
