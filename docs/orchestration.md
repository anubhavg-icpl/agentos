# Orchestrator and scheduler

The orchestrator runs coding agents headless, as **tasks**, with dependencies and a concurrency limit. The scheduler submits tasks on a calendar. Both are Python services in `services/nestlo_services/` (`orchestrator.py`, `tasks.py`, `taskrunner.py`, `scheduler.py`), started by the NixOS modules `nestlo.orchestration` and `nestlo.scheduler`.

```
 operator ──nestlo-task──▶ orchestrator (user nestlo, unix socket)
                                 │  systemctl start nestlo-task-runner@<id>   (polkit: this unit pattern only)
                                 ▼
                          task runner (root, oneshot) ─ validates ─▶ nestlo-agent-<id>.service (same sandbox as `nestlo spawn`)
                                                                            │
                                                     model gateway ◀────────┘  (metering, budgets, kill on overspend)
 scheduler ──submits──▶ orchestrator
```

## Enabling

```nix
nestlo = {
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

Operators (`nestlo.runtime.operators`) need no sudo: tasks are launched by a root helper that the orchestrator may start, not by the operator.

## Tasks

A task is `{id, agent, workspace, prompt, budget_usd?, timeout_sec, depends_on[], group?, isolate, origin?, gate, priority, concurrency_key?, dedupe_key?, max_retries, backoff_sec, attempt, attempts[], verify?, status, result}`. Documents written before the newer fields existed keep working: a missing field means its default.

| Status | Meaning |
|:---|:---|
| `awaiting_approval` | A gated task: waits for `approve` or `reject`; holds no worker slot |
| `queued` | Waiting for a worker slot, a dependency, a concurrency key or a retry back-off |
| `running` | The runner unit is active |
| `succeeded` / `failed` / `timeout` / `cancelled` | Finished; `result` has `exit_code`, `output_tail` (last `resultTailKB`), `branch`, `log`, `worktree`, `error` |
| `skipped` | A dependency did not succeed |

```sh
nestlo-task submit --agent claude --workspace myproj --prompt "Fix the failing tests" --budget 3
nestlo-task submit --agent claude --workspace myproj --prompt-file plan.md --timeout 1800 --wait

# Pipeline: the second task starts after the first succeeded and sees its output
first=$(nestlo-task submit --agent claude --workspace myproj --prompt "Write the parser")
nestlo-task submit --agent codex --workspace myproj --after "$first" \
  --prompt "Review this work and list problems: {prev_result}"

# Swarm: 3 agents, same prompt, each in its own git worktree on its own branch
nestlo-task submit --agent aider --workspace myproj --prompt "Speed up the build" --swarm 3

