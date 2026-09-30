"""Task model, validation and Redis storage for the orchestrator.

A task is one non-interactive agent run:

    {id, agent, workspace, prompt, budget_usd, timeout_sec, depends_on[],
     group, isolate, origin, status, result, created_at, started_at,
     finished_at}

Status flow: queued -> running -> succeeded | failed | timeout | cancelled,
or queued -> skipped (a dependency did not succeed) / cancelled.

Three programs touch tasks and none of them trusts the others' input:

  * the orchestrator (user agentos) validates submissions, orders and
    dispatches them;
  * the task runner (root, one oneshot unit per task) re-validates the
    record with `validate_record` before it launches anything;
  * the scheduler submits templates through the orchestrator socket.

Everything that ends up on a command line is validated here: the agent must
be one of the runtime's known agents, the workspace must resolve to a
directory below the workspace root, and the prompt is only ever passed as
one argv element (never through a shell).

Redis keys (all prefixed with "agentos:"):
  task:<id>            JSON    the task record
  tasks                zset    every task id, scored by creation time
  tasks:active         set     ids that are not in a terminal state
  group:<name>         set     task ids of a swarm / pipeline group
"""

import json
import math
import os
import re
import time
import uuid

import redis

from . import config as configmod

QUEUED, RUNNING = "queued", "running"
SUCCEEDED, FAILED, TIMEOUT, CANCELLED, SKIPPED = "succeeded", "failed", "timeout", "cancelled", "skipped"
TERMINAL = {SUCCEEDED, FAILED, TIMEOUT, CANCELLED, SKIPPED}

TASK_TTL = 30 * 24 * 3600
# Linux limits one argv element to 128 KiB; stay below it
MAX_ARG_BYTES = 120_000

DEFAULTS = {
    "orchestrator": {
        "socket": "/run/agentos-orchestrator/orchestrator.sock",
        "runtime_file": "/etc/agentos/runtime.json",
        "tasks_dir": "/var/lib/agentos/tasks",
        "max_workers": 4,
        "default_timeout_sec": 3600,
        "max_timeout_sec": 7 * 24 * 3600,
        "max_prompt_bytes": 64 * 1024,
        "max_swarm": 16,
        "result_tail_kb": 16,
        "log_cap_mb": 64,
        "tick_sec": 1.0,
        "start_grace_sec": 30,
        "runner_unit_prefix": "agentos-task-runner@",
        "agent_path": "/run/current-system/sw/bin",
        # agent name (or its command) -> argv template with {prompt},
        # {workspace} and {task_id} placeholders
        "task_commands": {},
    },
    "scheduler": {
        "socket": "/run/agentos-scheduler/scheduler.sock",
        "tick_sec": 5.0,
        "schedules": [],
    },
}


def settings(cfg, section):
    """DEFAULTS[section] with the [section] table of the services config on top."""
    merged = configmod._merge(json.loads(json.dumps(DEFAULTS[section])), cfg.get(section, {}))
    return merged


class ValidationError(ValueError):
    pass


def load_runtime(path):
    with open(path) as f:
        return json.load(f)


# ── validation ───────────────────────────────────────────────────────────
SUBMIT_FIELDS = {
    "agent", "workspace", "prompt", "budget_usd", "timeout_sec",
    "depends_on", "after", "swarm", "group", "isolate", "origin",
}
_PLACEHOLDER = re.compile(r"\{(prompt|workspace|task_id)\}")
_PREV = re.compile(r"\{prev_result\}")


def resolve_workspace(workspace, root, must_exist=True):
    """Resolve to an absolute path strictly below the workspace root."""
    if not isinstance(workspace, str) or not workspace or "\0" in workspace:
        raise ValidationError("workspace must be a non-empty string")
    path = workspace if "/" in workspace else os.path.join(root, workspace)
    if not os.path.isabs(path):
        raise ValidationError("workspace must be a name or an absolute path")
    real, root_real = os.path.realpath(path), os.path.realpath(root)
    if not real.startswith(root_real + os.sep):
        raise ValidationError("workspace %r is not below %s" % (workspace, root_real))
    if must_exist and not os.path.isdir(real):
        raise ValidationError("no such workspace: %s" % real)
    return real


def _positive_number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValidationError("%s must be a positive number" % name)
    return float(value)


