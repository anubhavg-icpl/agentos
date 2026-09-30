# ═══════════════════════════════════════════════════════════════════════
# AgentOS Circuit Breaker & Rate Limiter Module
# ═══════════════════════════════════════════════════════════════════════
#
# Protects the system from runaway agents:
#   - Rate limit on LLM API calls per agent per minute (model gateway, 429)
#   - Circuit breaker: after N consecutive upstream failures an agent's
#     requests are refused for a cooldown period (model gateway, 503)
#   - Loop detection: an agent that keeps sending the same request is refused
#     (model gateway, 429 loop_detected) and a loop_detected event is published
#   - Resource limits on each sandboxed agent's systemd unit: memory, CPU,
#     number of processes (set by `agentos spawn`)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.circuit-breaker;
  adminSocket = config.agentos.services.settings.gateway.admin_socket;

  breakerCli = pkgs.writeShellApplication {
    name = "agentos-breaker";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      case "''${1:-status}" in
        status)
          echo "Rate limit:       ${toString cfg.maxApiCallsPerMinute} LLM requests per agent per minute"
          echo "Circuit breaker:  opens after ${toString cfg.maxConsecutiveFailures} consecutive upstream failures, for ${toString cfg.cooldownPeriodSec}s"
          echo "Loop detection:   ${if cfg.enableLoopDetection then "${toString cfg.loopRepeatThreshold} identical requests within ${toString cfg.loopWindowSec}s" else "off"}"
          echo "Agent limits:    ${toString cfg.maxMemoryMB} MB memory, ${toString cfg.maxCpuPercent}% of all CPUs, ${toString cfg.maxProcesses} processes"
          ;;
        reset)
          [ $# -eq 2 ] || { echo "Usage: agentos-breaker reset <agent-id>" >&2; exit 1; }
          curl -fsS --unix-socket "${adminSocket}" -X DELETE "http://localhost/_agentos/circuit/$2" \
            | jq -r '"Circuit for \(.agent): \(.circuit)"'
          ;;
        reset-loop)
          [ $# -eq 2 ] || { echo "Usage: agentos-breaker reset-loop <agent-id>" >&2; exit 1; }
          curl -fsS --unix-socket "${adminSocket}" -X DELETE "http://localhost/_agentos/loop/$2" \
            | jq -r '"Loop detection for \(.agent): \(.loop)"'
          ;;
        *)
          echo "Usage: agentos-breaker <status|reset <agent-id>|reset-loop <agent-id>>" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.agentos.circuit-breaker = {
    enable = lib.mkEnableOption "AgentOS circuit breaker and rate limiter";

    maxApiCallsPerMinute = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = "Max LLM API calls per agent per minute (0 = unlimited)";
    };

    maxConsecutiveFailures = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Consecutive upstream failures (5xx or unreachable) before the circuit opens";
    };

    cooldownPeriodSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "How long an open circuit refuses the agent's requests";
    };

    enableLoopDetection = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Refuse (429, error type loop_detected) an agent that sends the same
        request repeatedly. A request's fingerprint is a hash of the last few
        messages (or input items) of its body, so a conversation that makes
        progress never matches. Publishes a loop_detected event, which the
        notifications module reports in the agent-error group.
      '';
    };

    loopRepeatThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Identical consecutive requests after which the agent is treated as looping";
    };

    loopWindowSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "The repeats must all fall within this many seconds of the first one";
    };

    maxCpuPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 80;
      description = "CPU quota per agent, as a percentage of all CPUs";
    };

    maxMemoryMB = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Memory limit per agent (the agent is OOM-killed above it)";
    };

    maxProcesses = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Maximum number of processes/threads per agent (fork-bomb protection)";
    };
  };

  config = lib.mkIf cfg.enable {
    agentos.services.settings.limits = {
      max_requests_per_minute = cfg.maxApiCallsPerMinute;
      max_consecutive_failures = cfg.maxConsecutiveFailures;
      cooldown_sec = cfg.cooldownPeriodSec;
      loop_detection = cfg.enableLoopDetection;
      loop_repeat_threshold = cfg.loopRepeatThreshold;
      loop_window_sec = cfg.loopWindowSec;
    };

    agentos.runtime.agentLimits = {
      memory_mb = cfg.maxMemoryMB;
      cpu_percent = cfg.maxCpuPercent;
      tasks_max = cfg.maxProcesses;
    };

    environment.systemPackages = [ breakerCli ];
  };
}