nestlo-task list [--status running] [--group <name>]
nestlo-task show <task-id|group>
nestlo-task logs <task-id> [-f]
nestlo-task cancel <task-id|group>
nestlo-task approve <task-id> [--note <text>]
nestlo-task reject <task-id> [--note <text>]
nestlo-task workflow submit <file.json> [--wait]
nestlo-task workflow status <group>
```

- **Branches.** Every task runs on `agent/<task-id>`, like `nestlo spawn`. Pipeline tasks share the workspace and run one after another, so each branch starts from where the previous agent left the working tree. Swarm tasks (and `--isolate`) get a git worktree `<workspace>.<task-id>` next to the workspace, so they can run in parallel; review the results with `git branch --list 'agent/*'`. A workspace without a commit gets an empty initial commit first.
- **Ordering.** Tasks start in submission order. Tasks that share a working tree (not isolated, same workspace) never run at the same time. `maxWorkers` and `nestlo.runtime.maxAgents` (which also counts agents started by hand) limit concurrency.
- **`{prev_result}`** expands to the output tail of the dependencies (joined in `--after` order) when the dependent task starts. It is substituted once; output is never re-expanded.
- **Budgets and metering.** The task id is the agent id: the gateway prices it, `--budget` sets its daily cap, the daemon stops it when it is exceeded (the task then fails with the reason), and it shows up in `nestlo list`, `nestlo budget status` and the metrics.
- **Logs.** The full output is `/var/lib/nestlo/tasks/<id>.log` (readable by the `nestlo` group, capped at 64 MB).

### Approval gates

Who may approve, and which tasks are gated automatically, is set by `nestlo.rbac` and `nestlo.policy` ([policy.md](policy.md)).

`gate: true` (`--gate`) makes a task wait in `awaiting_approval`. It does not start and holds no worker slot until someone runs `nestlo-task approve <id>`; the task then queues normally (dependencies, priority and limits still apply). `reject` cancels it and every unfinished task that depends on it, directly or not, even a workflow node whose `when` is `always`. A gated task whose dependency fails is skipped without waiting for a decision. In a swarm every member is gated and must be approved separately.

The approver is the client's uid from `SO_PEERCRED` on the orchestrator socket, which the kernel supplies and a client cannot forge (a `by` field in the request body is ignored). The decision is recorded on the task as `approval: {decision, by, uid, at, note}`; the submitter is recorded the same way as `submitted_by`. Any member of the `nestlo` group can approve; deciding twice, or on a task that is not awaiting approval, is refused (HTTP 409).

### Workflows (DAGs)

```json
{
  "nodes": {
    "build":  {"agent": "claude", "workspace": "app", "prompt": "Build it", "isolate": true},
    "lint":   {"agent": "codex",  "workspace": "app", "prompt": "Lint it",  "isolate": true},
    "report": {"agent": "claude", "workspace": "app", "depends_on": ["build", "lint"],
               "prompt": "Summarise: {nodes.build.result} and {nodes.lint.result}"},
    "alert":  {"agent": "claude", "workspace": "app", "depends_on": ["build", "lint"],
               "when": "any_failed", "prompt": "Something failed: {prev_result}"}
  }
}
```

`nestlo-task workflow submit flow.json` expands every node into a task; all share one `group` (printed by the command, or given as `"group"`; `"origin"` is inherited by nodes that set none). `workflow status <group>` lists nodes with their status and attempts.

- A node waits until **all** its dependencies are terminal (fan-out and fan-in), then `when` decides whether it runs or is `skipped`.
- Node fields are the task fields (`agent`, `workspace`, `prompt`, `budget_usd`, `timeout_sec`, `isolate`, `gate`, `priority`, `max_retries`, `backoff_sec`, `verify`, `concurrency_key`, `origin`) plus `depends_on` (node names) and `when`. `swarm`, `judge`, `group`, `after` and `dedupe_key` are refused in a node. Nodes that share a workspace without `isolate` run one at a time.
- `{nodes.<name>.result}` is the output tail of that node (any ancestor, not only direct dependencies); `{prev_result}` is the direct dependencies' tails joined in `depends_on` order, as in a pipeline. Both are substituted once.
- **`when`** is a fixed grammar, parsed by hand and never evaluated: `all_succeeded` (default), `any_succeeded`, `any_failed` (a dependency failed or timed out), `all_failed`, `always`, and `node:<dep>=succeeded|failed|timeout|skipped|cancelled` (`failed` includes `timeout`), combined with `and`, `or`, `not` and parentheses (`not` binds tighter than `and`, then `or`). At most 200 printable ASCII characters and 8 levels of nesting; anything else is a validation error, as is naming a node that is not a direct dependency.
- Refused at submit time, creating nothing: cycles, unknown or self dependencies, names outside `[A-Za-z0-9][A-Za-z0-9_-]{0,31}`, references to `{nodes.x.result}` for a node that is not an ancestor, an existing group name, and more than `nestlo.orchestration.maxWorkflowNodes` nodes (default 50).

### Retries and recovery

`max_retries` (`--retries`, default 0, at most `nestlo.orchestration.maxRetries`, hard ceiling 10) retries a task whose run **failed or timed out**: it goes back to `queued` with `attempt + 1` and waits `backoff_sec * 2^(attempt-1)` seconds (`--backoff`, default 10, at most 3600; the wait is capped at 24 h). While it waits it holds no slot and its dependents wait for it. The prompt (`{prev_result}` and friends) is expanded again for each attempt. Cancelled and skipped tasks, tasks stopped by the gateway for overspending (`stopped: ...`) and tasks the runner rejected are never retried. The retry is decided in `TaskStore.finish`, so it also applies to results written by the runner. Every attempt is kept in `attempts: [{attempt, status, started_at, finished_at, exit_code, error, branch, output_tail (2 KiB)}]`; `result` is the last attempt's. An isolated task's worktree and branch are recreated for the retry, so work from the failed attempt is discarded (it stays in the log).

When the orchestrator starts it reconciles tasks marked `running` against the runner unit's state straight away (without the start grace period): if the unit is gone the task is retried when it has retries left, otherwise failed.

### Swarm verify and judge

```sh
nestlo-task submit --agent aider --workspace myproj --prompt "Speed up the build" --swarm 3 \
  --verify '["make","test"]' --judge-agent claude \
  --judge-prompt "Pick the best branch. Reply with 'winner: <task-id>' on the first line. {results}"
