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
  GET    /groups/<name>
"""

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time

from . import config as configmod
from . import tasks as T
from .store import Store, connect
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


class Orchestrator:
    def __init__(self, cfg, tasks, runtime=None, clock=time.time, runner=_run, agents_running=None):
        self.cfg = cfg
        self.opts = T.settings(cfg, "orchestrator")
        self.tasks = tasks
        self._runtime = runtime
        self.clock = clock
        self.run_cmd = runner
        self.state_dir = cfg["daemon"]["state_dir"]
        self.agents_running = agents_running or (lambda exclude: count_running_agents(self.state_dir, exclude))
        self.lock = threading.RLock()
        self._seq = 0

    def runtime(self):
        return self._runtime if self._runtime is not None else T.load_runtime(self.opts["runtime_file"])

    def unit(self, task_id):
        return "%s%s.service" % (self.opts["runner_unit_prefix"], task_id)

    # ── submission ─────────────────────────────────────────────────────
    def submit(self, body):
        """Validate and queue a task (or a swarm). Returns the new tasks."""
        if not isinstance(body, dict):
            raise T.ValidationError("task must be a JSON object")
        rt = self.runtime()
        swarm = T.validate_swarm(body, self.opts)
        fields = T.validate_fields({k: v for k, v in body.items() if k != "swarm"}, rt, self.opts)
        T.task_command(self.opts, rt, fields["agent"])
        for dep in fields["depends_on"]:
            if self.tasks.get(dep) is None:
                raise T.ValidationError("unknown dependency: %s" % dep)
        group = fields["group"]
        if swarm > 1:
            group = group or T.new_id("swarm", self.clock)
            fields["isolate"] = True
        now = self.clock()
        created = []
        with self.lock:
            for _ in range(swarm):
                # The sequence number keeps FIFO order for tasks queued in the same instant
                self._seq += 1
                task = dict(fields, group=group, id=T.new_id("task", self.clock), status=T.QUEUED,
                            created_at=now + self._seq * 1e-6, started_at=None, finished_at=None, result=None)
                created.append(self.tasks.create(task))
        log.info("queued %s", ", ".join(t["id"] for t in created))
        return created

    # ── control ────────────────────────────────────────────────────────
    def cancel(self, ident):
        """Cancel one task, or every unfinished task of a group."""
        task = self.tasks.get(ident)
        ids = [ident] if task else self.tasks.group_ids(ident)
        if not ids:
            raise ApiError(404, "no such task or group: %s" % ident)
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

    # ── scheduling loop ────────────────────────────────────────────────
    def alive(self, task_id):
        try:
            res = self.run_cmd(["systemctl", "show", "-p", "ActiveState", "--value", self.unit(task_id)])
        except (OSError, subprocess.SubprocessError):
            return True  # cannot tell; do not fail the task
        return (res.stdout or "").strip() in ALIVE_STATES

    def _reconcile(self, running):
        grace = float(self.opts["start_grace_sec"])
        for task in running:
            if self.clock() - (task.get("started_at") or 0) < grace or self.alive(task["id"]):
                continue
            log.warning("task %s: runner is gone", task["id"])
            self.tasks.finish(task["id"], T.FAILED, error="task runner exited without reporting a result "
                              "(see: journalctl -u %s)" % self.unit(task["id"]))

    def _dependency_state(self, task):
        """'ready', 'wait' or an error message when a dependency failed."""
        state = "ready"
        for dep_id in task["depends_on"]:
            dep = self.tasks.get(dep_id)
            if dep is None:
                return "dependency %s no longer exists" % dep_id
            if dep["status"] in T.TERMINAL:
                if dep["status"] != T.SUCCEEDED:
                    return "dependency %s %s" % (dep_id, dep["status"])
            else:
                state = "wait"
        return state

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
            active = self.tasks.active()
            running = [t for t in active if t["status"] == T.RUNNING]
            self._reconcile(running)
            running = [t for t in self.tasks.active() if t["status"] == T.RUNNING]
            ready = []
            for task in (t for t in self.tasks.active() if t["status"] == T.QUEUED):
                state = self._dependency_state(task)
                if state == "ready":
                    ready.append(task)
                elif state != "wait":
                    self.tasks.finish(task["id"], T.SKIPPED, error=state)
            if not ready:
                return
            slots = self._free_slots(running)
            busy = {t["workspace"] for t in running if not t.get("isolate")}
            for task in ready:
                if slots <= 0:
                    break
                if not task.get("isolate"):
                    # Non-isolated tasks share the working tree: one at a time
                    if task["workspace"] in busy:
                        continue
                    busy.add(task["workspace"])
                if self._dispatch(task):
                    slots -= 1

    def _dispatch(self, task):
        results = []
        for dep_id in task["depends_on"]:
            dep = self.tasks.get(dep_id) or {}
            results.append((dep.get("result") or {}).get("output_tail", ""))
        prompt = T.expand_prompt(task["prompt"], results) if results else task["prompt"]
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

    def loop(self, stop):
        interval = float(self.opts["tick_sec"])
        while not stop.is_set():
            try:
                self.tick()
            except Exception:
                log.exception("scheduling error")
            stop.wait(interval)

    # ── API ────────────────────────────────────────────────────────────
    def app(self, method, parts, query, body):
        if method == "GET" and parts == ["health"]:
            active = self.tasks.active()
            return 200, {
                "status": "ok",
                "running": sum(1 for t in active if t["status"] == T.RUNNING),
                "queued": sum(1 for t in active if t["status"] == T.QUEUED),
                "max_workers": int(self.opts["max_workers"]),
            }
        if parts[:1] == ["tasks"]:
            if method == "POST" and len(parts) == 1:
                try:
                    created = self.submit(body)
                except T.ValidationError as exc:
                    raise ApiError(400, str(exc))
                return 201, {"tasks": created, "group": created[0].get("group")}
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
                return 200, {"tasks": self.cancel(parts[1])}
        if method == "GET" and len(parts) == 2 and parts[0] == "groups":
            members = self.tasks.list(group=parts[1], limit=1000)
            if not members:
                raise ApiError(404, "no such group: %s" % parts[1])
            counts = {}
            for t in members:
                counts[t["status"]] = counts.get(t["status"], 0) + 1
            return 200, {"group": parts[1], "counts": counts, "tasks": members}
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
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    server = serve_unix(orch.opts["socket"], orch.app)
    log.info("orchestrator listening on %s (max %s workers)", orch.opts["socket"], orch.opts["max_workers"])
    try:
        orch.loop(stop)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
