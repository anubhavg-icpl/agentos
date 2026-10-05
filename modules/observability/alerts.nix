# AgentOS alerting: Prometheus alert rules, a gateway availability SLO with
# multi-window burn-rate alerts, and an optional Alertmanager.
#
# The series come from the gateway (/metrics on loopback) and the daemon
# (:9950/metrics), plus the systemd exporter for unit state. Every alert
# links a runbook in docs/runbooks/<alert>.md through `runbook_url`.
{ config, lib, ... }:

let
  obs = config.agentos.observability;
  cfg = obs.alerts;
  am = obs.alertmanager;

  gatewayPort = config.agentos.networking.modelGatewayPort;

  # 0.995 -> "0.995", 99.5 -> "99.5" (toString on floats pads with zeros)
  trim = s: let t = lib.removeSuffix "0" s; in if t != s then trim t else lib.removeSuffix "." s;
  num = x: trim (toString x);
  pct = x: num (x * 100);
  slo = cfg.sloTarget;
  budget = 1 - slo; # allowed error ratio, 0.005 for 99.5 %

  runbook = name: "${cfg.runbookBaseUrl}/${name}.md";
  alert = name: { expr, for ? "0m", severity, summary, description }: {
    alert = name;
    inherit expr for;
    labels = { inherit severity; };
    annotations = {
      inherit summary description;
      runbook_url = runbook name;
    };
  };

  # Error ratio of the gateway: 5xx responses over all responses. 4xx
  # (including 402 budget, 429 rate limit and loop detection) are the
  # clients' doing and do not count against availability.
  ratio = w: "agentos:gateway_error_ratio:rate${w}";
  windows = [ "5m" "30m" "1h" "2h" "6h" "1d" "3d" ];
  burn = factor: long: short:
    "${ratio long} > (${num factor} * ${num budget}) and ${ratio short} > (${num factor} * ${num budget})";

  rules = {
    groups = [
      {
        name = "agentos-slo-recording";
        rules = map
          (w: {
            record = ratio w;
            expr = ''
              sum(rate(agentos_gateway_responses_total{code=~"5.."}[${w}]))
              /
              sum(rate(agentos_gateway_responses_total[${w}]))
            '';
          })
          windows;
      }
      {
        name = "agentos-slo-burn";
        rules = [
          (alert "AgentOSGatewaySLOBurnFast" {
            expr = burn 14.4 "1h" "5m";
            severity = "critical";
            summary = "Gateway is burning its ${pct slo}% availability budget 14.4x too fast";
            description = "At this rate the 30-day error budget is gone in about 2 days (1h and 5m windows both above 14.4x).";
          })
          (alert "AgentOSGatewaySLOBurnMedium" {
            expr = burn 6 "6h" "30m";
            severity = "critical";
            summary = "Gateway is burning its availability budget 6x too fast";
            description = "At this rate the 30-day error budget is gone in about 5 days (6h and 30m windows both above 6x).";
          })
          (alert "AgentOSGatewaySLOBurnSlow" {
            expr = "(${burn 3 "1d" "2h"}) or (${burn 1 "3d" "6h"})";
            severity = "warning";
            summary = "Gateway is steadily eating its availability budget";
            description = "A slow burn: 3x over 1d/2h or 1x over 3d/6h. Open a ticket; it will exhaust the budget within the month.";
          })
        ];
      }
      {
        name = "agentos-alerts";
        rules = [
          (alert "AgentOSServiceDown" {
            expr = ''
              systemd_unit_state{name=~"agentos-(model-gateway|daemon|orchestrator|dashboard|scheduler)\\.service",state="active"} == 0
              or
              up{job=~"agentos-(daemon|gateway)"} == 0
            '';
            for = "2m";
            severity = "critical";
            summary = "{{ $labels.name }}{{ $labels.job }} is down";
            description = "An AgentOS service is not active (or its metrics endpoint is unreachable) for 2 minutes.";
          })
          (alert "AgentOSGatewayHighErrorRatio" {
            expr = "${ratio "5m"} > ${num cfg.gatewayErrorRatio}";
            for = "10m";
            severity = "warning";
            summary = "Gateway 5xx ratio is {{ $value | humanizePercentage }}";
            description = "More than ${pct cfg.gatewayErrorRatio}% of gateway responses were 5xx over 5 minutes, for 10 minutes.";
          })
          (alert "AgentOSBudgetNearExhaustion" {
            expr = ''
              (agentos_agent_spend_usd_today / agentos_agent_budget_usd > ${num cfg.budgetRatio} and agentos_agent_budget_usd > 0)
              or
              (agentos_spend_usd_today / agentos_budget_global_usd > ${num cfg.budgetRatio} and agentos_budget_global_usd > 0)
            '';
            for = "1m";
            severity = "warning";
            summary = "Budget {{ if $labels.agent }}of agent {{ $labels.agent }}{{ else }}(global){{ end }} is {{ $value | humanizePercentage }} spent";
            description = "Daily spend passed ${pct cfg.budgetRatio}% of its cap; the gateway answers 402 at 100%.";
          })
          (alert "AgentOSCircuitOpen" {
            expr = "agentos_circuit_open == 1";
            for = "1m";
            severity = "warning";
            summary = "Circuit breaker open for agent {{ $labels.agent }}";
            description = "Repeated upstream failures opened the agent's circuit; its requests get 503 until the cooldown ends.";
          })
          (alert "AgentOSLoopDetected" {
            expr = "increase(agentos_gateway_loop_detections_total[10m]) > 0";
            severity = "warning";
            summary = "Loop detection refused requests";
            description = "An agent keeps sending the same request (or alternating between two); the gateway answers 429 loop_detected.";
          })
          (alert "AgentOSOrchestratorQueueAge" {
            expr = "agentos_orchestrator_queue_oldest_age_seconds > ${toString cfg.queueAgeSeconds}";
            for = "5m";
            severity = "warning";
            summary = "Oldest queued task is {{ $value | humanizeDuration }} old";
            description = "Tasks wait longer than ${toString cfg.queueAgeSeconds}s: workers are saturated, the orchestrator is stuck, or tasks await approval.";
          })
          (alert "AgentOSStateDiskUsage" {
            expr = "agentos_state_disk_used_ratio > ${num cfg.diskUsedRatio}";
            for = "10m";
            severity = "warning";
            summary = "{{ $labels.path }} is {{ $value | humanizePercentage }} full";
            description = "The filesystem holding /var/lib/agentos passed ${pct cfg.diskUsedRatio}% usage.";
          })
          (alert "AgentOSRedisDown" {
            expr = ''
              agentos_redis_up == 0
              or
              systemd_unit_state{name="redis-agentos.service",state="active"} == 0
            '';
            for = "1m";
            severity = "critical";
            summary = "Control-plane Redis is down";
            description = "Without Redis the gateway fails closed (503 store_unavailable) and the orchestrator cannot schedule.";
          })
          (alert "AgentOSBackupFailed" {
            expr = ''systemd_unit_state{name=~"restic-backups-.*\\.service",state="failed"} == 1'';
            severity = "warning";
            summary = "Backup {{ $labels.name }} failed";
            description = "The last restic backup run failed; state is not being protected.";
          })
        ];
      }
    ];
  };

  # One receiver carrying whichever channels are configured
  receiver = {
    name = "agentos";
    webhook_configs = lib.optional (am.webhook.urlFile != null) {
      url_file = toString am.webhook.urlFile;
      send_resolved = true;
    };
    email_configs = lib.optional (am.email.to != null) ({
      to = am.email.to;
      from = am.email.from;
      smarthost = am.email.smarthost;
      send_resolved = true;
    } // lib.optionalAttrs (am.email.authUsername != null) {
      auth_username = am.email.authUsername;
      auth_password_file = toString am.email.authPasswordFile;
    });
  };
