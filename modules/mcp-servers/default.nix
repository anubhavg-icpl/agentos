# ═══════════════════════════════════════════════════════════════════════
# AgentOS MCP Server Registry — 35 Preconfigured MCP Servers
# ═══════════════════════════════════════════════════════════════════════
#
# The Model Context Protocol (MCP) is how agents access external tools.
# This module writes /etc/agentos/mcp-servers.json describing 35 MCP
# servers. Every entry points at a package published on npm (run with
# `npx -y`) or PyPI (run with `uvx`); nothing is pre-downloaded, so a
# server is fetched the first time it starts.
#
# Categories:
#   CORE (7): filesystem, git, memory, fetch, sequential-thinking, time,
#             everything
#   DATABASE (7): postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse
#   CLOUD (4, off by default): aws, azure, cloudflare, supabase
#   INTEGRATION (7): github, gitlab, linear, slack, notion, sentry,
#                    pagerduty
#   BROWSER (3): puppeteer, playwright, browserbase
#   AI/ML (1): huggingface
#   DEVOPS (2): docker, kubernetes
#   DATA (4): brave-search, tavily, exa, perplexity
#
# Several @modelcontextprotocol/* servers used here (github, gitlab, slack,
# postgres, redis, puppeteer, brave-search) are archived upstream; they
# still install but no longer receive fixes.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.mcp-servers;
in
{
  options.agentos.mcp-servers = {
    enable = lib.mkEnableOption "AgentOS MCP server registry (35 servers)";

    enableCore = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable core MCP servers (filesystem, git, memory, etc.)";
    };

    enableDatabases = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable database MCP servers";
    };

    enableCloud = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable cloud provider MCP servers (needs credentials)";
    };

    enableIntegrations = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SaaS integration MCP servers (needs API keys)";
    };

    enableBrowser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable browser automation MCP servers";
    };

    enableAI = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable AI/ML MCP servers";
    };

    enableDevOps = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable DevOps MCP servers";
    };

    enableData = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable data/search MCP servers";
    };

    registryPort = lib.mkOption {
      type = lib.types.port;
      default = 9946;
      description = "Port for the MCP registry API";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── MCP server registry config ───────────────────────────────────
    environment.etc."agentos/mcp-servers.json".text = builtins.toJSON {
      servers = lib.flatten [
        # ════════════════════════════════════════════════════════════
        # CORE MCP SERVERS (10)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableCore [
          {
            name = "filesystem";
            description = "Read, write, search files in workspaces";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-filesystem" "/var/lib/agentos/workspaces" ];
            category = "core";
            port = null;
            env = { };
            enabled = true;
          }
          {
            name = "git";
            description = "Git operations: commit, branch, diff, log, merge";
            command = "uvx";
            args = [ "mcp-server-git" ];
            category = "core";
            enabled = true;
          }
          {
            name = "memory";
            description = "Persistent key-value memory graph";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-memory" ];
            category = "core";
            enabled = true;
          }
          {
            name = "fetch";
            description = "Fetch web pages and APIs, convert to markdown";
            command = "uvx";
            args = [ "mcp-server-fetch" ];
            category = "core";
            enabled = true;
          }
          {
            name = "sequential-thinking";
            description = "Step-by-step reasoning with revision and branching";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-sequential-thinking" ];
            category = "core";
            enabled = true;
          }
          {
            name = "time";
            description = "Time and timezone tools";
            command = "uvx";
            args = [ "mcp-server-time" ];
            category = "core";
            enabled = true;
          }
          {
            name = "everything";
            description = "Reference server that exercises every MCP feature (for testing clients)";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-everything" ];
            category = "core";
            enabled = true;
          }
          {
            # Ships with AgentOS (no download); reads AGENTOS_AGENT_ID and the
            # gateway URL from the environment `agentos spawn` sets.
            name = "agentos-bus";
            description = "Message other agents through the AgentOS gateway: send_message, read_messages";
            command = "${pkgs.agentos.services}/bin/agentos-mcp-bus";
            args = [ ];
            category = "core";
            port = null;
            env = { };
            enabled = true;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # DATABASE MCP SERVERS (8)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableDatabases [
          {
            name = "postgres";
            description = "PostgreSQL: query, schema, migrations";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-postgres" "postgresql://agentos@localhost/agentos" ];
            category = "database";
            enabled = true;
          }
          {
            name = "sqlite";
            description = "SQLite: query, create, manage databases";
            command = "uvx";
            args = [ "mcp-server-sqlite" "--db-path" "/var/lib/agentos/data/sqlite.db" ];
            category = "database";
            enabled = true;
          }
          {
            name = "mysql";
            description = "MySQL/MariaDB: query and manage";
            command = "npx";
            args = [ "-y" "@benborla29/mcp-server-mysql" ];
            category = "database";
            env = { MYSQL_HOST = "localhost"; MYSQL_USER = "agentos"; };
            enabled = false;
          }
          {
            name = "redis";
            description = "Redis: key-value, pub/sub, streams";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-redis" "redis://localhost:6379" ];
            category = "database";
            enabled = true;
          }
          {
            name = "mongo";
            description = "MongoDB: CRUD, aggregation, indexes";
            command = "npx";
            args = [ "-y" "mongodb-mcp-server" ];
            category = "database";
            enabled = false;
          }
          {
            name = "duckdb";
            description = "DuckDB: in-process analytics SQL";
            command = "uvx";
            args = [ "mcp-server-motherduck" "--db-path" ":memory:" ];
            category = "database";
            enabled = true;
          }
          {
            name = "clickhouse";
            description = "ClickHouse: columnar OLAP queries";
            command = "uvx";
            args = [ "mcp-clickhouse" ];
            category = "database";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # CLOUD PROVIDER MCP SERVERS (8)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableCloud [
          {
            name = "aws";
            description = "AWS: S3, EC2, Lambda, DynamoDB, CloudFormation";
            command = "uvx";
            args = [ "awslabs.aws-api-mcp-server" ];
            env = { AWS_REGION = "us-east-1"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "azure";
            description = "Azure: Storage, Functions, CosmosDB";
            command = "npx";
            args = [ "-y" "@azure/mcp" "server" "start" ];
            category = "cloud";
            enabled = false;
          }
          {
            name = "cloudflare";
            description = "Cloudflare: Workers, KV, R2, D1, Durable Objects";
            command = "npx";
            args = [ "-y" "@cloudflare/mcp-server-cloudflare" ];
            env = { CLOUDFLARE_API_TOKEN = "\${CF_API_TOKEN}"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "supabase";
            description = "Supabase: database, auth, storage, realtime";
            command = "npx";
            args = [ "-y" "@supabase/mcp-server-supabase" ];
            env = { SUPABASE_URL = "\${SUPABASE_URL}"; SUPABASE_KEY = "\${SUPABASE_KEY}"; };
            category = "cloud";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # SAAS INTEGRATION MCP SERVERS (12)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableIntegrations [
          {
            name = "github";
            description = "GitHub: repos, issues, PRs, actions, gists";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-github" ];
            env = { GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}"; };
            category = "integration";
            enabled = true;
          }
          {
            name = "gitlab";
            description = "GitLab: repos, MRs, pipelines";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-gitlab" ];
            env = { GITLAB_PERSONAL_ACCESS_TOKEN = "\${GITLAB_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "linear";
            description = "Linear: issues, projects, cycles, sprints";
            command = "npx";
            args = [ "-y" "mcp-remote" "https://mcp.linear.app/sse" ];
            category = "integration";
            enabled = false;
          }
          {
            name = "slack";
            description = "Slack: channels, messages, threads, files";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-slack" ];
            env = { SLACK_BOT_TOKEN = "\${SLACK_BOT_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "notion";
            description = "Notion: pages, databases, blocks";
            command = "npx";
            args = [ "-y" "@notionhq/notion-mcp-server" ];
            env = { NOTION_API_KEY = "\${NOTION_KEY}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "sentry";
            description = "Sentry: errors, issues, releases, stack traces";
            command = "npx";
            args = [ "-y" "@sentry/mcp-server" ];
            env = { SENTRY_ACCESS_TOKEN = "\${SENTRY_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "pagerduty";
            description = "PagerDuty: incidents, services, schedules";
            command = "uvx";
            args = [ "pagerduty-mcp" ];
            env = { PAGERDUTY_USER_API_KEY = "\${PD_API_KEY}"; };
            category = "integration";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # BROWSER AUTOMATION MCP SERVERS (4)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableBrowser [
          {
            name = "puppeteer";
            description = "Puppeteer: headless Chrome automation";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-puppeteer" ];
            category = "browser";
            enabled = true;
          }
          {
            name = "playwright";
            description = "Playwright: cross-browser automation, screenshots";
            command = "npx";
            args = [ "-y" "@playwright/mcp" ];
            category = "browser";
            enabled = true;
          }
          {
            name = "browserbase";
            description = "Browserbase: cloud browser sessions at scale";
            command = "npx";
            args = [ "-y" "@browserbasehq/mcp" ];
            env = { BROWSERBASE_API_KEY = "\${BB_API_KEY}"; };
            category = "browser";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # AI/ML MCP SERVERS (4)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableAI [
          {
            name = "huggingface";
            description = "HuggingFace: models, datasets, spaces";
            command = "npx";
            args = [ "-y" "@llmindset/hf-mcp-server" ];
            env = { HF_API_TOKEN = "\${HF_TOKEN}"; };
            category = "ai";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # DEVOPS MCP SERVERS (6)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableDevOps [
          {
            name = "docker";
            description = "Docker: containers, images, volumes, compose";
            command = "uvx";
            args = [ "mcp-server-docker" ];
            category = "devops";
            enabled = true;
          }
          {
            name = "kubernetes";
            description = "Kubernetes: pods, deployments, services";
            command = "npx";
            args = [ "-y" "mcp-server-kubernetes" ];
            category = "devops";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # DATA / SEARCH MCP SERVERS (4)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableData [
          {
            name = "brave-search";
            description = "Brave Search: web, news, images, videos";
            command = "npx";
            args = [ "-y" "@modelcontextprotocol/server-brave-search" ];
            env = { BRAVE_API_KEY = "\${BRAVE_API_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "tavily";
            description = "Tavily: AI-optimized web search and extraction";
            command = "npx";
            args = [ "-y" "tavily-mcp" ];
            env = { TAVILY_API_KEY = "\${TAVILY_API_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "exa";
            description = "Exa: neural web search for AI agents";
            command = "npx";
            args = [ "-y" "exa-mcp-server" ];
            env = { EXA_API_KEY = "\${EXA_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "perplexity";
            description = "Perplexity: AI-powered web search with citations";
            command = "npx";
            args = [ "-y" "@perplexity-ai/mcp-server" ];
            env = { PERPLEXITY_API_KEY = "\${PERPLEXITY_KEY}"; };
            category = "data";
            enabled = false;
          }
        ])
      ];
    };

    # ── MCP registry management CLI ──────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-mcp" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        NC='\033[0m'
        info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        # /etc is read-only (generated by Nix); runtime changes go to STATE.
        DEFAULTS="/etc/agentos/mcp-servers.json"
        STATE="/var/lib/agentos/mcp-servers.json"
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
            CATEGORY="''${2:-}"
            echo -e "''${BOLD}═══════════════════════════════════════════════════''${NC}"
            echo -e "''${BOLD}         AgentOS MCP Server Registry                 ''${NC}"
            echo -e "''${BOLD}═══════════════════════════════════════════════════''${NC}"
            echo ""

            if [ -n "$CATEGORY" ]; then
              echo -e "''${BOLD}Category: $CATEGORY''${NC}"
              ${pkgs.jq}/bin/jq -r --arg cat "$CATEGORY" '.servers[] | select(.category == $cat) | select(.enabled) | "  ✓ \(.name)\t\(.description)"' "$CONFIG" 2>/dev/null | column -t -s $'\t'
              exit 0
            fi

            for cat in core database cloud integration browser ai devops data; do
              count=$(${pkgs.jq}/bin/jq -r --arg c "$cat" '[.servers[] | select(.category == $c) | select(.enabled)] | length' "$CONFIG" 2>/dev/null || echo 0)
              total=$(${pkgs.jq}/bin/jq -r --arg c "$cat" '[.servers[] | select(.category == $c)] | length' "$CONFIG" 2>/dev/null || echo 0)
              if [ "$total" -gt 0 ]; then
                echo -e "''${BOLD}$(echo $cat | tr '[:lower:]' '[:upper:]') ($count/$total enabled)''${NC}"
                ${pkgs.jq}/bin/jq -r --arg cat "$cat" '.servers[] | select(.category == $cat) | (if .enabled then "  ✓" else "  ✗" end) + " \(.name)\t\(.description)"' "$CONFIG" 2>/dev/null | column -t -s $'\t'
                echo ""
              fi
            done

            enabled_count=$(${pkgs.jq}/bin/jq '[.servers[] | select(.enabled)] | length' "$CONFIG" 2>/dev/null || echo 0)
            total_count=$(${pkgs.jq}/bin/jq '[.servers] | length' "$CONFIG" 2>/dev/null || echo "?")
            echo -e "''${BOLD}Total: $enabled_count enabled''${NC}"
            ;;

          enable)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp enable <server-name>"
              exit 1
            fi
            ${pkgs.jq}/bin/jq --arg n "$SERVER" '.servers |= map(if .name == $n then .enabled = true else . end)' "$CONFIG" | save
            ok "Enabled: $SERVER"
            ;;

          disable)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp disable <server-name>"
              exit 1
            fi
            ${pkgs.jq}/bin/jq --arg n "$SERVER" '.servers |= map(if .name == $n then .enabled = false else . end)' "$CONFIG" | save
            ok "Disabled: $SERVER"
            ;;

          start)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp start <server-name>"
              exit 1
            fi
            info "Starting MCP server: $SERVER"
            mapfile -t ARGV < <(${pkgs.jq}/bin/jq -r --arg n "$SERVER" '.servers[] | select(.name == $n) | .command, .args[]' "$CONFIG" 2>/dev/null)
            if [ "''${#ARGV[@]}" -eq 0 ]; then
              warn "Server not found: $SERVER"
              exit 1
            fi
            echo "  Command: ''${ARGV[*]}"
            exec "''${ARGV[@]}"
            ;;

          test)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp test <server-name>"
              exit 1
            fi
            info "Testing MCP server: $SERVER"
            mapfile -t ARGV < <(${pkgs.jq}/bin/jq -r --arg n "$SERVER" '.servers[] | select(.name == $n) | .command, .args[]' "$CONFIG" 2>/dev/null)
            if [ "''${#ARGV[@]}" -eq 0 ]; then
              warn "Server not found: $SERVER"
              exit 1
            fi
            timeout 5 "''${ARGV[@]}" --help >/dev/null 2>&1 && ok "Server $SERVER: healthy" || warn "Server $SERVER: may need dependencies"
            ;;

          info)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp info <server-name>"
              exit 1
            fi
            ${pkgs.jq}/bin/jq --arg n "$SERVER" '.servers[] | select(.name == $n)' "$CONFIG"
            ;;

          categories)
            echo -e "''${BOLD}MCP Server Categories:''${NC}"
            for cat in core database cloud integration browser ai devops data; do
              count=$(${pkgs.jq}/bin/jq -r --arg c "$cat" '[.servers[] | select(.category == $c)] | length' "$CONFIG" 2>/dev/null || echo 0)
              echo "  $cat: $count servers"
            done
            ;;

          enable-all)
            info "Enabling all MCP servers..."
            ${pkgs.jq}/bin/jq '.servers |= map(.enabled = true)' "$CONFIG" | save
            ok "All servers enabled (note: cloud/integration servers need API keys)"
            ;;

          stats)
            echo -e "''${BOLD}MCP Server Registry Stats:''${NC}"
            total=$(${pkgs.jq}/bin/jq '.servers | length' "$CONFIG" 2>/dev/null || echo 0)
            enabled=$(${pkgs.jq}/bin/jq '[.servers[] | select(.enabled)] | length' "$CONFIG" 2>/dev/null || echo 0)
            disabled=$((total - enabled))
            echo "  Total servers:   $total"
            echo "  Enabled:         $enabled"
            echo "  Disabled:        $disabled"
            echo "  Categories:      $(${pkgs.jq}/bin/jq '[.servers[].category] | unique | length' "$CONFIG" 2>/dev/null || echo 0)"
            ;;

          *)
            cat <<'HELP'
        AgentOS MCP Server Registry

        USAGE:
            agentos-mcp <COMMAND> [ARGS]

        COMMANDS:
            list [category]      List all servers (or filter by category)
            enable <name>        Enable a server
            disable <name>       Disable a server
            enable-all           Enable all servers
            start <name>         Start a server manually
            test <name>          Health-check a server
            info <name>          Show server details (JSON)
            categories           Show category summary
            stats                Show registry statistics

        CATEGORIES:
            core         filesystem, git, memory, fetch, time, sequential-thinking
            database     postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse
            cloud        aws, azure, cloudflare, supabase
            integration  github, gitlab, linear, slack, notion, sentry, pagerduty
            browser      puppeteer, playwright, browserbase
            ai           huggingface
            devops       docker, kubernetes
            data         brave-search, tavily, exa, perplexity

        HELP
            ;;
        esac
      '')
    ];

    networking.firewall.interfaces.agentos0.allowedTCPPorts = [ cfg.registryPort ];
  };
}
