"""agentos-herdr: AgentOS's view of herdr (https://herdr.dev), the terminal
workspace manager the agents run in.

  status [--user U]... [--json]   panes and agents per user with their state
                                  (working / blocked / idle / done / unknown)
  metrics [--user U]...           the same as Prometheus text, once
  monitor --port N [--interval S] serve /metrics on loopback and notify when an
                                  agent becomes blocked (runs as the user whose
                                  herdr it watches: the NixOS module starts one
                                  per configured user)
  attach [--user U] [-- ARGS]     attach to another user's herdr (through sudo)

The users come from /etc/agentos/herdr.json (written by agentos.herdr), or
from --user. A user other than the caller is queried through `runuser` (root)
or `sudo -n`, with HOME set so herdr finds that user's socket.

Everything herdr reports (agent names, labels) is untrusted: it is stripped of
control characters before it reaches a notification, and metrics only carry
the fixed state names, never agent-supplied strings.
"""

import argparse
import json
import os
import pwd
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATES = ("idle", "working", "blocked", "done", "unknown")
DEFAULT_CONFIG = "/etc/agentos/herdr.json"
USER_RE = re.compile(r"^[a-z0-9_][a-z0-9_.-]{0,31}$")
ANSI_RE = re.compile(r"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\)|.)")
CTRL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def current_user():
    try:
        return pwd.getpwuid(os.geteuid()).pw_name
    except KeyError:  # a uid without a passwd entry (some sandboxes)
        return os.environ.get("USER") or str(os.geteuid())


def clean(text, limit=60):
    return CTRL_RE.sub("", ANSI_RE.sub("", str(text or "")))[:limit]


def load_config(path=None):
    path = path or os.environ.get("AGENTOS_HERDR_CONFIG") or DEFAULT_CONFIG
    try:
        with open(path) as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {}
    cfg.setdefault("users", [])
    return cfg


def herdr_binary(cfg=None):
    return os.environ.get("AGENTOS_HERDR_BIN") or (cfg or {}).get("herdr") or "herdr"


def user_spec(cfg, name):
    for u in cfg.get("users", []):
        if u.get("name") == name:
            return u
    try:
        return {"name": name, "home": pwd.getpwnam(name).pw_dir}
    except KeyError:
        raise SystemExit(f"agentos-herdr: unknown user {name}")


def command_for(spec, binary, args):
    """argv that runs herdr as spec['name'] (directly when that is the caller)."""
    name = spec["name"]
    me = current_user()
    if name == me:
        return [binary, *args]
    env = ["env", f"HOME={spec.get('home') or pwd.getpwnam(name).pw_dir}"]
    if os.geteuid() == 0:
        return ["runuser", "-u", name, "--", *env, binary, *args]
    return ["sudo", "-n", "-u", name, *env, binary, *args]


def run_json(argv, timeout=10):
    """(result dict or None, error text or None) of a herdr CLI call."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return None, "herdr not found"
    except subprocess.TimeoutExpired:
        return None, "timed out"
    for line in reversed((p.stdout or "").strip().splitlines()):
        try:
            data = json.loads(line)
        except ValueError:
            continue
        if isinstance(data, dict):
            if "error" in data:
                err = data["error"]
                code = err.get("code") if isinstance(err, dict) else None
                return None, code or str(err)
            return data.get("result", {}), None
    return None, clean(p.stderr.strip() or f"exit status {p.returncode}", 120)


def query(spec, binary):
    """The state of one user's herdr: {user, up, error, panes, agents}."""
    out = {"user": spec["name"], "up": False, "error": None, "panes": [], "agents": []}
    res, err = run_json(command_for(spec, binary, ["pane", "list"]))
    if res is None:
        out["error"] = "server not running" if err == "server_not_running" else err
        return out
    out["up"] = True
    for p in res.get("panes", []):
        st = p.get("agent_status") if p.get("agent_status") in STATES else "unknown"
        out["panes"].append({"pane_id": clean(p.get("pane_id"), 32), "workspace_id": clean(p.get("workspace_id"), 32),
                             "state": st, "cwd": clean(p.get("cwd"), 200)})
    res, _ = run_json(command_for(spec, binary, ["agent", "list"]))
    for a in (res or {}).get("agents", []):
        st = a.get("agent_status") if a.get("agent_status") in STATES else "unknown"
        out["agents"].append({"pane_id": clean(a.get("pane_id"), 32), "state": st,
                              "name": clean(a.get("name") or a.get("agent") or a.get("kind") or a.get("pane_id"))})
    return out


