# ═══════════════════════════════════════════════════════════════════════
# AgentOS MCP Tool Registry Module
# ═══════════════════════════════════════════════════════════════════════
#
# Manages MCP (Model Context Protocol) tool servers:
#   - A list of MCP tool servers in /etc/agentos/mcp-tools.json
#   - `agentos-tools` to list, enable, disable and add servers
# (A registry service with discovery and health checks is on the roadmap.)
#
# MCP tools let agents do things beyond file editing:
#   - Browser automation (Puppeteer, Playwright)
#   - Database access (Postgres, SQLite, Redis)
#   - Cloud APIs (AWS, GCP, Azure)
#   - SaaS integrations (Slack, GitHub, Linear, Jira)
#   - Code analysis (Semgrep, CodeQL)
#   - Diagram generation (Mermaid, PlantUML)
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.mcp-registry;
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "agentos" "mcp-registry" "registryPort" ]
      "The MCP registry service was a stub and is removed; the tool list is still written to /etc/agentos/mcp-tools.json. See docs/ROADMAP.md.")
  ];

  options.agentos.mcp-registry = {
    enable = lib.mkEnableOption "AgentOS MCP tool registry";

    enableBuiltinTools = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable built-in MCP tool servers";
    };

    extraToolServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
            description = "Command to start the MCP server";
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Command arguments";
          };
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Environment variables";
          };
          enabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      });
      default = { };
      description = "Additional MCP tool servers to register";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Built-in MCP tool servers config ──────────────────────────────
    environment.etc."agentos/mcp-tools.json".text = builtins.toJSON {
      tools = [
        {
          name = "filesystem";
          description = "Read, write, and search files";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-filesystem" "/var/lib/agentos/workspaces" ];
          category = "core";
          enabled = true;
        }
        {
          name = "git";
          description = "Git operations (commit, branch, diff, log)";
          command = "uvx";
          args = [ "mcp-server-git" ];
          category = "core";
          enabled = true;
        }
        {
          name = "github";
          description = "GitHub API (issues, PRs, actions)";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-github" ];
          env = { GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}"; };
          category = "integration";
          enabled = true;
        }
        {
          name = "postgres";
          description = "PostgreSQL database access";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-postgres" ];
          category = "database";
          enabled = false;
        }
        {
          name = "sqlite";
          description = "SQLite database access";
          command = "uvx";
          args = [ "mcp-server-sqlite" "--db-path" "/var/lib/agentos/data/sqlite.db" ];
          category = "database";
          enabled = true;
        }
        {
          name = "fetch";
          description = "Fetch web pages and APIs";
          command = "uvx";
          args = [ "mcp-server-fetch" ];
          category = "web";
          enabled = true;
        }
        {
          name = "memory";
          description = "Persistent key-value memory";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-memory" ];
          category = "core";
          enabled = true;
        }
        {
          name = "puppeteer";
          description = "Browser automation";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-puppeteer" ];
          category = "browser";
          enabled = false;
        }
        {
          name = "brave-search";
          description = "Web search via Brave API";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-brave-search" ];
          env = { BRAVE_API_KEY = "\${BRAVE_API_KEY}"; };
          category = "web";
          enabled = false;
        }
        {
          name = "sequential-thinking";
          description = "Step-by-step reasoning tool";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-sequential-thinking" ];
          category = "reasoning";
          enabled = true;
        }
        {
          name = "slack";
          description = "Slack messaging integration";
          command = "npx";
          args = [ "-y" "@modelcontextprotocol/server-slack" ];
          env = { SLACK_BOT_TOKEN = "\${SLACK_BOT_TOKEN}"; };
          category = "integration";
          enabled = false;
        }
        {
          name = "linear";
          description = "Linear issue tracking";
          command = "npx";
          args = [ "-y" "mcp-remote" "https://mcp.linear.app/sse" ];
          category = "integration";
          enabled = false;
        }
        {
          name = "sentry";
          description = "Sentry error tracking";
          command = "npx";
          args = [ "-y" "@sentry/mcp-server" ];
          env = { SENTRY_ACCESS_TOKEN = "\${SENTRY_TOKEN}"; };
          category = "integration";
          enabled = false;
        }
        {
          name = "semgrep";
          description = "Code security analysis";
          command = "uvx";
          args = [ "semgrep-mcp" ];
          category = "security";
          enabled = true;
        }
      ];
    };

    # ─ MCP tool management CLI ───────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-tools" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
        info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        # /etc is read-only (generated by Nix); runtime changes go to STATE.
        DEFAULTS="/etc/agentos/mcp-tools.json"
        STATE="/var/lib/agentos/mcp-tools.json"
        CONFIG="$DEFAULTS"
        [ -f "$STATE" ] && CONFIG="$STATE"
        save() {
          local tmp
          tmp=$(mktemp)
          cat > "$tmp"
          install -D -m 644 "$tmp" "$STATE"
          rm -f "$tmp"
        }

        case "''${1:-list}" in
          list)
            info "Available MCP tools:"
            echo ""
            ${pkgs.jq}/bin/jq -r '.tools[] | select(.enabled) | "  \(.name)\t\(.description)"' "$CONFIG" 2>/dev/null | \
              column -t -s $'\t'
            echo ""
            warn "Disabled tools:"
            ${pkgs.jq}/bin/jq -r '.tools[] | select(.enabled | not) | "  \(.name)\t\(.description)"' "$CONFIG" 2>/dev/null | \
              column -t -s $'\t' || true
            ;;

          enable)
            TOOL="''${2:-}"
            if [ -z "$TOOL" ]; then
              echo "Usage: agentos-tools enable <tool-name>"
              exit 1
            fi
            info "Enabling tool: $TOOL"
            ${pkgs.jq}/bin/jq --arg n "$TOOL" '.tools |= map(if .name == $n then .enabled = true else . end)' "$CONFIG" | save
            ok "Enabled: $TOOL"
            ;;

          disable)
            TOOL="''${2:-}"
            if [ -z "$TOOL" ]; then
              echo "Usage: agentos-tools disable <tool-name>"
              exit 1
            fi
            info "Disabling tool: $TOOL"
            ${pkgs.jq}/bin/jq --arg n "$TOOL" '.tools |= map(if .name == $n then .enabled = false else . end)' "$CONFIG" | save
            ok "Disabled: $TOOL"
            ;;

          add)
            NAME="''${2:-}"
            CMD="''${3:-}"
            if [ -z "$NAME" ] || [ -z "$CMD" ]; then
              echo "Usage: agentos-tools add <name> <command>"
              exit 1
            fi
            info "Adding custom tool: $NAME"
            ${pkgs.jq}/bin/jq --arg n "$NAME" --arg c "$CMD" '.tools += [{name: $n, command: $c, enabled: true, category: "custom"}]' "$CONFIG" | save
            ok "Added: $NAME"
            ;;

          *)
            echo "Usage: agentos-tools <list|enable|disable|add> [args]"
            ;;
        esac
      '')
    ];
  };
}
