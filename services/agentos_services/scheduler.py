"""AgentOS scheduler.

Fires orchestrator tasks on a calendar. A schedule is

    {name, calendar, agent, workspace, prompt, budget_usd, timeout_sec,
     swarm, persistent, allow_overlap, enabled}

`calendar` is systemd OnCalendar syntax ("daily", "Mon..Fri 09:00",
"*-*-* *:00/15:00", "Sun 03:00 Europe/Berlin"). Why not cron: operators of
a NixOS host already know OnCalendar from systemd timers, it covers more
(time zones, ranges, "last day of month"), and `systemd-analyze calendar`
is the reference implementation, so this scheduler never disagrees with
what `systemd-analyze calendar` prints. The price is one short-lived
process per computation, which happens once per firing, not per tick.

Semantics follow systemd timers:
  * times are UTC unless the expression names a time zone;
  * persistent = true: a run that came due while the scheduler was down
    fires once at start-up; otherwise missed runs are skipped;
  * a schedule does not fire while its previous run is still queued or
    running, unless allow_overlap is set.

Schedules live in Redis (agentos:sched:<name>) and come from `agentos-schedule
add` or from the NixOS option agentos.scheduler.schedules (declarative:
re-synced at every start, read-only for the CLI). Firing means submitting a
task to the orchestrator socket.

API on a unix socket (group agentos):
  GET    /health
  GET    /schedules
  PUT    /schedules/<name>        create or replace (body: the fields above)
  DELETE /schedules/<name>
  POST   /schedules/<name>/run    fire now
"""

import argparse
import calendar as _calendar
import json
import logging
import os
import re
import signal
import subprocess
import sys
import threading
import time

from . import config as configmod
from . import tasks as T
from .store import Store, connect
from .unixapi import ApiError, call, serve_unix

log = logging.getLogger("agentos.scheduler")

_TIME = re.compile(r"(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})")
SCHEDULE_FIELDS = {
    "name", "calendar", "agent", "workspace", "prompt", "budget_usd", "timeout_sec", "swarm",
    "persistent", "allow_overlap", "enabled",
}
TEMPLATE_FIELDS = ("agent", "workspace", "prompt", "budget_usd", "timeout_sec")


class CalendarError(ValueError):
    pass


def parse_next_elapse(output):
    """Epoch seconds from `systemd-analyze calendar` output, None for "never"."""
    lines = output.splitlines()
    # When the expression carries a time zone, the "(in UTC)" line is exact
    for marker in ("(in UTC):", "Next elapse:"):
        for line in lines:
            if marker in line:
                value = line.split(marker, 1)[1]
                if value.strip().startswith(("never", "n/a")):
                    return None
                match = _TIME.search(value)
                if match:
                    return _calendar.timegm(time.strptime(match.group(1), "%Y-%m-%d %H:%M:%S"))
    raise CalendarError("cannot parse systemd-analyze output: %r" % output[:200])


def systemd_next(expr, after, run=subprocess.run):
    """The first time strictly after `after` (epoch) that `expr` elapses."""
    if not isinstance(expr, str) or not expr.strip() or len(expr) > 200 or not expr.isprintable() \
            or expr.lstrip().startswith("-"):
        raise CalendarError("invalid calendar expression")
    res = run(["systemd-analyze", "calendar", "--iterations=1", "--base-time=@%d" % int(after), expr],
              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False, timeout=30,
              env={"PATH": os.environ.get("PATH", ""), "TZ": "UTC", "LC_ALL": "C.UTF-8"})
    if res.returncode != 0:
        raise CalendarError((res.stderr or "").strip() or "invalid calendar expression")
    return parse_next_elapse(res.stdout)


class ScheduleStore:
    """Schedules in Redis (agentos:sched:<name>, agentos:scheds)."""

    def __init__(self, store):
        self.store = store
        self.r = store.r

    def get(self, name):
        raw = self.r.get(self.store._k("sched", name)) if configmod.valid_agent_id(name) else None
        return json.loads(raw) if raw else None

    def put(self, sched):
        p = self.r.pipeline()
        p.set(self.store._k("sched", sched["name"]), json.dumps(sched))
        p.sadd(self.store._k("scheds"), sched["name"])
        p.execute()

    def delete(self, name):
        p = self.r.pipeline()
        p.delete(self.store._k("sched", name))
        p.srem(self.store._k("scheds"), name)
        p.execute()

    def list(self):
        out = [self.get(n) for n in sorted(self.r.smembers(self.store._k("scheds")))]
        return [s for s in out if s]


