"""nestlo-tuios-bridge against canned TUIOS event lines (shapes from docs/protocol.md, "Event stream")."""

import io
import json
import subprocess
import threading
import urllib.request

import pytest

from nestlo_services import audit as A
from nestlo_services import tuios_bridge as tb

BOOT = "9f2c41d07a3e8b65"


def line(**ev):
    ev.setdefault("boot_id", BOOT)
    ev.setdefault("time", 1737200000000000000)
    return json.dumps(ev)


ACK = json.dumps({"type": "subscribed", "seq": 42, "boot_id": BOOT})


class FakeAudit:
    enabled = True
    dropped = 0

    def __init__(self):
        self.events = []

    def emit(self, etype, actor=None, **data):
        self.events.append({"type": etype, "actor": actor, "data": {k: v for k, v in data.items() if v is not None}})

    def close(self):
        pass


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


class Runner:
    def __init__(self, rc=0):
        self.calls, self.rc = [], rc

    def __call__(self, argv, **kw):
        self.calls.append(argv)
        return subprocess.CompletedProcess(argv, self.rc, "", "boom" if self.rc else "")


@pytest.fixture
def audit():
    return FakeAudit()


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def runner():
    return Runner()


@pytest.fixture
def bridge(audit, clock, runner):
    return tb.Bridge("alice", audit, ["nestlo-notify", "test"], grace=15, clock=clock, runner=runner)


def test_audit_type_is_accepted_by_the_writer():
    assert tb.AUDIT_TYPE in A.EVENT_TYPES


def test_window_and_session_events_are_audited(bridge, audit):
    bridge.handle_line(ACK)
    bridge.handle_line(line(seq=43, type="session-created", session="ci"))
    bridge.handle_line(line(seq=44, type="window-created", session="ci", window="1f3c0000", pty_id="9ab2", title="Terminal 1f3c"))
    bridge.handle_line(line(seq=45, type="window-closed", session="ci", window="1f3c0000", pty_id="9ab2"))
    bridge.handle_line(line(seq=46, type="session-closed", session="ci"))
    kinds = [(e["data"]["event"], e["data"].get("session"), e["data"].get("window")) for e in audit.events]
    assert kinds == [("session-created", "ci", None), ("window-created", "ci", "1f3c0000"),
                     ("window-closed", "ci", "1f3c0000"), ("session-closed", "ci", None)]
    assert all(e["type"] == "terminal.tuios" and e["actor"] == "alice" for e in audit.events)
    assert audit.events[1]["data"]["title"] == "Terminal 1f3c"
    assert bridge.last_seq == 46 and bridge.boot_id == BOOT


def test_command_finished_hides_the_command_line_unless_asked(audit, clock, runner):
    ev = line(seq=50, type="command-finished", session="ci", window="w1", pty_id="p1",
              cmdline="make test TOKEN=********", exit_code=2, duration_ms=1234, command_seq=7)
    b = tb.Bridge("alice", audit, clock=clock, runner=runner)
    b.handle_line(ev)
    data = audit.events[-1]["data"]
    assert data == {"event": "command-finished", "session": "ci", "window": "w1", "exit_code": 2, "duration_ms": 1234}
    b = tb.Bridge("alice", audit, command_lines=True, clock=clock, runner=runner)
    b.handle_line(ev)
    assert audit.events[-1]["data"]["cmdline"] == "make test TOKEN=********"


def test_command_finished_without_status(bridge, audit):
    bridge.handle_line(line(seq=51, type="command-finished", session="ci", window="w1", cmdline="ls", duration_ms=3))
    data = audit.events[-1]["data"]
    assert "exit_code" not in data and data["duration_ms"] == 3 and "cmdline" not in data


def test_untrusted_text_is_cleaned(audit):
    b = tb.Bridge("alice", audit, command_lines=True)
    b.handle_line(line(seq=1, type="window-created", session="s\x1b[31m", window="w\x00", title="evil\x1b]0;x\x07 title\r\n" + "A" * 500))
    d = audit.events[-1]["data"]
    assert d["session"] == "s" and d["window"] == "w"
    assert "\x1b" not in d["title"] and "\n" not in d["title"] and len(d["title"]) <= 80


def test_agent_state_changes_are_audited_with_the_previous_state(bridge, audit):
    bridge.handle_line(line(seq=60, type="agent-state", session="ci", window="w1", pty_id="p1", state="working"))
    bridge.handle_line(line(seq=61, type="agent-state", session="ci", window="w1", pty_id="p1", state="needs_input"))
    bridge.handle_line(line(seq=62, type="agent-state", session="ci", window="w1", pty_id="p1", state="none"))
    assert [(e["data"]["state"], e["data"]["previous"]) for e in audit.events] == [
        ("working", "none"), ("needs_input", "working"), ("none", "needs_input")]
    assert bridge.agents == {}