def counts(items):
    c = dict.fromkeys(STATES, 0)
    for i in items:
        c[i["state"]] += 1
    return c


def render_metrics(results, notified=0):
    lines = [
        "# HELP agentos_herdr_up 1 when the user's herdr server answers.",
        "# TYPE agentos_herdr_up gauge",
    ]
    for r in results:
        lines.append(f'agentos_herdr_up{{user="{r["user"]}"}} {1 if r["up"] else 0}')
    lines += ["# HELP agentos_herdr_panes Panes by agent state.", "# TYPE agentos_herdr_panes gauge"]
    for r in results:
        for st, n in counts(r["panes"]).items():
            lines.append(f'agentos_herdr_panes{{user="{r["user"]}",state="{st}"}} {n}')
    lines += ["# HELP agentos_herdr_agents Detected coding agents by state.", "# TYPE agentos_herdr_agents gauge"]
    for r in results:
        for st, n in counts(r["agents"]).items():
            lines.append(f'agentos_herdr_agents{{user="{r["user"]}",state="{st}"}} {n}')
    lines += ["# HELP agentos_herdr_blocked_notifications_total Notifications sent for blocked agents.",
              "# TYPE agentos_herdr_blocked_notifications_total counter",
              f"agentos_herdr_blocked_notifications_total {notified}"]
    return "\n".join(lines) + "\n"


def targets(args, cfg):
    names = args.user or [u["name"] for u in cfg.get("users", [])] or [current_user()]
    for n in names:
        if not USER_RE.match(n):
            raise SystemExit(f"agentos-herdr: invalid user name {n!r}")
    return [user_spec(cfg, n) for n in names]


def cmd_status(args):
    cfg = load_config()
    binary = herdr_binary(cfg)
    results = [query(s, binary) for s in targets(args, cfg)]
    if args.json:
        print(json.dumps(results, indent=2))
        return 0
    for r in results:
        if not r["up"]:
            print(f"{r['user']}: herdr not available ({r['error']})")
            continue
        c = counts(r["panes"])
        print(f"{r['user']}: {len(r['panes'])} pane(s)  " + "  ".join(f"{n} {s}" for s, n in c.items() if n))
        for a in r["agents"]:
            print(f"    {a['pane_id']:<8} {a['state']:<8} {a['name']}")
    return 0


def cmd_metrics(args):
    cfg = load_config()
    binary = herdr_binary(cfg)
    sys.stdout.write(render_metrics([query(s, binary) for s in targets(args, cfg)]))
    return 0


def cmd_attach(args):
    cfg = load_config()
    name = args.user or "agentos-agent"
    if not USER_RE.match(name):
        raise SystemExit(f"agentos-herdr: invalid user name {name!r}")
    argv = command_for(user_spec(cfg, name), herdr_binary(cfg), args.herdr_args)
    os.execvp(argv[0], argv)


def notify_argv(notify_json, notify_cmd):
    """The notifier's argv: --notify-json keeps every argument intact,
    --notify-cmd is split on whitespace."""
    if notify_json:
        try:
            argv = json.loads(notify_json)
        except ValueError:
            argv = None
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
            raise SystemExit("--notify-json must be a non-empty JSON list of strings")
        return argv
    return notify_cmd.split() if notify_cmd else None


