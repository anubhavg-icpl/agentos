"""Task model, validation and Redis storage for the orchestrator.

A task is one non-interactive agent run:

    {id, agent, workspace, prompt, budget_usd, timeout_sec, depends_on[],
     group, isolate, origin, status, result, created_at, started_at,
     finished_at}

Status flow: [awaiting_approval ->] queued -> running -> succeeded | failed |
timeout | cancelled, or queued -> skipped (a dependency did not succeed, or
the node's `when` is false) / cancelled. A failed or timed-out task with
retries left goes back from running to queued (see TaskStore.finish).

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
  groupmeta:<name>     JSON    {members, judge_task, winner} of a judged swarm
  dedupe:<key>         string  id of the live task that owns a dedupe_key
"""

import json
import math
import os
import re
import time
import uuid

import redis

from . import config as configmod

QUEUED, RUNNING, AWAITING = "queued", "running", "awaiting_approval"
SUCCEEDED, FAILED, TIMEOUT, CANCELLED, SKIPPED = "succeeded", "failed", "timeout", "cancelled", "skipped"
TERMINAL = {SUCCEEDED, FAILED, TIMEOUT, CANCELLED, SKIPPED}

# Hard ceilings that apply whatever the configuration or a stored record says
MAX_RETRIES_HARD = 10
MAX_BACKOFF_HARD = 24 * 3600
MAX_ATTEMPT_TAIL = 2048

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
        "max_workflow_nodes": 50,
        "max_retries_cap": 5,
        "default_backoff_sec": 10,
        "max_backoff_sec": 3600,
        "max_priority": 1000,
        "judge_tail_chars": 4000,
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
    "gate", "max_retries", "backoff_sec", "verify", "judge", "priority",
    "concurrency_key", "dedupe_key", "publish",
}
_PLACEHOLDER = re.compile(r"\{(prompt|workspace|task_id)\}")
_PREV = re.compile(r"\{prev_result\}")
NODE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}")
_NODEREF = re.compile(r"\{nodes\.([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.result\}")
_KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@-]{0,99}")


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


def validate_fields(body, runtime, opts, check_workspace=True, partial=False, node_refs=None):
    """Validate the user-controlled fields; returns the normalized dict.

    `partial` skips the prompt requirement (used for schedule templates
    that are completed later). `node_refs` is the set of node names a
    {nodes.<name>.result} placeholder may name (workflow nodes); None
    refuses such placeholders, True skips the check (stored records)."""
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

    gate = body.get("gate", False)
    if not isinstance(gate, bool):
        raise ValidationError("gate must be a boolean")
    out["gate"] = gate

    out["priority"] = _bounded_int(body.get("priority", 0), "priority", -int(opts["max_priority"]), int(opts["max_priority"]))
    cap = min(int(opts["max_retries_cap"]), MAX_RETRIES_HARD)
    out["max_retries"] = _bounded_int(body.get("max_retries", 0), "max_retries", 0, cap)
    backoff = body.get("backoff_sec")
    if backoff is None:
        backoff = opts["default_backoff_sec"]
    if isinstance(backoff, bool) or not isinstance(backoff, (int, float)) or not math.isfinite(backoff) \
            or not 0 <= backoff <= min(int(opts["max_backoff_sec"]), MAX_BACKOFF_HARD):
        raise ValidationError("backoff_sec must be a number between 0 and %d" % int(opts["max_backoff_sec"]))
    out["backoff_sec"] = float(backoff)
    for name in ("concurrency_key", "dedupe_key"):
        value = body.get(name)
        if value is not None and (not isinstance(value, str) or not _KEY.fullmatch(value)):
            raise ValidationError("invalid %s" % name)
        out[name] = value
    out["verify"] = validate_verify(body.get("verify"))
    out["publish"] = validate_publish(body.get("publish"))

    if _PREV.search(prompt) and not out["depends_on"] and not partial:
        raise ValidationError("prompt uses {prev_result} but the task has no dependency")
    refs = set(_NODEREF.findall(prompt))
    if refs and node_refs is not True:
        unknown = sorted(refs - set(node_refs or ()))
        if unknown:
            raise ValidationError("prompt refers to node(s) it does not depend on: %s" % ", ".join(unknown))
    return out


