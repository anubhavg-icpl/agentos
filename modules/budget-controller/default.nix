# ═══════════════════════════════════════════════════════════════════════
# AgentOS Budget & Cost Controller Module
# ═══════════════════════════════════════════════════════════════════════
#
# Prevents agents from spending too much money:
#   - Per-agent spending caps (daily, session, per-task)
#   - Real-time cost tracking for every LLM call
#   - Alerts at configurable thresholds (50%, 80%, 100%)
#   - Automatic agent shutdown when budget is exhausted
#   - Cost breakdowns by agent, model, and project
#   - Token-level accounting (input, output, cached)
#
# All LLM calls must go through the model gateway, which enforces budget.
# Agents that bypass the gateway are killed.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.budget-controller;
in
{
  options.agentos.budget-controller = {
    enable = lib.mkEnableOption "AgentOS budget controller";

    defaultDailyBudgetUSD = lib.mkOption {
      type = lib.types.float;
      default = 50.0;
      description = "Default daily budget per agent (USD)";
    };

    defaultSessionBudgetUSD = lib.mkOption {
      type = lib.types.float;
      default = 100.0;
      description = "Default per-session budget per agent (USD)";
    };

    globalDailyBudgetUSD = lib.mkOption {
      type = lib.types.float;
      default = 500.0;
      description = "Global daily budget across all agents (USD)";
    };

    alertThresholds = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ 50 80 95 100 ];
      description = "Alert at these percentage thresholds";
    };

    autoShutdown = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically kill agents that exceed their budget";
    };

    pricingFile = lib.mkOption {
      type = lib.types.path;
      default = ./pricing.json;
      description = "JSON file with per-model pricing";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Pricing reference data ────────────────────────────────────────
    environment.etc."agentos/pricing.json".source = ./pricing.json;

    # ─ Budget controller service ─────────────────────────────────────
    systemd.services.agentos-budget-controller = lib.mkIf config.agentos.daemons.enable {
      description = "AgentOS Budget Controller";
      after = [ "network.target" "redis-agentos.service" "agentos-model-gateway.service" ];
      wants = [ "redis-agentos.service" "agentos-model-gateway.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_DEFAULT_DAILY_BUDGET = toString cfg.defaultDailyBudgetUSD;
        AGENTOS_DEFAULT_SESSION_BUDGET = toString cfg.defaultSessionBudgetUSD;
        AGENTOS_GLOBAL_DAILY_BUDGET = toString cfg.globalDailyBudgetUSD;
        AGENTOS_ALERT_THRESHOLDS = builtins.concatStringsSep "," (map toString cfg.alertThresholds);
        AGENTOS_AUTO_SHUTDOWN = lib.boolToString cfg.autoShutdown;
        AGENTOS_PRICING_FILE = "/etc/agentos/pricing.json";
        AGENTOS_REDIS_URL = "redis://localhost:6379";
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.budget-controller}/bin/agentos-budget-controller";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Daily budget reset ────────────────────────────────────────────
    systemd.services.agentos-budget-reset = {
      description = "Reset daily budget counters";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        User = "agentos";
        ExecStart = toString (pkgs.writeShellScript "budget-reset" ''
          # DEL doesn't expand globs; delete the matching keys one by one
          ${pkgs.redis}/bin/redis-cli -n 2 --scan --pattern "daily:*" 2>/dev/null \
            | ${pkgs.findutils}/bin/xargs -r ${pkgs.redis}/bin/redis-cli -n 2 DEL >/dev/null || true
          echo "[budget-reset] Daily counters reset at $(date)"
        '');
      };
    };

    # ─ Budget CLI ────────────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-budget" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        RED='\033[0;31m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        NC='\033[0m'

        info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

        case "''${1:-status}" in
          status)
            echo -e "''${BOLD}Budget Status''${NC}"
            echo ""
            echo "  Default daily budget:   \$${toString cfg.defaultDailyBudgetUSD}"
            echo "  Default session budget: \$${toString cfg.defaultSessionBudgetUSD}"
            echo "  Global daily budget:    \$${toString cfg.globalDailyBudgetUSD}"
            echo ""

            # Per-agent spend today
            echo -e "''${BOLD}Per-Agent Spend (Today):''${NC}"
            keys=$(${pkgs.redis}/bin/redis-cli -n 2 KEYS "daily:agent:*" 2>/dev/null || true)
            if [ -n "$keys" ]; then
              for key in $keys; do
                agent=$(echo "$key" | sed 's/daily:agent://')
                spend=$(${pkgs.redis}/bin/redis-cli -n 2 GET "$key" 2>/dev/null || echo "0")
                pct=$(echo "scale=0; $spend * 100 / ${toString cfg.defaultDailyBudgetUSD}" | ${pkgs.bc}/bin/bc 2>/dev/null || echo "0")
                color=$GREEN
                [ "$pct" -gt 50 ] && color=$YELLOW
                [ "$pct" -gt 80 ] && color=$RED
                printf "  %-30s \$%8.2f  ''${color}%s%%''${NC}\n" "$agent" "$spend" "$pct"
              done
            else
              echo "  (no spending yet today)"
            fi

            echo ""

            # Global spend today
            echo -e "''${BOLD}Global Spend (Today):''${NC}"
            global=$(${pkgs.redis}/bin/redis-cli -n 2 GET "daily:global" 2>/dev/null || echo "0")
            pct=$(echo "scale=0; $global * 100 / ${toString cfg.globalDailyBudgetUSD}" | ${pkgs.bc}/bin/bc 2>/dev/null || echo "0")
            color=$GREEN
            [ "$pct" -gt 50 ] && color=$YELLOW
            [ "$pct" -gt 80 ] && color=$RED
            printf "  Total: \$%.2f / \$%.2f  ''${color}%s%%''${NC}\n" "$global" "${toString cfg.globalDailyBudgetUSD}" "$pct"
            ;;

          set)
            AGENT="''${2:-}"
            AMOUNT="''${3:-}"
            if [ -z "$AGENT" ] || [ -z "$AMOUNT" ]; then
              echo "Usage: agentos-budget set <agent-id> <amount-usd>"
              exit 1
            fi
            ${pkgs.redis}/bin/redis-cli -n 2 SET "budget:$AGENT" "$AMOUNT"
            info "Budget for $AGENT set to \$$AMOUNT"
            ;;

          history)
            echo -e "''${BOLD}Cost History (7 days):''${NC}"
            for i in $(seq 0 6); do
              date=$(date -d "$i days ago" +%Y%m%d)
              spend=$(${pkgs.redis}/bin/redis-cli -n 2 GET "daily:global:$date" 2>/dev/null || echo "0")
              printf "  %s  \$%8.2f\n" "$(date -d "$i days ago" +%Y-%m-%d)" "$spend"
            done
            ;;

          by-model)
            echo -e "''${BOLD}Spend by Model:''${NC}"
            keys=$(${pkgs.redis}/bin/redis-cli -n 2 KEYS "daily:model:*" 2>/dev/null || true)
            for key in $keys; do
              model=$(echo "$key" | sed 's/daily:model://')
              spend=$(${pkgs.redis}/bin/redis-cli -n 2 GET "$key" 2>/dev/null || echo "0")
              printf "  %-40s \$%8.2f\n" "$model" "$spend"
            done
            ;;

          alerts)
            echo -e "''${BOLD}Budget Alerts:''${NC}"
            # Show recent alerts from logs
            grep "BUDGET ALERT" /var/lib/agentos/logs/budget-controller.log 2>/dev/null | tail -20 || echo "  (no alerts)"
            ;;

          *)
            echo "Usage: agentos-budget <status|set|history|by-model|alerts>"
            ;;
        esac
      '')
    ];
  };
}
