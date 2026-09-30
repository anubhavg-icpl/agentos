import os
import shutil
import subprocess

import pytest

from agentos_services import scheduler as S
from agentos_services import tasks as T
from agentos_services.unixapi import call, serve_unix
from orchfix import cfg, clock, runtime  # noqa: F401


def every(expr, after):
    """Fake calendar: "every:N" elapses on multiples of N seconds; "never" never."""
    if expr == "never":
        return None
    if not expr.startswith("every:"):
        raise S.CalendarError("Failed to parse calendar specification %r" % expr)
    n = int(expr.split(":")[1])
    return (int(after) // n + 1) * n


class Harness:
    def __init__(self, cfg, store, runtime, clock):
        self.cfg, self.store, self.runtime, self.clock = cfg, store, runtime, clock
        self.submitted = []
        self.status = {}
        self.fail_submit = False
        self.sched = self.make()

    def submit(self, body):
        if self.fail_submit:
            raise RuntimeError("orchestrator is down")
        self.submitted.append(body)
        task_id = "task-%d" % len(self.submitted)
        self.status[task_id] = T.QUEUED
        return [{"id": task_id}]

    def make(self):
        return S.Scheduler(self.cfg, self.store, self.submit, self.status.get, next_fn=every,
                           runtime=self.runtime, clock=self.clock)


@pytest.fixture
def h(cfg, store, runtime, clock):
    return Harness(cfg, store, runtime, clock)


def definition(**fields):
    body = {"name": "nightly", "calendar": "every:3600", "agent": "fake", "workspace": "demo", "prompt": "scan"}
    body.update(fields)
    return body


# ── calendar evaluation ──────────────────────────────────────────────────
def test_parse_next_elapse_variants():
    utc = "Original form: daily\nNormalized form: *-*-* 00:00:00\n    Next elapse: Thu 2026-10-01 00:00:00 UTC\n       From now: 3h left\n"
    assert S.parse_next_elapse(utc) == 1790812800
    zoned = ("Normalized form: *-*-* 00:00:00\n    Next elapse: Tue 2026-09-22 00:00:00 IST\n"
             "       (in UTC): Mon 2026-09-21 18:30:00 UTC\n       From now: 1 week ago\n")
    assert S.parse_next_elapse(zoned) == 1790015400
    assert S.parse_next_elapse("    Next elapse: Thu 2026-10-01 00:00:00.500000 UTC\n") == 1790812800
    assert S.parse_next_elapse("Normalized form: 2020-01-01 00:00:00\n    Next elapse: never\n") is None
    with pytest.raises(S.CalendarError):
        S.parse_next_elapse("garbage")


def test_systemd_next_builds_a_safe_command():
    calls = []

    def run(cmd, **kw):
        calls.append((cmd, kw))
        return subprocess.CompletedProcess(cmd, 0, "    Next elapse: Thu 2026-10-01 00:00:00 UTC\n", "")

    assert S.systemd_next("Mon..Fri 09:00", 1790000000.7, run=run) == 1790812800
    cmd, kw = calls[0]
    assert cmd == ["systemd-analyze", "calendar", "--iterations=1", "--base-time=@1790000000", "Mon..Fri 09:00"]
    assert kw["env"]["TZ"] == "UTC"
    for bad in ("--help", " -x", "", "a" * 300, "daily\x00", 5, "daily\nweekly"):
        with pytest.raises(S.CalendarError):
            S.systemd_next(bad, 0, run=run)
    assert len(calls) == 1

    with pytest.raises(S.CalendarError, match="Invalid argument"):
        S.systemd_next("bogus", 0, run=lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, "", "Failed: Invalid argument"))


@pytest.mark.skipif(shutil.which("systemd-analyze") is None, reason="systemd-analyze is not installed")
def test_real_systemd_analyze():
    try:
        subprocess.run(["systemd-analyze", "calendar", "--iterations=1", "daily"], check=True,
                       capture_output=True, timeout=30)
    except (subprocess.SubprocessError, OSError):
        pytest.skip("systemd-analyze is not usable here")
    base = 1790000000  # 2026-09-21 14:13:20 UTC
    assert S.systemd_next("*-*-* *:00/30:00", base) == 1790001000
    assert S.systemd_next("daily", base) == 1790035200
    try:
        assert S.systemd_next("Mon..Fri 09:00 Europe/Berlin", base) == 1790060400
    except S.CalendarError:
        pass  # no time zone database in this environment (the Nix build sandbox)
    assert S.systemd_next("2020-01-01", base) is None
    with pytest.raises(S.CalendarError):
        S.systemd_next("not a calendar", base)


