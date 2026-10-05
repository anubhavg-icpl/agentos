# nestlo-schedule: manage recurring orchestrator tasks
#
# Talks to the scheduler over its unix socket (group nestlo). Schedules
# declared in the NixOS configuration (nestlo.scheduler.schedules) are
# listed too but cannot be changed here.
{ writeShellApplication
, coreutils
, curl
, jq
, util-linux
}:

writeShellApplication {
  name = "nestlo-schedule";
  runtimeInputs = [ coreutils curl jq util-linux ];

  text = ''
    SOCKET="''${NESTLO_SCHED_SOCKET:-/run/nestlo-scheduler/scheduler.sock}"

    if [ -t 2 ]; then
      RED='\033[0;31m' GREEN='\033[0;32m' NC='\033[0m'
    else
      RED="" GREEN="" NC=""
    fi
    ok()  { echo -e "''${GREEN}[OK]''${NC} $*" >&2; }
    die() { echo -e "''${RED}[ERR]''${NC} $*" >&2; exit 1; }

    usage() {
      cat <<'EOF'
    nestlo-schedule: run agent tasks on a calendar

    USAGE
      nestlo-schedule add <name> --calendar <expr> --agent <name> --workspace <name|path>
                           (--prompt <text> | --prompt-file <file>) [--budget <usd>]
                           [--timeout <sec>] [--swarm <n>] [--persistent] [--allow-overlap] [--disabled]
      nestlo-schedule list [--json]
      nestlo-schedule show <name>
      nestlo-schedule remove <name>
      nestlo-schedule run-now <name>

    CALENDAR
      systemd OnCalendar syntax, UTC unless a time zone is given. Check one with:
      systemd-analyze calendar "<expr>"
        daily                        every day at 00:00
        Mon..Fri 09:00               weekdays at 09:00
        *-*-* *:00/15:00             every 15 minutes
        Sun 03:00 Europe/Berlin      Sundays at 03:00 Berlin time

    --persistent    run once at start-up if a run came due while the scheduler was down
    --allow-overlap start a new run even if the previous one is still queued or running
    EOF
    }

    [ -S "$SOCKET" ] || die "scheduler socket $SOCKET not found; is nestlo.scheduler.enable set?"

    api() {
      local method="$1" path="$2" body="''${3:-}" out code
      out=$(mktemp)
      local args=(-sS -o "$out" -w '%{http_code}' --unix-socket "$SOCKET" -X "$method" -H 'Content-Type: application/json')
      if [ -n "$body" ]; then
        args+=(--data-binary "$body")
      fi
      code=$(curl "''${args[@]}" "http://scheduler$path") || { rm -f "$out"; die "cannot reach the scheduler (are you in the nestlo group?)"; }
      if [ "''${code:0:1}" != "2" ]; then
        local msg
        msg=$(jq -r '.error // empty' "$out" 2>/dev/null || true)
        rm -f "$out"
        die "''${msg:-scheduler returned HTTP $code}"
      fi
      cat "$out"
      rm -f "$out"
    }

    valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; }

    cmd_add() {
      local name="''${1:-}"
      [ -n "$name" ] || die "Usage: nestlo-schedule add <name> --calendar <expr> --agent <name> ..."
      valid_name "$name" || die "invalid schedule name: $name"
      shift
      local calendar="" agent="" workspace="" prompt="" have_prompt=0 budget="" timeout="" swarm=""
      local persistent=false overlap=false enabled=true
      while [ $# -gt 0 ]; do
        case "$1" in
          --calendar) calendar="''${2:?--calendar needs a value}"; shift 2 ;;
          --agent) agent="''${2:?--agent needs a value}"; shift 2 ;;
          --workspace) workspace="''${2:?--workspace needs a value}"; shift 2 ;;
          --prompt) prompt="''${2:?--prompt needs a value}"; have_prompt=1; shift 2 ;;
          --prompt-file)
            [ -r "''${2:?--prompt-file needs a value}" ] || die "cannot read $2"
            prompt=$(cat "$2"); have_prompt=1; shift 2 ;;
          --budget) budget="''${2:?--budget needs a value}"; shift 2 ;;
          --timeout) timeout="''${2:?--timeout needs a value}"; shift 2 ;;
          --swarm) swarm="''${2:?--swarm needs a value}"; shift 2 ;;
          --persistent) persistent=true; shift ;;
          --allow-overlap) overlap=true; shift ;;
          --disabled) enabled=false; shift ;;
          *) die "unknown option: $1 (see: nestlo-schedule help)" ;;
        esac
      done
      [ -n "$calendar" ] || die "--calendar is required"
      [ -n "$agent" ] || die "--agent is required"
      [ -n "$workspace" ] || die "--workspace is required"
      [ "$have_prompt" -eq 1 ] || die "--prompt or --prompt-file is required"
      local body
      body=$(jq -cn --arg calendar "$calendar" --arg agent "$agent" --arg workspace "$workspace" --arg prompt "$prompt" \
        --arg budget "$budget" --arg timeout "$timeout" --arg swarm "$swarm" \
        --argjson persistent "$persistent" --argjson overlap "$overlap" --argjson enabled "$enabled" '
        {calendar: $calendar, agent: $agent, workspace: $workspace, prompt: $prompt,
         persistent: $persistent, allow_overlap: $overlap, enabled: $enabled}
        + (if $budget != "" then {budget_usd: ($budget | tonumber)} else {} end)
        + (if $timeout != "" then {timeout_sec: ($timeout | tonumber)} else {} end)
        + (if $swarm != "" then {swarm: ($swarm | tonumber)} else {} end)') \
        || die "invalid number in --budget, --timeout or --swarm"
      local resp
      resp=$(api PUT "/schedules/$name" "$body")
      ok "schedule $name: next run $(date -u -d "@$(jq -r '.next_run // empty' <<<"$resp")" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo never)"
    }

    cmd_list() {
      local resp
      resp=$(api GET /schedules)
      if [ "''${1:-}" = "--json" ]; then
        echo "$resp"
        return
      fi
      if [ "$(jq '.schedules | length' <<<"$resp")" -eq 0 ]; then
        echo "No schedules. Add one with: nestlo-schedule add <name> --calendar daily ..." >&2
        return
      fi
      jq -r '
        (["NAME", "CALENDAR", "AGENT", "NEXT RUN (UTC)", "LAST RUN (UTC)", "FLAGS"] | @tsv),
        (.schedules[] | [ .name, .calendar, .task.agent,
            (if .next_run then (.next_run | floor | strftime("%Y-%m-%d %H:%M")) else "never" end),
            (if .last_run then (.last_run | floor | strftime("%Y-%m-%d %H:%M")) else "-" end),
            ([(if .declarative then "declared" else empty end), (if .enabled then empty else "disabled" end),
              (if .persistent then "persistent" else empty end)] | join(",") | if . == "" then "-" else . end) ] | @tsv)' \
        <<<"$resp" | column -t -s "$(printf '\t')"
    }

    cmd_show() {
      local name="''${1:-}"
      [ -n "$name" ] || die "Usage: nestlo-schedule show <name>"
      valid_name "$name" || die "invalid schedule name: $name"
      api GET "/schedules/$name" | jq .
    }

    cmd_remove() {
      local name="''${1:-}"
      [ -n "$name" ] || die "Usage: nestlo-schedule remove <name>"
      valid_name "$name" || die "invalid schedule name: $name"
      api DELETE "/schedules/$name" >/dev/null
      ok "removed $name"
    }

    cmd_run_now() {
      local name="''${1:-}"
      [ -n "$name" ] || die "Usage: nestlo-schedule run-now <name>"
      valid_name "$name" || die "invalid schedule name: $name"
      local resp
      resp=$(api POST "/schedules/$name/run")
      jq -r '.tasks[]' <<<"$resp"
      ok "submitted; follow with: nestlo-task show $(jq -r '.tasks[0] // empty' <<<"$resp")"
    }

    case "''${1:-help}" in
      add) shift; cmd_add "$@" ;;
      list|ls) shift; cmd_list "$@" ;;
      show) shift; cmd_show "$@" ;;
      remove|rm) shift; cmd_remove "$@" ;;
      run-now|run) shift; cmd_run_now "$@" ;;
      help|-h|--help) usage ;;
      *) usage >&2; exit 1 ;;
    esac
  '';

  meta.description = "Manage Nestlo scheduled agent tasks";
}
