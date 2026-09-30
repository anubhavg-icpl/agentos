# Orchestrator and scheduler

The orchestrator runs coding agents headless, as **tasks**, with dependencies and a concurrency limit. The scheduler submits tasks on a calendar. Both are Python services in `services/agentos_services/` (`orchestrator.py`, `taskrunner.py`, `scheduler.py`), started by the NixOS modules `agentos.orchestration` and `agentos.scheduler`.

```
 operator ──agentos-task──▶ orchestrator (user agentos, unix socket)
                                 │  systemctl start agentos-task-runner@<id>   (polkit: this unit pattern only)
                                 ▼
                          task runner (root, oneshot) ─ validates ─▶ agentos-agent-<id>.service (same sandbox as `agentos spawn`)
                                                                            │
                                                     model gateway ◀────────┘  (metering, budgets, kill on overspend)
 scheduler ──submits──▶ orchestrator
```

## Enabling

```nix
agentos = {
  runtime.enable = true;
  networking.enable = true;              # the gateway meters task agents
  orchestration = {
    enable = true;
    maxWorkers = 4;                      # tasks running at once
  };
  scheduler = {
    enable = true;
    schedules.nightly-audit = {
      calendar = "*-*-* 02:00:00";
      agent = "claude";
      workspace = "main-project";
      prompt = "Run a security audit and fix what you find";
      budgetUSD = 5;
      persistent = true;
    };
  };
};
```

Operators (`agentos.runtime.operators`) need no sudo: tasks are launched by a root helper that the orchestrator may start, not by the operator.

## Tasks

A task is `{id, agent, workspace, prompt, budget_usd?, timeout_sec, depends_on[], group?, isolate, origin?, status, result}`.

| Status | Meaning |
|:---|:---|
| `queued` | Waiting for a worker slot or a dependency |
| `running` | The runner unit is active |
| `succeeded` / `failed` / `timeout` / `cancelled` | Finished; `result` has `exit_code`, `output_tail` (last `resultTailKB`), `branch`, `log`, `worktree`, `error` |
| `skipped` | A dependency did not succeed |

```sh
agentos-task submit --agent claude --workspace myproj --prompt "Fix the failing tests" --budget 3
agentos-task submit --agent claude --workspace myproj --prompt-file plan.md --timeout 1800 --wait

# Pipeline: the second task starts after the first succeeded and sees its output
first=$(agentos-task submit --agent claude --workspace myproj --prompt "Write the parser")
agentos-task submit --agent codex --workspace myproj --after "$first" \
  --prompt "Review this work and list problems: {prev_result}"

# Swarm: 3 agents, same prompt, each in its own git worktree on its own branch
agentos-task submit --agent aider --workspace myproj --prompt "Speed up the build" --swarm 3

agentos-task list [--status running] [--group <name>]
agentos-task show <task-id|group>
agentos-task logs <task-id> [-f]
agentos-task cancel <task-id|group>
```

- **Branches.** Every task runs on `agent/<task-id>`, like `agentos spawn`. Pipeline tasks share the workspace and run one after another, so each branch starts from where the previous agent left the working tree. Swarm tasks (and `--isolate`) get a git worktree `<workspace>.<task-id>` next to the workspace, so they can run in parallel; review the results with `git branch --list 'agent/*'`. A workspace without a commit gets an empty initial commit first.
- **Ordering.** Tasks start in submission order. Tasks that share a working tree (not isolated, same workspace) never run at the same time. `maxWorkers` and `agentos.runtime.maxAgents` (which also counts agents started by hand) limit concurrency.
- **`{prev_result}`** expands to the output tail of the dependencies (joined in `--after` order) when the dependent task starts. It is substituted once; output is never re-expanded.
- **Budgets and metering.** The task id is the agent id: the gateway prices it, `--budget` sets its daily cap, the daemon stops it when it is exceeded (the task then fails with the reason), and it shows up in `agentos list`, `agentos budget status` and the metrics.
- **Logs.** The full output is `/var/lib/agentos/tasks/<id>.log` (readable by the `agentos` group, capped at 64 MB).

### How each agent is run

`agentos.orchestration.taskCommands` maps an agent name (or its command) to an argument vector; `{prompt}`, `{workspace}` and `{task_id}` are replaced inside single arguments. Defaults exist for claude, codex, aider, gemini, qwen, goose, opencode, amp, cursor-agent, copilot and droid. Add or replace entries:

```nix
agentos.orchestration.taskCommands.my-agent = [ "my-agent" "--headless" "--prompt" "{prompt}" ];
agentos.orchestration.taskCommands.claude = lib.mkForce [ "claude" "-p" "{prompt}" "--max-turns" "20" ];
```

Agents without an entry are refused at submit time. Verify the defaults against the versions you install; headless flags change between releases.

## Security model

