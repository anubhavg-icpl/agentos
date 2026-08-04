# ═══════════════════════════════════════════════════════════════════════
# AgentOS Circuit Breaker & Rate Limiter Module
# ═══════════════════════════════════════════════════════════════════════
#
# Protects the system from runaway agents:
#   - Rate limits on LLM API calls (per agent, per minute)
#   - Rate limits on file writes (prevent disk fill)
#   - Rate limits on shell commands (prevent fork bombs)
#   - Circuit breaker: if an agent fails N times in a row, pause it
#   - Resource monitors: kill agents that use too much CPU/RAM
#   - Infinite loop detection (repeated identical actions)
#   - Network flood protection
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.circuit-breaker;
in
{
  options.agentos.circuit-breaker = {
    enable = lib.mkEnableOption "AgentOS circuit breaker and rate limiter";

    maxApiCallsPerMinute = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Max LLM API calls per agent per minute";
    };

    maxFileWritesPerMinute = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "Max file writes per agent per minute";
    };

    maxShellCommandsPerMinute = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Max shell commands per agent per minute";
    };

    maxConsecutiveFailures = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Consecutive failures before circuit breaker trips";
    };

    cooldownPeriodSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "How long to pause an agent after circuit breaker trips (5 min)";
    };

    maxCpuPercent = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "Max CPU percentage per agent before kill";
    };

    maxMemoryMB = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Max memory per agent in MB before kill";
    };

    enableLoopDetection = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Detect and break agents stuck in loops";
    };

    loopDetectionWindow = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Number of recent actions to check for loops";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Resource limits via systemd ───────────────────────────────────
    systemd.extraConfig = ''
      DefaultCPUAccounting=yes
      DefaultIOAccounting=yes
      DefaultBlockIOAccounting=yes
      DefaultMemoryAccounting=yes
      DefaultTasksAccounting=yes
      DefaultLimitNOFILE=4096
      DefaultTasksMax=256
    '';

    # ─ Per-agent resource limits (applied at agent spawn time) ───────
    # These are enforced by the agentos-daemon when it spawns containers.
    environment.etc."agentos/limits.conf".text = ''
      [rate-limits]
      api_calls_per_minute = ${toString cfg.maxApiCallsPerMinute}
      file_writes_per_minute = ${toString cfg.maxFileWritesPerMinute}
      shell_commands_per_minute = ${toString cfg.maxShellCommandsPerMinute}

      [circuit-breaker]
      max_consecutive_failures = ${toString cfg.maxConsecutiveFailures}
      cooldown_period_sec = ${toString cfg.cooldownPeriodSec}

      [resource-limits]
      max_cpu_percent = ${toString cfg.maxCpuPercent}
      max_memory_mb = ${toString cfg.maxMemoryMB}
      max_disk_mb = 5120
      max_network_connections = 50

      [loop-detection]
      enabled = ${lib.boolToString cfg.enableLoopDetection}
      window_size = ${toString cfg.loopDetectionWindow}
    '';

    # ─ Circuit breaker service ───────────────────────────────────────
    systemd.services.agentos-circuit-breaker = {
      description = "AgentOS Circuit Breaker";
      after = [ "network.target" "redis.service" "agentos-daemon.service" ];
      wants = [ "redis.service" "agentos-daemon.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_LIMITS_CONFIG = "/etc/agentos/limits.conf";
        AGENTOS_REDIS_URL = "redis://localhost:6379";
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.circuit-breaker}/bin/agentos-circuit-breaker";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Resource monitor (checks every 30s for runaway agents) ────────
    systemd.services.agentos-resource-monitor = {
      description = "AgentOS Resource Monitor";
      after = [ "agentos-daemon.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "root";  # needs root to read cgroup stats
        ExecStart = toString (pkgs.writeShellScript "resource-monitor" ''
          #!/usr/bin/env bash
          set -euo pipefail

          MAX_CPU=${toString cfg.maxCpuPercent}
          MAX_MEM=${toString cfg.maxMemoryMB}

          while true; do
            sleep 30

            # Check each agent container
            for cg in /sys/fs/cgroup/system.slice/agentos-agent-*/; do
              [ -d "$cg" ] || continue
              AGENT_ID=$(basename "$cg" | sed 's/agentos-agent-//')

              # Read memory usage (bytes)
              if [ -f "$cg/memory.current" ]; then
                MEM_BYTES=$(cat "$cg/memory.current")
                MEM_MB=$((MEM_BYTES / 1048576))

                if [ "$MEM_MB" -gt "$MAX_MEM" ]; then
                  echo "[resource-monitor] KILLING agent $AGENT_ID: using ''${MEM_MB}MB (limit: ''${MAX_MEM}MB)"
                  # Notify daemon to kill gracefully
                  ${pkgs.redis}/bin/redis-cli PUBLISH agentos.kill "$AGENT_ID" 2>/dev/null || true
                fi
              fi

              # Read CPU usage
              if [ -f "$cg/cpu.stat" ]; then
                # This is a simplification; real implementation uses usec deltas
                CPU_USEC=$(grep usage_usec "$cg/cpu.stat" 2>/dev/null | awk '{print $2}' || echo "0")
                # Log for monitoring; actual CPU% needs time-windowed comparison
              fi
            done
          done
        '');
        Restart = "always";
        RestartSec = 10;
      };
    };

    # ─ Circuit breaker CLI ───────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-breaker" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        RED='\033[0;31m'
        NC='\033[0m'

        case "''${1:-status}" in
          status)
            echo -e "''${GREEN}Circuit Breaker Status''${NC}"
            echo ""
            echo "Rate limits:"
            echo "  API calls:      ${toString cfg.maxApiCallsPerMinute}/min"
            echo "  File writes:    ${toString cfg.maxFileWritesPerMinute}/min"
            echo "  Shell commands: ${toString cfg.maxShellCommandsPerMinute}/min"
            echo ""
            echo "Circuit breaker:"
            echo "  Max failures:   ${toString cfg.maxConsecutiveFailures}"
            echo "  Cooldown:       ${toString cfg.cooldownPeriodSec}s"
            echo ""
            echo "Resource limits:"
            echo "  Max CPU:        ${toString cfg.maxCpuPercent}%"
            echo "  Max memory:     ${toString cfg.maxMemoryMB}MB"
            echo ""
            echo "Tripped circuits:"
            keys=$(${pkgs.redis}/bin/redis-cli -n 3 KEYS "tripped:*" 2>/dev/null || true)
            if [ -n "$keys" ]; then
              for key in $keys; do
                agent=$(echo "$key" | sed 's/tripped://')
                ttl=$(${pkgs.redis}/bin/redis-cli -n 3 TTL "$key" 2>/dev/null || echo "?")
                echo -e "  ''${RED}$agent (cooldown: ''${ttl}s)''${NC}"
              done
            else
              echo "  (none)"
            fi
            ;;

          trip)
            AGENT="''${2:-}"
            if [ -z "$AGENT" ]; then
              echo "Usage: agentos-breaker trip <agent-id>"
              exit 1
            fi
            ${pkgs.redis}/bin/redis-cli -n 3 SETEX "tripped:$AGENT" ${toString cfg.cooldownPeriodSec} "manual"
            echo "Tripped circuit for: $AGENT"
            ;;

          reset)
            AGENT="''${2:-}"
            if [ -z "$AGENT" ]; then
              echo "Resetting all circuits..."
              ${pkgs.redis}/bin/redis-cli -n 3 FLUSHDB
              echo "Done."
            else
              ${pkgs.redis}/bin/redis-cli -n 3 DEL "tripped:$AGENT"
              echo "Reset circuit for: $AGENT"
            fi
            ;;

          *)
            echo "Usage: agentos-breaker <status|trip|reset> [agent-id]"
            ;;
        esac
      '')
    ];
  };
}
