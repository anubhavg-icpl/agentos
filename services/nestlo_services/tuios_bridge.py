"""nestlo-tuios-bridge: Nestlo's view of TUIOS (https://github.com/Gaurav-Gosain/tuios),
the terminal multiplexer the agents run in.

It follows `tuios subscribe` (the daemon's event stream, one JSON object per
line) for one user and

  - writes an audit event of type `terminal.tuios` for every window that opens
    or closes, every command that finishes (when the shell marks its commands
    with OSC 133), every agent state change and every session that is created
    or closed,
  - tells the notifier (nestlo-notify) when an agent has waited for input
    longer than --grace seconds, once per wait,
  - serves nestlo_tuios_* Prometheus metrics on loopback (--port).

It runs as the user whose daemon it follows (the NixOS module starts one per
user) and is a read-only client of the daemon's socket. When the stream ends
(the daemon restarted or is not up yet) it reconnects, resuming at the last
seq it saw; a restarted daemon shows up as a `gap` line, counted in
nestlo_tuios_stream_gaps_total.

Everything TUIOS reports (window titles, command lines) is untrusted: it is
stripped of control characters and cut before it reaches the audit log or a
notification, and metrics only carry the fixed state names. Command lines go
to the audit log only with --command-lines (TUIOS masks likely secrets in
them, which is a heuristic).
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import audit as auditmod
from .herdr_bridge import clean, current_user, notify_argv

AUDIT_TYPE = "terminal.tuios"
SOURCE = "tuios-bridge"
FOLLOWED = ("window-created", "window-closed", "command-finished", "agent-state",
            "session-created", "session-closed")
STATES = ("none", "working", "needs_input", "idle", "done", "errored", "unknown")
DEFAULT_AUDIT_SOCKET = "/run/nestlo-audit/audit.sock"


def tuios_binary():
    return os.environ.get("NESTLO_TUIOS_BIN") or "tuios"


def _int(value):
    return value if isinstance(value, int) and not isinstance(value, bool) else None


class Bridge:
    """Turns stream lines into audit events, notifications and metrics."""

    def __init__(self, user, audit=None, notify=None, grace=15, command_lines=False,
                 clock=time.time, runner=subprocess.run):
        self.user = user
        self.audit = audit or auditmod.NullClient()
        self.notify_argv, self.grace = notify, grace
        self.command_lines = command_lines
        self.clock, self.runner = clock, runner
        self.lock = threading.Lock()
        self.connected = False
        self.boot_id = None
        self.last_seq = None
        self.agents = {}          # (session, window) -> state
        self.waiting = {}         # (session, window) -> first time seen on needs_input
        self.notified = set()     # keys notified in the current wait
        self.events = {}          # type -> count
        self.sent = 0
        self.gaps = 0
        self.reconnects = 0
        self.ignored = 0
        self.current = None       # the running `tuios subscribe`

    # -- one line of the stream
    def handle_line(self, line):
        """Process one line; returns the event type handled or None."""
        try:
            ev = json.loads(line)
        except ValueError:
            self.ignored += 1
            return None
        if not isinstance(ev, dict):
            self.ignored += 1
            return None
        etype = ev.get("type")
        if etype == "subscribed":
            with self.lock:
                self.boot_id = clean(ev.get("boot_id"), 32) or self.boot_id
                seq = _int(ev.get("seq"))
                if seq is not None and self.last_seq is None:
                    self.last_seq = seq
            return etype
        if etype == "gap":
            with self.lock:
                self.gaps += 1
                # The numbering may restart (boot_changed): current agent states
                # are unknown until the next agent-state event.
                if ev.get("reason") in ("boot_changed", "overflow", "evicted"):
                    self.agents.clear()
                    self.waiting.clear()
                    self.notified.clear()
                if ev.get("reason") == "boot_changed":
                    self.last_seq = None
                    self.boot_id = clean(ev.get("boot_id"), 32) or None
            return etype
        if etype not in FOLLOWED:
            self.ignored += 1
            return None
        seq = _int(ev.get("seq"))
        with self.lock:
            if seq is not None:
                self.last_seq = seq
            if ev.get("boot_id"):
                self.boot_id = clean(ev.get("boot_id"), 32)
            self.events[etype] = self.events.get(etype, 0) + 1
        getattr(self, "on_" + etype.replace("-", "_"))(ev)
        return etype

    @staticmethod
    def _ids(ev):
        return clean(ev.get("session"), 64), clean(ev.get("window"), 64)

    def _audit(self, kind, **data):
        self.audit.emit(AUDIT_TYPE, self.user, event=kind, **data)

    def on_window_created(self, ev):
        session, window = self._ids(ev)
        self._audit("window-created", session=session, window=window, title=clean(ev.get("title"), 80) or None)

    def on_window_closed(self, ev):
        session, window = self._ids(ev)
        with self.lock:
            self._forget((session, window))
        self._audit("window-closed", session=session, window=window)

    def on_session_created(self, ev):
        self._audit("session-created", session=clean(ev.get("session"), 64))

    def on_session_closed(self, ev):
        session = clean(ev.get("session"), 64)
        with self.lock:
            for key in [k for k in self.agents if k[0] == session]:
                self._forget(key)
        self._audit("session-closed", session=session)

    def on_command_finished(self, ev):
        session, window = self._ids(ev)
        data = {"session": session, "window": window, "exit_code": _int(ev.get("exit_code")),
                "duration_ms": _int(ev.get("duration_ms"))}
        if self.command_lines:
            data["cmdline"] = clean(ev.get("cmdline"), 200) or None
        self._audit("command-finished", **data)

    def on_agent_state(self, ev):
        session, window = self._ids(ev)
        state = ev.get("state") if ev.get("state") in STATES else "unknown"
        key = (session, window)
        with self.lock:
            prev = self.agents.get(key, "none")
            if state == "none":
                self._forget(key)
            else:
                self.agents[key] = state
                if state == "needs_input":
                    self.waiting.setdefault(key, self.clock())
                else:
                    self.waiting.pop(key, None)
                    self.notified.discard(key)
        self._audit("agent-state", session=session, window=window, state=state, previous=prev)

    def _forget(self, key):
        self.agents.pop(key, None)
        self.waiting.pop(key, None)
        self.notified.discard(key)

    # -- notifications
    def tick(self):
        """Notify for agents that have waited for input longer than the grace period."""
        now = self.clock()
        due = []
        with self.lock:
            for key, since in sorted(self.waiting.items()):
                if key not in self.notified and now - since >= self.grace:
                    self.notified.add(key)
                    due.append(key)
        for session, window in due:
            self.notify(f"an agent in tuios window {window} (session {session}, user {self.user}) waits for input")
        return len(due)

    def notify(self, message):
        print(f"needs input: {message}", file=sys.stderr, flush=True)
        if not self.notify_argv:
            return
        try:
            p = self.runner([*self.notify_argv, message], capture_output=True, text=True, timeout=30)
            if p.returncode == 0:
                self.sent += 1
            else:
                print(f"notification failed: {clean(p.stderr or p.stdout, 200)}", file=sys.stderr, flush=True)
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"notification failed: {e}", file=sys.stderr, flush=True)

    # -- metrics
    def metrics(self):
        u = self.user
        with self.lock:
            counts = dict.fromkeys(STATES, 0)
            for st in self.agents.values():
                counts[st] += 1
            events = dict(self.events)
            up = 1 if self.connected else 0
        lines = [
            "# HELP nestlo_tuios_up 1 while the event stream of the user's TUIOS daemon is connected.",
            "# TYPE nestlo_tuios_up gauge",
            f'nestlo_tuios_up{{user="{u}"}} {up}',
            "# HELP nestlo_tuios_agents Agent panes by state, as reported on the event stream.",
            "# TYPE nestlo_tuios_agents gauge",
        ]
        lines += [f'nestlo_tuios_agents{{user="{u}",state="{st}"}} {n}' for st, n in counts.items()]
        lines += ["# HELP nestlo_tuios_events_total Stream events handled, by type.",
                  "# TYPE nestlo_tuios_events_total counter"]
        lines += [f'nestlo_tuios_events_total{{user="{u}",type="{t}"}} {events.get(t, 0)}' for t in FOLLOWED]
        lines += [
            "# HELP nestlo_tuios_needs_input_notifications_total Notifications sent for agents waiting for input.",
            "# TYPE nestlo_tuios_needs_input_notifications_total counter",
            f'nestlo_tuios_needs_input_notifications_total{{user="{u}"}} {self.sent}',
            "# HELP nestlo_tuios_stream_gaps_total Gaps (missed events) reported by the daemon.",
            "# TYPE nestlo_tuios_stream_gaps_total counter",
            f'nestlo_tuios_stream_gaps_total{{user="{u}"}} {self.gaps}',
            "# HELP nestlo_tuios_stream_reconnects_total Times the event stream was opened again.",
            "# TYPE nestlo_tuios_stream_reconnects_total counter",
            f'nestlo_tuios_stream_reconnects_total{{user="{u}"}} {self.reconnects}',
            "# HELP nestlo_tuios_audit_dropped_total Audit events lost because the audit writer was unreachable.",
            "# TYPE nestlo_tuios_audit_dropped_total counter",
            f'nestlo_tuios_audit_dropped_total{{user="{u}"}} {getattr(self.audit, "dropped", 0)}',
        ]
        return "\n".join(lines) + "\n"

    # -- the stream
    def subscribe_argv(self, binary):
        argv = [binary, "subscribe", "--types", ",".join(FOLLOWED)]
        with self.lock:
            if self.last_seq is not None and self.boot_id:
                argv += ["--after-seq", str(self.last_seq), "--boot-id", self.boot_id]
        return argv

    def follow(self, binary, stop, popen=subprocess.Popen, retry=3.0, sleep=time.sleep, once=False):
        """Follow the stream until `stop` is set (or one connection, with once)."""
        while not stop.is_set():
            try:
                proc = popen(self.subscribe_argv(binary), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            except OSError as e:
                print(f"cannot run {binary}: {e}", file=sys.stderr, flush=True)
                proc = None
            if proc is not None:
                self.reconnects += 1
                self.current = proc
                try:
                    for line in proc.stdout:
                        if not self.connected:
                            self.connected = True
                        if line.strip():
                            self.handle_line(line)
                finally:
                    self.connected = False
                    proc.wait()
                if proc.returncode not in (0, None) and not stop.is_set():
                    err = clean(proc.stderr.read() if proc.stderr else "", 200)
                    print(f"tuios subscribe ended with status {proc.returncode}: {err}", file=sys.stderr, flush=True)
            if once:
                return
            if not stop.is_set():
                sleep(retry)


def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/metrics":
                body, ctype = bridge.metrics(), "text/plain; version=0.0.4"
            elif self.path == "/healthz":
                body, ctype = "ok\n", "text/plain"
            else:
                self.send_error(404)
                return
            data = body.encode()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    return Handler


def main(argv=None):
    p = argparse.ArgumentParser(prog="nestlo-tuios-bridge", description=__doc__.split("\n\n")[0])
    p.add_argument("--listen", default="127.0.0.1")
    p.add_argument("--port", type=int, default=0, help="serve /metrics on this loopback port (0: off)")
    p.add_argument("--grace", type=float, default=15, help="seconds an agent waits for input before a notification")
    p.add_argument("--notify-json", help="the notify command as a JSON list of arguments; the message is appended")
    p.add_argument("--audit-socket", help="audit writer socket (default: no audit events)")
    p.add_argument("--audit-buffer", type=int, default=1000)
    p.add_argument("--command-lines", action="store_true", help="put the command line of finished commands in the audit event")
    p.add_argument("--retry", type=float, default=3.0, help="seconds between attempts to open the stream")
    args = p.parse_args(argv)

    user = current_user()
    audit = auditmod.AuditClient(args.audit_socket, source=SOURCE, buffer=args.audit_buffer) \
        if args.audit_socket else auditmod.NullClient()
    bridge = Bridge(user, audit, notify_argv(args.notify_json, None), args.grace, args.command_lines)
    stop = threading.Event()

    def shutdown(*_):
        stop.set()
        proc = bridge.current
        if proc is not None and proc.poll() is None:
            proc.terminate()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    if args.port:
        server = ThreadingHTTPServer((args.listen, args.port), make_handler(bridge))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"nestlo-tuios-bridge for {user} on http://{args.listen}:{args.port}/metrics", file=sys.stderr, flush=True)

    def ticker():
        while not stop.wait(1.0):
            try:
                bridge.tick()
            except Exception as e:  # a failed notification must not stop the bridge
                print(f"tick failed: {e}", file=sys.stderr, flush=True)

    threading.Thread(target=ticker, daemon=True).start()
    bridge.follow(tuios_binary(), stop, retry=args.retry)
    audit.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
