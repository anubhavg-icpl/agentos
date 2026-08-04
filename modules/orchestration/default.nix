# ═══════════════════════════════════════════════════════════════════════
# AgentOS Multi-Agent Orchestration Module
# ═══════════════════════════════════════════════════════════════════════
#
# Coordinates multiple agents working together:
#   - Planner/worker pattern: a planner agent breaks down tasks and
#     assigns subtasks to worker agents
#   - Task queue (Redis-backed) for distributing work
#   - Inter-agent message bus for communication
#   - Swarm mode: multiple agents on the same problem in parallel
#   - Hierarchical mode: agents spawn sub-agents
#   - Result aggregation and conflict resolution
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.orchestration;
in
{
  options.agentos.orchestration = {
    enable = lib.mkEnableOption "AgentOS multi-agent orchestration";

    mode = lib.mkOption {
      type = lib.types.enum [ "planner-worker" "swarm" "hierarchical" "pipeline" ];
      default = "planner-worker";
      description = "Default orchestration mode";
    };

    maxWorkers = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Maximum concurrent worker agents per task";
    };

    taskTimeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 3600;
      description = "Default task timeout (1 hour)";
    };

    enableMessageBus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable inter-agent message bus (Redis pub/sub)";
    };

    resultStrategy = lib.mkOption {
      type = lib.types.enum [ "first-success" "best-of-n" "consensus" "all" ];
      default = "first-success";
      description = "How to handle multiple agent results";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Redis for task queue and message bus ──────────────────────────
    services.redis = {
      enable = true;
      port = 6379;
      settings = {
        maxmemory = "256mb";
        maxmemory-policy = "allkeys-lru";
        appendonly = "yes";
        save = "60 1000";
      };
    };

    # ─ Orchestrator service ──────────────────────────────────────────
    systemd.services.agentos-orchestrator = {
      description = "AgentOS Multi-Agent Orchestrator";
      after = [ "network.target" "redis.service" "agentos-daemon.service" ];
      wants = [ "redis.service" "agentos-daemon.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_MODE = cfg.mode;
        AGENTOS_MAX_WORKERS = toString cfg.maxWorkers;
        AGENTOS_TASK_TIMEOUT = toString cfg.taskTimeoutSec;
        AGENTOS_RESULT_STRATEGY = cfg.resultStrategy;
        AGENTOS_REDIS_URL = "redis://localhost:6379";
        AGENTOS_MESSAGE_BUS = lib.boolToString cfg.enableMessageBus;
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.orchestrator}/bin/agentos-orchestrator";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Orchestration CLI ─────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-orchestrate" ''
        #!/usr/bin/env bash
        set -euo pipefail

        BOLD='\033[1m'
        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        NC='\033[0m'

        info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()   { echo -e "''${GREEN}[OK]''${NC} $*"; }

        case "''${1:-help}" in
          status)
            info "Orchestration status:"
            echo "  Mode: ${cfg.mode}"
            echo "  Max workers: ${cfg.maxWorkers}"
            echo "  Task timeout: ${cfg.taskTimeoutSec}s"
            echo "  Result strategy: ${cfg.resultStrategy}"
            echo ""
            echo "  Active tasks:"
            ${pkgs.redis}/bin/redis-cli -n 1 KEYS "task:*" 2>/dev/null | while read -r key; do
              status=$(${pkgs.redis}/bin/redis-cli -n 1 HGET "$key" status 2>/dev/null)
              agent=$(${pkgs.redis}/bin/redis-cli -n 1 HGET "$key" agent 2>/dev/null)
              echo "    $key: $status ($agent)"
            done
            ;;

          run)
            TASK="''${2:-}"
            AGENT="''${3:-claude-code}"
            if [ -z "$TASK" ]; then
              echo "Usage: agentos-orchestrate run \"task description\" [agent]"
              exit 1
            fi
            info "Submitting task to orchestrator..."
            info "Task: $TASK"
            info "Agent: $AGENT"
            info "Mode: ${cfg.mode}"

            # Push task to Redis queue
            TASK_ID="task-$(date +%s)"
            ${pkgs.redis}/bin/redis-cli -n 1 HSET "$TASK_ID" \
              description "$TASK" \
              agent "$AGENT" \
              status "queued" \
              created "$(date -Iseconds)" >/dev/null
            ${pkgs.redis}/bin/redis-cli -n 1 LPUSH "task_queue" "$TASK_ID" >/dev/null
            ok "Task queued: $TASK_ID"
            echo ""
            echo "Monitor with: agentos-orchestrate status"
            echo "View results: agentos-orchestrate results $TASK_ID"
            ;;

          results)
            TASK_ID="''${2:-}"
            if [ -z "$TASK_ID" ]; then
              echo "Usage: agentos-orchestrate results <task-id>"
              exit 1
            fi
            info "Results for $TASK_ID:"
            ${pkgs.redis}/bin/redis-cli -n 1 HGETALL "$TASK_ID" 2>/dev/null
            ;;

          swarm)
            # Swarm mode: run N agents on the same task in parallel
            TASK="''${2:-}"
            N="''${3:-3}"
            if [ -z "$TASK" ]; then
              echo "Usage: agentos-orchestrate swarm \"task\" [count]"
              exit 1
            fi
            info "Starting swarm of $N agents on task:"
            info "  $TASK"

            for i in $(seq 1 "$N"); do
              AGENT_ID="swarm-$(date +%s)-$i"
              info "  Spawning agent $i/$N..."
              (
                cd /var/lib/agentos/workspaces
                mkdir -p "$AGENT_ID" && cd "$AGENT_ID"
                git init --quiet
                agentos spawn claude-code --workspace . &
              ) &
            done
            wait
            ok "Swarm complete. Results in /var/lib/agentos/workspaces/swarm-*"
            ;;

          cancel)
            TASK_ID="''${2:-}"
            if [ -z "$TASK_ID" ]; then
              echo "Usage: agentos-orchestrate cancel <task-id>"
              exit 1
            fi
            ${pkgs.redis}/bin/redis-cli -n 1 HSET "$TASK_ID" status "cancelled" >/dev/null
            ok "Task cancelled: $TASK_ID"
            ;;

          help|*)
            cat <<'HELP'
        AgentOS Orchestration CLI

        USAGE:
            agentos-orchestrate <COMMAND> [ARGS]

        COMMANDS:
            status                 Show orchestration status and active tasks
            run "task" [agent]     Submit a task to the orchestrator
            results <task-id>      Get results for a completed task
            swarm "task" [n]       Run N agents on the same task in parallel
            cancel <task-id>       Cancel a running task

        MODES:
            planner-worker   One planner delegates to workers
            swarm            N agents work independently, best result wins
            hierarchical     Agents spawn sub-agents recursively
            pipeline         Agents work in sequence (output feeds next)

        HELP
            ;;
        esac
      '')
    ];

    networking.firewall.allowedTCPPorts = [ 6379 ];
  };
}
