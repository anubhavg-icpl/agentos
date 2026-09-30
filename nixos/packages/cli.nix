# AgentOS CLI — user-facing command for managing agents
#
# Commands:
#   agentos list                  List running agents
#   agentos spawn <agent>         Start a new agent in a sandboxed workspace
#   agentos kill <id>             Stop a running agent
#   agentos logs <id>             Tail agent logs
#   agentos status                Show system status
#   agentos budget                Show token/cost usage
#   agentos agents                List all pre-installed agents
#   agentos install <pkg>         Install an agent or tool
#   agentos workspace create      Create a new workspace
#   agentos workspace list        List workspaces
#   agentos snapshot              Snapshot current state
#   agentos rollback <snap>       Rollback to a snapshot
#   agentos shell <id>            Attach to an agent's shell
{ writeShellScriptBin, jq, btrfs-progs }:

writeShellScriptBin "agentos" ''
  #!/usr/bin/env bash
  set -euo pipefail

  # ── Colors ─────────────────────────────────────────────────────────
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'

  info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
  ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
  warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
  err()   { echo -e "''${RED}[ERR]''${NC} $*" >&2; }

  # ── Config ─────────────────────────────────────────────────────────
  WORKSPACE_ROOT="/var/lib/agentos/workspaces"
  STATE_DIR="/var/lib/agentos/state"

  # ── Commands ───────────────────────────────────────────────────────
  cmd_help() {
    cat <<'HELP'
  AgentOS — An OS for coding agents

  USAGE:
      agentos <COMMAND> [OPTIONS]

  COMMANDS:
      list                  List running agents
      spawn <agent>         Start a new agent (e.g. agentos spawn claude-code)
      kill <id>             Stop a running agent
      logs <id>             Tail agent logs
      shell <id>            Attach to agent's shell
      status                Show system status

      agents                List all pre-installed agents
      install <pkg>         Install a package (nix profile install)
      search <query>        Search for available packages

      workspace create [name]   Create a new workspace
      workspace list            List workspaces
      workspace rm <name>       Remove a workspace

      snapshot [name]       Create a snapshot
      snapshots             List snapshots
      rollback <snap>       Rollback to a snapshot

      budget                Show token/cost usage
      models                List available LLM models

      help                  Show this help
      version               Show version

  EXAMPLES:
      agentos spawn claude-code --workspace ./myproject
      agentos spawn aider -- --model sonnet
      agentos budget
  HELP
  }

  cmd_version() {
    echo "AgentOS v0.1.0"
    echo "An operating system for coding agents"
  }

  cmd_agents() {
    cat <<'AGENTS'
  ╔══════════════════════════════════════════════════════════════════╗
  ║                    PRE-INSTALLED AGENTS                          ║
  ╠══════════════════════════════════════════════════════════════════╣
  ║                                                                  ║
  ║  NIX-PACKAGED (reproducible, pinned by flake.lock)               ║
  ║                                                                  ║
  ║  claude            Anthropic Claude Code                         ║
  ║  codex             OpenAI Codex CLI                              ║
  ║  aider             AI pair programmer (terminal)                 ║
  ║  gemini            Google Gemini CLI                             ║
  ║  qwen              Alibaba Qwen Code (also: qwen-code)           ║
  ║  amp               Sourcegraph Amp                               ║
  ║  goose             Block Goose                                   ║
  ║  opencode          OpenCode (SST)                                ║
  ║  crush             Charm Crush                                   ║
  ║  cursor-agent      Cursor CLI (also: cursor)                     ║
  ║  copilot           GitHub Copilot CLI                            ║
  ║  interpreter       Open Interpreter                              ║
  ║                                                                  ║
  ║  NPM LAUNCHERS (pinned version, fetched on first run)            ║
  ║                                                                  ║
  ║  droid             Factory Droid                                 ║
  ║  cline             Cline                                         ║
  ║  cn                Continue CLI (also: continue)                 ║
  ║                                                                  ║
  ╚══════════════════════════════════════════════════════════════════╝

  To start an agent:
      agentos spawn <name>       (on a fresh agent/* git branch)
      <name>                     (direct)
  AGENTS
  }

  cmd_spawn() {
    local agent="''${1:-}"
    shift || true
    local workspace
    workspace="$(pwd)"
    local model=""
    local extra_args=()

    # AgentOS flags are consumed here; everything else goes to the agent
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --workspace) workspace="$2"; shift 2 ;;
        --model) model="$2"; shift 2 ;;
        --) shift; extra_args+=("$@"); break ;;
        *) extra_args+=("$1"); shift ;;
      esac
    done

    if [ -z "$agent" ]; then
      err "Usage: agentos spawn <agent-name> [--workspace ./path] [--model name] [agent args...]"
      echo ""
      echo "Run 'agentos agents' to see available agents"
      exit 1
    fi

    # Map agent names to commands
    local cmd=""
    case "$agent" in
      claude|claude-code)          cmd="claude" ;;
      codex)                       cmd="codex" ;;
      aider)                       cmd="aider" ;;
      gemini|gemini-cli)           cmd="gemini" ;;
      qwen|qwen-code)              cmd="qwen" ;;
      amp)                         cmd="amp" ;;
      goose)                       cmd="goose" ;;
      opencode)                    cmd="opencode" ;;
      crush)                       cmd="crush" ;;
      cursor|cursor-agent|cursor-cli) cmd="cursor-agent" ;;
      copilot|github-copilot)      cmd="copilot" ;;
      interpreter|open-interpreter) cmd="interpreter" ;;
      droid|factory-droid)         cmd="droid" ;;
      cline)                       cmd="cline" ;;
      cn|continue)                 cmd="cn" ;;
      *)
        err "Unknown agent: $agent"
        echo "Run 'agentos agents' to see available agents"
        exit 1
        ;;
    esac

    local agent_id
    agent_id="agent-$(date +%s)-$$"

    info "Spawning agent: $agent"
    info "Workspace: $workspace"
    info "Agent ID: $agent_id"

    cd "$workspace"

    # Initialize git if not already
    if [ ! -d .git ]; then
      git init --quiet
      info "Initialized git repo in workspace"
    fi

    # Create agent branch
    local branch="agent/$agent-$(date +%s)"
    git checkout -b "$branch" --quiet 2>/dev/null || true

    ok "Starting $cmd in workspace"

    # Set environment for agent
    export AGENTOS_AGENT_ID="$agent_id"
    export AGENTOS_WORKSPACE="$workspace"
    export AGENTOS_BRANCH="$branch"
    if [ -n "$model" ]; then
      export AGENTOS_MODEL="$model"
    fi

    # Execute the agent
    exec "$cmd" ''${extra_args[@]+"''${extra_args[@]}"}
  }

  cmd_list() {
    info "Running agents:"
    if [ -d "$STATE_DIR" ]; then
      for f in "$STATE_DIR"/agent-*.json; do
        [ -f "$f" ] || continue
        ${jq}/bin/jq -r '"  \(.id)  \(.agent)  \(.status)  \(.workspace)"' "$f" 2>/dev/null || echo "  (corrupt state: $f)"
      done
    else
      echo "  (no agents running)"
    fi
  }

  cmd_kill() {
    local id="''${1:-}"
    if [ -z "$id" ]; then
      err "Usage: agentos kill <agent-id>"
      exit 1
    fi
    info "Killing agent: $id"
    # Send signal to agent process
    local pidfile="$STATE_DIR/$id.pid"
    if [ -f "$pidfile" ]; then
      kill "$(cat "$pidfile")" 2>/dev/null || true
      rm -f "$pidfile"
      ok "Agent $id stopped"
    else
      err "Agent not found: $id"
    fi
  }

  cmd_logs() {
    local id="''${1:-}"
    if [ -z "$id" ]; then
      err "Usage: agentos logs <agent-id>"
      exit 1
    fi
    local logfile="/var/lib/agentos/logs/$id.log"
    if [ -f "$logfile" ]; then
      tail -f "$logfile"
    else
      err "No logs for agent: $id"
    fi
  }

  cmd_shell() {
    local id="''${1:-}"
    if [ -z "$id" ]; then
      err "Usage: agentos shell <agent-id>"
      exit 1
    fi
    info "Attaching to agent shell: $id"
    local pidfile="$STATE_DIR/$id.pid"
    if [ -f "$pidfile" ]; then
      local pid=$(cat "$pidfile")
      # Use nsenter to join the agent container namespace
      warn "Shell attach uses container namespace"
      nsenter -t "$pid" -m -u -i -n -p -- bash || err "Could not attach to agent $id"
    else
      err "Agent not found: $id"
    fi
  }

  cmd_status() {
    echo -e "''${BOLD}AgentOS System Status''${NC}"
    echo ""

    # CPU
    local cpu_count=$(nproc 2>/dev/null || echo "?")
    local load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}' || echo "?")
    echo "  CPU cores:    $cpu_count"
    echo "  Load:         $load"

    # Memory
    local meminfo=$(cat /proc/meminfo 2>/dev/null)
    local mem_total=$(echo "$meminfo" | grep MemTotal | awk '{print int($2/1024)}')
    local mem_avail=$(echo "$meminfo" | grep MemAvailable | awk '{print int($2/1024)}')
    echo "  Memory:       ''${mem_avail}MB available / ''${mem_total}MB total"

    # Disk
    local disk=$(df -h / 2>/dev/null | tail -1 | awk '{print $4 " available / " $2 " total"}')
    echo "  Disk:         $disk"

    # Agents
    local agent_count=$(ls "$STATE_DIR"/agent-*.json 2>/dev/null | wc -l || echo "0")
    echo "  Agents:       $agent_count running"

    # Workspaces
    local ws_count=$(ls -d "$WORKSPACE_ROOT"/* 2>/dev/null | wc -l || echo "0")
    echo "  Workspaces:   $ws_count"

    echo ""
    info "Services:"
    systemctl is-active agentos-daemon >/dev/null 2>&1 && ok "  agentos-daemon: running" || warn "  agentos-daemon: stopped"
    systemctl is-active agentos-mcp-gateway >/dev/null 2>&1 && ok "  mcp-gateway: running" || warn "  mcp-gateway: stopped"
    systemctl is-active agentos-model-gateway >/dev/null 2>&1 && ok "  model-gateway: running" || warn "  model-gateway: stopped"
  }

  cmd_budget() {
    info "Token/cost budget:"
    local budget_file="$STATE_DIR/budget.json"
    if [ -f "$budget_file" ]; then
      ${jq}/bin/jq '.' "$budget_file" 2>/dev/null || cat "$budget_file"
    else
      echo "  No budget data yet"
      echo "  (Budget tracking starts when agents make LLM calls)"
    fi
  }

  cmd_workspace() {
    local subcmd="''${1:-}"
    case "$subcmd" in
      create)
        local name="''${2:-workspace-$(date +%s)}"
        local path="$WORKSPACE_ROOT/$name"
        mkdir -p "$path"
        cd "$path"
        git init --quiet
        echo "# Workspace: $name" > README.md
        mkdir -p .agentos
        cat > .agentos/config.toml <<'CONF'
  [workspace]
  persistent = false

  [permissions]
  file_read = true
  file_write = true
  shell_exec = true
  network_egress = "limited"

  [budget]
  max_daily_usd = 20.0

  [git]
  auto_commit = true
  auto_branch = true
  CONF
        ok "Created workspace: $path"
        ;;
      list)
        info "Workspaces:"
        ls -1 "$WORKSPACE_ROOT" 2>/dev/null || echo "  (none)"
        ;;
      rm)
        local name="''${2:-}"
        if [ -z "$name" ]; then
          err "Usage: agentos workspace rm <name>"
          exit 1
        fi
        case "$name" in
          */*|.|..) err "Invalid workspace name: $name"; exit 1 ;;
        esac
        rm -rf "''${WORKSPACE_ROOT:?}/$name"
        ok "Removed workspace: $name"
        ;;
      *)
        err "Usage: agentos workspace <create|list|rm>"
        exit 1
        ;;
    esac
  }

  cmd_install() {
    local pkg="''${1:-}"
    if [ -z "$pkg" ]; then
      err "Usage: agentos install <package>"
      echo ""
      echo "Examples:"
      echo "  agentos install python311"
      echo "  agentos install go_1_23"
      echo "  agentos install rustc"
      exit 1
    fi
    info "Installing: $pkg"
    nix profile install "nixpkgs#$pkg"
    ok "Installed: $pkg"
  }

  cmd_search() {
    local query="''${1:-}"
    if [ -z "$query" ]; then
      err "Usage: agentos search <query>"
      exit 1
    fi
    nix search "nixpkgs#$query" 2>/dev/null || err "Search failed"
  }

  cmd_snapshot() {
    local name="''${1:-snap-$(date +%Y%m%d-%H%M%S)}"
    info "Creating snapshot: $name"
    if command -v btrfs &>/dev/null; then
      ${btrfs-progs}/bin/btrfs subvolume snapshot -r "$WORKSPACE_ROOT" "/var/lib/agentos/snapshots/$name" 2>/dev/null && \
        ok "Snapshot created: $name" || warn "btrfs snapshot failed"
    else
      warn "btrfs not available, using rsync fallback"
      rsync -a "$WORKSPACE_ROOT/" "/var/lib/agentos/snapshots/$name/"
      ok "Snapshot created (rsync): $name"
    fi
  }

  cmd_snapshots() {
    info "Snapshots:"
    ls -1 /var/lib/agentos/snapshots 2>/dev/null || echo "  (none)"
  }

  cmd_rollback() {
    local snap="''${1:-}"
    if [ -z "$snap" ]; then
      err "Usage: agentos rollback <snapshot>"
      exit 1
    fi
    warn "Rolling back to: $snap"
    warn "This will discard all changes since the snapshot!"
    read -rp "Continue? [y/N] " confirm
    [ "$confirm" = "y" ] || exit 0
    # Implementation depends on btrfs or rsync
    err "Rollback not yet implemented for this snapshot type"
  }

  # ── Main ───────────────────────────────────────────────────────────
  main() {
    local cmd="''${1:-help}"
    shift || true

    case "$cmd" in
      list|ls)         cmd_list "$@" ;;
      spawn|run)       cmd_spawn "$@" ;;
      kill|stop)       cmd_kill "$@" ;;
      logs)            cmd_logs "$@" ;;
      shell)           cmd_shell "$@" ;;
      status|st)       cmd_status ;;
      budget)          cmd_budget ;;
      agents)          cmd_agents ;;
      install|i)       cmd_install "$@" ;;
      search)          cmd_search "$@" ;;
      workspace|ws)    cmd_workspace "$@" ;;
      snapshot)        cmd_snapshot "$@" ;;
      snapshots)       cmd_snapshots ;;
      rollback)        cmd_rollback "$@" ;;
      version|--version|-v) cmd_version ;;
      help|--help|-h)  cmd_help ;;
      *)
        err "Unknown command: $cmd"
        echo ""
        cmd_help
        exit 1
        ;;
    esac
  }

  main "$@"
''
