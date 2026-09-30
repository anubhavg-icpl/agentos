# ═══════════════════════════════════════════════════════════════════════
# AgentOS Notifications Module
# ═══════════════════════════════════════════════════════════════════════
#
# Sends notifications when agent events happen:
#   - Agent task completed
#   - Agent needs human approval
#   - Budget threshold reached
#   - Agent error/crash
#   - PR created
#   - Tests passed/failed
#
# Channels: Slack, Discord, Email, Webhook, Desktop (if available)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.notifications;
in
{
  options.agentos.notifications = {
    enable = lib.mkEnableOption "AgentOS notifications";

    enableSlack = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Slack notifications";
    };

    slackWebhook = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Slack incoming webhook URL";
    };

    enableDiscord = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable Discord notifications";
    };

    discordWebhook = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Discord webhook URL";
    };

    enableEmail = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable email notifications";
    };

    emailRecipient = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Email address for notifications";
    };

    enableWebhook = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable generic webhook notifications";
    };

    webhookUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Generic webhook URL for notifications";
    };

    notifyOn = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "task-completed"
        "approval-needed"
        "budget-threshold"
        "agent-error"
        "pr-created"
        "tests-failed"
        "tests-passed"
      ]);
      default = [ "task-completed" "approval-needed" "budget-threshold" "agent-error" ];
      description = "Which events trigger notifications";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Notification dispatcher ───────────────────────────────────────
    systemd.services.agentos-notifier = lib.mkIf config.agentos.daemons.enable {
      description = "AgentOS Notification Dispatcher";
      after = [ "network.target" "redis-agentos.service" ];
      wants = [ "redis-agentos.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_NOTIFY_SLACK = lib.boolToString cfg.enableSlack;
        AGENTOS_NOTIFY_DISCORD = lib.boolToString cfg.enableDiscord;
        AGENTOS_NOTIFY_EMAIL = lib.boolToString cfg.enableEmail;
        AGENTOS_NOTIFY_WEBHOOK = lib.boolToString cfg.enableWebhook;
        AGENTOS_REDIS_URL = "redis://localhost:6379";
        AGENTOS_NOTIFY_EVENTS = builtins.concatStringsSep "," cfg.notifyOn;
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.notifier}/bin/agentos-notifier";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Secrets for webhooks (via environment file) ───────────────────
    environment.etc."agentos/notifications.conf".text = lib.concatStringsSep "\n" (
      lib.optional (cfg.slackWebhook != "") "SLACK_WEBHOOK=${cfg.slackWebhook}"
      ++ lib.optional (cfg.discordWebhook != "") "DISCORD_WEBHOOK=${cfg.discordWebhook}"
      ++ lib.optional (cfg.webhookUrl != "") "GENERIC_WEBHOOK=${cfg.webhookUrl}"
      ++ lib.optional (cfg.emailRecipient != "") "EMAIL_RECIPIENT=${cfg.emailRecipient}"
    );

    # ─ Notification CLI ──────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-notify" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        NC='\033[0m'
        info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()   { echo -e "''${GREEN}[OK]''${NC} $*"; }

        # Source webhook config
        [ -f /etc/agentos/notifications.conf ] && source /etc/agentos/notifications.conf

        send_slack() {
          local msg="$1"
          [ -z "''${SLACK_WEBHOOK:-}" ] && return
          ${pkgs.curl}/bin/curl -s -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"text\": \"AgentOS: $msg\"}" >/dev/null 2>&1 || true
        }

        send_discord() {
          local msg="$1"
          [ -z "''${DISCORD_WEBHOOK:-}" ] && return
          ${pkgs.curl}/bin/curl -s -X POST "$DISCORD_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"content\": \"AgentOS: $msg\"}" >/dev/null 2>&1 || true
        }

        send_webhook() {
          local event="$1"
          local msg="$2"
          [ -z "''${GENERIC_WEBHOOK:-}" ] && return
          ${pkgs.curl}/bin/curl -s -X POST "$GENERIC_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"event\": \"$event\", \"message\": \"$msg\", \"source\": \"agentos\", \"timestamp\": \"$(date -Iseconds)\"}" >/dev/null 2>&1 || true
        }

        case "''${1:-status}" in
          send)
            EVENT="''${2:-info}"
            MSG="''${3:-No message}"
            info "Sending notification: $MSG"
            send_slack "$MSG"
            send_discord "$MSG"
            send_webhook "$EVENT" "$MSG"
            ok "Notifications sent"
            ;;

          test)
            info "Sending test notification..."
            send_slack "Test notification from AgentOS"
            send_discord "Test notification from AgentOS"
            send_webhook "test" "Test notification from AgentOS"
            ok "Test sent. Check your channels."
            ;;

          status)
            echo "Notification channels:"
            [ -n "''${SLACK_WEBHOOK:-}" ] && ok "Slack: configured" || echo "  Slack: not configured"
            [ -n "''${DISCORD_WEBHOOK:-}" ] && ok "Discord: configured" || echo "  Discord: not configured"
            [ -n "''${GENERIC_WEBHOOK:-}" ] && ok "Webhook: configured" || echo "  Webhook: not configured"
            echo ""
            echo "Notify on: ${lib.concatStringsSep ", " cfg.notifyOn}"
            ;;

          *)
            echo "Usage: agentos-notify <send|test|status>"
            ;;
        esac
      '')
    ];
  };
}
