"""AgentOS orchestrator.

Runs coding agents headless, as tasks (see tasks.py), with dependencies and
a concurrency limit:

  * single task     agentos-task submit --agent claude --workspace w --prompt ...
  * pipeline        --after <task-id>: starts when the task succeeded; the
                    prompt may contain {prev_result} (the earlier task's
                    output) and the tasks share the workspace one after another
  * swarm           --swarm N: N tasks with the same prompt, running in
                    parallel, each in its own git worktree on its own branch

The orchestrator (user agentos, no sudo) never starts an agent itself. To
run task <id> it starts the systemd unit agentos-task-runner@<id>.service
(a polkit rule allows exactly that); the root helper in taskrunner.py
re-validates the task and launches the same sandbox `agentos spawn` uses.

API on a unix socket (group agentos):
  GET    /health
  POST   /tasks                 submit (body: see tasks.SUBMIT_FIELDS)
  GET    /tasks[?status=&group=&limit=]
  GET    /tasks/<id>
  POST   /tasks/<id>/cancel     a task id, or a group id (cancels its tasks)
  GET    /groups/<name>         counts, tasks, node -> id map, judge winner
  POST   /tasks/<id>/approve    {note?} release a gated task (awaiting_approval)
  POST   /tasks/<id>/reject     {note?} cancel it and everything depending on it
  POST   /workflows             {nodes: {name: {...task fields, depends_on, when}}}
  GET    /workflows/<group>     same as /groups/<group>

Beyond the above: approval gates, DAG workflows with `when` conditions,
retries with exponential back-off (tasks.TaskStore.finish), swarm verify and
judge, priorities, concurrency keys and dedupe keys. See docs/orchestration.md.
"""

import argparse
import json
import logging
import os
import pwd
import signal
import subprocess
import sys
import threading
import time

from . import config as configmod
from . import policy as policymod
from . import rbac as rbacmod
from . import tasks as T
from . import unixapi
from .store import Store, connect
from . import health as healthmod
from .unixapi import ApiError, serve_unix

log = logging.getLogger("agentos.orchestrator")

ALIVE_STATES = {"active", "activating", "reloading", "deactivating"}


def _run(cmd, timeout=60):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False, timeout=timeout)


def count_running_agents(state_dir, exclude=()):
    """Running agents in the daemon's registry, except the ids in `exclude`."""
    n = 0
    try:
        names = os.listdir(state_dir)
    except OSError:
        return 0
    for name in names:
        if not name.endswith(".json") or name[:-5] in exclude:
            continue
        try:
            with open(os.path.join(state_dir, name)) as f:
                if json.load(f).get("status") == "running":
                    n += 1
        except (OSError, ValueError):
            continue
    return n


def peer_identity(peer):
    """(name, uid) of a socket client from SO_PEERCRED credentials."""
    if not peer:
        return "unknown", None
    uid = peer.get("uid")
    try:
        return pwd.getpwuid(uid).pw_name, uid
    except (KeyError, TypeError):
        return str(uid), uid


def _note(value):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > 1000 or "\0" in value:
        raise T.ValidationError("note must be text of at most 1000 characters")
    return value


