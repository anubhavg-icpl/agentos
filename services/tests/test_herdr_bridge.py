"""nestlo-herdr status bridge against a fake herdr binary."""

import json
import os
import urllib.request

import pytest
from herdrfix import FakeHerdr

from nestlo_services import herdr_bridge as hb

ME = hb.current_user()


@pytest.fixture
def herdr(tmp_path, monkeypatch):
    h = FakeHerdr(tmp_path)
    monkeypatch.setenv("NESTLO_HERDR_BIN", h.path)
    monkeypatch.setenv("FAKE_HERDR_STATE", h.state)
    cfg = tmp_path / "herdr.json"
    cfg.write_text(json.dumps({"users": [{"name": ME, "home": os.path.expanduser("~")}]}))
    monkeypatch.setenv("NESTLO_HERDR_CONFIG", str(cfg))
    return h


PANES = [
    {"pane_id": "w1:p1", "workspace_id": "w1", "agent_status": "working", "cwd": "/work/a"},
    {"pane_id": "w1:p2", "workspace_id": "w1", "agent_status": "blocked", "cwd": "/work/a"},
    {"pane_id": "w2:p1", "workspace_id": "w2", "agent_status": "idle", "cwd": "/work/b"},
    {"pane_id": "w2:p2", "workspace_id": "w2", "agent_status": "unknown", "cwd": "/work/b"},
    {"pane_id": "w2:p3", "workspace_id": "w2", "agent_status": "weird-new-state"},
]
AGENTS = [
    {"pane_id": "w1:p1", "name": "builder", "agent_status": "working"},
    {"pane_id": "w1:p2", "name": "rev\x1b[31miewer", "agent_status": "blocked"},
    {"pane_id": "w2:p1", "agent": "codex", "agent_status": "idle"},
]


def test_status_json_and_text(herdr, capsys):
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    assert hb.main(["status", "--json"]) == 0
    res = json.loads(capsys.readouterr().out)
    assert len(res) == 1 and res[0]["user"] == ME and res[0]["up"] is True
    assert hb.counts(res[0]["panes"]) == {"idle": 1, "working": 1, "blocked": 1, "done": 0, "unknown": 2}
    assert [a["name"] for a in res[0]["agents"]] == ["builder", "reviewer", "codex"]  # control characters stripped
    assert hb.main(["status"]) == 0
    out = capsys.readouterr().out
    assert "5 pane(s)" in out and "1 blocked" in out and "w1:p2" in out and "reviewer" in out


def test_status_when_the_server_is_down(herdr, capsys):
    assert hb.main(["status"]) == 0
    assert "herdr not available (server not running)" in capsys.readouterr().out
    hb.main(["status", "--json"])
    res = json.loads(capsys.readouterr().out)[0]
    assert res["up"] is False and res["panes"] == []


def test_status_without_herdr(monkeypatch, capsys):
    monkeypatch.setenv("NESTLO_HERDR_BIN", "/nonexistent/herdr")
    monkeypatch.setenv("NESTLO_HERDR_CONFIG", "/nonexistent.json")
    assert hb.main(["status"]) == 0
    assert "herdr not found" in capsys.readouterr().out


def test_metrics_text(herdr, capsys):
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    assert hb.main(["metrics"]) == 0
    out = capsys.readouterr().out
    assert f'nestlo_herdr_up{{user="{ME}"}} 1' in out
    assert f'nestlo_herdr_panes{{user="{ME}",state="blocked"}} 1' in out
    assert f'nestlo_herdr_panes{{user="{ME}",state="unknown"}} 2' in out
    assert f'nestlo_herdr_panes{{user="{ME}",state="done"}} 0' in out
    assert f'nestlo_herdr_agents{{user="{ME}",state="idle"}} 1' in out
    assert "# TYPE nestlo_herdr_panes gauge" in out
    # Prometheus text: every sample line is name{labels} value
    for line in out.splitlines():
        if line and not line.startswith("#"):
            assert len(line.rsplit(" ", 1)) == 2 and float(line.rsplit(" ", 1)[1]) >= 0


def test_metrics_server_down(herdr, capsys):
    hb.main(["metrics"])
    out = capsys.readouterr().out
    assert f'nestlo_herdr_up{{user="{ME}"}} 0' in out and f'nestlo_herdr_panes{{user="{ME}",state="idle"}} 0' in out


