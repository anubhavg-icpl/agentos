import copy
import http.client
import json
import os
import socket
import threading

import pytest

from nestlo_services import config as configmod
from nestlo_services import health as H
from nestlo_services.dashboard import serve as serve_dashboard
from nestlo_services.unixapi import call, serve_unix
from conftest import request
from orchfix import cfg, clock, orch, runtime, systemctl, taskstore  # noqa: F401
from test_daemon import make_daemon  # noqa: F401


# ── sd_notify ────────────────────────────────────────────────────────────
@pytest.fixture
def notify_socket(short_dir):
    path = os.path.join(short_dir, "notify")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(path)
    sock.settimeout(2)
    yield path, sock
    sock.close()


def test_sd_notify_sends_datagram(notify_socket):
    path, sock = notify_socket
    assert H.sd_notify("READY=1", {"NOTIFY_SOCKET": path})
    assert sock.recv(64) == b"READY=1"


def test_sd_notify_abstract_socket():
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    name = "\0nestlo-test-%d" % os.getpid()
    sock.bind(name)
    sock.settimeout(2)
    try:
        assert H.sd_notify("WATCHDOG=1", {"NOTIFY_SOCKET": "@" + name[1:]})
        assert sock.recv(64) == b"WATCHDOG=1"
    finally:
        sock.close()


def test_sd_notify_is_a_noop_without_a_socket(short_dir):
    assert H.sd_notify("READY=1", {}) is False
    assert H.sd_notify("READY=1", {"NOTIFY_SOCKET": "relative/path"}) is False
    assert H.sd_notify("READY=1", {"NOTIFY_SOCKET": os.path.join(short_dir, "missing")}) is False


def test_watchdog_interval_is_half_of_watchdogsec():
    assert H.watchdog_interval({"WATCHDOG_USEC": "60000000"}) == 30.0
    assert H.watchdog_interval({}) is None
    assert H.watchdog_interval({"WATCHDOG_USEC": "junk"}) is None
    assert H.watchdog_interval({"WATCHDOG_USEC": "0"}) is None
    assert H.watchdog_interval({"WATCHDOG_USEC": "10000000", "WATCHDOG_PID": "1"}, pid=2) is None
    assert H.watchdog_interval({"WATCHDOG_USEC": "10000000", "WATCHDOG_PID": "2"}, pid=2) == 5.0


def test_watchdog_loop_sends_ready_then_pings_only_while_healthy():
    sent, stop, state = [], threading.Event(), {"n": 0}

    def probe():
        state["n"] += 1
        if state["n"] >= 4:
            stop.set()
        return state["n"] != 2          # second probe fails

    H.watchdog_loop(stop, probe, interval=0.01, notify=sent.append)
    assert sent[0] == "READY=1"
    assert sent.count("WATCHDOG=1") == 3     # probes 1, 3 and 4
    assert sent[-1] == "STOPPING=1"


# ── Health ───────────────────────────────────────────────────────────────
def test_health_reports_failing_checks():
    def bad():
        raise RuntimeError("boom")

    h = H.Health("x", {"good": lambda: None, "bad": bad})
    assert h.respond("healthz") == (200, {"status": "ok", "service": "x"})
    status, body = h.respond("readyz")
    assert status == 503 and body["checks"] == {"good": "ok", "bad": "failed"}
    h.checks.pop("bad")
    assert h.respond("readyz")[0] == 200


def test_heartbeat_check_goes_stale():
    now = [100.0]
    beat = H.Heartbeat(lambda: now[0])
    check = H.heartbeat_check(beat, 10)
    check()
    now[0] += 11
    with pytest.raises(RuntimeError):
        check()
    beat.beat()
    check()


def test_socket_check(short_dir):
    path = os.path.join(short_dir, "s")
    with pytest.raises(RuntimeError):
        H.socket_check(path)()
    open(path, "w").close()
    with pytest.raises(RuntimeError, match="not a socket"):
        H.socket_check(path)()


# ── gateway ──────────────────────────────────────────────────────────────
def test_gateway_healthz_and_readyz_on_both_listeners(make_gateway):
    gw = make_gateway()
    for admin in (False, True):
        assert request(gw, "GET", "/healthz", admin=admin)[0] == 200
        status, _, raw = request(gw, "GET", "/readyz", admin=admin)
        body = json.loads(raw)
        assert status == 200 and body["checks"] == {"redis": "ok", "listening": "ok", "admin_socket": "ok"}


