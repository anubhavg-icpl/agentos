# agentos-task: submit and follow orchestrator tasks
#
# Talks to the orchestrator over its unix socket (group agentos), which
# validates every task; this script only builds requests. Task output is
# read from the log files the task runner writes.
{ writeShellApplication
, coreutils
, curl
, gnugrep
, jq
, util-linux
}:

writeShellApplication {
  name = "agentos-task";
  runtimeInputs = [ coreutils curl gnugrep jq util-linux ];

  text = ''
    SOCKET="''${AGENTOS_ORCH_SOCKET:-/run/agentos-orchestrator/orchestrator.sock}"
    TASKS_DIR="''${AGENTOS_TASKS_DIR:-/var/lib/agentos/tasks}"

    if [ -t 2 ]; then
      RED='\033[0;31m' GREEN='\033[0;32m' BLUE='\033[0;34m' NC='\033[0m'
    else
      RED="" GREEN="" BLUE="" NC=""
    fi
    info() { echo -e "''${BLUE}[INFO]''${NC} $*" >&2; }
    ok()   { echo -e "''${GREEN}[OK]''${NC} $*" >&2; }
    die()  { echo -e "''${RED}[ERR]''${NC} $*" >&2; exit 1; }

    usage() {
      cat <<'EOF'
    agentos-task: run coding agents headless through the AgentOS orchestrator

    USAGE
      agentos-task submit --agent <name> [--workspace <name|path>] (--prompt <text> | --prompt-file <file>)
                          [--budget <usd>] [--timeout <sec>] [--after <task-id>]... [--swarm <n>]
                          [--group <name>] [--isolate] [--wait] [--json]
      agentos-task list [--status <s>] [--group <name>] [--json]
      agentos-task show <task-id|group> [--json]
      agentos-task logs <task-id> [-f]
      agentos-task cancel <task-id|group>

    NOTES
      --after <id>   start when that task has succeeded; the prompt may use {prev_result}
                     (its output) and the tasks run one after another in the workspace
      --swarm <n>    n agents, same prompt, in parallel; each in its own git worktree on its
                     own branch (agent/<task-id>)
      --budget       daily budget for each task's agent, in USD (enforced by the gateway)
      --wait         block until the task (or the whole swarm) has finished; exit 1 if any failed
    EOF
    }

    [ -S "$SOCKET" ] || die "orchestrator socket $SOCKET not found; is agentos.orchestration.enable set?"

    # api METHOD PATH [JSON] -> prints the body, fails on HTTP errors
    api() {
      local method="$1" path="$2" body="''${3:-}" out code
      out=$(mktemp)
      local args=(-sS -o "$out" -w '%{http_code}' --unix-socket "$SOCKET" -X "$method" -H 'Content-Type: application/json')
      if [ -n "$body" ]; then
        args+=(--data-binary "$body")
      fi
      code=$(curl "''${args[@]}" "http://orchestrator$path") || { rm -f "$out"; die "cannot reach the orchestrator (are you in the agentos group?)"; }
      if [ "''${code:0:1}" != "2" ]; then
        local msg
        msg=$(jq -r '.error // empty' "$out" 2>/dev/null || true)
        rm -f "$out"
        die "''${msg:-orchestrator returned HTTP $code}"
      fi
      cat "$out"
      rm -f "$out"
    }

    valid_id() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

    summary() {
      jq -r '
        (["ID", "STATUS", "AGENT", "WORKSPACE", "GROUP", "STARTED"] | @tsv),
        (.tasks[] | [ .id, .status, .agent, (.workspace | split("/") | last), (.group // "-"),
                      (if .started_at then (.started_at | floor | strftime("%m-%d %H:%M:%S")) else "-" end) ] | @tsv)' \
        | column -t -s "$(printf '\t')"
    }

    cmd_submit() {
      local agent="" workspace="$PWD" prompt="" have_prompt=0 budget="" timeout="" swarm="" group="" isolate=false wait=0 raw=0
      local after=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --agent) agent="''${2:?--agent needs a value}"; shift 2 ;;
          --workspace) workspace="''${2:?--workspace needs a value}"; shift 2 ;;
          --prompt) prompt="''${2:?--prompt needs a value}"; have_prompt=1; shift 2 ;;
          --prompt-file)
            [ -r "''${2:?--prompt-file needs a value}" ] || die "cannot read $2"
            prompt=$(cat "$2"); have_prompt=1; shift 2 ;;
          --budget) budget="''${2:?--budget needs a value}"; shift 2 ;;
          --timeout) timeout="''${2:?--timeout needs a value}"; shift 2 ;;
          --after) after+=("''${2:?--after needs a value}"); shift 2 ;;
          --swarm) swarm="''${2:?--swarm needs a value}"; shift 2 ;;
          --group) group="''${2:?--group needs a value}"; shift 2 ;;
          --isolate) isolate=true; shift ;;
          --wait) wait=1; shift ;;
          --json) raw=1; shift ;;
          *) die "unknown option: $1 (see: agentos-task help)" ;;
        esac
      done
      [ -n "$agent" ] || die "--agent is required"
      [ "$have_prompt" -eq 1 ] || die "--prompt or --prompt-file is required"

      local body
      body=$(jq -cn --arg agent "$agent" --arg workspace "$workspace" --arg prompt "$prompt" \
        --arg budget "$budget" --arg timeout "$timeout" --arg swarm "$swarm" --arg group "$group" \
        --argjson isolate "$isolate" --args '
        {agent: $agent, workspace: $workspace, prompt: $prompt, isolate: $isolate, depends_on: $ARGS.positional}
        + (if $budget != "" then {budget_usd: ($budget | tonumber)} else {} end)
        + (if $timeout != "" then {timeout_sec: ($timeout | tonumber)} else {} end)
        + (if $swarm != "" then {swarm: ($swarm | tonumber)} else {} end)
        + (if $group != "" then {group: $group} else {} end)' "''${after[@]}") \
        || die "invalid number in --budget, --timeout or --swarm"

      local resp
      resp=$(api POST /tasks "$body")
      if [ "$raw" -eq 1 ]; then
        echo "$resp"
      else
        jq -r '.tasks[].id' <<<"$resp"
        ok "queued $(jq '.tasks | length' <<<"$resp") task(s); follow with: agentos-task show $(jq -r '.group // .tasks[0].id' <<<"$resp")"
      fi
      if [ "$wait" -eq 1 ]; then
        wait_for "$(jq -r '.group // .tasks[0].id' <<<"$resp")"
      fi
    }

    # Poll until every task behind an id (task or group) has finished
    wait_for() {
      local id="$1" resp pending failed
      while true; do
        if resp=$(api GET "/groups/$id" 2>/dev/null); then
          :
        else
          resp=$(api GET "/tasks/$id" | jq -c '{tasks: [.]}')
        fi
        pending=$(jq '[.tasks[] | select(.status == "queued" or .status == "running")] | length' <<<"$resp")
        if [ "$pending" -eq 0 ]; then
          break
        fi
        sleep 2
      done
      failed=$(jq '[.tasks[] | select(.status != "succeeded")] | length' <<<"$resp")
      summary <<<"$resp"
      [ "$failed" -eq 0 ] || exit 1
    }

    cmd_list() {
      local query="" raw=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --status) query="$query&status=''${2:?--status needs a value}"; shift 2 ;;
          --group) query="$query&group=''${2:?--group needs a value}"; shift 2 ;;
          --json) raw=1; shift ;;
          *) die "unknown option: $1" ;;
        esac
      done
      local resp
      resp=$(api GET "/tasks?limit=50$query")
      if [ "$raw" -eq 1 ]; then
        echo "$resp"
      elif [ "$(jq '.tasks | length' <<<"$resp")" -eq 0 ]; then
        info "no tasks"
      else
        summary <<<"$resp"
      fi
    }

    cmd_show() {
      local id="''${1:-}" raw=0
      [ -n "$id" ] || die "Usage: agentos-task show <task-id|group> [--json]"
      [ "''${2:-}" != "--json" ] || raw=1
      valid_id "$id" || die "invalid id: $id"
      local resp
      if resp=$(api GET "/groups/$id" 2>/dev/null); then
        if [ "$raw" -eq 1 ]; then echo "$resp"; return; fi
        jq -r '"group \(.group): " + ([.counts | to_entries[] | "\(.value) \(.key)"] | join(", "))' <<<"$resp"
        summary <<<"$resp"
        return
      fi
      resp=$(api GET "/tasks/$id")
      if [ "$raw" -eq 1 ]; then echo "$resp"; return; fi
      jq -r '
        "task:      \(.id)",
        "status:    \(.status)\(if .result.error then " (\(.result.error))" else "" end)",
        "agent:     \(.agent)",
        "workspace: \(.workspace)",
        "branch:    \(.result.branch // "-")",
        "group:     \(.group // "-")",
        "after:     \(if (.depends_on | length) > 0 then (.depends_on | join(", ")) else "-" end)",
        "budget:    \(if .budget_usd then "$\(.budget_usd)" else "gateway default" end)   timeout: \(.timeout_sec)s",
        "exit code: \(.result.exit_code // "-")",
        "prompt:    \(.prompt | if length > 200 then .[0:200] + "..." else . end)",
        (if .result.output_tail then "\n--- output (tail) ---\n\(.result.output_tail)" else empty end)' <<<"$resp"
    }

    cmd_logs() {
      local id="''${1:-}" follow="''${2:-}"
      [ -n "$id" ] || die "Usage: agentos-task logs <task-id> [-f]"
      valid_id "$id" || die "invalid id: $id"
      local log="$TASKS_DIR/$id.log"
      if [ ! -f "$log" ]; then
        api GET "/tasks/$id" >/dev/null   # a clear error if the task does not exist
        die "no log for $id yet (queued tasks have none)"
      fi
      if [ "$follow" = "-f" ]; then
        exec tail -n +1 -F "$log"
      fi
      cat "$log"
    }

    cmd_cancel() {
      local id="''${1:-}"
      [ -n "$id" ] || die "Usage: agentos-task cancel <task-id|group>"
      valid_id "$id" || die "invalid id: $id"
      api POST "/tasks/$id/cancel" | jq -r '.tasks[] | "\(.id) \(.status)"'
    }

    case "''${1:-help}" in
      submit|run) shift; cmd_submit "$@" ;;
      list|ls) shift; cmd_list "$@" ;;
      show|status) shift; cmd_show "$@" ;;
      logs) shift; cmd_logs "$@" ;;
      cancel|kill) shift; cmd_cancel "$@" ;;
      help|-h|--help) usage ;;
      *) usage >&2; exit 1 ;;
    esac
  '';

  meta.description = "Submit and follow AgentOS orchestrator tasks";
}