def test_unknown_state_names_are_not_passed_on(bridge, audit):
    bridge.handle_line(line(seq=63, type="agent-state", session="ci", window="w1", state="sudo rm -rf"))
    assert audit.events[-1]["data"]["state"] == "unknown"
    assert 'state="sudo' not in bridge.metrics()


def test_needs_input_notifies_once_after_the_grace_period(bridge, clock, runner):
    bridge.handle_line(line(seq=70, type="agent-state", session="ci", window="w1", state="needs_input"))
    assert bridge.tick() == 0 and runner.calls == []
    clock.t += 14
    assert bridge.tick() == 0
    clock.t += 2
    assert bridge.tick() == 1
    assert runner.calls[0][:2] == ["nestlo-notify", "test"]
    assert "w1" in runner.calls[0][2] and "ci" in runner.calls[0][2] and "alice" in runner.calls[0][2]
    clock.t += 100
    assert bridge.tick() == 0 and len(runner.calls) == 1 and bridge.sent == 1


def test_a_short_wait_does_not_notify_and_a_new_wait_does(bridge, clock, runner):
    bridge.handle_line(line(seq=71, type="agent-state", session="ci", window="w1", state="needs_input"))
    clock.t += 5
    bridge.handle_line(line(seq=72, type="agent-state", session="ci", window="w1", state="working"))
    clock.t += 60
    assert bridge.tick() == 0
    bridge.handle_line(line(seq=73, type="agent-state", session="ci", window="w1", state="needs_input"))
    clock.t += 20
    assert bridge.tick() == 1 and len(runner.calls) == 1


def test_a_closed_window_does_not_notify(bridge, clock, runner):
    bridge.handle_line(line(seq=74, type="agent-state", session="ci", window="w1", state="needs_input"))
    bridge.handle_line(line(seq=75, type="window-closed", session="ci", window="w1"))
    clock.t += 60
    assert bridge.tick() == 0 and runner.calls == []


def test_a_closed_session_forgets_its_agents(bridge):
    bridge.handle_line(line(seq=76, type="agent-state", session="ci", window="w1", state="working"))
    bridge.handle_line(line(seq=77, type="agent-state", session="other", window="w2", state="idle"))
    bridge.handle_line(line(seq=78, type="session-closed", session="ci"))
    assert bridge.agents == {("other", "w2"): "idle"}


def test_failed_notifier_is_not_counted(audit, clock, capsys):
    b = tb.Bridge("alice", audit, ["nestlo-notify", "test"], grace=0, clock=clock, runner=Runner(rc=1))
    b.handle_line(line(seq=1, type="agent-state", session="ci", window="w1", state="needs_input"))
    assert b.tick() == 1 and b.sent == 0
    assert "notification failed" in capsys.readouterr().err


def test_no_notifier_configured_still_logs(audit, clock, capsys):
    b = tb.Bridge("alice", audit, None, grace=0, clock=clock)
    b.handle_line(line(seq=1, type="agent-state", session="ci", window="w1", state="needs_input"))
    assert b.tick() == 1 and b.sent == 0
    assert "needs input" in capsys.readouterr().err


def test_metrics(bridge, runner, clock):
    bridge.connected = True
    bridge.handle_line(line(seq=80, type="agent-state", session="ci", window="w1", state="working"))
    bridge.handle_line(line(seq=81, type="agent-state", session="ci", window="w2", state="needs_input"))
    bridge.handle_line(line(seq=82, type="command-finished", session="ci", window="w1", exit_code=0))
    clock.t += 30
    bridge.tick()
    text = bridge.metrics()
    assert 'nestlo_tuios_up{user="alice"} 1' in text
    assert 'nestlo_tuios_agents{user="alice",state="working"} 1' in text
    assert 'nestlo_tuios_agents{user="alice",state="needs_input"} 1' in text
    assert 'nestlo_tuios_agents{user="alice",state="done"} 0' in text
    assert 'nestlo_tuios_events_total{user="alice",type="agent-state"} 2' in text
    assert 'nestlo_tuios_events_total{user="alice",type="command-finished"} 1' in text
    assert 'nestlo_tuios_needs_input_notifications_total{user="alice"} 1' in text
    assert 'nestlo_tuios_audit_dropped_total{user="alice"} 0' in text


def test_gaps_and_garbage(bridge):
    bridge.handle_line(line(seq=90, type="agent-state", session="ci", window="w1", state="working"))
    assert bridge.handle_line("not json") is None
    assert bridge.handle_line("[1, 2]") is None
    assert bridge.handle_line(line(seq=91, type="output", session="ci", window="w1", bytes=5)) is None
    assert bridge.ignored == 3
    bridge.handle_line(json.dumps({"type": "gap", "reason": "boot_changed", "dropped": 0, "boot_id": "aaaa"}))
    assert bridge.gaps == 1 and bridge.agents == {} and bridge.last_seq is None and bridge.boot_id == "aaaa"
    assert 'nestlo_tuios_stream_gaps_total{user="alice"} 1' in bridge.metrics()


