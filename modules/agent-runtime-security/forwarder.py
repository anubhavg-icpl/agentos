#!/usr/bin/env python3
"""Nestlo agent runtime security forwarder.

Tails the JSON export of Tetragon (one protojson event per line), keeps the
events that belong to Nestlo agents (process uid in the configured users)
and
  * writes one normalised alert per line to the alerts log,
  * sends it to the Nestlo audit writer (unix socket, one JSON line per event),
  * counts it for Prometheus (/metrics on loopback),
  * in enforce mode kills the offending process (or its agent unit).

Tetragon cannot select by uid in the kernel, so its policies match on what is
touched (paths, syscalls, destinations) and this program applies the "is this
an agent" test. Stdlib only. Configuration: a JSON file (--config).
"""

import argparse
import collections
import json
import os
import pwd
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

POLICY_PREFIX = "nestlo-ars-"
SEVERITY = {
    "credential-access": "critical",
    "kernel-module": "critical",
    "ptrace": "high",
    "raw-socket": "high",
    "egress-bypass": "medium",
    "write-protected": "high",
}
UNIT_RE = re.compile(r"/([^/]+\.service)$")


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Metrics:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = collections.Counter()      # (rule, action) -> n
        self.audit_sent = 0
        self.audit_dropped = 0
        self.parse_errors = 0

    def render(self):
        with self.lock:
            out = ["# HELP nestlo_runtime_security_events_total Agent runtime security events by rule and action",
                   "# TYPE nestlo_runtime_security_events_total counter"]
            for (rule, action), n in sorted(self.events.items()):
                out.append('nestlo_runtime_security_events_total{rule="%s",action="%s"} %d' % (rule, action, n))
            out += ["# TYPE nestlo_runtime_security_audit_sent_total counter",
                    "nestlo_runtime_security_audit_sent_total %d" % self.audit_sent,
                    "# TYPE nestlo_runtime_security_audit_dropped_total counter",
                    "nestlo_runtime_security_audit_dropped_total %d" % self.audit_dropped,
                    "# TYPE nestlo_runtime_security_parse_errors_total counter",
                    "nestlo_runtime_security_parse_errors_total %d" % self.parse_errors]
            return "\n".join(out) + "\n"


def serve_metrics(metrics, port):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/metrics":
                self.send_error(404)
                return
            body = metrics.render().encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    srv = HTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True, name="metrics").start()


class AuditSink:
    """Best-effort client of the audit writer socket: buffers while it is away."""

    def __init__(self, path, event_type, metrics, capacity=1000):
        self.path = path
        self.type = event_type
        self.metrics = metrics
        self.buf = collections.deque()
        self.capacity = capacity
        self.sock = None
        self.warned = False

    def _connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(self.path)
        self.sock = s
        self.warned = False

    def emit(self, actor, data):
        if not self.path:
            return
        ev = {"type": self.type, "actor": actor, "source": "agent-runtime-security",
              "data": data, "ets": int(time.time() * 1000)}
        line = json.dumps(ev, separators=(",", ":"), default=str).encode() + b"\n"
        if len(self.buf) >= self.capacity:
            self.buf.popleft()
            with self.metrics.lock:
                self.metrics.audit_dropped += 1
        self.buf.append(line)
        self.flush()

    def flush(self):
        while self.buf:
            try:
                if self.sock is None:
                    self._connect()
                self.sock.sendall(self.buf[0])
                self.buf.popleft()
                with self.metrics.lock:
                    self.metrics.audit_sent += 1
            except OSError as exc:
                if not self.warned:
                    log("audit socket %s unavailable (%s); buffering" % (self.path, exc))
                    self.warned = True
                if self.sock is not None:
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                    self.sock = None
                return


def resolve_uids(names, known):
    uids = {}
    for n in names:
        try:
            uids[pwd.getpwnam(n).pw_uid] = n
        except KeyError:
            if n not in known:
                log("user %s does not exist (yet); events of that user are ignored" % n)
            known.add(n)
    return uids


def arg_value(arg):
    """One kprobe argument as a short string."""
    if not isinstance(arg, dict):
        return None
    for key, val in arg.items():
        if key == "label":
            continue
        if isinstance(val, dict):
            if "path" in val:
                return val.get("path")
            if "addr" in val:
                return "%s:%s" % (val.get("addr"), val.get("port", "?"))
            if "family" in val:
                return str(val.get("family"))
            return json.dumps(val, separators=(",", ":"))[:200]
        return str(val)
    return None


def normalise(raw, rule, uids):
    kp = raw.get("process_kprobe")
    if kp is None:
        return None
    proc = kp.get("process") or {}
    uid = proc.get("uid", 0)
    if uid not in uids:
        return None
    args = [arg_value(a) for a in kp.get("args") or []]
    args = [a for a in args if a is not None]
    if rule in ("credential-access", "write-protected"):
        target = args[0] if args else ""
    elif rule == "egress-bypass":
        target = args[0] if args else ""
    else:
        target = " ".join(args) or kp.get("function_name", "")
    return {
        "rule": rule,
        "severity": SEVERITY.get(rule, "high"),
        "user": uids[uid],
        "uid": uid,
        "pid": proc.get("pid"),
        "binary": proc.get("binary"),
        "arguments": (proc.get("arguments") or "")[:512],
        "cwd": proc.get("cwd"),
        "parent_binary": (kp.get("parent") or {}).get("binary"),
        "target": target,
        "function": kp.get("function_name"),
        "policy": kp.get("policy_name"),
        "message": kp.get("message"),
        "start_time": proc.get("start_time"),
        "kernel_action": kp.get("action"),
        "ts": raw.get("time"),
    }


