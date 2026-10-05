# Nestlo alerting: Prometheus alert rules, a gateway availability SLO with
# multi-window burn-rate alerts, and an optional Alertmanager.
#
# The series come from the gateway (/metrics on loopback) and the daemon
# (:9950/metrics), plus the systemd exporter for unit state. Every alert
# links a runbook in docs/runbooks/<alert>.md through `runbook_url`.
{ config, lib, ... }:

let
  obs = config.nestlo.observability;
  cfg = obs.alerts;
  am = obs.alertmanager;

  gatewayPort = config.nestlo.networking.modelGatewayPort;

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
  ratio = w: "nestlo:gateway_error_ratio:rate${w}";
  windows = [ "5m" "30m" "1h" "2h" "6h" "1d" "3d" ];
  burn = factor: long: short:
    "${ratio long} > (${num factor} * ${num budget}) and ${ratio short} > (${num factor} * ${num budget})";

  rules = {
    groups = [
      {
        name = "nestlo-slo-recording";
        rules = map
          (w: {
            record = ratio w;
            expr = ''
              (sum(rate(nestlo_gateway_responses_total{code=~"5.."}[${w}])) or vector(0))
              /
              sum(rate(nestlo_gateway_responses_total[${w}]))
            '';
          })
          windows;
      }
      {
        name = "nestlo-slo-burn";
        rules = [
          (alert "NestloGatewaySLOBurnFast" {
            expr = burn 14.4 "1h" "5m";
            severity = "critical";
            summary = "Gateway is burning its ${pct slo}% availability budget 14.4x too fast";
            description = "At this rate the 30-day error budget is gone in about 2 days (1h and 5m windows both above 14.4x).";
          })
          (alert "NestloGatewaySLOBurnMedium" {
            expr = burn 6 "6h" "30m";
            severity = "critical";
            summary = "Gateway is burning its availability budget 6x too fast";
            description = "At this rate the 30-day error budget is gone in about 5 days (6h and 30m windows both above 6x).";
          })
          (alert "NestloGatewaySLOBurnSlow" {
            expr = "(${burn 3 "1d" "2h"}) or (${burn 1 "3d" "6h"})";
            severity = "warning";
            summary = "Gateway is steadily eating its availability budget";
            description = "A slow burn: 3x over 1d/2h or 1x over 3d/6h. Open a ticket; it will exhaust the budget within the month.";
          })
        ];
      }
      {
        name = "nestlo-alerts";
        rules = [
          (alert "NestloServiceDown" {
            expr = ''
              systemd_unit_state{name=~"nestlo-(model-gateway|daemon|orchestrator|dashboard|scheduler)\\.service",state="active"} == 0
              or
              up{job=~"nestlo-(daemon|gateway|factory)"} == 0
              or
              up{job="systemd"} == 0
            '';
            for = "2m";
            severity = "critical";
            summary = "{{ $labels.name }}{{ $labels.job }} is down";
            description = "An Nestlo service is not active (or its metrics endpoint is unreachable) for 2 minutes.";
          })
          (alert "NestloGatewayHighErrorRatio" {
            expr = "${ratio "5m"} > ${num cfg.gatewayErrorRatio}";
            for = "10m";
            severity = "warning";
            summary = "Gateway 5xx ratio is {{ $value | humanizePercentage }}";
            description = "More than ${pct cfg.gatewayErrorRatio}% of gateway responses were 5xx over 5 minutes, for 10 minutes.";
          })
          (alert "NestloBudgetNearExhaustion" {
            expr = ''
              (nestlo_agent_spend_usd_today / nestlo_agent_budget_usd > ${num cfg.budgetRatio} and nestlo_agent_budget_usd > 0)
              or
              (nestlo_spend_usd_today / nestlo_budget_global_usd > ${num cfg.budgetRatio} and nestlo_budget_global_usd > 0)
            '';
            for = "1m";
            severity = "warning";
            summary = "Budget {{ if $labels.agent }}of agent {{ $labels.agent }}{{ else }}(global){{ end }} is {{ $value | humanizePercentage }} spent";
            description = "Daily spend passed ${pct cfg.budgetRatio}% of its cap; the gateway answers 402 at 100%.";
          })
          (alert "NestloCircuitOpen" {
            expr = "nestlo_circuit_open == 1";
            for = "1m";
            severity = "warning";
            summary = "Circuit breaker open for agent {{ $labels.agent }}";
            description = "Repeated upstream failures opened the agent's circuit; its requests get 503 until the cooldown ends.";
          })
          (alert "NestloLoopDetected" {
            expr = "increase(nestlo_gateway_loop_detections_total[10m]) > 0";
            severity = "warning";
            summary = "Loop detection refused requests";
            description = "An agent keeps sending the same request (or alternating between two); the gateway answers 429 loop_detected.";
          })
          (alert "NestloOrchestratorQueueAge" {
            expr = "nestlo_orchestrator_queue_oldest_age_seconds > ${toString cfg.queueAgeSeconds}";
            for = "5m";
            severity = "warning";
            summary = "Oldest queued task is {{ $value | humanizeDuration }} old";
            description = "Tasks wait longer than ${toString cfg.queueAgeSeconds}s: workers are saturated, the orchestrator is stuck, or tasks await approval.";
          })
          # Series of the factory service (metrics port, nestlo.factory.metricsPort);
          # they exist only where nestlo.factory is enabled, so these never fire elsewhere
          (alert "NestloFactoryBlocked" {
            expr = ''sum by (line) (nestlo_factory_items{state="blocked"}) > 0'';
            for = "30m";
            severity = "warning";
            summary = "Factory line {{ $labels.line }} has {{ $value }} blocked item(s)";
            description = "Items waited 30 minutes in the blocked state: a budget, fix-round or approval limit was hit and a human has to decide.";
          })
          (alert "NestloFactoryStuck" {
            expr = ''max by (line, state) (nestlo_factory_item_age_seconds{state=~"${lib.concatStringsSep "|" cfg.factoryActiveStates}"}) > ${toString cfg.factoryStuckSeconds}'';
            severity = "warning";
            summary = "A factory item on line {{ $labels.line }} has sat in {{ $labels.state }} for {{ $value | humanizeDuration }}";
            description = "An item in an active state was not updated for more than ${toString cfg.factoryStuckSeconds}s: its task, a worker or the factory loop is stuck.";
          })
          (alert "NestloFactoryBudgetBurn" {
            expr = "sum by (line) (increase(nestlo_factory_cost_usd_total[1h])) > ${num cfg.factoryBudgetBurnUSDPerHour}";
            severity = "warning";
            summary = "Factory line {{ $labels.line }} spent {{ $value | printf \"%.2f\" }} USD in the last hour";
            description = "The line spends more than ${num cfg.factoryBudgetBurnUSDPerHour} USD per hour; check for a fix loop that does not converge.";
          })
          (alert "NestloStateDiskUsage" {
            expr = "nestlo_state_disk_used_ratio > ${num cfg.diskUsedRatio}";
            for = "10m";
            severity = "warning";
            summary = "{{ $labels.path }} is {{ $value | humanizePercentage }} full";
            description = "The filesystem holding /var/lib/nestlo passed ${pct cfg.diskUsedRatio}% usage.";
          })
          (alert "NestloRedisDown" {
            expr = ''
              nestlo_redis_up == 0
              or
              systemd_unit_state{name="redis-nestlo.service",state="active"} == 0
            '';
            for = "1m";
            severity = "critical";
            summary = "Control-plane Redis is down";
            description = "Without Redis the gateway fails closed (503 store_unavailable) and the orchestrator cannot schedule.";
          })
          (alert "NestloBackupFailed" {
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
    name = "nestlo";
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
  options.nestlo.observability = {
    alerts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Load the Nestlo Prometheus alert and SLO recording rules.";
      };
      runbookBaseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/anubhavg-icpl/nestlo/blob/main/docs/runbooks";
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
        description = "5xx ratio that triggers NestloGatewayHighErrorRatio.";
      };
      budgetRatio = lib.mkOption {
        type = lib.types.float;
        default = 0.9;
        description = "Share of a daily budget spent that triggers NestloBudgetNearExhaustion.";
      };
      queueAgeSeconds = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = "Age in seconds of the oldest queued task that triggers NestloOrchestratorQueueAge.";
      };
      factoryActiveStates = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "planning" "building" "reviewing" "fixing" "qa" "publishing" ];
        description = "Factory item states in which NestloFactoryStuck applies (the states of nestlo_factory_item_age_seconds that mean work is in progress).";
      };
      factoryStuckSeconds = lib.mkOption {
        type = lib.types.int;
        default = 7200;
        description = "Seconds an item may stay in an active state without an update before NestloFactoryStuck fires.";
      };
      factoryBudgetBurnUSDPerHour = lib.mkOption {
        type = lib.types.either lib.types.int lib.types.float;
        default = 50;
        description = "Spend of one factory line per hour (USD) that triggers NestloFactoryBudgetBurn.";
      };
      diskUsedRatio = lib.mkOption {
        type = lib.types.float;
        default = 0.85;
        description = "Filesystem usage of /var/lib/nestlo that triggers NestloStateDiskUsage.";
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
        from = lib.mkOption { type = lib.types.str; default = "nestlo@localhost"; description = "Sender address."; };
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
            job_name = "nestlo-gateway";
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
        message = "nestlo.observability.alertmanager.enable needs a receiver: set alertmanager.webhook.urlFile or alertmanager.email.to";
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
