# ═══════════════════════════════════════════════════════════════════════
# Nestlo Notifications Module
# ═══════════════════════════════════════════════════════════════════════
#
# The agent daemon forwards agent events to Slack, Discord or a generic
# JSON webhook:
#   agent-started     an agent was spawned
#   task-completed    an agent exited on its own
#   budget-threshold  an agent crossed a budget alert threshold, exceeded its
#                     budget, or the global budget ran out
#   agent-error       an agent was stopped (budget, manual), its circuit
#                     breaker opened, or loop detection refused it
#
# Webhook URLs are secrets, so they are read from files at send time (for
# example sops secrets under /run/secrets) instead of being put in the
# world-readable Nix store. The nestlo user must be able to read them.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.notifications;

  eventMap = {
    agent-started = [ "agent_started" ];
    task-completed = [ "agent_exited" ];
    budget-threshold = [ "budget_threshold" "budget_exceeded" "global_budget_exceeded" ];
    agent-error = [ "agent_killed" "circuit_open" "loop_detected" ];
  };

  targets =
    lib.optional (cfg.slackWebhookFile != null) { kind = "slack"; url_file = cfg.slackWebhookFile; }
    ++ lib.optional (cfg.discordWebhookFile != null) { kind = "discord"; url_file = cfg.discordWebhookFile; }
    ++ lib.optional (cfg.webhookUrlFile != null) { kind = "webhook"; url_file = cfg.webhookUrlFile; }
    ++ lib.optional (cfg.webhookUrl != null) { kind = "webhook"; url = cfg.webhookUrl; };

  notifyCli = pkgs.writeShellApplication {
    name = "nestlo-notify";
    runtimeInputs = [ pkgs.curl pkgs.jq ];
    text = ''
      targets='${builtins.toJSON targets}'

      post() {
        local kind="$1" url="$2" text="$3" body
        case "$kind" in
          slack)   body=$(jq -cn --arg t "Nestlo: $text" '{text: $t}') ;;
          discord) body=$(jq -cn --arg t "Nestlo: $text" '{content: $t}') ;;
          *)       body=$(jq -cn --arg t "$text" '{type: "test", text: $t, source: "nestlo"}') ;;
        esac
        curl -fsS -m 10 -X POST -H 'Content-Type: application/json' --data "$body" "$url" >/dev/null
      }

      case "''${1:-status}" in
        status)
          echo "Events: ${lib.concatStringsSep ", " cfg.notifyOn}"
          echo "Targets:"
          echo "$targets" | jq -r 'if length == 0 then "  (none configured)" else .[] | "  \(.kind): \(.url_file // "inline URL")" end'
          ;;
        test)
          msg="''${2:-Test notification}"
          echo "$targets" | jq -c '.[]' | while read -r t; do
            kind=$(echo "$t" | jq -r .kind)
            url=$(echo "$t" | jq -r '.url // empty')
            file=$(echo "$t" | jq -r '.url_file // empty')
            if [ -n "$file" ]; then
              url=$(cat "$file")
            fi
            if post "$kind" "$url" "$msg"; then
              echo "$kind: sent"
            else
              echo "$kind: FAILED"
            fi
          done
          ;;
        *)
          echo "Usage: nestlo-notify <status|test [message]>" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.nestlo.notifications = {
    enable = lib.mkEnableOption "Nestlo notifications";

    slackWebhookFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/SLACK_WEBHOOK";
      description = "File containing a Slack incoming-webhook URL";
    };

    discordWebhookFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File containing a Discord webhook URL";
    };

    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File containing a generic webhook URL (receives the event JSON)";
    };

    webhookUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://127.0.0.1:9000/nestlo";
      description = "Generic webhook URL (stored in the Nix store; use webhookUrlFile for secret URLs)";
    };

    notifyOn = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames eventMap));
      default = [ "task-completed" "budget-threshold" "agent-error" ];
      description = "Which events trigger notifications";
    };
  };

  config = lib.mkIf cfg.enable {
    nestlo.services.settings.notify = {
      events = lib.unique (lib.concatMap (e: eventMap.${e}) cfg.notifyOn);
      inherit targets;
    };

    environment.systemPackages = [ notifyCli ];
  };
}
