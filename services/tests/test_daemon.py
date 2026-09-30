import copy
import json
import os
import subprocess
import time

import pytest

from agentos_services import config as configmod
from agentos_services.daemon import Daemon


class FakeRunner:
    def __init__(self, active=()):
        self.active = set(active)
        self.calls = []

    def __call__(self, cmd):
        self.calls.append(cmd)
        if cmd[:2] == ["systemctl", "is-active"]:
            rc = 0 if cmd[-1] in self.active else 3
        elif cmd[:2] == ["systemctl", "stop"]:
            self.active.discard(cmd[-1])
            rc = 0
        else:
            rc = 1
        return subprocess.CompletedProcess(cmd, rc, "", "")


@pytest.fixture
def make_daemon(tmp_path, store):
    def make(runner=None, sent=None, **overrides):
        cfg = copy.deepcopy(configmod.DEFAULTS)
        cfg["daemon"]["state_dir"] = str(tmp_path / "state")
        for section, values in overrides.items():
            cfg[section].update(values)
        sender = (lambda url, payload: sent.append((url, payload))) if sent is not None else None
        return Daemon(cfg, store, runner=runner or FakeRunner(), sender=sender)
    return make


def register(daemon, agent_id, age=60, **fields):
    state = {"id": agent_id, "agent": "claude", "command": "claude", "status": "running",
             "started_at": time.time() - age}
    state.update(fields)
    daemon.save(state)
    return state


def test_reap_releases_stale_gpu_locks(make_daemon, tmp_path):
    lock_dir = tmp_path / "gpu"
    lock_dir.mkdir()
    d = make_daemon(gpu={"lock_dir": str(lock_dir), "stale_grace_sec": 30})
    register(d, "live", pid=os.getpid())
    for index, holder in ((0, "live"), (1, "gone"), (2, "starting")):
        (lock_dir / str(index)).write_text(holder + "\n")
    old = time.time() - 300
    for index in (0, 1):
        os.utime(lock_dir / str(index), (old, old))
    d.reap()
    assert sorted(os.listdir(lock_dir)) == [".lock", "0", "2"]


def test_reap_ignores_missing_gpu_dir(make_daemon, tmp_path):
    d = make_daemon(gpu={"lock_dir": str(tmp_path / "absent")})
    d.reap()
    assert not (tmp_path / "absent").exists()


def test_reap_archives_dead_agents(make_daemon, events):
    runner = FakeRunner(active={"agentos-agent-live.service"})
    d = make_daemon(runner)
    register(d, "live", unit="agentos-agent-live.service")
    register(d, "gone", unit="agentos-agent-gone.service")
    register(d, "young", unit="agentos-agent-young.service", age=1)   # still starting
    register(d, "proc", pid=os.getpid())
    d.reap()
    assert sorted(a["id"] for a in d.agents()) == ["live", "proc", "young"]
    with open(os.path.join(d.history_dir, "gone.json")) as f:
        assert json.load(f)["status"] == "exited"
    kinds = sorted((e["type"], e["agent"]) for e in events.drain())
    assert kinds == [("agent_exited", "gone"), ("agent_started", "live"), ("agent_started", "proc")]
    d.reap()   # announced only once
    assert events.drain() == []


def test_budget_exceeded_stops_unit(make_daemon, events):
    runner = FakeRunner(active={"agentos-agent-a1.service"})
    d = make_daemon(runner)
    register(d, "a1", unit="agentos-agent-a1.service", announced=True)
    d.handle({"type": "budget_exceeded", "agent": "a1", "usd": 6.0, "limit_usd": 5.0})
    assert ["systemctl", "stop", "agentos-agent-a1.service"] in runner.calls
    state = d.load("a1")
    assert state["status"] == "killed" and "budget" in state["reason"]
    assert [e["type"] for e in events.drain()] == ["agent_killed"]
    d.reap()
    assert d.agents() == []
    assert os.path.exists(os.path.join(d.history_dir, "a1.json"))


def test_auto_shutdown_disabled(make_daemon):
    runner = FakeRunner(active={"agentos-agent-a1.service"})
    d = make_daemon(runner, budget={"auto_shutdown": False})
    register(d, "a1", unit="agentos-agent-a1.service")
    d.handle({"type": "budget_exceeded", "agent": "a1", "usd": 6.0, "limit_usd": 5.0})
    assert not any(c[:2] == ["systemctl", "stop"] for c in runner.calls)
    assert d.load("a1")["status"] == "running"


def test_unknown_agent_is_ignored(make_daemon):
    runner = FakeRunner()
    d = make_daemon(runner)
    d.handle({"type": "budget_exceeded", "agent": "../etc/passwd", "usd": 1, "limit_usd": 0})
    d.handle({"type": "budget_exceeded", "agent": "nobody", "usd": 1, "limit_usd": 0})
    assert runner.calls == []


def test_notifications(make_daemon, tmp_path):
    url_file = tmp_path / "slack-url"
    url_file.write_text("https://hooks.example/slack\n")
    sent = []
    d = make_daemon(sent=sent, notify={
        "events": ["budget_exceeded"],
        "targets": [{"kind": "slack", "url_file": str(url_file)},
                    {"kind": "webhook", "url": "https://hooks.example/generic"}],
    })
    d.handle({"type": "budget_threshold", "agent": "a1", "threshold": 50, "usd": 1, "limit_usd": 2})
    d.handle({"type": "budget_exceeded", "agent": "a1", "usd": 6.0, "limit_usd": 5.0})
    deadline = time.time() + 5
    while len(sent) < 2 and time.time() < deadline:
        time.sleep(0.05)
    by_url = dict(sent)
    assert by_url["https://hooks.example/slack"]["text"] == "AgentOS: Agent a1 exceeded its daily budget ($6.00 of $5.00)"
    assert by_url["https://hooks.example/generic"]["type"] == "budget_exceeded"
    assert len(sent) == 2


def test_metrics(make_daemon, store):
    d = make_daemon(FakeRunner(active={"agentos-agent-a1.service"}))
    register(d, "a1", unit="agentos-agent-a1.service")
    store.record("a1", "claude-test", 1.5, {"input_tokens": 10, "output_tokens": 2})
    store.count_request("a1", 200)
    text = d.metrics()
    assert "agentos_agents_running 1" in text
    assert 'agentos_agent_spend_usd_today{agent="a1"} 1.5' in text
    assert 'agentos_agent_tokens_today{agent="a1",kind="input_tokens"} 10' in text
    assert 'agentos_agent_requests_today{agent="a1",status="2xx"} 1' in text
    assert "agentos_spend_usd_today 1.5" in text
