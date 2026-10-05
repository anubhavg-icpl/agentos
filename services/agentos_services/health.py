"""Health checks and systemd readiness for the AgentOS services.

* `sd_notify` speaks the systemd notification protocol with the stdlib
  (a datagram to $NOTIFY_SOCKET); no libsystemd binding is needed.
* `Health` runs named readiness checks. Every service answers
  `/healthz` (liveness: the process serves requests) and `/readyz`
  (Redis reachable, sockets listening, and for the orchestrator its loop
  ticking) from `Health.respond`.
* `Heartbeat` records the last time a loop made progress.
* `watchdog_loop` is the main loop of services without one: it sends
  READY=1 once, then WATCHDOG=1 at half the unit's WatchdogSec as long as
  the service's own probe passes.
"""

import http.client
import logging
import os
import socket
import stat
import time

log = logging.getLogger("agentos.health")

HEALTH_PATHS = ("healthz", "readyz")


# ── systemd notification ──────────────────────────────────────────────
def sd_notify(message, env=None):
    """Send `message` ("READY=1", "WATCHDOG=1", ...) to systemd.

    Returns True when it was sent. Without $NOTIFY_SOCKET (not started by
    systemd, or Type is not notify) it does nothing and returns False.
    """
    env = os.environ if env is None else env
    path = env.get("NOTIFY_SOCKET")
    if not path:
        return False
    if path[0] == "@":
        path = "\0" + path[1:]          # abstract socket namespace
    elif path[0] != "/":
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM | socket.SOCK_CLOEXEC) as sock:
            sock.settimeout(2.0)
            sock.connect(path)
            sock.sendall(message.encode())
        return True
    except OSError as exc:
        log.warning("sd_notify failed: %s", exc)
        return False


def watchdog_interval(env=None, pid=None):
    """Seconds between WATCHDOG=1 pings (half of WatchdogSec), or None when
    the unit has no watchdog or it is meant for another process."""
    env = os.environ if env is None else env
    try:
        usec = int(env.get("WATCHDOG_USEC", ""))
    except ValueError:
        return None
    if usec <= 0:
        return None
    target = env.get("WATCHDOG_PID")
    if target and target != str(os.getpid() if pid is None else pid):
        return None
    return usec / 1e6 / 2.0


# ── checks ────────────────────────────────────────────────────────────
class Heartbeat:
    """Timestamp of the last progress of a loop."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self.last = clock()

    def beat(self):
        self.last = self.clock()

    def age(self):
        return self.clock() - self.last


def redis_check(store):
    def check():
        store.r.ping()
    return check


def socket_check(path):
    """The unix socket exists and is a socket."""
    def check():
        try:
            mode = os.stat(path).st_mode
        except OSError as exc:
            raise RuntimeError("socket %s: %s" % (path, exc.strerror))
        if not stat.S_ISSOCK(mode):
            raise RuntimeError("%s is not a socket" % path)
    return check


def listening_check(servers):
    """Every server (a callable returning the list) still has an open socket."""
    def check():
        found = list(servers())
        if not found:
            raise RuntimeError("no listeners")
        for srv in found:
            if srv.socket.fileno() < 0:
                raise RuntimeError("listener closed")
    return check


def heartbeat_check(beat, max_age):
    def check():
        age = beat.age()
        if age > max_age:
            raise RuntimeError("loop has not ticked for %.0fs (limit %.0fs)" % (age, max_age))
    return check


class Health:
    def __init__(self, service, checks=None):
        self.service = service
        self.checks = dict(checks or {})

    def add(self, name, check):
        self.checks[name] = check

    def liveness(self):
        return 200, {"status": "ok", "service": self.service}

    def readiness(self):
        results, ok = {}, True
        for name, check in self.checks.items():
            try:
                check()
                results[name] = "ok"
            except Exception as exc:
                ok = False
                results[name] = "failed: %s" % (str(exc) or type(exc).__name__)
        return (200 if ok else 503), {"status": "ready" if ok else "not ready",
                                      "service": self.service, "checks": results}

    def respond(self, name):
        """(status, object) for "healthz" or "readyz"."""
        return self.liveness() if name == "healthz" else self.readiness()


def http_probe(host, port, path, timeout=2.0):
    """True if GET http://host:port/path answers 200."""
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("GET", path)
        resp = conn.getresponse()
        resp.read()
        return resp.status == 200
    except OSError:
        return False
    finally:
        conn.close()


def unix_probe(path, url, timeout=2.0):
    from . import unixapi
    try:
        status, _ = unixapi.call(path, "GET", url, timeout=timeout)
        return status == 200
    except OSError:
        return False


def watchdog_loop(stop, probe, interval=None, notify=sd_notify):
    """Main loop for services whose work happens in server threads.

    Sends READY=1 once, then WATCHDOG=1 every `interval` seconds (default:
    half of WatchdogSec, or 5s without a watchdog) while `probe()` is true.
    When the probe fails the ping is withheld, so systemd restarts the
    service after WatchdogSec.
    """
    interval = interval or watchdog_interval() or 5.0
    notify("READY=1")
    while not stop.is_set():
        try:
            healthy = probe()
        except Exception:
            log.exception("health probe error")
            healthy = False
        if healthy:
            notify("WATCHDOG=1")
        else:
            log.error("health probe failed; withholding the watchdog ping")
        stop.wait(interval)
    notify("STOPPING=1")