def test_subscribe_argv_resumes_after_the_last_seq(bridge):
    argv = bridge.subscribe_argv("tuios")
    assert argv[:3] == ["tuios", "subscribe", "--types"] and "--after-seq" not in argv
    assert set(argv[3].split(",")) == set(tb.FOLLOWED)
    bridge.handle_line(ACK)
    bridge.handle_line(line(seq=100, type="session-created", session="ci"))
    assert bridge.subscribe_argv("tuios")[-4:] == ["--after-seq", "100", "--boot-id", BOOT]


class FakeProc:
    def __init__(self, lines, rc=0, err=""):
        self.stdout = io.StringIO("".join(l + "\n" for l in lines))
        self.stderr = io.StringIO(err)
        self.returncode = rc

    def wait(self):
        return self.returncode

    def poll(self):
        return self.returncode

    def terminate(self):
        pass


def test_follow_reconnects_and_resumes(audit, clock, runner):
    b = tb.Bridge("alice", audit, clock=clock, runner=runner)
    streams = [
        FakeProc([ACK, line(seq=43, type="window-created", session="ci", window="w1", title="t")], rc=1,
                 err="the daemon closed the event stream"),
        FakeProc([json.dumps({"type": "subscribed", "seq": 43, "boot_id": BOOT}),
                  line(seq=44, type="window-closed", session="ci", window="w1")]),
    ]
    spawned = []
    stop = threading.Event()

    def popen(argv, **kw):
        spawned.append(argv)
        if not streams:
            stop.set()
            raise OSError("no more")
        return streams.pop(0)

    b.follow("tuios", stop, popen=popen, retry=0, sleep=lambda s: None)
    assert "--after-seq" not in spawned[0]
    assert spawned[1][-4:] == ["--after-seq", "43", "--boot-id", BOOT]
    assert [e["data"]["event"] for e in audit.events] == ["window-created", "window-closed"]
    assert b.reconnects == 2 and b.connected is False


def test_follow_survives_a_missing_binary(bridge):
    stop = threading.Event()

    def popen(argv, **kw):
        stop.set()
        raise FileNotFoundError(argv[0])

    bridge.follow("tuios", stop, popen=popen, retry=0, sleep=lambda s: None)
    assert bridge.reconnects == 0


def test_metrics_endpoint(bridge):
    srv = tb.ThreadingHTTPServer(("127.0.0.1", 0), tb.make_handler(bridge))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        base = "http://127.0.0.1:%d" % srv.server_address[1]
        with urllib.request.urlopen(base + "/metrics") as r:
            assert r.status == 200 and b"nestlo_tuios_up" in r.read()
        with urllib.request.urlopen(base + "/healthz") as r:
            assert r.read() == b"ok\n"
        with pytest.raises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(base + "/status")
        assert e.value.code == 404
    finally:
        srv.shutdown()
        srv.server_close()


def test_events_reach_a_real_audit_writer(tmp_path):
    """The bridge's events are accepted by the audit writer (type and shape)."""
    import socket
    sock = str(tmp_path / "a.sock")
    log = A.AuditLog(str(tmp_path / "log"))
    w = A.Writer(log, sock)
    w.serve_socket()
    w.start()
    client = A.AuditClient(sock, source=tb.SOURCE)
    b = tb.Bridge("alice", client)
    try:
        b.handle_line(line(seq=1, type="window-created", session="ci", window="w1", title="t"))
        b.handle_line(line(seq=2, type="agent-state", session="ci", window="w1", state="needs_input"))
        import time
        for _ in range(100):
            w.drain()
            recs = [r for r in A.iter_records(str(tmp_path / "log")) if r["type"] == "terminal.tuios"]
            if len(recs) == 2:
                break
            time.sleep(0.05)
        assert [r["data"]["event"] for r in recs] == ["window-created", "agent-state"]
        assert recs[1]["data"]["state"] == "needs_input" and recs[1]["actor"] == "alice"
        assert recs[0]["source"] == "tuios-bridge"
        assert w.rejected == 0
    finally:
        client.close()
        w.shutdown()
        socket  # noqa: B018


def test_main_requires_nothing_but_runs_and_stops(tmp_path, monkeypatch):
    """main() with a fake tuios that prints an ack and one event, then exits on SIGTERM-free EOF."""
    fake = tmp_path / "tuios"
    fake.write_text("#!/bin/sh\necho '%s'\necho '%s'\n" % (ACK, line(seq=43, type="session-created", session="ci")))
    fake.chmod(0o755)
    monkeypatch.setenv("NESTLO_TUIOS_BIN", str(fake))
    calls = []
    real_follow = tb.Bridge.follow

    def once(self, binary, stop, **kw):
        calls.append(binary)
        return real_follow(self, binary, stop, once=True, retry=0)

    monkeypatch.setattr(tb.Bridge, "follow", once)
    assert tb.main([]) == 0
    assert calls == [str(fake)]