The orchestrator runs as `agentos` and has no sudo. The only privilege it has is starting and stopping units matching `agentos-task-runner@<id>.service` (a polkit rule in `modules/orchestration`). Everything reachable from a compromised orchestrator is therefore limited to what the root runner is willing to do:

- **Validation, twice.** At submit time and again in the runner, from the stored record: the agent must be a key of `/etc/agentos/runtime.json` `agents`; the workspace must resolve (symlinks followed) to an existing directory strictly below the workspace root; the prompt is text without NUL bytes, at most 64 KiB, and must not start with `-` (it would be parsed as an option); budget, timeout and ids are checked for type and range; unknown fields are rejected.
- **No shell, no command from the record.** The command line comes from the root-owned `services.toml` (`taskCommands`) and is passed to `systemd-run` as an argument vector. The prompt is one argv element; placeholders are filled in one pass, so a prompt that contains `{workspace}` or `$(...)` is passed literally.
- **Only tasks in state `running` start.** The runner refuses a record that the orchestrator has not dispatched.
- **git runs as the agent user.** Hooks and config in agent-writable repositories never run as root.
- **The log file** is created `O_EXCL|O_NOFOLLOW` after removing any existing entry, in a directory the orchestrator can write to.
- **The sandbox** is the one `agentos spawn` uses: read-only system, hidden homes, private /tmp, writes only to the workspace (and, for worktree tasks, the workspace's `.git`) and the agent home, memory/CPU/process limits, plus `RuntimeMaxSec = timeout + 60 s` as a backstop. The runner enforces the task timeout itself and stops the unit on cancel.
- **Sockets** (`/run/agentos-orchestrator`, `/run/agentos-scheduler`) are mode 0750/0660 group `agentos`; the `agentos-agent` user cannot reach them, Redis, or the gateway admin socket.

The sandbox arguments live in `TaskRunner.sandbox_args` (Python) and in `cmd_spawn` (`nixos/packages/cli.nix`); keep them in step when changing one.

## Scheduler

```sh
agentos-schedule add nightly --calendar '*-*-* 02:00:00' --agent claude --workspace myproj \
  --prompt "Run the test suite and fix failures" --budget 5 --persistent
agentos-schedule list
agentos-schedule run-now nightly
agentos-schedule remove nightly
```

- **Calendar syntax is systemd's `OnCalendar`**, evaluated by `systemd-analyze calendar` (`--base-time`, first iteration). It is used rather than a small cron parser because operators of a NixOS host already know it from timers, it is a superset (ranges, steps, time zones, `Mon..Fri`, `last day of month`) and it is the reference implementation, so the scheduler cannot disagree with `systemd-analyze calendar '<expr>'`. It costs one short process per firing and per `add`. Times are UTC unless the expression ends with a time zone. Expressions that begin with `-`, contain control characters or exceed 200 characters are refused before the process is started.
- **Persistence.** Schedules are kept in Redis. `persistent`: a run that came due while the scheduler was down fires once at start-up; otherwise it is skipped, as with `Persistent=` on a systemd timer.
- **Overlap.** A schedule does not fire while its previous run (any task it created) is still queued or running, unless `allow_overlap` is set; `run-now` always fires.
- **Declarative schedules** (`agentos.scheduler.schedules`) are synced at every scheduler start, keep their run state, are removed when they leave the configuration, and cannot be changed with the CLI. The workspace of a declared schedule need not exist when the system boots.
- Firing means posting the task template to the orchestrator socket, so validation, budgets and concurrency are the orchestrator's; `origin` on the task is `schedule:<name>`.

Removed options: `agentos.orchestration.mode` and `resultStrategy`, and `agentos.scheduler.maxConcurrent`, `enablePriorityQueues`, `offHours*` (setting them now fails with a message that says what to use instead). The old `agentos-orchestrate` shell script is gone.

## Testing

- `services/tests/test_orchestrator.py`: validation (injection attempts), dependency ordering, `{prev_result}`, swarm fan-out, concurrency limit, workspace serialization, cancel, dead-runner detection, the socket API.
- `services/tests/test_taskrunner.py`: the root helper against real git repositories and worktrees with a stand-in for `systemd-run`: results, tail bounding, timeout, cancel, budget kill, tampered records, symlinked log, configuration-only commands.
- `services/tests/test_scheduler.py`: next-run computation (parser, command line, and the real `systemd-analyze` when present), due detection with an injected clock and submitter, overlap, catch-up after downtime, declarative sync.
- `tests/orchestration.nix`: a VM test with a fake headless agent that calls a mock model API through the gateway: single task, 2-step pipeline, swarm of 2, timeout/cancel/skipped, hostile input, polkit limits, a schedule firing. Run with `nix build .#checks.x86_64-linux.orchestration` once it is listed in `flake.nix`.