def validate_fields(body, runtime, opts, check_workspace=True, partial=False):
    """Validate the user-controlled fields; returns the normalized dict.

    `partial` skips the prompt requirement (used for schedule templates
    that are completed later)."""
    if not isinstance(body, dict):
        raise ValidationError("task must be a JSON object")
    unknown = sorted(set(body) - SUBMIT_FIELDS)
    if unknown:
        raise ValidationError("unknown field(s): %s" % ", ".join(unknown))

    agent = body.get("agent")
    if not isinstance(agent, str) or not configmod.valid_agent_id(agent) or agent not in runtime.get("agents", {}):
        raise ValidationError("unknown agent %r (see: agentos agents)" % (agent if isinstance(agent, str) else None))

    workspace = resolve_workspace(body.get("workspace"), runtime["workspace_root"], must_exist=check_workspace)

    prompt = body.get("prompt")
    if not isinstance(prompt, str) or (not prompt and not partial):
        raise ValidationError("prompt must be a non-empty string")
    if "\0" in prompt:
        raise ValidationError("prompt must not contain NUL bytes")
    if len(prompt.encode()) > int(opts["max_prompt_bytes"]):
        raise ValidationError("prompt is longer than %d bytes" % int(opts["max_prompt_bytes"]))
    if prompt.startswith("-"):
        # It would be parsed as an option by the agent's command line
        raise ValidationError("prompt must not start with '-'")

    out = {"agent": agent, "workspace": workspace, "prompt": prompt}

    budget = body.get("budget_usd")
    out["budget_usd"] = None if budget is None else _positive_number(budget, "budget_usd")

    timeout = body.get("timeout_sec")
    if timeout is None:
        timeout = opts["default_timeout_sec"]
    if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= int(opts["max_timeout_sec"]):
        raise ValidationError("timeout_sec must be an integer between 1 and %d" % int(opts["max_timeout_sec"]))
    out["timeout_sec"] = timeout

    deps = body.get("depends_on", body.get("after")) or []
    if isinstance(deps, str):
        deps = [deps]
    if not isinstance(deps, list) or len(deps) > 64 or not all(isinstance(d, str) and configmod.valid_agent_id(d) for d in deps):
        raise ValidationError("depends_on must be a list of task ids")
    out["depends_on"] = list(dict.fromkeys(deps))

    group = body.get("group")
    if group is not None and (not isinstance(group, str) or not configmod.valid_agent_id(group)):
        raise ValidationError("invalid group name")
    out["group"] = group

    isolate = body.get("isolate", False)
    if not isinstance(isolate, bool):
        raise ValidationError("isolate must be a boolean")
    out["isolate"] = isolate

    origin = body.get("origin")
    if origin is not None and (not isinstance(origin, str) or len(origin) > 100 or not origin.isprintable()):
        raise ValidationError("invalid origin")
    out["origin"] = origin

    if _PREV.search(prompt) and not out["depends_on"] and not partial:
        raise ValidationError("prompt uses {prev_result} but the task has no dependency")
    return out


def validate_swarm(body, opts):
    swarm = body.get("swarm", 1)
    if isinstance(swarm, bool) or not isinstance(swarm, int) or not 1 <= swarm <= int(opts["max_swarm"]):
        raise ValidationError("swarm must be an integer between 1 and %d" % int(opts["max_swarm"]))
    return swarm


def validate_record(task, runtime, opts):
    """Re-validate a stored task (run by the root task runner).

    Checks the same rules as a submission plus the fields only the
    orchestrator sets. Returns the task with a normalized workspace."""
    if not isinstance(task, dict) or not configmod.valid_agent_id(task.get("id")):
        raise ValidationError("malformed task record")
    fields = {k: task.get(k) for k in SUBMIT_FIELDS if k in task}
    fields.pop("swarm", None)
    checked = validate_fields(fields, runtime, opts)
    resolved = task.get("resolved_prompt")
    if resolved is not None:
        if not isinstance(resolved, str) or "\0" in resolved or resolved.startswith("-") \
                or len(resolved.encode()) > MAX_ARG_BYTES:
            raise ValidationError("invalid resolved prompt")
    out = dict(task, **checked)
    out["resolved_prompt"] = resolved if resolved is not None else checked["prompt"]
    return out