def test_unknown_or_invalid_users_are_rejected(herdr):
    with pytest.raises(SystemExit):
        hb.main(["status", "--user", "no such;user"])
    with pytest.raises(SystemExit):
        hb.main(["status", "--user", "definitely-not-a-user-xyz"])


def test_other_users_are_queried_through_sudo_or_runuser():
    spec = {"name": "someone-else", "home": "/home/x"}
    argv = hb.command_for(spec, "/bin/herdr", ["pane", "list"])
    assert "HOME=/home/x" in argv and argv[-3:] == ["/bin/herdr", "pane", "list"]
    assert argv[0] == ("runuser" if os.geteuid() == 0 else "sudo")
    me = hb.command_for({"name": ME}, "/bin/herdr", ["pane", "list"])
    assert me == ["/bin/herdr", "pane", "list"]


# ── monitor ────────────────────────────────────────────────────────────

class Clock:
    t = 1000.0

    def __call__(self):
        return self.t


class Runner:
    def __init__(self, rc=0):
        self.calls, self.rc = [], rc

    def __call__(self, argv, **kw):
        self.calls.append(argv)

        class P:
            returncode = self.rc
            stdout = stderr = ""
        return P()


def test_monitor_notifies_once_per_blocked_episode(herdr):
    clock, runner = Clock(), Runner()
    mon = hb.Monitor({"name": ME}, herdr.path, ["nestlo-notify", "test"], grace=15, clock=clock, runner=runner)
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    mon.poll()
    assert runner.calls == []                      # blocked, but not for long enough yet
    clock.t += 10
    mon.poll()
    assert runner.calls == []
    clock.t += 10
    mon.poll()
    assert len(runner.calls) == 1
    argv = runner.calls[0]
    assert argv[:2] == ["nestlo-notify", "test"]
    assert "reviewer is blocked and waits for input" in argv[2] and "w1:p2" in argv[2] and ME in argv[2]
    assert "\x1b" not in argv[2]
    clock.t += 100
    mon.poll()
    assert len(runner.calls) == 1                  # same episode: no repeat
    # it becomes idle, then blocked again: a new episode
    herdr.update(panes=[dict(p, agent_status="idle") if p["pane_id"] == "w1:p2" else p for p in PANES])
    mon.poll()
    herdr.update(panes=PANES)
    mon.poll()
    clock.t += 20
    mon.poll()
    assert len(runner.calls) == 2
    assert 'nestlo_herdr_blocked_notifications_total 2' in mon.metrics()


def test_monitor_flicker_does_not_notify(herdr):
    clock, runner = Clock(), Runner()
    mon = hb.Monitor({"name": ME}, herdr.path, ["notify"], grace=15, clock=clock, runner=runner)
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    for _ in range(5):
        mon.poll()
        clock.t += 10
        herdr.update(panes=[dict(p, agent_status="working") for p in PANES])
        mon.poll()
        clock.t += 10
        herdr.update(panes=PANES)
    assert runner.calls == []


def test_monitor_without_notifier_and_failing_notifier(herdr, capsys):
    clock = Clock()
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    mon = hb.Monitor({"name": ME}, herdr.path, None, grace=0, clock=clock)
    mon.poll()
    assert "blocked: agent reviewer" in capsys.readouterr().err
    failing = Runner(rc=1)
    mon = hb.Monitor({"name": ME}, herdr.path, ["notify"], grace=0, clock=clock, runner=failing)
    mon.poll()
    assert len(failing.calls) == 1 and mon.sent == 0


def test_monitor_http_endpoints(herdr):
    from http.server import ThreadingHTTPServer
    import threading
    herdr.update(server=True, panes=PANES, agents=AGENTS)
    mon = hb.Monitor({"name": ME}, herdr.path)
    mon.poll()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), hb.make_handler(mon))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        body = urllib.request.urlopen(base + "/metrics").read().decode()
        assert f'nestlo_herdr_panes{{user="{ME}",state="working"}} 1' in body
        assert json.loads(urllib.request.urlopen(base + "/status").read())["up"] is True
        assert urllib.request.urlopen(base + "/healthz").read() == b"ok\n"
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(base + "/etc/passwd")
    finally:
        srv.shutdown()