def unit_of(pid):
    try:
        with open("/proc/%d/cgroup" % pid) as f:
            for line in f:
                m = UNIT_RE.search(line.strip())
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def enforce(alert, scope, killable_units):
    """Kill the process (or its agent unit). Returns "killed" or a failure word."""
    pid = alert.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return "kill_skipped"
    # PIDs are recycled: the process must still run the same binary as the same uid
    try:
        with open("/proc/%d/status" % pid) as f:
            uids = [l for l in f if l.startswith("Uid:")][0].split()[1:3]
        if int(uids[0]) != alert["uid"]:
            return "kill_skipped"
        if os.readlink("/proc/%d/exe" % pid) != alert["binary"]:
            return "kill_skipped"
    except (OSError, IndexError, ValueError):
        return "gone"
    unit = unit_of(pid)
    alert["unit"] = unit
    try:
        if scope == "unit" and unit and any(unit.startswith(p) for p in killable_units):
            subprocess.run(["systemctl", "kill", "--signal=SIGKILL", "--kill-whom=all", unit],
                           check=True, timeout=10, capture_output=True)
        else:
            os.kill(pid, signal.SIGKILL)
        return "killed"
    except (OSError, subprocess.SubprocessError) as exc:
        log("cannot kill pid %s: %s" % (pid, exc))
        return "kill_failed"


class Tail:
    """Follows a file across rotation, resuming from a saved offset."""

    def __init__(self, path, state_path):
        self.path = path
        self.state_path = state_path
        self.f = None
        self.buf = b""
        self.saved = 0.0

    def _open(self, resume):
        try:
            f = open(self.path, "rb")
        except OSError:
            return False
        ino = os.fstat(f.fileno()).st_ino
        off = 0
        if resume:
            try:
                with open(self.state_path) as s:
                    st = json.load(s)
                if st.get("ino") == ino and st.get("off", 0) <= os.fstat(f.fileno()).st_size:
                    off = st["off"]
            except (OSError, ValueError):
                pass
        f.seek(off)
        self.f = f
        self.buf = b""
        return True

    def _save(self, force=False):
        now = time.time()
        if not force and now - self.saved < 5 or self.f is None:
            return
        self.saved = now
        try:
            tmp = self.state_path + ".tmp"
            with open(tmp, "w") as s:
                json.dump({"ino": os.fstat(self.f.fileno()).st_ino, "off": self.f.tell() - len(self.buf)}, s)
            os.replace(tmp, self.state_path)
        except OSError:
            pass

    def lines(self):
        """Generator of complete lines; sleeps when there is nothing new."""
        first = True
        while True:
            if self.f is None:
                if not self._open(resume=first):
                    time.sleep(1)
                    continue
                first = False
            chunk = self.f.read(65536)
            if chunk:
                self.buf += chunk
                *done, self.buf = self.buf.split(b"\n")
                for line in done:
                    if line.strip():
                        yield line
                self._save()
                continue
            # at the end: has the file been rotated away?
            try:
                st = os.stat(self.path)
                rotated = st.st_ino != os.fstat(self.f.fileno()).st_ino
            except OSError:
                rotated = False
            if rotated:
                self._save(force=True)
                self.f.close()
                self.f = None
                continue
            self._save()
            time.sleep(0.5)
            yield None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    cfg = json.load(open(ap.parse_args().config))

    metrics = Metrics()
    if cfg.get("metrics_port"):
        serve_metrics(metrics, cfg["metrics_port"])
    audit = AuditSink(cfg.get("audit_socket"), cfg["audit_event_type"], metrics)
    alerts_path = cfg["alerts_log"]
    enforced = set(cfg["enforce_rules"]) if cfg["mode"] == "enforce" else set()
    dedupe = cfg["dedupe_seconds"]

    known = set()
    uids = resolve_uids(cfg["users"], known)
    uids_at = time.time()
    seen = {}                      # key -> [last emit time, suppressed count]
    alerts = open(alerts_path, "a", buffering=1)
    log("watching %s for users %s, mode %s" % (cfg["export_file"], sorted(uids.values()), cfg["mode"]))

    tail = Tail(cfg["export_file"], cfg["state_file"])
    for line in tail.lines():
        now = time.time()
        audit.flush()
        if now - uids_at > 60:
            uids, uids_at = resolve_uids(cfg["users"], known), now
        if len(seen) > 5000:
            seen = {k: v for k, v in seen.items() if now - v[0] < dedupe}
        if line is None:
            continue
        try:
            raw = json.loads(line)
        except ValueError:
            with metrics.lock:
                metrics.parse_errors += 1
            continue
        name = ((raw.get("process_kprobe") or {}).get("policy_name")) or ""
        if not name.startswith(POLICY_PREFIX):
            continue
        rule = name[len(POLICY_PREFIX):]
        alert = normalise(raw, rule, uids)
        if alert is None:
            continue

        action = "alert"
        if rule in enforced:
            action = enforce(alert, cfg["kill_scope"], cfg["killable_unit_prefixes"])
        alert["action"] = action
        with metrics.lock:
            metrics.events[(rule, action)] += 1

        key = (rule, alert["uid"], alert["binary"], alert["target"], action)
        last = seen.get(key)
        if last and now - last[0] < dedupe and action == "alert":
            last[1] += 1
            continue
        alert["repeats"] = last[1] if last else 0
        seen[key] = [now, 0]
        if not alert.get("unit"):
            alert["unit"] = unit_of(alert["pid"]) if isinstance(alert.get("pid"), int) else None
        alerts.write(json.dumps(alert, separators=(",", ":"), default=str) + "\n")
        log("%s %s %s by %s (%s) %s" % (alert["severity"].upper(), rule, alert["target"], alert["user"],
                                         alert["binary"], action))
        audit.emit(alert["user"], alert)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    main()
