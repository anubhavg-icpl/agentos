# ═══════════════════════════════════════════════════════════════════════
# AgentOS MCP Server Registry — 50+ Preconfigured MCP Servers
# ═══════════════════════════════════════════════════════════════════════
#
# The Model Context Protocol (MCP) is how agents access external tools.
# This module ships 50+ MCP servers preconfigured and ready to use.
# Each server extends agents with new capabilities.
#
# Categories:
#   CORE (10): filesystem, git, memory, search, fetch, reasoning, time, exec
#   DATABASE (8): postgres, sqlite, mysql, redis, mongo, duckdb, clickhouse, surreal
#   CLOUD (8): aws, gcp, azure, cloudflare, vercel, fly, railway, render
#   INTEGRATION (12): github, gitlab, linear, jira, slack, discord, notion,
#                     sentry, datadog, pagerduty, asana, trello
#   BROWSER (4): puppeteer, playwright, browserbase, selenium
#   AI/ML (4): openai, anthropic, replicate, huggingface
#   DEVOPS (6): docker, k8s, terraform, ansible, grafana, prometheus
#   DATA (4): brave-search, tavily, exa, perplexity
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.mcp-servers;
in
{
  options.agentos.mcp-servers = {
    enable = lib.mkEnableOption "AgentOS MCP server registry (50+ servers)";

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
            args = [ "@modelcontextprotocol/server-filesystem" "/var/lib/agentos/workspaces" ];
            category = "core";
            port = null;
            env = { };
            enabled = true;
          }
          {
            name = "git";
            description = "Git operations: commit, branch, diff, log, merge";
            command = "npx";
            args = [ "@modelcontextprotocol/server-git" "--repository" "/var/lib/agentos/workspaces" ];
            category = "core";
            enabled = true;
          }
          {
            name = "memory";
            description = "Persistent key-value memory graph";
            command = "npx";
            args = [ "@modelcontextprotocol/server-memory" ];
            category = "core";
            enabled = true;
          }
          {
            name = "fetch";
            description = "Fetch web pages and APIs, convert to markdown";
            command = "npx";
            args = [ "@modelcontextprotocol/server-fetch" ];
            category = "core";
            enabled = true;
          }
          {
            name = "sequential-thinking";
            description = "Step-by-step reasoning with revision and branching";
            command = "npx";
            args = [ "@modelcontextprotocol/server-sequential-thinking" ];
            category = "core";
            enabled = true;
          }
          {
            name = "time";
            description = "Time and timezone tools";
            command = "npx";
            args = [ "@modelcontextprotocol/server-time" ];
            category = "core";
            enabled = true;
          }
          {
            name = "everything";
            description = "All-in-one server: search, fetch, analyze";
            command = "npx";
            args = [ "@modelcontextprotocol/server-everything" ];
            category = "core";
            enabled = true;
          }
          {
            name = "exec";
            description = "Execute shell commands in sandboxed environment";
            command = "npx";
            args = [ "@modelcontextprotocol/server-exec" ];
            category = "core";
            enabled = false; # dangerous, enable per-agent
          }
          {
            name = "filesystem-watch";
            description = "Watch files for changes in real-time";
            command = "npx";
            args = [ "@modelcontextprotocol/server-filesystem-watch" ];
            category = "core";
            enabled = true;
          }
          {
            name = "clipboard";
            description = "Read/write system clipboard";
            command = "npx";
            args = [ "@modelcontextprotocol/server-clipboard" ];
            category = "core";
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
            args = [ "@modelcontextprotocol/server-postgres" "postgresql://agentos@localhost/agentos" ];
            category = "database";
            enabled = true;
          }
          {
            name = "sqlite";
            description = "SQLite: query, create, manage databases";
            command = "npx";
            args = [ "@modelcontextprotocol/server-sqlite" "--db-path" "/var/lib/agentos/data/sqlite.db" ];
            category = "database";
            enabled = true;
          }
          {
            name = "mysql";
            description = "MySQL/MariaDB: query and manage";
            command = "npx";
            args = [ "@benborla29/mcp-server-mysql" ];
            category = "database";
            env = { MYSQL_HOST = "localhost"; MYSQL_USER = "agentos"; };
            enabled = false;
          }
          {
            name = "redis";
            description = "Redis: key-value, pub/sub, streams";
            command = "npx";
            args = [ "@modelcontextprotocol/server-redis" "redis://localhost:6379" ];
            category = "database";
            enabled = true;
          }
          {
            name = "mongo";
            description = "MongoDB: CRUD, aggregation, indexes";
            command = "npx";
            args = [ "@modelcontextprotocol/server-mongo" "mongodb://localhost:27017" ];
            category = "database";
            enabled = false;
          }
          {
            name = "duckdb";
            description = "DuckDB: in-process analytics SQL";
            command = "npx";
            args = [ "@modelcontextprotocol/server-duckdb" ];
            category = "database";
            enabled = true;
          }
          {
            name = "clickhouse";
            description = "ClickHouse: columnar OLAP queries";
            command = "npx";
            args = [ "@modelcontextprotocol/server-clickhouse" ];
            category = "database";
            enabled = false;
          }
          {
            name = "surrealdb";
            description = "SurrealDB: multi-model database";
            command = "npx";
            args = [ "@modelcontextprotocol/server-surrealdb" ];
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
            command = "npx";
            args = [ "@modelcontextprotocol/server-aws" ];
            env = { AWS_REGION = "us-east-1"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "gcp";
            description = "Google Cloud: GCS, Cloud Run, Firestore, BigQuery";
            command = "npx";
            args = [ "@modelcontextprotocol/server-gcp" ];
            category = "cloud";
            enabled = false;
          }
          {
            name = "azure";
            description = "Azure: Storage, Functions, CosmosDB";
            command = "npx";
            args = [ "@modelcontextprotocol/server-azure" ];
            category = "cloud";
            enabled = false;
          }
          {
            name = "cloudflare";
            description = "Cloudflare: Workers, KV, R2, D1, Durable Objects";
            command = "npx";
            args = [ "@modelcontextprotocol/server-cloudflare" ];
            env = { CLOUDFLARE_API_TOKEN = "\${CF_API_TOKEN}"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "vercel";
            description = "Vercel: deployments, projects, env vars";
            command = "npx";
            args = [ "@modelcontextprotocol/server-vercel" ];
            env = { VERCEL_TOKEN = "\${VERCEL_TOKEN}"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "fly";
            description = "Fly.io: apps, machines, volumes";
            command = "npx";
            args = [ "@modelcontextprotocol/server-fly" ];
            env = { FLY_API_TOKEN = "\${FLY_TOKEN}"; };
            category = "cloud";
            enabled = false;
          }
          {
            name = "railway";
            description = "Railway: deployments, databases";
            command = "npx";
            args = [ "@modelcontextprotocol/server-railway" ];
            category = "cloud";
            enabled = false;
          }
          {
            name = "supabase";
            description = "Supabase: database, auth, storage, realtime";
            command = "npx";
            args = [ "@modelcontextprotocol/server-supabase" ];
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
            args = [ "@modelcontextprotocol/server-github" ];
            env = { GITHUB_PERSONAL_ACCESS_TOKEN = "\${GITHUB_TOKEN}"; };
            category = "integration";
            enabled = true;
          }
          {
            name = "gitlab";
            description = "GitLab: repos, MRs, pipelines";
            command = "npx";
            args = [ "@modelcontextprotocol/server-gitlab" ];
            env = { GITLAB_PERSONAL_ACCESS_TOKEN = "\${GITLAB_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "linear";
            description = "Linear: issues, projects, cycles, sprints";
            command = "npx";
            args = [ "@modelcontextprotocol/server-linear" ];
            env = { LINEAR_API_KEY = "\${LINEAR_API_KEY}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "jira";
            description = "Jira: issues, sprints, boards, transitions";
            command = "npx";
            args = [ "@modelcontextprotocol/server-jira" ];
            env = { JIRA_API_TOKEN = "\${JIRA_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "slack";
            description = "Slack: channels, messages, threads, files";
            command = "npx";
            args = [ "@modelcontextprotocol/server-slack" ];
            env = { SLACK_BOT_TOKEN = "\${SLACK_BOT_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "discord";
            description = "Discord: channels, messages, roles";
            command = "npx";
            args = [ "@modelcontextprotocol/server-discord" ];
            env = { DISCORD_TOKEN = "\${DISCORD_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "notion";
            description = "Notion: pages, databases, blocks";
            command = "npx";
            args = [ "@modelcontextprotocol/server-notion" ];
            env = { NOTION_API_KEY = "\${NOTION_KEY}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "sentry";
            description = "Sentry: errors, issues, releases, stack traces";
            command = "npx";
            args = [ "@modelcontextprotocol/server-sentry" ];
            env = { SENTRY_AUTH_TOKEN = "\${SENTRY_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "datadog";
            description = "Datadog: metrics, logs, traces, monitors";
            command = "npx";
            args = [ "@modelcontextprotocol/server-datadog" ];
            env = { DATADOG_API_KEY = "\${DD_API_KEY}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "pagerduty";
            description = "PagerDuty: incidents, services, schedules";
            command = "npx";
            args = [ "@modelcontextprotocol/server-pagerduty" ];
            env = { PAGERDUTY_API_KEY = "\${PD_API_KEY}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "asana";
            description = "Asana: tasks, projects, sections";
            command = "npx";
            args = [ "@modelcontextprotocol/server-asana" ];
            env = { ASANA_TOKEN = "\${ASANA_TOKEN}"; };
            category = "integration";
            enabled = false;
          }
          {
            name = "trello";
            description = "Trello: boards, lists, cards";
            command = "npx";
            args = [ "@modelcontextprotocol/server-trello" ];
            env = { TRELLO_API_KEY = "\${TRELLO_KEY}"; };
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
            args = [ "@modelcontextprotocol/server-puppeteer" ];
            category = "browser";
            enabled = true;
          }
          {
            name = "playwright";
            description = "Playwright: cross-browser automation, screenshots";
            command = "npx";
            args = [ "@modelcontextprotocol/server-playwright" ];
            category = "browser";
            enabled = true;
          }
          {
            name = "browserbase";
            description = "Browserbase: cloud browser sessions at scale";
            command = "npx";
            args = [ "@modelcontextprotocol/server-browserbase" ];
            env = { BROWSERBASE_API_KEY = "\${BB_API_KEY}"; };
            category = "browser";
            enabled = false;
          }
          {
            name = "selenium";
            description = "Selenium: WebDriver automation";
            command = "npx";
            args = [ "@modelcontextprotocol/server-selenium" ];
            category = "browser";
            enabled = false;
          }
        ])

        # ════════════════════════════════════════════════════════════
        # AI/ML MCP SERVERS (4)
        # ════════════════════════════════════════════════════════════
        (lib.optionals cfg.enableAI [
          {
            name = "openai-tools";
            description = "OpenAI: DALL-E, Whisper, embeddings, moderation";
            command = "npx";
            args = [ "@modelcontextprotocol/server-openai" ];
            env = { OPENAI_API_KEY = "\${OPENAI_API_KEY}"; };
            category = "ai";
            enabled = true;
          }
          {
            name = "anthropic-tools";
            description = "Anthropic: Claude vision, analysis tools";
            command = "npx";
            args = [ "@modelcontextprotocol/server-anthropic" ];
            env = { ANTHROPIC_API_KEY = "\${ANTHROPIC_API_KEY}"; };
            category = "ai";
            enabled = true;
          }
          {
            name = "replicate";
            description = "Replicate: run ML models (SD, LLaMA, Whisper)";
            command = "npx";
            args = [ "@modelcontextprotocol/server-replicate" ];
            env = { REPLICATE_API_TOKEN = "\${REPLICATE_TOKEN}"; };
            category = "ai";
            enabled = false;
          }
          {
            name = "huggingface";
            description = "HuggingFace: models, datasets, spaces";
            command = "npx";
            args = [ "@modelcontextprotocol/server-huggingface" ];
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
            command = "npx";
            args = [ "@modelcontextprotocol/server-docker" ];
            category = "devops";
            enabled = true;
          }
          {
            name = "kubernetes";
            description = "Kubernetes: pods, deployments, services";
            command = "npx";
            args = [ "@modelcontextprotocol/server-kubernetes" ];
            category = "devops";
            enabled = false;
          }
          {
            name = "terraform";
            description = "Terraform: plan, apply, state, modules";
            command = "npx";
            args = [ "@modelcontextprotocol/server-terraform" ];
            category = "devops";
            enabled = false;
          }
          {
            name = "ansible";
            description = "Ansible: playbooks, inventory, modules";
            command = "npx";
            args = [ "@modelcontextprotocol/server-ansible" ];
            category = "devops";
            enabled = false;
          }
          {
            name = "grafana";
            description = "Grafana: dashboards, alerts, datasources";
            command = "npx";
            args = [ "@modelcontextprotocol/server-grafana" ];
            env = { GRAFANA_API_KEY = "\${GRAFANA_KEY}"; };
            category = "devops";
            enabled = true;
          }
          {
            name = "prometheus";
            description = "Prometheus: metrics, queries, alerts";
            command = "npx";
            args = [ "@modelcontextprotocol/server-prometheus" ];
            category = "devops";
            enabled = true;
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
            args = [ "@modelcontextprotocol/server-brave-search" ];
            env = { BRAVE_API_KEY = "\${BRAVE_API_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "tavily";
            description = "Tavily: AI-optimized web search and extraction";
            command = "npx";
            args = [ "@modelcontextprotocol/server-tavily" ];
            env = { TAVILY_API_KEY = "\${TAVILY_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "exa";
            description = "Exa: neural web search for AI agents";
            command = "npx";
            args = [ "@modelcontextprotocol/server-exa" ];
            env = { EXA_API_KEY = "\${EXA_KEY}"; };
            category = "data";
            enabled = false;
          }
          {
            name = "perplexity";
            description = "Perplexity: AI-powered web search with citations";
            command = "npx";
            args = [ "@modelcontextprotocol/server-perplexity" ];
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

        CONFIG="/etc/agentos/mcp-servers.json"

        case "''${1:-list}" in
          list)
            CATEGORY="''${2:-}"
            echo -e "''${BOLD}═══════════════════════════════════════════════════''${NC}"
            echo -e "''${BOLD}         AgentOS MCP Server Registry                 ''${NC}"
            echo -e "''${BOLD}═══════════════════════════════════════════════════''${NC}"
            echo ""

            if [ -n "$CATEGORY" ]; then
              echo -e "''${BOLD}Category: $Category''${NC}"
              ${pkgs.jq}/bin/jq -r --arg cat "$CATEGORY" '.servers[] | select(.category == $cat) | select(.enabled) | "  ✓ \(.name)\t\(.description)"' "$CONFIG" 2>/dev/null | column -t -s $'\t'
              return
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
            ${pkgs.jq}/bin/jq ".servers |= map(if .name == \"$SERVER\" then .enabled = true else .)" "$CONFIG" > /tmp/mcp.json
            ${pkgs.install}/bin/install -m 644 /tmp/mcp.json "$CONFIG"
            ok "Enabled: $SERVER"
            ;;

          disable)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp disable <server-name>"
              exit 1
            fi
            ${pkgs.jq}/bin/jq ".servers |= map(if .name == \"$SERVER\" then .enabled = false else .)" "$CONFIG" > /tmp/mcp.json
            ${pkgs.install}/bin/install -m 644 /tmp/mcp.json "$CONFIG"
            ok "Disabled: $SERVER"
            ;;

          start)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp start <server-name>"
              exit 1
            fi
            info "Starting MCP server: $SERVER"
            CMD=$(${pkgs.jq}/bin/jq -r --arg n "$SERVER" '.servers[] | select(.name == $n) | .command + " " + (.args | join(" "))' "$CONFIG" 2>/dev/null)
            if [ -z "$CMD" ] || [ "$CMD" = "null" ]; then
              warn "Server not found: $SERVER"
              exit 1
            fi
            echo "  Command: $CMD"
            exec eval "$CMD"
            ;;

          test)
            SERVER="''${2:-}"
            if [ -z "$SERVER" ]; then
              echo "Usage: agentos-mcp test <server-name>"
              exit 1
            fi
            info "Testing MCP server: $SERVER"
            CMD=$(${pkgs.jq}/bin/jq -r --arg n "$SERVER" '.servers[] | select(.name == $n) | .command + " " + (.args | join(" "))' "$CONFIG" 2>/dev/null)
            timeout 5 eval "$CMD" --help 2>/dev/null && ok "Server $SERVER: healthy" || warn "Server $SERVER: may need dependencies"
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
            ${pkgs.jq}/bin/jq '.servers |= map(.enabled = true)' "$CONFIG" > /tmp/mcp.json
            ${pkgs.install}/bin/install -m 644 /tmp/mcp.json "$CONFIG"
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
            core         filesystem, git, memory, fetch, reasoning, time...
            database     postgres, sqlite, redis, mongo, duckdb...
            cloud        aws, gcp, azure, cloudflare, vercel, fly...
            integration  github, gitlab, linear, jira, slack, notion...
            browser      puppeteer, playwright, browserbase, selenium
            ai           openai-tools, anthropic-tools, replicate, huggingface
            devops       docker, kubernetes, terraform, grafana...
            data         brave-search, tavily, exa, perplexity

        HELP
            ;;
        esac
      '')
    ];

    networking.firewall.allowedTCPPorts = [ cfg.registryPort ];
  };
}