_REPO = re.compile(r"[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}")


def validate_publish(block):
    """A request to open a pull request after the task succeeds.

    Only {repo, title, body} are accepted; whether and where the branch is
    pushed is decided by root-owned configuration (see publish.py)."""
    if block is None:
        return None
    if not isinstance(block, dict) or set(block) - {"repo", "title", "body"}:
        raise ValidationError("publish must be an object with only repo, title and body")
    out = {}
    repo = block.get("repo")
    if repo is not None:
        if not isinstance(repo, str) or not _REPO.fullmatch(repo):
            raise ValidationError("publish.repo must look like owner/name")
        out["repo"] = repo
    for key, cap in (("title", 200), ("body", 4000)):
        value = block.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or "\0" in value or len(value) > cap:
            raise ValidationError("publish.%s must be a string of at most %d characters" % (key, cap))
        out[key] = value
    return out


def _bounded_int(value, name, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValidationError("%s must be an integer between %d and %d" % (name, low, high))
    return value


def validate_verify(verify):
    """`verify: {cmd: [argv...], timeout_sec?}`: an argument vector, never a shell string."""
    if verify is None:
        return None
    if not isinstance(verify, dict) or set(verify) - {"cmd", "timeout_sec"}:
        raise ValidationError("verify must be an object with cmd (and optionally timeout_sec)")
    cmd = verify.get("cmd")
    if not isinstance(cmd, list) or not 1 <= len(cmd) <= 32 or not all(isinstance(a, str) for a in cmd):
        raise ValidationError("verify.cmd must be a list of 1-32 strings")
    if not cmd[0] or cmd[0].startswith("-"):
        raise ValidationError("verify.cmd[0] must be a program name or path")
    if any("\0" in a or len(a.encode()) > 4096 for a in cmd) or sum(len(a.encode()) for a in cmd) > 16384:
        raise ValidationError("verify.cmd contains a NUL byte or is too long")
    timeout = _bounded_int(verify.get("timeout_sec", 600), "verify.timeout_sec", 1, 3600)
    return {"cmd": list(cmd), "timeout_sec": timeout}


def validate_judge(judge, runtime, opts):
    """`judge: {agent, prompt, budget_usd?, timeout_sec?}` for a swarm."""
    if not isinstance(judge, dict) or set(judge) - {"agent", "prompt", "budget_usd", "timeout_sec"}:
        raise ValidationError("judge must be an object with agent and prompt")
    checked = validate_fields({"agent": judge.get("agent"), "workspace": runtime["workspace_root"] + "/judge", "prompt": judge.get("prompt"),
                               "budget_usd": judge.get("budget_usd"), "timeout_sec": judge.get("timeout_sec")},
                              runtime, opts, check_workspace=False)
    task_command(opts, runtime, checked["agent"])
    return {k: checked[k] for k in ("agent", "prompt", "budget_usd", "timeout_sec")}


# ── the `when` condition of a workflow node ──────────────────────────────
# A fixed grammar, parsed by hand and never evaluated as code:
#   expr  := and ( "or" and )*
#   and   := not ( "and" not )*
#   not   := "not" not | "(" expr ")" | atom
#   atom  := all_succeeded | any_succeeded | any_failed | all_failed | always
#          | node:<name>=<succeeded|failed|timeout|skipped|cancelled>
WHEN_MAX_CHARS = 200
WHEN_MAX_DEPTH = 8
_WHEN_ATOMS = {"all_succeeded", "any_succeeded", "any_failed", "all_failed", "always"}
_WHEN_STATES = {SUCCEEDED, FAILED, TIMEOUT, SKIPPED, CANCELLED}
_WHEN_TOKEN = re.compile(r"\s*(?:(\()|(\))|(node:[A-Za-z0-9][A-Za-z0-9_-]{0,31}=[a-z]+)|([a-z_]+))")


def parse_when(text, nodes=None):
    """Parse a `when` expression into a tuple tree; ValidationError if it is not in the grammar.
    `nodes`, when given, is the set of node names a node:<name>= test may use."""
    if not isinstance(text, str) or not text.strip() or len(text) > WHEN_MAX_CHARS or not text.isascii() or not text.isprintable():
        raise ValidationError("when must be a short expression (at most %d characters)" % WHEN_MAX_CHARS)
    tokens, pos = [], 0
    while text[pos:].strip():
        m = _WHEN_TOKEN.match(text, pos)
        if not m or len(tokens) >= 64:
            raise ValidationError("when: unexpected input at %r" % text[pos:pos + 12].strip())
        tokens.append(next(g for g in m.groups() if g))
        pos = m.end()
    state = {"i": 0}

    def peek():
        return tokens[state["i"]] if state["i"] < len(tokens) else None

    def take():
        tok = peek()
        state["i"] += 1
        return tok

    def expr(depth):
        if depth > WHEN_MAX_DEPTH:
            raise ValidationError("when: nested too deeply")
        left = conj(depth)
        while peek() == "or":
            take()
            left = ("or", left, conj(depth))
        return left

    def conj(depth):
        left = neg(depth)
        while peek() == "and":
            take()
            left = ("and", left, neg(depth))
        return left

    def neg(depth):
        tok = take()
        if tok is None:
            raise ValidationError("when: expression ends too early")
        if tok == "not":
            if depth + 1 > WHEN_MAX_DEPTH:
                raise ValidationError("when: nested too deeply")
            return ("not", neg(depth + 1))
        if tok == "(":
            inner = expr(depth + 1)
            if take() != ")":
                raise ValidationError("when: missing ')'")
            return inner
        if tok in _WHEN_ATOMS:
            return ("atom", tok)
        if tok.startswith("node:"):
            name, _, state_name = tok[5:].partition("=")
            if state_name not in _WHEN_STATES:
                raise ValidationError("when: unknown status %r in %s" % (state_name, tok))
            if nodes is not None and name not in nodes:
                raise ValidationError("when: node %r is not a dependency of this node" % name)
            return ("node", name, state_name)
        raise ValidationError("when: unexpected %r" % tok)

    tree = expr(0)
    if peek() is not None:
        raise ValidationError("when: unexpected %r" % peek())
    return tree


def _failed(status):
    return status in (FAILED, TIMEOUT)


def eval_when(tree, deps):
    """Evaluate a parsed `when` over terminal dependency tasks."""
    kind = tree[0]
    if kind == "atom":
        statuses = [d["status"] for d in deps]
        return {
            "all_succeeded": lambda: all(s == SUCCEEDED for s in statuses),
            "any_succeeded": lambda: any(s == SUCCEEDED for s in statuses),
            "any_failed": lambda: any(_failed(s) for s in statuses),
            "all_failed": lambda: bool(statuses) and all(_failed(s) for s in statuses),
            "always": lambda: True,
        }[tree[1]]()
    if kind == "node":
        for d in deps:
            if d.get("node") == tree[1]:
                return _failed(d["status"]) if tree[2] == FAILED else d["status"] == tree[2]
        return False
    if kind == "not":
        return not eval_when(tree[1], deps)
    if kind == "and":
        return eval_when(tree[1], deps) and eval_when(tree[2], deps)
    return eval_when(tree[1], deps) or eval_when(tree[2], deps)


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
    fields.pop("judge", None)
    checked = validate_fields(fields, runtime, opts, node_refs=True)
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


def expand_prompt(prompt, dependency_results, node_results=None, results=None):
    """Substitute {prev_result}, {nodes.<name>.result} and (judges) {results}.

    One pass, so substituted output is never re-expanded. {prev_result} is
    the dependencies' results joined in dependency order; each value is cut
    from the front to its share of what fits in one argv element."""
    node_results = node_results or {}
    names = r"\{prev_result\}|\{nodes\.([A-Za-z0-9][A-Za-z0-9_-]{0,31})\.result\}"
    pattern = re.compile(names + (r"|\{results\}" if results is not None else ""))
    count = len(pattern.findall(prompt))
    room = max(0, MAX_ARG_BYTES - len(pattern.sub("", prompt).encode()) - 64)
    share = room // max(1, count)
    joined = "\n\n---\n\n".join(dependency_results)

    def clip(text):
        raw = text.encode()
        if len(raw) <= share:
            return text
        return "[...]" + raw[len(raw) - max(0, share - 5):].decode(errors="ignore")

    def value(m):
        if m.group(0) == "{prev_result}":
            return clip(joined)
        if m.group(0) == "{results}":
            return clip(results)
        return clip(node_results.get(m.group(1), ""))
    return pattern.sub(value, prompt)


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
        """Store a task. With a dedupe_key, an existing task that has not
        finished and shares the key is returned instead (check its id)."""
        def queue(p):
            p.set(self._k("task", task["id"]), json.dumps(task), ex=TASK_TTL)
            p.zadd(self._k("tasks"), {task["id"]: task["created_at"]})
            p.sadd(self._k("tasks", "active"), task["id"])
            if task.get("group"):
                p.sadd(self._k("group", task["group"]), task["id"])

        dkey = task.get("dedupe_key")
        if not dkey:
            p = self.r.pipeline()
            queue(p)
            p.execute()
            return task
        dk = self._k("dedupe", dkey)
        with self.r.pipeline() as p:
            while True:
                try:
                    p.watch(dk)
                    existing = self.get(p.get(dk) or "")
                    if existing and existing["status"] not in TERMINAL:
                        p.unwatch()
                        return existing
                    p.multi()
                    queue(p)
                    p.set(dk, task["id"], ex=TASK_TTL)
                    p.execute()
                    return task
                except redis.WatchError:
                    continue

    def group_meta(self, group):
        raw = self.r.get(self._k("groupmeta", group))
        return json.loads(raw) if raw else None

    def set_group_meta(self, group, meta):
        self.r.set(self._k("groupmeta", group), json.dumps(meta), ex=TASK_TTL)

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
        """Move a task to a terminal state unless it already is in one.

        A running task that failed or timed out goes back to `queued`
        instead when it has retries left (attempt <= max_retries): it waits
        backoff_sec * 2^(attempt-1) seconds, and every attempt's result is
        kept in `attempts`. The runner calls this too, so retries need no
        cooperation from it."""
        now = self.clock()

        def mutate(task):
            if task["status"] in TERMINAL:
                return False
            was_running = task["status"] == RUNNING
            merged = dict(task.get("result") or {}, **result)
            attempt = int(task.get("attempt") or 1)
            if task.get("started_at"):
                entry = {"attempt": attempt, "status": status, "started_at": task["started_at"], "finished_at": now,
                         "exit_code": merged.get("exit_code"), "error": merged.get("error"),
                         "branch": merged.get("branch"),
                         "output_tail": (merged.get("output_tail") or "")[-MAX_ATTEMPT_TAIL:]}
                task["attempts"] = (list(task.get("attempts") or []) + [entry])[-(MAX_RETRIES_HARD + 1):]
            retries = min(int(task.get("max_retries") or 0), MAX_RETRIES_HARD)
            error = str(merged.get("error") or "")
            if was_running and status in (FAILED, TIMEOUT) and attempt <= retries \
                    and not error.startswith(("stopped:", "rejected:")):
                delay = min(float(task.get("backoff_sec") or 0) * 2 ** (attempt - 1), MAX_BACKOFF_HARD)
                task.update(status=QUEUED, attempt=attempt + 1, not_before=now + delay, started_at=None,
                            finished_at=None, result=None)
                task.pop("resolved_prompt", None)
                return True
            task["status"] = status
            task["finished_at"] = now
            task["result"] = merged
            return True
        task = self.update(task_id, mutate)
        if task and task.get("role") == "judge" and task["status"] == SUCCEEDED:
            self._record_winner(task)
        return task

    def _record_winner(self, judge_task):
        """A judge's first output line `winner: <task-id>` names the winning member."""
        meta = self.group_meta(judge_task.get("group") or "")
        if meta is None:
            return
        first = next((ln.strip() for ln in ((judge_task.get("result") or {}).get("output_tail") or "").splitlines()
                      if ln.strip()), "")
        m = re.match(r"(?i)^winner:\s*([A-Za-z0-9][A-Za-z0-9._-]{0,63})$", first)
        if m and m.group(1) in meta.get("members", []):
            meta["winner"], meta["winner_error"] = m.group(1), None
        else:
            meta["winner"], meta["winner_error"] = None, "judge's first line is not 'winner: <member task id>'"
        self.set_group_meta(judge_task["group"], meta)

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
