#!/bin/sh
# AgentOS panels for herdr (see herdr-plugin.toml and docs/herdr.md).
#
#   panel.sh tasks|factory|budget    live view, refreshed every few seconds
#   panel.sh approve|cancel          list the candidates and ask for a task id
#   panel.sh open <pane>             action entry point: open that pane
#
# Plain POSIX sh, no network. It only runs the AgentOS CLIs as the user that
# runs herdr, so it can do exactly what that user can do on the command line.

PATH="/run/wrappers/bin:/run/current-system/sw/bin:$PATH"
export PATH
INTERVAL="${AGENTOS_PANEL_INTERVAL:-5}"

have() { command -v "$1" >/dev/null 2>&1; }

# A task id is what the orchestrator accepts: nothing else reaches a CLI.
valid_id() { printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'; }

# run <cli> <hint> <args...>: run a CLI, or say why it cannot be used
run() {
  cli="$1"; hint="$2"; shift 2
  if ! have "$cli"; then
    echo "$cli is not installed ($hint)"
    return 0
  fi
  "$cli" "$@" 2>&1 || echo "($cli exited with status $?; your user may not be allowed to use it)"
}

show() {
  case "$1" in
    tasks)   run agentos-task "agentos.orchestration is not enabled" list ;;
    factory) run agentos-factory "the AgentOS factory is not enabled on this host" list ;;
    budget)  run agentos-budget "agentos.budget-controller is not enabled" status ;;
    *) echo "unknown panel: $1"; return 1 ;;
  esac
}

watch_panel() {
  while :; do
    printf '\033[H\033[2J'
    echo "AgentOS $1   $(date '+%H:%M:%S')   (refreshes every ${INTERVAL}s, ctrl+c to close)"
    echo
    show "$1"
    sleep "$INTERVAL"
  done
}

ask_id() {
  printf '%s id: ' "$1"
  read -r id || exit 0
  [ -n "$id" ] || { echo "nothing done"; return 1; }
  valid_id "$id" || { echo "not a task id: $id"; return 1; }
}

pause() {
  printf '\npress enter to close '
  read -r _ || true
}

case "${1:-}" in
  tasks | factory | budget)
    watch_panel "$1"
    ;;
  approve)
    echo "Tasks waiting for approval:"
    run agentos-task "agentos.orchestration is not enabled" list --status awaiting_approval
    echo
    if have agentos-task && ask_id approve; then
      run agentos-task "" approve "$id"
    fi
    pause
    ;;
  cancel)
    echo "Running and queued tasks:"
    run agentos-task "agentos.orchestration is not enabled" list --status running
    run agentos-task "" list --status queued
    run agentos-task "" list --status awaiting_approval
    echo
    if have agentos-task && ask_id cancel; then
      printf 'cancel %s? [y/N] ' "$id"
      read -r answer || exit 0
      case "$answer" in
        y | Y | yes) run agentos-task "" cancel "$id" ;;
        *) echo "left running" ;;
      esac
    fi
    pause
    ;;
  open)
    case "${2:-}" in
      tasks | factory | budget | approve | cancel) ;;
      *) echo "usage: panel.sh open tasks|factory|budget|approve|cancel" >&2; exit 2 ;;
    esac
    exec "${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "${HERDR_PLUGIN_ID:-agentos.dashboard}" --entrypoint "$2"
    ;;
  *)
    echo "usage: panel.sh tasks|factory|budget|approve|cancel|open <pane>" >&2
    exit 2
    ;;
esac