def task_command(opts, runtime, agent):
    """The argv template for an agent: by agent name, else by its command."""
    templates = opts["task_commands"]
    template = templates.get(agent) or templates.get(runtime["agents"].get(agent, ""))
    if not template or not isinstance(template, list) or not all(isinstance(t, str) for t in template):
        raise ValidationError("no task command is configured for agent %s (agentos.orchestration.taskCommands)" % agent)
    return template


def render_argv(template, prompt, workspace, task_id):
    """Fill placeholders in one pass; the prompt is never re-scanned."""
    values = {"prompt": prompt, "workspace": workspace, "task_id": task_id}
    return [_PLACEHOLDER.sub(lambda m: values[m.group(1)], part) for part in template]


def expand_prompt(prompt, dependency_results):
    """Substitute {prev_result} (single pass, so output is never re-expanded).

    Results are joined in dependency order and cut from the front if the
    prompt would not fit in one argv element."""
    joined = "\n\n---\n\n".join(dependency_results)
    room = max(0, MAX_ARG_BYTES - len(_PREV.sub("", prompt).encode()) - 64)
    raw = joined.encode()
    if len(raw) > room:
        joined = "[...]" + raw[len(raw) - room:].decode(errors="ignore")
    return _PREV.sub(lambda _m: joined, prompt)


# ── storage ──────────────────────────────────────────────────────────────
def new_id(prefix="task", clock=time.time):
    return "%s-%s-%s" % (prefix, time.strftime("%Y%m%d-%H%M%S", time.gmtime(clock())), uuid.uuid4().hex[:6])


class TaskStore:
    """Tasks in Redis; wraps a Store for its client, clock and key prefix."""

    def __init__(self, store):
        self.store = store
        self.r = store.r
        self.clock = store.clock

    def _k(self, *parts):
        return self.store._k(*parts)

    def create(self, task):
        key = self._k("task", task["id"])
        p = self.r.pipeline()
        p.set(key, json.dumps(task), ex=TASK_TTL)
        p.zadd(self._k("tasks"), {task["id"]: task["created_at"]})
        p.sadd(self._k("tasks", "active"), task["id"])
        if task.get("group"):
            p.sadd(self._k("group", task["group"]), task["id"])
        p.execute()
        return task

    def get(self, task_id):
        if not configmod.valid_agent_id(task_id):
            return None
        raw = self.r.get(self._k("task", task_id))
        return json.loads(raw) if raw else None

    def update(self, task_id, mutate):
        """Atomic read-modify-write. `mutate(task)` edits in place and returns
        True to store the change; the (possibly unchanged) task is returned,
        or None when it does not exist."""
        key = self._k("task", task_id)
        with self.r.pipeline() as p:
            while True:
                try:
                    p.watch(key)
                    raw = p.get(key)
                    if raw is None:
                        p.unwatch()
                        return None
                    task = json.loads(raw)
                    if not mutate(task):
                        p.unwatch()
                        return task
                    p.multi()
                    terminal = task["status"] in TERMINAL
                    p.set(key, json.dumps(task), ex=TASK_TTL)
                    if terminal:
                        p.srem(self._k("tasks", "active"), task_id)
                    p.execute()
                    return task
                except redis.WatchError:
                    continue

    def finish(self, task_id, status, **result):
        """Move a task to a terminal state unless it already is in one."""
        def mutate(task):
            if task["status"] in TERMINAL:
                return False
            task["status"] = status
            task["finished_at"] = self.clock()
            task["result"] = dict(task.get("result") or {}, **result)
            return True
        return self.update(task_id, mutate)

    def active_ids(self):
        return sorted(self.r.smembers(self._k("tasks", "active")))

    def active(self):
        tasks = [self.get(i) for i in self.active_ids()]
        tasks = [t for t in tasks if t]
        return sorted(tasks, key=lambda t: (t["created_at"], t["id"]))

    def list(self, status=None, group=None, limit=100):
        if group:
            ids = sorted(self.r.smembers(self._k("group", group)))
        else:
            ids = self.r.zrevrange(self._k("tasks"), 0, max(0, int(limit)) * 2 + 50)
        out = []
        for task_id in ids:
            task = self.get(task_id)
            if task is None:
                self.r.zrem(self._k("tasks"), task_id)
                continue
            if status and task["status"] != status:
                continue
            out.append(task)
        out.sort(key=lambda t: (t["created_at"], t["id"]), reverse=not group)
        return out[:int(limit)]

    def group_ids(self, group):
        return sorted(self.r.smembers(self._k("group", group)))
