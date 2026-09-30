# ═══════════════════════════════════════════════════════════════════════
# AgentOS Budget & Cost Controller Module
# ═══════════════════════════════════════════════════════════════════════
#
# Budgets are enforced by the model gateway (agentos.networking):
#   - every LLM response is priced from token usage (pricing.json)
#   - per-agent and global daily caps (UTC days); requests over the cap get
#     HTTP 402 before they reach the provider
#   - alerts at configurable thresholds (sent through agentos-notify targets)
#   - auto-shutdown: the agent daemon stops a sandboxed agent's unit when it
#     exceeds its budget
#
# Sandboxed agents (run as agentos-agent) cannot reach provider APIs except
# through the gateway, so they cannot bypass the cap.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.budget-controller;
  adminSocket = config.agentos.services.settings.gateway.admin_socket;
  gatewayUrl = "http://127.0.0.1:${toString config.agentos.networking.modelGatewayPort}";

  budgetCli = pkgs.writeShellApplication {
    name = "agentos-budget";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.util-linux ];
    text = ''
      GATEWAY="${gatewayUrl}"
      ADMIN_SOCKET="${adminSocket}"

      get() { curl -fsS "$GATEWAY/_agentos/$1"; }
      admin() {
        local method="$1" path="$2"
        local args=(-fsS --unix-socket "$ADMIN_SOCKET" -X "$method" -H 'Content-Type: application/json')
        if [ $# -ge 3 ]; then
          args+=(--data "$3")
        fi
        if [ ! -w "$ADMIN_SOCKET" ]; then
          echo "Cannot write to $ADMIN_SOCKET: changing budgets needs membership in the agentos group" >&2
          exit 1
        fi
        curl "''${args[@]}" "http://localhost/_agentos/$path"
      }

      usage() {
        cat <<'EOF'
      Usage: agentos-budget <command>

        status [--json]            Spend per agent today (UTC) and limits
        set <agent-id> <usd>       Set an agent's daily budget
        reset <agent-id>           Back to the default daily budget
        history                    Global spend for the last 7 days
        by-model                   Spend per model today
      EOF
      }

      case "''${1:-status}" in
        status)
          snap=$(get spend)
          if [ "''${2:-}" = "--json" ]; then
            echo "$snap"
            exit 0
          fi
          echo "$snap" | jq -r '
            "Date (UTC):        \(.date)",
            "Default budget:    $\(.default_limit_usd) per agent per day",
            "Global:            $\(.global_usd * 100 | round / 100) of $\(.global_limit_usd)",
            "",
            (if (.agents | length) == 0 then "No agent spend today."
             else
               (["AGENT", "SPENT", "LIMIT", "USED", "REQUESTS"] | @tsv),
               (.agents | to_entries[] |
                 [ .key,
                   "$" + (.value.usd * 10000 | round / 10000 | tostring),
                   "$" + (.value.limit_usd | tostring),
                   (if .value.limit_usd > 0 then (.value.usd / .value.limit_usd * 100 | floor | tostring) + "%" else "-" end),
                   (.value.requests | to_entries | map("\(.key):\(.value)") | join(" "))
                 ] | @tsv)
             end)' | column -t -s $'\t'
          ;;
        set)
          [ $# -eq 3 ] || { usage; exit 1; }
          admin PUT "budget/$2" "$(jq -cn --argjson usd "$3" '{daily_usd: $usd}')" | jq -r '"Budget for \(.agent): $\(.limit_usd)/day"'
          ;;
        reset)
          [ $# -eq 2 ] || { usage; exit 1; }
          admin DELETE "budget/$2" | jq -r '"Budget for \(.agent): $\(.limit_usd)/day (default)"'
          ;;
        history)
          get "history?days=7" | jq -r 'to_entries | sort_by(.key) | reverse[] | "\(.key)  $\(.value * 100 | round / 100)"'
          ;;
        by-model)
          get spend | jq -r '.models | to_entries | sort_by(-.value)[] | "\(.key)\t$\(.value * 10000 | round / 10000)"' | column -t -s $'\t'
          ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
      esac
    '';
  };
in
{
  options.agentos.budget-controller = {
    enable = lib.mkEnableOption "AgentOS budget controller";

    defaultDailyBudgetUSD = lib.mkOption {
      type = lib.types.float;
      default = 50.0;
      description = "Default daily budget per agent (USD, UTC day)";
    };

    globalDailyBudgetUSD = lib.mkOption {
      type = lib.types.float;
      default = 500.0;
      description = "Daily budget across all agents (USD, UTC day)";
    };

    alertThresholds = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ 50 80 95 ];
      description = "Percentages of an agent's budget that trigger a budget_threshold event";
    };

    autoShutdown = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Stop sandboxed agents that exceed their budget";
    };

    pricingFile = lib.mkOption {
      type = lib.types.path;
      default = ./pricing.json;
      description = "JSON file with per-model pricing (USD per million tokens)";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.agentos.networking.enable;
      message = "agentos.budget-controller is enforced by the model gateway; enable agentos.networking";
    }];

    environment.etc."agentos/pricing.json".source = cfg.pricingFile;

    agentos.services.settings.budget = {
      default_daily_usd = cfg.defaultDailyBudgetUSD;
      global_daily_usd = cfg.globalDailyBudgetUSD;
      alert_thresholds = cfg.alertThresholds;
      auto_shutdown = cfg.autoShutdown;
    };

    environment.systemPackages = [ budgetCli ];
  };
}
