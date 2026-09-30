# ═══════════════════════════════════════════════════════════════════════
# AgentOS Scheduler Module
# ═══════════════════════════════════════════════════════════════════════
#
# Schedules agent tasks:
#   - Cron-like scheduling for recurring agent tasks
#   - Priority queues (high/normal/low)
#   - Deadline-aware scheduling (run before a date)
#   - Dependency chains (task B runs after task A completes)
#   - Resource-aware (don't oversubscribe CPU/GPU)
#   - Time-window scheduling (only run during off-hours)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.scheduler;
in
{
  options.agentos.scheduler = {
    enable = lib.mkEnableOption "AgentOS scheduler";

    maxConcurrent = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Maximum concurrent scheduled tasks";
    };

    enablePriorityQueues = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable priority-based task scheduling";
    };

    offHoursOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Only run scheduled tasks during off-hours (22:00-06:00)";
    };

    offHoursStart = lib.mkOption {
      type = lib.types.int;
      default = 22;
      description = "Start of off-hours (24h format)";
    };

    offHoursEnd = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "End of off-hours (24h format)";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Scheduled tasks config ────────────────────────────────────────
    environment.etc."agentos/schedules.yaml".text = ''
      # Scheduled agent tasks
      # Each task defines: when to run, which agent, what prompt
      #
      # - name: nightly-security-scan
      #   schedule: "0 2 * * *"        # 2 AM daily
      #   agent: claude-code
      #   prompt: "Run a security audit of this codebase"
      #   priority: low
      #   workspace: /var/lib/agentos/workspaces/main-project
      #
      # - name: weekly-dependency-update
      #   schedule: "0 4 * * 1"        # 4 AM every Monday
      #   agent: aider
      #   prompt: "Update all dependencies and run tests"
      #   priority: normal
      #
      # - name: hourly-test-run
      #   schedule: "@hourly"
      #   agent: swe-agent
      #   prompt: "Run the test suite and fix any failures"
      #   priority: high
      #   deadline: "1h"               # must complete within 1 hour
    '';

    # ─ Scheduler service ─────────────────────────────────────────────
    systemd.services.agentos-scheduler = lib.mkIf config.agentos.plannedServices.enable {
      description = "AgentOS Task Scheduler";
      after = [ "network.target" "redis-agentos.service" "agentos-daemon.service" ];
      wants = [ "redis-agentos.service" "agentos-daemon.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_MAX_CONCURRENT = toString cfg.maxConcurrent;
        AGENTOS_SCHEDULES = "/etc/agentos/schedules.yaml";
        AGENTOS_OFF_HOURS_ONLY = lib.boolToString cfg.offHoursOnly;
        AGENTOS_OFF_HOURS_START = toString cfg.offHoursStart;
        AGENTOS_OFF_HOURS_END = toString cfg.offHoursEnd;
        AGENTOS_REDIS_URL = "redis://localhost:6379";
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.scheduler}/bin/agentos-scheduler";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Scheduler CLI ─────────────────────────────────────────────────
    # The CLI only queues work for the planned service, so ship them together
    environment.systemPackages = lib.optionals config.agentos.plannedServices.enable [
      (pkgs.writeShellScriptBin "agentos-schedule" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
        info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        SCHEDULES="/etc/agentos/schedules.yaml"

        case "''${1:-list}" in
          list)
            info "Scheduled tasks:"
            if [ -f "$SCHEDULES" ]; then
              ${pkgs.yq}/bin/yq -r '.[] | "  \(.name): \(.schedule) [\(.agent)] \(.priority // \"normal\")"' "$SCHEDULES" 2>/dev/null || \
                echo "  (no tasks scheduled, or yq not installed)"
            else
              echo "  (no schedules file)"
            fi
            ;;

          add)
            NAME="''${2:-}"
            SCHEDULE="''${3:-}"
            AGENT="''${4:-claude-code}"
            PROMPT="''${5:-No prompt provided}"
            if [ -z "$NAME" ] || [ -z "$SCHEDULE" ]; then
              echo "Usage: agentos-schedule add <name> <cron> [agent] [prompt]"
              echo ""
              echo "Example:"
              echo "  agentos-schedule add nightly-scan '0 2 * * *' claude-code 'Run security audit'"
              exit 1
            fi
            info "Adding scheduled task: $NAME"
            # Append to schedules file (simple YAML append)
            echo "" >> "$SCHEDULES"
            echo "- name: $NAME" >> "$SCHEDULES"
            echo "  schedule: \"$SCHEDULE\"" >> "$SCHEDULES"
            echo "  agent: $AGENT" >> "$SCHEDULES"
            echo "  prompt: \"$PROMPT\"" >> "$SCHEDULES"
            echo "  priority: normal" >> "$SCHEDULES"
            ok "Added: $NAME (cron: $SCHEDULE, agent: $AGENT)"
            systemctl restart agentos-scheduler
            ;;

          remove)
            NAME="''${2:-}"
            if [ -z "$NAME" ]; then
              echo "Usage: agentos-schedule remove <name>"
              exit 1
            fi
            info "Removing scheduled task: $NAME"
            # Remove block from YAML
            ${pkgs.gnused}/bin/sed -i "/name: $NAME/,/priority:/d" "$SCHEDULES"
            ok "Removed: $NAME"
            systemctl restart agentos-scheduler
            ;;

          status)
            info "Scheduler status:"
            echo "  Max concurrent: ${toString cfg.maxConcurrent}"
            echo "  Off-hours only: ${lib.boolToString cfg.offHoursOnly}"
            echo ""
            echo "  Queue:"
            ${pkgs.redis}/bin/redis-cli -n 4 ZRANGE "schedule_queue" 0 -1 WITHSCORES 2>/dev/null | while read -r task; read -r score; do
              echo "    $task (score: $score)"
            done || echo "    (empty)"
            ;;

          run-now)
            NAME="''${2:-}"
            if [ -z "$NAME" ]; then
              echo "Usage: agentos-schedule run-now <name>"
              exit 1
            fi
            info "Triggering immediate run: $NAME"
            ${pkgs.redis}/bin/redis-cli -n 4 LPUSH "schedule_trigger" "$NAME" >/dev/null
            ok "Triggered: $NAME"
            ;;

          help|*)
            cat <<'HELP'
        AgentOS Scheduler

        USAGE:
            agentos-schedule <COMMAND> [ARGS]

        COMMANDS:
            list                          List scheduled tasks
            add <name> <cron> [agent] [prompt]  Add a scheduled task
            remove <name>                 Remove a scheduled task
            status                        Show scheduler status and queue
            run-now <name>                Trigger a task immediately

        CRON FORMAT:
            "0 2 * * *"     - Daily at 2 AM
            "0 4 * * 1"     - Every Monday at 4 AM
            "@hourly"       - Every hour
            "@daily"        - Every day at midnight
            "*/30 * * * *"  - Every 30 minutes

        HELP
            ;;
        esac
      '')
    ];
  };
}
