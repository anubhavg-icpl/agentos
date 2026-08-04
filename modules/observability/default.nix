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
          otlp/tempo = {
            endpoint = "localhost:4317";
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
        distributor.receivers.otlp.protocols.grpc.endpoint = "127.0.0.1:4317";
        storage = {
          trace.backend = "local";
          trace.local.path = "/var/lib/tempo/traces";
          trace.retention = "${toString cfg.retentionDays}h";
        };
      };
    };

    # ─ Grafana (dashboards) ──────────────────────────────────────────
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "0.0.0.0";
          http_port = cfg.grafanaPort;
        };
        security = {
          admin_user = "admin";
          admin_password = "agentos";  # change immediately
          disable_gravatar = true;
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

    # ─ Network: expose internal-only ports ───────────────────────────
    networking.firewall.allowedTCPPorts = [ cfg.grafanaPort ];
  };
}