class Scheduler:
    def __init__(self, cfg, store, submit, task_status, next_fn=systemd_next, runtime=None, clock=time.time):
        self.cfg = cfg
        self.opts = T.settings(cfg, "scheduler")
        self.orch = T.settings(cfg, "orchestrator")
        self.schedules = ScheduleStore(store)
        self.submit = submit          # (task body) -> [task dict]
        self.task_status = task_status  # (task id) -> status string or None
        self.next_fn = next_fn
        self._runtime = runtime
        self.clock = clock
        self.lock = threading.RLock()

    def runtime(self):
        return self._runtime if self._runtime is not None else T.load_runtime(self.orch["runtime_file"])

    # ── definitions ────────────────────────────────────────────────────
    def build(self, body, declarative=False):
        """Validate a schedule definition; returns the record (without run state)."""
        if not isinstance(body, dict):
            raise T.ValidationError("schedule must be a JSON object")
        unknown = sorted(set(body) - SCHEDULE_FIELDS)
        if unknown:
            raise T.ValidationError("unknown field(s): %s" % ", ".join(unknown))
        name = body.get("name")
        if not isinstance(name, str) or not configmod.valid_agent_id(name):
            raise T.ValidationError("invalid schedule name")
        swarm = T.validate_swarm(body, self.orch)
        # Declarative schedules may name a workspace that does not exist yet
        template = T.validate_fields({k: body[k] for k in TEMPLATE_FIELDS if k in body},
                                     self.runtime(), self.orch, check_workspace=not declarative)
        T.task_command(self.orch, self.runtime(), template["agent"])
        flags = {}
        for flag, default in (("persistent", False), ("allow_overlap", False), ("enabled", True)):
            flags[flag] = body.get(flag, default)
            if not isinstance(flags[flag], bool):
                raise T.ValidationError("%s must be a boolean" % flag)
        expr = body.get("calendar")
        try:
            first = self.next_fn(expr, self.clock())
        except CalendarError as exc:
            raise T.ValidationError("calendar: %s" % exc)
        return {
            "name": name, "calendar": expr, "declarative": declarative, "swarm": swarm,
            "task": {k: template[k] for k in TEMPLATE_FIELDS}, "next_run": first,
            "created_at": self.clock(), "last_run": None, "last_tasks": [], "last_error": None,
            **flags,
        }

    def add(self, body, declarative=False):
        with self.lock:
            sched = self.build(body, declarative)
            old = self.schedules.get(sched["name"])
            if old:
                if old.get("declarative") and not declarative:
                    raise ApiError(409, "%s is declared in the NixOS configuration" % sched["name"])
                sched.update(created_at=old["created_at"], last_run=old["last_run"],
                             last_tasks=old["last_tasks"], last_error=old["last_error"])
                if old["calendar"] == sched["calendar"] and old.get("next_run"):
                    sched["next_run"] = old["next_run"]  # keep a pending (possibly missed) run
            self.schedules.put(sched)
            return sched

    def remove(self, name):
        with self.lock:
            sched = self.schedules.get(name)
            if not sched:
                raise ApiError(404, "no such schedule: %s" % name)
            if sched.get("declarative"):
                raise ApiError(409, "%s is declared in the NixOS configuration" % name)
            self.schedules.delete(name)

    def sync_declarative(self):
        wanted = {}
        for body in self.opts["schedules"]:
            try:
                sched = self.add(body, declarative=True)
                wanted[sched["name"]] = True
            except (T.ValidationError, ApiError) as exc:
                log.error("declarative schedule %r ignored: %s", body.get("name") if isinstance(body, dict) else body,
                          getattr(exc, "message", exc))
        for sched in self.schedules.list():
            if sched.get("declarative") and sched["name"] not in wanted:
                self.schedules.delete(sched["name"])

    # ── firing ─────────────────────────────────────────────────────────
    def fire(self, name, force=False):
        """Submit the schedule's task. Returns the new task ids ([] if skipped)."""
        with self.lock:
            sched = self.schedules.get(name)
            if not sched:
                raise ApiError(404, "no such schedule: %s" % name)
            now = self.clock()
            ids = []
            if not force and not sched["allow_overlap"] and any(
                    self.task_status(t) in (T.QUEUED, T.RUNNING) for t in sched["last_tasks"]):
                log.info("schedule %s: previous run still active; skipping", name)
                sched["last_error"] = "skipped: previous run still active"
            else:
                body = {k: v for k, v in sched["task"].items() if v is not None}
                body.update(swarm=sched["swarm"], origin="schedule:" + name)
                try:
                    ids = [t["id"] for t in self.submit(body)]
                    sched.update(last_run=now, last_tasks=ids, last_error=None)
                    log.info("schedule %s: submitted %s", name, ", ".join(ids))
                except Exception as exc:
                    sched["last_error"] = "submit failed: %s" % exc
                    log.error("schedule %s: %s", name, exc)
            if not force or (sched.get("next_run") or 0) <= now:
                sched["next_run"] = self._next(sched, now)
            self.schedules.put(sched)
            return ids

    def _next(self, sched, after):
        try:
            return self.next_fn(sched["calendar"], after)
        except CalendarError as exc:
            log.error("schedule %s: %s", sched["name"], exc)
            return None

    # ── loop ───────────────────────────────────────────────────────────
    def start(self):
        """Sync declarative schedules and drop runs missed while down."""
        self.sync_declarative()
        now = self.clock()
        with self.lock:
            for sched in self.schedules.list():
                due = sched.get("next_run") is not None and sched["next_run"] <= now
                if sched.get("next_run") is None or (due and not sched["persistent"]):
                    if due:
                        log.info("schedule %s: skipping a run missed while down", sched["name"])
                    sched["next_run"] = self._next(sched, now)
                    self.schedules.put(sched)

    def tick(self):
        now = self.clock()
        for sched in self.schedules.list():
            if sched["enabled"] and sched.get("next_run") is not None and sched["next_run"] <= now:
                self.fire(sched["name"])

    def loop(self, stop):
        interval = float(self.opts["tick_sec"])
        while not stop.is_set():
            try:
                self.tick()
            except Exception:
                log.exception("scheduler error")
            stop.wait(interval)

    # ── API ────────────────────────────────────────────────────────────
    def app(self, method, parts, query, body):
        if method == "GET" and parts == ["health"]:
            return 200, {"status": "ok", "schedules": len(self.schedules.list())}
        if method == "GET" and parts == ["schedules"]:
            return 200, {"schedules": self.schedules.list()}
        if parts[:1] == ["schedules"] and len(parts) >= 2:
            name = parts[1]
            if method == "PUT" and len(parts) == 2:
                try:
                    return 200, self.add(dict(body, name=name))
                except T.ValidationError as exc:
                    raise ApiError(400, str(exc))
            if method == "DELETE" and len(parts) == 2:
                self.remove(name)
                return 200, {"removed": name}
            if method == "POST" and parts[2:] == ["run"]:
                return 200, {"tasks": self.fire(name, force=True)}
            if method == "GET" and len(parts) == 2:
                sched = self.schedules.get(name)
                if not sched:
                    raise ApiError(404, "no such schedule: %s" % name)
                return 200, sched
        raise ApiError(404, "unknown endpoint")


def orchestrator_client(socket_path):
    """(submit, task_status) callables talking to the orchestrator socket."""
    def submit(body):
        status, obj = call(socket_path, "POST", "/tasks", body)
        if status != 201:
            raise RuntimeError(obj.get("error", "orchestrator returned %d" % status))
        return obj["tasks"]

    def task_status(task_id):
        try:
            status, obj = call(socket_path, "GET", "/tasks/" + task_id)
        except OSError:
            return None
        return obj.get("status") if status == 200 else None

    return submit, task_status


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS scheduler")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    opts = T.settings(cfg, "scheduler")
    submit, task_status = orchestrator_client(T.settings(cfg, "orchestrator")["socket"])
    sched = Scheduler(cfg, Store(connect(cfg["redis"]["url"])), submit, task_status)
    sched.start()
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    server = serve_unix(opts["socket"], sched.app)
    log.info("scheduler listening on %s; %d schedule(s)", opts["socket"], len(sched.schedules.list()))
    try:
        sched.loop(stop)
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