def test_gateway_readyz_fails_when_redis_is_down(make_gateway, store):
    gw = make_gateway()

    def down():
        raise ConnectionError("redis gone")

    store.r.ping = down
    assert request(gw, "GET", "/healthz")[0] == 200            # still alive
    status, _, raw = request(gw, "GET", "/readyz")
    assert status == 503 and json.loads(raw)["checks"]["redis"] == "failed"


def test_gateway_readyz_fails_when_admin_socket_is_gone(make_gateway):
    gw = make_gateway()
    os.unlink(gw.socket_path)
    status, _, raw = request(gw, "GET", "/readyz")
    assert status == 503 and json.loads(raw)["checks"]["admin_socket"].startswith("failed")


def test_gateway_metrics_count_responses_and_skip_probes(make_gateway):
    gw = make_gateway()
    request(gw, "GET", "/healthz")
    request(gw, "GET", "/nonsense/path")                        # 404
    status, _, raw = request(gw, "GET", "/metrics")
    text = raw.decode()
    assert status == 200
    assert 'nestlo_gateway_responses_total{code="404"} 1' in text
    assert 'code="200"' not in text                            # probes are not counted
    assert "nestlo_gateway_loop_detections_total 0" in text


# ── daemon ───────────────────────────────────────────────────────────────
def test_daemon_health_and_operational_metrics(make_daemon, store, tmp_path):
    daemon = make_daemon(daemon={"disk_path": str(tmp_path)})
    assert daemon.health.respond("readyz")[0] == 200
    store.open_circuit("alice", 300)
    text = daemon.metrics()
    assert "nestlo_redis_up 1" in text
    assert 'nestlo_circuit_open{agent="alice"} 1' in text
    assert "nestlo_orchestrator_queue_oldest_age_seconds 0.0" in text
    assert "nestlo_state_disk_used_ratio" in text


def test_daemon_readyz_fails_when_reaper_stalls(make_daemon):
    daemon = make_daemon()
    daemon.reap_beat.last -= 3600
    status, body = daemon.health.respond("readyz")
    assert status == 503 and body["checks"]["reaper"].startswith("failed")


def test_daemon_metrics_report_redis_down(make_daemon, store):
    daemon = make_daemon()

    def down(*a, **k):
        raise ConnectionError("gone")

    store.r.ping = down
    assert "nestlo_redis_up 0" in daemon.metrics()


# ── dashboard ────────────────────────────────────────────────────────────
def test_dashboard_probes_need_no_token_but_data_does(tmp_path, store):
    cfg_ = copy.deepcopy(configmod.DEFAULTS)
    cfg_["daemon"]["state_dir"] = str(tmp_path)
    cfg_["gateway"]["log_dir"] = str(tmp_path)
    token = tmp_path / "token"
    token.write_text("a-long-enough-token\n")
    srv = serve_dashboard(cfg_, str(token), "127.0.0.1", 0, store=store)
    try:
        port = srv.server_address[1]
        for path, want in (("/healthz", 200), ("/readyz", 200), ("/api/agents", 401)):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("GET", path)
            assert conn.getresponse().status == want, path
            conn.close()
    finally:
        srv.shutdown()


# ── orchestrator ─────────────────────────────────────────────────────────
def test_orchestrator_readyz_requires_a_ticking_loop(orch, clock):
    assert orch.app("GET", ["healthz"], {}, {})[0] == 200
    assert orch.app("GET", ["readyz"], {}, {})[0] == 200
    clock.advance(orch.tick_limit() + 1)
    status, body = orch.app("GET", ["readyz"], {}, {})
    assert status == 503 and body["checks"]["loop"].startswith("failed")
    orch.tick_beat.beat()
    assert orch.app("GET", ["readyz"], {}, {})[0] == 200


def test_orchestrator_loop_pings_the_watchdog_each_pass(orch):
    stop, sent = threading.Event(), []

    def notify(msg):
        sent.append(msg)
        if len(sent) == 3:
            stop.set()

    orch.opts["tick_sec"] = 0.01
    orch.loop(stop, notify)
    assert sent == ["WATCHDOG=1"] * 3


def test_orchestrator_health_over_the_unix_socket(orch, short_dir):
    path = os.path.join(short_dir, "o.sock")
    orch.health.add("socket", H.socket_check(path))
    server = serve_unix(path, orch.app)
    try:
        assert call(path, "GET", "/healthz")[0] == 200
        status, body = call(path, "GET", "/readyz")
        assert status == 200 and body["checks"]["socket"] == "ok"
    finally:
        server.shutdown()