class Monitor:
    """Polls one user's herdr; tells the notifier when an agent has been
    blocked for `grace` seconds (once per blocked episode)."""

    def __init__(self, spec, binary, notify_argv=None, grace=15, clock=time.time, runner=subprocess.run):
        self.spec, self.binary = spec, binary
        self.notify_argv, self.grace = notify_argv, grace
        self.clock, self.runner = clock, runner
        self.blocked_since = {}   # pane_id -> first time seen blocked
        self.notified = set()     # pane ids notified in this blocked episode
        self.sent = 0
        self.last = {"user": spec["name"], "up": False, "error": "not polled yet", "panes": [], "agents": []}
        self.lock = threading.Lock()

    def poll(self):
        r = query(self.spec, self.binary)
        now = self.clock()
        names = {a["pane_id"]: a["name"] for a in r["agents"]}
        blocked = {p["pane_id"] for p in r["panes"] if p["state"] == "blocked"}
        for pid in list(self.blocked_since):
            if pid not in blocked:
                del self.blocked_since[pid]
                self.notified.discard(pid)
        for pid in sorted(blocked):
            first = self.blocked_since.setdefault(pid, now)
            if pid not in self.notified and now - first >= self.grace:
                self.notified.add(pid)
                self.notify(f"agent {names.get(pid, 'in pane ' + pid)} is blocked and waits for input "
                            f"(herdr pane {pid}, user {self.spec['name']})")
        with self.lock:
            self.last = r
        return r

    def notify(self, message):
        print(f"blocked: {message}", file=sys.stderr, flush=True)
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

    def metrics(self):
        with self.lock:
            return render_metrics([self.last], self.sent)

    def snapshot(self):
        with self.lock:
            return json.dumps(self.last)


def make_handler(monitor):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/metrics":
                body, ctype = monitor.metrics(), "text/plain; version=0.0.4"
            elif self.path == "/status":
                body, ctype = monitor.snapshot(), "application/json"
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


def cmd_monitor(args):
    cfg = load_config()
    me = current_user()
    spec = user_spec(cfg, me)
    notify = notify_argv(args.notify_json, args.notify_cmd)
    mon = Monitor(spec, herdr_binary(cfg), notify, args.grace)
    mon.poll()
    server = ThreadingHTTPServer((args.listen, args.port), make_handler(mon))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"agentos-herdr monitor for {me} on http://{args.listen}:{args.port}/metrics", file=sys.stderr, flush=True)
    try:
        while True:
            time.sleep(args.interval)
            try:
                mon.poll()
            except Exception as e:  # a bad poll must not stop the exporter
                print(f"poll failed: {e}", file=sys.stderr, flush=True)
    except KeyboardInterrupt:
        return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="agentos-herdr", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("status", help="panes and agents per user")
    s.add_argument("--user", action="append")
    s.add_argument("--json", action="store_true")
    m = sub.add_parser("metrics", help="Prometheus text, once")
    m.add_argument("--user", action="append")
    mo = sub.add_parser("monitor", help="serve metrics and notify on blocked agents")
    mo.add_argument("--listen", default="127.0.0.1")
    mo.add_argument("--port", type=int, required=True)
    mo.add_argument("--interval", type=float, default=10)
    mo.add_argument("--grace", type=float, default=15, help="seconds blocked before notifying")
    mo.add_argument("--notify-cmd", help="command that gets the message as its last argument (split on spaces)")
    mo.add_argument("--notify-json", help="the notify command as a JSON list of arguments (kept intact)")
    at = sub.add_parser("attach", help="attach to a user's herdr")
    at.add_argument("--user")
    at.add_argument("herdr_args", nargs="*")
    args = p.parse_args(argv)
    return {"status": cmd_status, "metrics": cmd_metrics, "monitor": cmd_monitor, "attach": cmd_attach}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