class Orchestrator:
    def __init__(self, cfg, tasks, runtime=None, clock=time.time, runner=_run, agents_running=None):
        self.cfg = cfg
        self.opts = T.settings(cfg, "orchestrator")
        self.tasks = tasks
        self.tasks.clock = clock       # retry back-off and the scheduling loop must share one clock
        self._runtime = runtime
        self.clock = clock
        self.run_cmd = runner
        self.state_dir = cfg["daemon"]["state_dir"]
        self.agents_running = agents_running or (lambda exclude: count_running_agents(self.state_dir, exclude))
        self.lock = threading.RLock()
        self._seq = 0
        self.policy = policymod.Policy.from_config(cfg)
        self.rbac = rbacmod.Rbac(cfg)
        self.tick_beat = healthmod.Heartbeat(clock)   # last successful scheduling pass
        self.health = healthmod.Health("orchestrator", {
            "redis": healthmod.redis_check(self.tasks.store),
            "loop": healthmod.heartbeat_check(self.tick_beat, self.tick_limit()),
        })

    def runtime(self):
        return self._runtime if self._runtime is not None else T.load_runtime(self.opts["runtime_file"])

    def unit(self, task_id):
        return "%s%s.service" % (self.opts["runner_unit_prefix"], task_id)

    # ── submission ─────────────────────────────────────────────────────
    def _check_origin(self, origin, peer):
        """The origin the OpenClaw bridge stamps is reserved for the bridge's own user."""
        if origin == T.RESERVED_ORIGIN and (not peer or peer_identity(peer)[0] != self.opts["bridge_user"]):
            raise ApiError(403, "origin %r is reserved for %s" % (origin, self.opts["bridge_user"]))

    def _apply_policy(self, fields, rt, count=1, reserve=None, judge=False):
        """Resolve and enforce the policy of a task; sets fields["policy"].
        `reserve` ({entry name: usd}) carries the budget committed earlier in
        the same request. Refusals are 403 errors that name the rule."""
        if not self.policy.enabled:
            return
        name, eff = self.policy.resolve(policymod.candidates(fields, rt.get("workspace_root")))
        reserve = reserve if reserve is not None else {}
        spent = 0.0
        if eff.get("daily_budget_usd") is not None and not judge:
            spent = policymod.day_spent(self.tasks.list(limit=1000), name, self.clock())
        try:
            rec = policymod.enforce(eff, name, self.policy.version, fields, rt, spent_today=spent,
                                    reserved=reserve.get(name, 0.0), count=count, judge=judge)
        except policymod.PolicyError as exc:
            raise ApiError(403, str(exc))
        if not judge:
            reserve[name] = reserve.get(name, 0.0) + (fields.get("budget_usd") or 0.0) * count
            fields["policy"] = rec
        return rec

    def _new_task(self, fields, group, now, submitter, **extra):
        # The sequence number keeps FIFO order for tasks queued in the same instant
        self._seq += 1
        task = dict(fields, group=group, id=T.new_id("task", self.clock),
                    status=T.AWAITING if fields.get("gate") else T.QUEUED,
                    created_at=now + self._seq * 1e-6, started_at=None, finished_at=None, result=None,
                    attempt=1, attempts=[], not_before=None, node=None, when=None, role=None,
                    submitted_by=submitter)
        task.update(extra)
        return task

    def submit(self, body, peer=None):
        """Validate and queue a task (or a swarm). Returns the new tasks."""
        return self.submit_ex(body, peer)[0]

    def submit_ex(self, body, peer=None):
        """Like submit; returns (tasks, deduplicated). When a live task with the
        same dedupe_key exists, that task is returned and nothing is queued."""
        if not isinstance(body, dict):
            raise T.ValidationError("task must be a JSON object")
        rt = self.runtime()
        swarm = T.validate_swarm(body, self.opts)
        fields = T.validate_fields({k: v for k, v in body.items() if k not in ("swarm", "judge")}, rt, self.opts)
        T.task_command(self.opts, rt, fields["agent"])
        self._check_origin(fields.get("origin"), peer)
        judge = None
        if body.get("judge") is not None:
            if swarm < 2:
                raise T.ValidationError("judge needs a swarm of at least 2")
            judge = T.validate_judge(body["judge"], rt, self.opts)
        if fields["dedupe_key"] and swarm > 1:
            raise T.ValidationError("dedupe_key cannot be combined with swarm")
        for dep in fields["depends_on"]:
            if self.tasks.get(dep) is None:
                raise T.ValidationError("unknown dependency: %s" % dep)
        group = fields["group"]
        if swarm > 1:
            group = group or T.new_id("swarm", self.clock)
            fields["isolate"] = True
        submitter = peer_identity(peer)[0] if peer else None
        now = self.clock()
        created = []
        with self.lock:
            self._apply_policy(fields, rt, count=swarm)
            if judge:
                jf = dict(fields, **judge)
                self._apply_policy(jf, rt, judge=True)
                judge["budget_usd"] = jf["budget_usd"]
            for _ in range(swarm):
                task = self._new_task(fields, group, now, submitter)
                stored = self.tasks.create(task)
                if stored["id"] != task["id"]:
                    return [stored], True        # a live task owns this dedupe_key
                created.append(stored)
            if judge:
                members = [t["id"] for t in created]
                created.append(self.tasks.create(self._new_task(
                    dict(fields, **judge, gate=False, max_retries=0, verify=None, dedupe_key=None,
                         concurrency_key=None, isolate=False, depends_on=members),
                    group, now, submitter, when="any_succeeded", role="judge")))
                self.tasks.set_group_meta(group, {"members": members, "judge_task": created[-1]["id"],
                                                  "winner": None, "winner_error": None})
        log.info("queued %s", ", ".join(t["id"] for t in created))
        return created, False

    def submit_workflow(self, body, peer=None):
        """Expand {nodes: {name: {...task fields, depends_on: [names], when}}}
        into tasks that share a group. Returns (group, {node name: task})."""
        if not isinstance(body, dict) or set(body) - {"nodes", "group", "origin"}:
            raise T.ValidationError("workflow must be an object with nodes (and optionally group, origin)")
        nodes = body.get("nodes")
        cap = int(self.opts["max_workflow_nodes"])
        if not isinstance(nodes, dict) or not nodes:
            raise T.ValidationError("workflow.nodes must be a non-empty object")
        if len(nodes) > cap:
            raise T.ValidationError("a workflow may have at most %d nodes" % cap)
        rt = self.runtime()
        group = body.get("group")
        if group is not None and (not isinstance(group, str) or not configmod.valid_agent_id(group)):
            raise T.ValidationError("invalid group name")
        if group and self.tasks.group_ids(group):
            raise T.ValidationError("group %s already exists" % group)
        group = group or T.new_id("wf", self.clock)

        deps = {}
        for name, spec in nodes.items():
            if not isinstance(name, str) or not T.NODE_NAME.fullmatch(name):
                raise T.ValidationError("invalid node name %r (letters, digits, - and _; at most 32)" % str(name)[:40])
            if not isinstance(spec, dict):
                raise T.ValidationError("node %s must be an object" % name)
            bad = sorted(set(spec) & {"swarm", "judge", "group", "after", "dedupe_key"})
            if bad:
                raise T.ValidationError("node %s: %s not allowed in a workflow node" % (name, ", ".join(bad)))
            listed = spec.get("depends_on") or []
            if not isinstance(listed, list) or not all(isinstance(d, str) for d in listed):
                raise T.ValidationError("node %s: depends_on must be a list of node names" % name)
            for d in listed:
                if d == name:
                    raise T.ValidationError("node %s depends on itself" % name)
                if d not in nodes:
                    raise T.ValidationError("node %s depends on unknown node %s" % (name, str(d)[:40]))
            deps[name] = list(dict.fromkeys(listed))

        # Kahn's algorithm: topological order, and whatever is left is a cycle
        order, remaining = [], {n: set(d) for n, d in deps.items()}
        while True:
            free = [n for n, d in remaining.items() if not d]
            if not free:
                break
            for n in free:
                order.append(n)
                del remaining[n]
            for d in remaining.values():
                d.difference_update(free)
        if remaining:
            raise T.ValidationError("workflow has a dependency cycle through: %s" % ", ".join(sorted(remaining)))
        ancestors = {}
        for n in order:
            ancestors[n] = set(deps[n]).union(*(ancestors[d] for d in deps[n])) if deps[n] else set()

        ids = {n: T.new_id("task", self.clock) for n in order}
        records = []
        reserve = {}
        for n in order:
            spec = {k: v for k, v in nodes[n].items() if k not in ("depends_on", "when")}
            spec["depends_on"] = [ids[d] for d in deps[n]]
            if body.get("origin") is not None and "origin" not in spec:
                spec["origin"] = body["origin"]
            try:
                fields = T.validate_fields(spec, rt, self.opts, node_refs=ancestors[n])
                T.task_command(self.opts, rt, fields["agent"])
                when = nodes[n].get("when")
                if when is not None:
                    T.parse_when(when, nodes=set(deps[n]))
            except T.ValidationError as exc:
                raise T.ValidationError("node %s: %s" % (n, exc))
            self._check_origin(fields.get("origin"), peer)
            with self.lock:
                try:
                    self._apply_policy(fields, rt, reserve=reserve)
                except ApiError as exc:
                    raise ApiError(exc.status, "node %s: %s" % (n, exc.message))
            records.append((n, fields, None if when is None else when.strip()))

        submitter = peer_identity(peer)[0] if peer else None
        now = self.clock()
        created = {}
        with self.lock:
            for n, fields, when in records:
                task = self._new_task(dict(fields, group=group), group, now, submitter, node=n, when=when)
                task["id"] = ids[n]
                created[n] = self.tasks.create(task)
        log.info("workflow %s: queued %d nodes", group, len(created))
        return group, created

    # ── control ────────────────────────────────────────────────────────
    def cancel(self, ident, caller=None):
        """Cancel one task, or every unfinished task of a group. With RBAC,
        `caller` (an identity from Rbac.identity) may only cancel its own
        tasks unless it is an admin."""
        task = self.tasks.get(ident)
        ids = [ident] if task else self.tasks.group_ids(ident)
        if not ids:
            raise ApiError(404, "no such task or group: %s" % ident)
        if caller is not None:
            for task_id in ids:
                current = self.tasks.get(task_id)
                if current and current["status"] not in T.TERMINAL and not self.rbac.may_cancel(caller, current):
                    raise ApiError(403, "rbac: %s may cancel only their own tasks; %s was submitted by %s (role required: admin)" % (
                        caller["name"], task_id, current.get("submitted_by") or "unknown"))
        cancelled = []
        for task_id in ids:
            with self.lock:
                current = self.tasks.get(task_id)
                if current is None or current["status"] in T.TERMINAL:
                    continue
                running = current["status"] == T.RUNNING
                if not running:
                    self.tasks.finish(task_id, T.CANCELLED, error="cancelled by operator")
            if running:
                # The runner stops the agent unit on SIGTERM and records the
                # result itself; finish() below only covers a runner that died.
                try:
                    self.run_cmd(["systemctl", "stop", self.unit(task_id)], timeout=60)
                except (OSError, subprocess.SubprocessError) as exc:
                    log.warning("could not stop %s: %s", task_id, exc)
                self.tasks.finish(task_id, T.CANCELLED, error="cancelled by operator")
            cancelled.append(task_id)
        if task and not cancelled:
            raise ApiError(409, "task %s already finished (%s)" % (ident, task["status"]))
        return [self.tasks.get(i) for i in cancelled]

    def decide(self, task_id, approve, peer=None, note=None):
        """Approve or reject a task that is awaiting approval.

        The decision (who, when, note) is recorded on the task. Approving
        queues it; rejecting cancels it and every unfinished task that
        depends on it, directly or not. Returns the tasks that changed."""
        note = _note(note)
        name, uid = peer_identity(peer)
        record = {"decision": "approved" if approve else "rejected", "by": name, "uid": uid,
                  "at": self.clock(), "note": note}

        won = []

        def mutate(task):
            won.clear()          # the update may be retried after a concurrent write
            if task["status"] != T.AWAITING:
                return False
            won.append(True)
            task["approval"] = record
            if approve:
                task["status"] = T.QUEUED
            else:
                task.update(status=T.CANCELLED, finished_at=record["at"],
                            result={"error": "rejected by %s%s" % (name, ": " + note if note else "")})
            return True

        with self.lock:
            current = self.tasks.get(task_id)
            if current is None:
                raise ApiError(404, "no such task: %s" % task_id)
            if self.rbac.separate_approver and current.get("submitted_by") == name:
                raise ApiError(403, "rbac: separate_approver is set; %s submitted %s and cannot %s it" % (
                    name, task_id, "approve" if approve else "reject"))
            updated = self.tasks.update(task_id, mutate)
            if not won:
                raise ApiError(409, "task %s is not awaiting approval (%s)" % (task_id, updated["status"]))
            changed = [updated]
            if not approve:
                doomed = {task_id}
                grew = True
                while grew:
                    grew = False
                    for t in self.tasks.active():
                        if t["id"] not in doomed and doomed & set(t["depends_on"]):
                            doomed.add(t["id"])
                            grew = True
                            changed.append(self.tasks.finish(
                                t["id"], T.CANCELLED, error="dependency %s was rejected" % task_id))
        log.info("%s %s by %s", record["decision"], task_id, name)
        return changed

    # ── scheduling loop ────────────────────────────────────────────────
    def alive(self, task_id):
        try:
            res = self.run_cmd(["systemctl", "show", "-p", "ActiveState", "--value", self.unit(task_id)])
        except (OSError, subprocess.SubprocessError):
            return True  # cannot tell; do not fail the task
        return (res.stdout or "").strip() in ALIVE_STATES

    def _runner_gone(self, task, why):
        log.warning("task %s: runner is gone", task["id"])
        # finish() re-queues the task when it has retries left
        self.tasks.finish(task["id"], T.FAILED, error="%s (see: journalctl -u %s)" % (why, self.unit(task["id"])))

    def _reconcile(self, running):
        grace = float(self.opts["start_grace_sec"])
        for task in running:
            if self.clock() - (task.get("started_at") or 0) < grace or self.alive(task["id"]):
                continue
            self._runner_gone(task, "task runner exited without reporting a result")

    def recover(self):
        """At start-up: tasks marked running whose runner unit is gone (the
        host or the orchestrator restarted) are retried or failed now,
        without waiting for the start grace period."""
        with self.lock:
            for task in self.tasks.active():
                if task["status"] == T.RUNNING and not self.alive(task["id"]):
                    self._runner_gone(task, "task runner is gone after an orchestrator restart")

    def _dependency_state(self, task):
        """'ready', 'wait' or the reason a task must be skipped."""
        deps = []
        for dep_id in task["depends_on"]:
            dep = self.tasks.get(dep_id)
            if dep is None:
                return "dependency %s no longer exists" % dep_id
            deps.append(dep)
        when = task.get("when")
        if not when:
            state = "ready"
            for dep in deps:
                if dep["status"] in T.TERMINAL:
                    if dep["status"] != T.SUCCEEDED:
                        return "dependency %s %s" % (dep["id"], dep["status"])
                else:
                    state = "wait"
            return state
        if any(d["status"] not in T.TERMINAL for d in deps):
            return "wait"
        try:
            ok = T.eval_when(T.parse_when(when), deps)
        except T.ValidationError as exc:
            return "invalid condition: %s" % exc
        return "ready" if ok else "condition not met: %s" % when

    def _free_slots(self, running):
        rt = self.runtime()
        slots = int(self.opts["max_workers"]) - len(running)
        max_agents = rt.get("max_agents")
        if max_agents:
            # Agents started by hand also count against the runtime's limit
            others = self.agents_running(set(self.tasks.active_ids()))
            slots = min(slots, int(max_agents) - others - len(running))
        return slots

    def tick(self):
        with self.lock:
            running = [t for t in self.tasks.active() if t["status"] == T.RUNNING]
            self._reconcile(running)
            now = self.clock()
            running = []
            ready = []
            for task in self.tasks.active():
                if task["status"] == T.RUNNING:
                    running.append(task)
                    continue
                if task["status"] not in (T.QUEUED, T.AWAITING):
                    continue
                state = self._dependency_state(task)
                if state == "ready":
                    # A task awaiting approval holds no slot and does not start
                    if task["status"] == T.QUEUED and (task.get("not_before") or 0) <= now:
                        ready.append(task)
                elif state != "wait":
                    self.tasks.finish(task["id"], T.SKIPPED, error=state)
            if not ready:
                return
            # Higher priority first, then submission order
            ready.sort(key=lambda t: (-int(t.get("priority") or 0), t["created_at"], t["id"]))
            slots = self._free_slots(running)
            busy = {t["workspace"] for t in running if not t.get("isolate")}
            keys = {t["concurrency_key"] for t in running if t.get("concurrency_key")}
            # Policy max_parallel: a concurrency key with a limit above one
            pol_running = {}
            for t in running:
                pk = (t.get("policy") or {}).get("name")
                if pk and (t["policy"].get("max_parallel") or 0) > 0:
                    pol_running[pk] = pol_running.get(pk, 0) + 1
            for task in ready:
                if slots <= 0:
                    break
                key = task.get("concurrency_key")
                if key and key in keys:
                    continue
                pol = task.get("policy") or {}
                if pol.get("max_parallel") and pol_running.get(pol["name"], 0) >= pol["max_parallel"]:
                    continue
                if not task.get("isolate"):
                    # Non-isolated tasks share the working tree: one at a time
                    if task["workspace"] in busy:
                        continue
                    busy.add(task["workspace"])
                if key:
                    keys.add(key)
                if pol.get("max_parallel"):
                    pol_running[pol["name"]] = pol_running.get(pol["name"], 0) + 1
                if self._dispatch(task):
                    slots -= 1

    def _judge_results(self, members):
        """The {results} text of a judge prompt: id, branch, verify status, result tail."""
        limit = int(self.opts["judge_tail_chars"])
        blocks = []
        for m in members:
            res = m.get("result") or {}
            verify = res.get("verify")
            if isinstance(verify, dict):
                vstatus = str(verify.get("status") or "unknown")
            else:
                vstatus = "not_reported" if m.get("verify") else "none"
            tail = (res.get("output_tail") or "")[-limit:]
            blocks.append("task: %s\nbranch: %s\nstatus: %s\nverify: %s\nresult tail:\n%s" % (
                m["id"], res.get("branch") or "-", m["status"], vstatus, tail))
        return "\n\n---\n\n".join(blocks)

    def _dispatch(self, task):
        deps = [self.tasks.get(d) or {} for d in task["depends_on"]]
        tails = [(d.get("result") or {}).get("output_tail", "") for d in deps]
        node_results, results = None, None
        if "{nodes." in task["prompt"] and task.get("group"):
            node_results = {t["node"]: (t.get("result") or {}).get("output_tail", "")
                            for t in self.tasks.list(group=task["group"], limit=1000) if t.get("node")}
        if task.get("role") == "judge":
            results = self._judge_results(deps)
        prompt = T.expand_prompt(task["prompt"], tails, node_results, results) \
            if (tails or node_results or results is not None) else task["prompt"]
        if prompt.startswith("-"):
            prompt = " " + prompt  # never let earlier output look like an option

        def start(t):
            if t["status"] != T.QUEUED:
                return False
            t.update(status=T.RUNNING, started_at=self.clock(), resolved_prompt=prompt)
            return True

        started = self.tasks.update(task["id"], start)
        if not started or started["status"] != T.RUNNING or started.get("resolved_prompt") != prompt:
            return False
        try:
            res = self.run_cmd(["systemctl", "start", "--no-block", self.unit(task["id"])])
            error = None if res.returncode == 0 else (res.stderr or "").strip() or "systemctl start failed"
        except (OSError, subprocess.SubprocessError) as exc:
            error = str(exc)
        if error:
            self.tasks.finish(task["id"], T.FAILED, error="could not start the task runner: " + error)
            log.error("task %s: %s", task["id"], error)
            return False
        log.info("started %s (%s in %s)", task["id"], task["agent"], task["workspace"])
        return True

    def loop(self, stop, notify=None):
        interval = float(self.opts["tick_sec"])
        notify = notify or (lambda msg: None)
        while not stop.is_set():
            try:
                self.tick()
                self.tick_beat.beat()
            except Exception:
                log.exception("scheduling error")
            # A hung tick never gets here, so systemd restarts the service;
            # a failing tick (Redis down) shows in /readyz instead.
            notify("WATCHDOG=1")
            stop.wait(interval)

    def tick_limit(self):
        return max(30.0, 5 * float(self.opts["tick_sec"]))

    # ── API ────────────────────────────────────────────────────────────
    def group_view(self, name):
        members = self.tasks.list(group=name, limit=1000)
        if not members:
            raise ApiError(404, "no such group: %s" % name)
        counts = {}
        for t in members:
            counts[t["status"]] = counts.get(t["status"], 0) + 1
        meta = self.tasks.group_meta(name) or {}
        view = {"group": name, "counts": counts, "tasks": members,
                "nodes": {t["node"]: t["id"] for t in members if t.get("node")}}
        if meta:
            view.update(winner=meta.get("winner"), judge_task=meta.get("judge_task"),
                        winner_error=meta.get("winner_error"))
        return view

    def _need(self, peer, action):
        """The caller's identity if their roles allow `action`, else a 403."""
        try:
            return self.rbac.require(peer, action)
        except rbacmod.Denied as exc:
            raise ApiError(403, "rbac: " + exc.message)

    def app(self, method, parts, query, body):
        peer = unixapi.peer_credentials()
        if method == "GET" and len(parts) == 1 and parts[0] in healthmod.HEALTH_PATHS:
            return self.health.respond(parts[0])
        if method == "GET" and parts == ["health"]:
            active = self.tasks.active()
            return 200, {
                "status": "ok",
                "running": sum(1 for t in active if t["status"] == T.RUNNING),
                "queued": sum(1 for t in active if t["status"] == T.QUEUED),
                "awaiting_approval": sum(1 for t in active if t["status"] == T.AWAITING),
                "max_workers": int(self.opts["max_workers"]),
            }
        if method == "GET" and parts == ["whoami"]:
            ident = self.rbac.identity(peer)
            return 200, dict(ident, rbac=self.rbac.enabled, separate_approver=self.rbac.separate_approver)
        if method == "GET" and parts == ["policy"]:
            self._need(peer, "read")
            return 200, self.policy.show((query.get("repo") or [None])[0])
        if parts[:1] == ["tasks"]:
            if method == "POST" and len(parts) == 1:
                self._need(peer, "submit")
                try:
                    created, deduped = self.submit_ex(body, peer)
                except T.ValidationError as exc:
                    raise ApiError(400, str(exc))
                return (200 if deduped else 201), {"tasks": created, "group": created[0].get("group"),
                                                   "deduplicated": deduped}
            if method == "GET" and len(parts) in (1, 2):
                self._need(peer, "read")
            if method == "GET" and len(parts) == 1:
                limit = int((query.get("limit") or ["100"])[0])
                listed = self.tasks.list((query.get("status") or [None])[0], (query.get("group") or [None])[0],
                                         max(1, min(limit, 1000)))
                return 200, {"tasks": listed}
            if method == "GET" and len(parts) == 2:
                task = self.tasks.get(parts[1])
                if task is None:
                    raise ApiError(404, "no such task: %s" % parts[1])
                return 200, task
            if method == "POST" and len(parts) == 3 and parts[2] == "cancel":
                return 200, {"tasks": self.cancel(parts[1], self._need(peer, "cancel"))}
            if method == "POST" and len(parts) == 3 and parts[2] in ("approve", "reject"):
                self._need(peer, "decide")
                try:
                    changed = self.decide(parts[1], parts[2] == "approve", peer,
                                          (body or {}).get("note") if isinstance(body, dict) else None)
                except T.ValidationError as exc:
                    raise ApiError(400, str(exc))
                return 200, {"tasks": changed}
        if method == "POST" and parts == ["workflows"]:
            self._need(peer, "submit")
            try:
                group, created = self.submit_workflow(body, peer)
            except T.ValidationError as exc:
                raise ApiError(400, str(exc))
            return 201, {"group": group, "tasks": list(created.values()),
                         "nodes": {n: t["id"] for n, t in created.items()}}
        if method == "GET" and len(parts) == 2 and parts[0] in ("groups", "workflows"):
            self._need(peer, "read")
            return 200, self.group_view(parts[1])
        raise ApiError(404, "unknown endpoint")


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS orchestrator")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    orch = Orchestrator(cfg, T.TaskStore(Store(connect(cfg["redis"]["url"]))))
    orch.recover()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    server = serve_unix(orch.opts["socket"], orch.app)
    orch.health.add("socket", healthmod.socket_check(orch.opts["socket"]))
    healthmod.sd_notify("READY=1")
    log.info("orchestrator listening on %s (max %s workers)", orch.opts["socket"], orch.opts["max_workers"])
    try:
        orch.loop(stop, healthmod.sd_notify)
    except KeyboardInterrupt:
        pass
    finally:
        healthmod.sd_notify("STOPPING=1")
        server.shutdown()


if __name__ == "__main__":
    main()