# ── schedules ────────────────────────────────────────────────────────────
def test_add_validates_and_computes_the_next_run(h, clock):
    s = h.sched.add(definition())
    assert s["next_run"] == (int(clock.now) // 3600 + 1) * 3600
    assert h.sched.schedules.get("nightly")["task"]["agent"] == "fake"
    for bad in (definition(calendar="nonsense"), definition(agent="nosuch"), definition(workspace="/etc"),
                definition(prompt=""), definition(name="a b"), definition(swarm=99), definition(persistent="yes"),
                definition(bogus=1), definition(prompt="--flag")):
        with pytest.raises(T.ValidationError):
            h.sched.add(bad)
    assert [s["name"] for s in h.sched.schedules.list()] == ["nightly"]


def test_due_detection_and_firing(h, clock):
    h.sched.add(definition(budget_usd=2.5, timeout_sec=600, swarm=2))
    h.sched.tick()
    assert h.submitted == []
    clock.advance(3600)
    h.sched.tick()
    assert len(h.submitted) == 1
    body = h.submitted[0]
    assert body == {"agent": "fake", "workspace": os.path.join(h.runtime["workspace_root"], "demo"),
                    "prompt": "scan", "budget_usd": 2.5, "timeout_sec": 600, "swarm": 2, "origin": "schedule:nightly"}
    s = h.sched.schedules.get("nightly")
    assert s["last_tasks"] == ["task-1"] and s["last_run"] == clock.now
    assert s["next_run"] > clock.now
    h.sched.tick()                 # not due again yet
    assert len(h.submitted) == 1
    h.status["task-1"] = T.SUCCEEDED
    clock.advance(3600)
    h.sched.tick()
    assert len(h.submitted) == 2


def test_disabled_schedule_does_not_fire(h, clock):
    h.sched.add(definition(enabled=False))
    clock.advance(7200)
    h.sched.tick()
    assert h.submitted == []


def test_overlapping_run_is_skipped_unless_allowed(h, clock):
    h.sched.add(definition())
    h.sched.add(definition(name="loose", allow_overlap=True))
    clock.advance(3600)
    h.sched.tick()
    assert len(h.submitted) == 2
    clock.advance(3600)
    h.sched.tick()                 # task-1 is still queued: only "loose" fires
    assert sorted(b["origin"] for b in h.submitted) == ["schedule:loose", "schedule:loose", "schedule:nightly"]
    assert "still active" in h.sched.schedules.get("nightly")["last_error"]


def test_run_now_ignores_overlap_and_keeps_the_calendar(h, clock):
    s = h.sched.add(definition())
    ids = h.sched.fire("nightly", force=True)
    ids2 = h.sched.fire("nightly", force=True)
    assert ids == ["task-1"] and ids2 == ["task-2"]
    assert h.sched.schedules.get("nightly")["next_run"] == s["next_run"]
    with pytest.raises(Exception, match="no such schedule"):
        h.sched.fire("nosuch", force=True)


def test_submit_failure_is_recorded_and_retried_next_period(h, clock):
    h.sched.add(definition())
    h.fail_submit = True
    clock.advance(3600)
    h.sched.tick()
    s = h.sched.schedules.get("nightly")
    assert "orchestrator is down" in s["last_error"] and s["last_tasks"] == []
    assert s["next_run"] > clock.now


def test_persistent_schedule_catches_up_after_downtime(h, clock):
    h.sched.add(definition(persistent=True))
    h.sched.add(definition(name="plain"))
    clock.advance(10 * 3600)                      # scheduler was down for ten hours
    restarted = h.make()
    restarted.start()
    restarted.tick()
    assert [b["origin"] for b in h.submitted] == ["schedule:nightly"]     # once, not ten times
    plain = restarted.schedules.get("plain")
    assert plain["next_run"] > clock.now and plain["last_run"] is None
    h.status["task-1"] = T.SUCCEEDED
    clock.advance(3600)
    restarted.tick()
    assert sorted(b["origin"] for b in h.submitted) == ["schedule:nightly", "schedule:nightly", "schedule:plain"]


def test_declarative_schedules_sync_at_start(h, clock):
    h.cfg.setdefault("scheduler", {})["schedules"] = [
        definition(name="declared", workspace="not-created-yet", persistent=True),
        definition(name="broken", calendar="nonsense"),
    ]
    h.sched.add(definition(name="manual"))
    sched = h.make()
    sched.start()
    names = {s["name"]: s for s in sched.schedules.list()}
    assert set(names) == {"declared", "manual"} and names["declared"]["declarative"] is True
    # CLI changes to a declared schedule are refused
    with pytest.raises(Exception, match="declared in the NixOS"):
        sched.remove("declared")
    with pytest.raises(Exception, match="declared in the NixOS"):
        sched.add(definition(name="declared"))
    # removing it from the configuration removes it, but manual ones stay
    h.cfg.setdefault("scheduler", {})["schedules"] = []
    again = h.make()
    again.start()
    assert [s["name"] for s in again.schedules.list()] == ["manual"]


def test_declarative_resync_keeps_run_state(h, clock):
    h.cfg.setdefault("scheduler", {})["schedules"] = [definition(name="declared")]
    sched = h.make()
    sched.start()
    clock.advance(3600)
    sched.tick()
    before = sched.schedules.get("declared")
    h.make().start()
    after = h.make().schedules.get("declared")
    assert after["last_tasks"] == before["last_tasks"] and after["next_run"] == before["next_run"]


def test_remove(h):
    h.sched.add(definition())
    h.sched.remove("nightly")
    assert h.sched.schedules.list() == []
    with pytest.raises(Exception, match="no such schedule"):
        h.sched.remove("nightly")


def test_api_over_unix_socket(h, short_dir, clock):
    path = os.path.join(short_dir, "sched.sock")
    server = serve_unix(path, h.sched.app)
    try:
        body = {k: v for k, v in definition().items() if k != "name"}
        status, obj = call(path, "PUT", "/schedules/nightly", body)
        assert status == 200 and obj["name"] == "nightly"
        assert call(path, "PUT", "/schedules/x", dict(body, calendar="nonsense"))[0] == 400
        assert [s["name"] for s in call(path, "GET", "/schedules")[1]["schedules"]] == ["nightly"]
        assert call(path, "GET", "/schedules/nightly")[1]["calendar"] == "every:3600"
        assert call(path, "POST", "/schedules/nightly/run")[1] == {"tasks": ["task-1"]}
        assert call(path, "DELETE", "/schedules/nightly")[0] == 200
        assert call(path, "DELETE", "/schedules/nightly")[0] == 404
        assert call(path, "GET", "/health")[1]["schedules"] == 0
    finally:
        server.shutdown()
        server.server_close()