```

- `verify: {cmd: [argv...], timeout_sec?}` (task and swarm submissions; every member gets it) is an argument vector run in the task's worktree after the agent succeeded. At most 32 arguments, no NUL bytes, `cmd[0]` not starting with `-`, `timeout_sec` 1-3600 (default 600). It never goes through a shell. See **Verify contract (taskrunner)** below for who runs it.
- `judge: {agent, prompt, budget_usd?, timeout_sec?}` needs `swarm >= 2`. The judge is queued with the members (`role: judge`, `depends_on` all members, `when: any_succeeded`), so it starts once every member is terminal and at least one succeeded, in the same workspace and group. `{results}` in its prompt is replaced, once, by one block per member: `task:`, `branch:`, `status:`, `verify:` (`passed`, `failed`, `error`, `none` when no verify was requested, `not_reported` when it was requested but the runner reported nothing) and `result tail:` (last 4000 characters). Member output is data: it is not re-expanded.
- When the judge succeeds, the **first non-empty line** of its output must be `winner: <task-id>` naming a member; the id is stored as `winner` on the group (`GET /groups/<g>`, `nestlo-task show <group>`). Anything else sets `winner: null` and `winner_error`. Only the first line counts so that a judge that echoes member output cannot be hijacked.

### Priority, concurrency keys and deduplication

- `priority` (`--priority`, integer -1000..1000, default 0): among tasks that could start, higher runs first, first come first served within a priority. A task that cannot start (its workspace or key is busy) never holds back a lower-priority task.
- `concurrency_key`: at most one *running* task per key (`[A-Za-z0-9][A-Za-z0-9._:/@#-]{0,99}`), across all groups.
- `dedupe_key`: a submit whose key belongs to a task that has not finished (awaiting approval, queued, backing off or running) returns that task (HTTP 200, `deduplicated: true`) and queues nothing; once it finished the key is free again. The check is atomic in Redis. Not allowed with `swarm` or in workflow nodes.

### Continuing a branch: `start_from`

`start_from: "<task-id>"` (needs `isolate: true`) makes the task's worktree and branch `agent/<id>` start from the tip of `agent/<that task>` instead of the workspace HEAD, so a fix round continues the previous round's work. The earlier task must exist and be in the same workspace (checked at submit); while it is still unfinished the new task also waits for it (it is added to `depends_on`), once it is finished any status is accepted. The runner checks that the branch exists when the task starts and otherwise fails the task (`setup failed: start_from: branch agent/<id> does not exist`). Work the earlier agent left uncommitted in its worktree is committed first (hooks off). A retry recreates the worktree from the same start point. The result records `base_sha` (the start commit), `start_from` and `chain_base_sha`, the `base_sha` of the first task of the chain. `start_from` is refused in workflow nodes (it names a task id, not a node; submit the follow-up as its own task).

### Publish tasks: `kind: "publish"`

`kind` is `"agent"` (default) or `"publish"`. A publish task runs no agent: the root task runner publishes the branch of `source_task` with `publish.py`, using the usual `publish` block (`{repo, title, body, merge?}`).

```sh
nestlo-task publish <source-task-id> --repo acme/widgets --title "Fix the crash" [--body-file f] [--merge squash]
```

or `POST /tasks {"kind": "publish", "source_task": "<id>", "workspace": "<same>", "publish": {...}}` (`agent` and `prompt` are optional and ignored). `source_task` is required, must be in the same workspace, must have `succeeded` and have produced a branch; a publish task cannot be a swarm, take `isolate` or `start_from`. In a workflow, a publish node instead names its source by `depends_on` (the first succeeded dependency with a branch). Every rule of `publish.py` applies: repository allow-list, `agent/<id>` branches only, protected branches, the bundle-then-push split, a provenance note when enabled. The empty-diff check compares against the diff base `chain_base_sha` of the source (else its `base_sha`), so a fix round that changes nothing itself is still publishable when an earlier round of its `start_from` chain did. The task's result has `pr_url`, `pr_number`, `branch`, `source_task` and the `publish` block (`status`, `merge` when asked for); a refused publish fails the task with `publish refused: <reason>`. Publish tasks do not hold the workspace, count as publishing for the policy (`require_approval.mode = "publish"`, `publish.enable`) and are audited (`publish.pr`, `publish.merge`). Merging is described in [triggers.md](triggers.md#publishing).

### How each agent is run

`nestlo.orchestration.taskCommands` maps an agent name (or its command) to an argument vector; `{prompt}`, `{workspace}` and `{task_id}` are replaced inside single arguments. Defaults exist for claude, codex, aider, agy (Antigravity CLI), gemini (deprecated), qwen, goose, opencode, amp, cursor-agent, copilot and droid. Add or replace entries:

```nix
nestlo.orchestration.taskCommands.my-agent = [ "my-agent" "--headless" "--prompt" "{prompt}" ];
nestlo.orchestration.taskCommands.claude = lib.mkForce [ "claude" "-p" "{prompt}" "--max-turns" "20" ];
```

Agents without an entry are refused at submit time. Verify the defaults against the versions you install; headless flags change between releases.

## Verify contract (taskrunner)

Status: implemented.

The orchestrator validates and stores `verify` and hands it to the runner in the task record; it never runs it (it has no privileges and the argv comes from a user). `taskrunner.py` can run it, because it already has everything needed: the working directory (`workdir`), the writable paths and `sandbox_args()`. The contract for the runner:

1. Only when the agent exited 0 (outcome `succeeded`) and `task["verify"]` is set. Re-validate it with `tasks.validate_verify` (`validate_record` already does).
2. Run `verify["cmd"]` as an argument vector (`systemd-run ... -- argv`, never a shell) in a second transient unit, `nestlo-verify-<task-id>`, with the same sandbox as the agent (`sandbox_args(unit, workdir, writable, env, timeout=verify["timeout_sec"])`) and the agent user, in `workdir` (the task's worktree for isolated tasks), with the agent's environment minus the gateway credentials. Enforce `verify["timeout_sec"]` and stop the unit on cancel.
3. Record the outcome in the task result **before** `finish()`: `result["verify"] = {"status": "passed" | "failed" | "error", "exit_code": int | null, "output_tail": str, "duration_sec": float}`; `failed` is a non-zero exit, `error` is a timeout or a failure to start. Task status stays that of the agent: a failed verification does not turn a `succeeded` task into `failed` (so retries and dependents are unaffected); consumers such as the judge read `result.verify.status`.
4. **Implemented** in `taskrunner.py` (`run_verify`). The runner also resolves `cmd[0]` against the agent `PATH` (or the worktree for a path containing `/`); a missing program is `error` with exit code `null`. Unit `nestlo-verify-<task-id>` is stopped on timeout or cancel and the `output_tail` is bounded by `result_tail_kb`. Verification runs before the publish step. If it is not `passed` (`failed` or `error`), publishing is not attempted and the result records `publish: {status: "skipped", error: "verify failed"}`; following point 3, the task status is not changed, even for an explicit publish request, so the PR is simply withheld. A task whose agent failed has no `verify` key, and a task without `verify` keeps `not_reported`/`none` in the judge prompt only when the runner is older than this contract.

Retries add one more requirement, which the runner already meets: when `task["attempt"] > 1`, `prepare_workspace` removes the previous attempt's worktree and branch before it creates them again.

## Security model

The orchestrator runs as `nestlo` and has no sudo. The only privilege it has is starting and stopping units matching `nestlo-task-runner@<id>.service` (a polkit rule in `modules/orchestration`). Everything reachable from a compromised orchestrator is therefore limited to what the root runner is willing to do:

- **Validation, twice.** At submit time and again in the runner, from the stored record: the agent must be a key of `/etc/nestlo/runtime.json` `agents`; the workspace must resolve (symlinks followed) to an existing directory strictly below the workspace root; the prompt is text without NUL bytes, at most 64 KiB, and must not start with `-` (it would be parsed as an option); budget, timeout and ids are checked for type and range; unknown fields are rejected.
- **No shell, no command from the record.** The command line comes from the root-owned `services.toml` (`taskCommands`) and is passed to `systemd-run` as an argument vector. The prompt is one argv element; placeholders are filled in one pass, so a prompt that contains `{workspace}` or `$(...)` is passed literally.
- **Only tasks in state `running` start.** The runner refuses a record that the orchestrator has not dispatched.
- **git runs as the agent user.** Hooks and config in agent-writable repositories never run as root.
- **The log file** is created `O_EXCL|O_NOFOLLOW` after removing any existing entry, in a directory the orchestrator can write to.
- **The sandbox** is the one `nestlo spawn` uses: read-only system, hidden homes, private /tmp, writes only to the workspace (and, for worktree tasks, the workspace's `.git`) and the agent home, memory/CPU/process limits, plus `RuntimeMaxSec = timeout + 60 s` as a backstop. The runner enforces the task timeout itself and stops the unit on cancel.
- **Sockets** (`/run/nestlo-orchestrator`, `/run/nestlo-scheduler`) are mode 0750/0660 group `nestlo`; the `nestlo-agent` user cannot reach them, Redis, or the gateway admin socket.

The sandbox arguments live in `TaskRunner.sandbox_args` (Python) and in `cmd_spawn` (`nixos/packages/cli.nix`); keep them in step when changing one.

## Scheduler

```sh
nestlo-schedule add nightly --calendar '*-*-* 02:00:00' --agent claude --workspace myproj \
  --prompt "Run the test suite and fix failures" --budget 5 --persistent
nestlo-schedule list
nestlo-schedule run-now nightly
nestlo-schedule remove nightly
```

- **Calendar syntax is systemd's `OnCalendar`**, evaluated by `systemd-analyze calendar` (`--base-time`, first iteration). It is used rather than a small cron parser because operators of a NixOS host already know it from timers, it is a superset (ranges, steps, time zones, `Mon..Fri`, `last day of month`) and it is the reference implementation, so the scheduler cannot disagree with `systemd-analyze calendar '<expr>'`. It costs one short process per firing and per `add`. Times are UTC unless the expression ends with a time zone. Expressions that begin with `-`, contain control characters or exceed 200 characters are refused before the process is started.
- **Persistence.** Schedules are kept in Redis. `persistent`: a run that came due while the scheduler was down fires once at start-up; otherwise it is skipped, as with `Persistent=` on a systemd timer.
- **Overlap.** A schedule does not fire while its previous run (any task it created) is still queued or running, unless `allow_overlap` is set; `run-now` always fires.
- **Declarative schedules** (`nestlo.scheduler.schedules`) are synced at every scheduler start, keep their run state, are removed when they leave the configuration, and cannot be changed with the CLI. The workspace of a declared schedule need not exist when the system boots.
- Firing means posting the task template to the orchestrator socket, so validation, budgets and concurrency are the orchestrator's; `origin` on the task is `schedule:<name>`.

Added options: `nestlo.orchestration.maxWorkflowNodes` (default 50) and `maxRetries` (default 5, ceiling 10). Added task fields: `gate`, `priority`, `concurrency_key`, `dedupe_key`, `max_retries`, `backoff_sec`, `verify`, and on submissions `judge`; added status `awaiting_approval`; added socket operations `POST /tasks/<id>/approve`, `POST /tasks/<id>/reject` and `POST /workflows`, and `GET /workflows/<group>` (same as `/groups/<group>`, plus a `nodes` map and the judge's `winner`).

Removed options: `nestlo.orchestration.mode` and `resultStrategy`, and `nestlo.scheduler.maxConcurrent`, `enablePriorityQueues` (queues are gone; tasks now take a `priority` of their own, schedules do not), `offHours*` (setting them now fails with a message that says what to use instead). The old `nestlo-orchestrate` shell script is gone.

## Limitations

- Tasks always run in the systemd sandbox. The `nestlo spawn` options for container isolation (`--isolation container`) and GPUs (`--gpu`) are not available to tasks yet.

## Testing

- `services/tests/test_orchestrator.py`: validation (injection attempts), dependency ordering, `{prev_result}`, swarm fan-out, concurrency limit, workspace serialization, cancel, dead-runner detection, the socket API.
- `services/tests/test_orchestrator_ext.py`: approval gates (slot accounting, who/when/note, reject cascade, approve/reject races, peer identity over the real socket), workflows (diamond fan-in/out, cycles, unknown dependencies, hostile names, size cap, `{nodes.x.result}`), the `when` grammar (truth table and injection attempts), retries (back-off, attempt records, caps, tampered records, restart reconciliation), verify and judge (winner parsing, hostile member output), priority, concurrency keys, dedupe races, and concurrent ticks never exceeding `maxWorkers`.
- `services/tests/test_retry_runner.py`: a retried isolated task gets a clean worktree.
- `services/tests/test_taskrunner.py`: the root helper against real git repositories and worktrees with a stand-in for `systemd-run`: results, tail bounding, timeout, cancel, budget kill, tampered records, symlinked log, configuration-only commands.
- `services/tests/test_scheduler.py`: next-run computation (parser, command line, and the real `systemd-analyze` when present), due detection with an injected clock and submitter, overlap, catch-up after downtime, declarative sync.
- `tests/orchestration.nix`: a VM test with a fake headless agent that calls a mock model API through the gateway: single task, 2-step pipeline, a gated task approved from the CLI, a 3-node DAG with fan-in, swarm of 2, timeout/cancel/skipped, hostile input, polkit limits, a schedule firing. Run with `nix build .#checks.x86_64-linux.orchestration`.