in
{
  options.agentos.observability = {
    alerts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Load the AgentOS Prometheus alert and SLO recording rules.";
      };
      runbookBaseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/anubhavg-icpl/agentos/blob/main/docs/runbooks";
        description = "Base URL of the runbooks; each alert links <base>/<alertname>.md.";
      };
      sloTarget = lib.mkOption {
        type = lib.types.float;
        default = 0.995;
        description = "Gateway availability SLO (share of non-5xx responses over 30 days).";
      };
      gatewayErrorRatio = lib.mkOption {
        type = lib.types.float;
        default = 0.05;
        description = "5xx ratio that triggers AgentOSGatewayHighErrorRatio.";
      };
      budgetRatio = lib.mkOption {
        type = lib.types.float;
        default = 0.9;
        description = "Share of a daily budget spent that triggers AgentOSBudgetNearExhaustion.";
      };
      queueAgeSeconds = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = "Age in seconds of the oldest queued task that triggers AgentOSOrchestratorQueueAge.";
      };
      diskUsedRatio = lib.mkOption {
        type = lib.types.float;
        default = 0.85;
        description = "Filesystem usage of /var/lib/agentos that triggers AgentOSStateDiskUsage.";
      };
    };

    alertmanager = {
      enable = lib.mkEnableOption "Alertmanager, wired to Prometheus (off by default)";
      port = lib.mkOption {
        type = lib.types.port;
        default = 9093;
        description = "Alertmanager listen port (loopback only).";
      };
      webhook.urlFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/alertmanager-webhook-url";
        description = "File holding the webhook URL alerts are POSTed to (Slack-compatible gateways, PagerDuty bridges, ...).";
      };
      email = {
        to = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Recipient; null disables the email receiver."; };
        from = lib.mkOption { type = lib.types.str; default = "agentos@localhost"; description = "Sender address."; };
        smarthost = lib.mkOption { type = lib.types.str; default = "localhost:25"; description = "SMTP relay host:port."; };
        authUsername = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "SMTP username; null for an unauthenticated relay."; };
        authPasswordFile = lib.mkOption { type = lib.types.nullOr lib.types.path; default = null; description = "File with the SMTP password."; };
      };
    };
  };

  config = lib.mkIf obs.enable (lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.prometheus = {
        rules = [ (builtins.toJSON rules) ];
        scrapeConfigs = [
          {
            job_name = "agentos-gateway";
            metrics_path = "/metrics";
            static_configs = [{ targets = [ "127.0.0.1:${toString gatewayPort}" ]; }];
          }
          {
            job_name = "systemd";
            static_configs = [{ targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.systemd.port}" ]; }];
          }
        ];
        exporters.systemd = {
          enable = true;
          listenAddress = "127.0.0.1";
        };
      };
    })

    (lib.mkIf am.enable {
      assertions = [{
        assertion = am.webhook.urlFile != null || am.email.to != null;
        message = "agentos.observability.alertmanager.enable needs a receiver: set alertmanager.webhook.urlFile or alertmanager.email.to";
      }];
      services.prometheus.alertmanager = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = am.port;
        configuration = {
          route = {
            receiver = receiver.name;
            group_by = [ "alertname" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
          };
          receivers = [ receiver ];
        };
      };
      services.prometheus.alertmanagers = [{
        static_configs = [{ targets = [ "127.0.0.1:${toString am.port}" ]; }];
      }];
    })
  ]);
}
