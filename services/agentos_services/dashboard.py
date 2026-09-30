"""AgentOS web dashboard.

A read-only status page and JSON API for operators. It reads spend and
budgets from the control-plane Redis (through the Store), agent records from
the daemon's state directory and request logs from the gateway's log
directory. It never writes to any of them, and offers no actions: killing an
agent or changing a budget stays with `agentos kill` / `agentos-budget`.

Access control: every request needs the dashboard token, sent as an
`Authorization: Bearer <token>` header or as the password of HTTP basic auth
(any user name), so a browser just prompts for it. The token is read from a
file on each request; the service refuses to start without one. By default it
listens on 127.0.0.1 only; reach it with an SSH tunnel, like Grafana.

Endpoints (GET):
  /                       the dashboard page
  /api/health             redis, gateway and daemon reachability
  /api/agents             running agents and recent history, with spend
  /api/spend              today's spend per agent and per model
  /api/history?days=N     spend per day (default 7) with per-agent split
  /api/requests?agent=ID&limit=N   tail of one agent's gateway request log
"""

import argparse
import base64
import hmac
import http.server
import json
import logging
import os
import sys
import threading
import time
import urllib.parse
import urllib.request

from . import config as configmod
from .dashboard_page import PAGE
from .store import Store, connect, utc_date

log = logging.getLogger("agentos.dashboard")

HISTORY_LIMIT = 25          # finished agents shown
LOG_TAIL_BYTES = 256 * 1024  # how much of a request log is scanned
MAX_REQUESTS = 500


class Dashboard:
    def __init__(self, cfg, store, token_file, clock=time.time):
        self.cfg = cfg
        self.store = store
        self.token_file = token_file
        self.clock = clock
        self.state_dir = cfg["daemon"]["state_dir"]
        self.log_dir = cfg["gateway"]["log_dir"]

    # ── auth ───────────────────────────────────────────────────────────
    def token(self):
        try:
            with open(self.token_file) as f:
                return f.read().strip()
        except OSError:
            return ""

    def authorized(self, header):
        token = self.token()
        if not token or not header:
            return False
        scheme, _, value = header.partition(" ")
        value = value.strip()
        scheme = scheme.lower()
        if scheme == "basic":
            try:
                value = base64.b64decode(value).decode().partition(":")[2]
            except (ValueError, UnicodeDecodeError):
                return False
        elif scheme != "bearer":
            return False
        return hmac.compare_digest(value.encode(), token.encode())

    # ── routing ────────────────────────────────────────────────────────
    def handle(self, path, authorization):
        """Returns (status, content_type, body_bytes)."""
        if not self.authorized(authorization):
            return 401, "application/json", _json({"error": "unauthorized"})
        parts = urllib.parse.urlsplit(path)
        query = urllib.parse.parse_qs(parts.query)
        route = parts.path.rstrip("/") or "/"
        if route == "/":
            return 200, "text/html; charset=utf-8", PAGE.encode()
        handlers = {
            "/api/health": self.health,
            "/api/agents": self.agents,
            "/api/spend": self.spend,
            "/api/history": self.history,
            "/api/requests": self.requests,
        }
        fn = handlers.get(route)
        if fn is None:
            return 404, "application/json", _json({"error": "not found"})
        try:
            status, obj = fn(query)
        except Exception as exc:  # Redis down etc.: report, don't crash
            log.warning("%s failed: %s", route, exc)
            return 500, "application/json", _json({"error": "%s: %s" % (type(exc).__name__, exc)})
        return status, "application/json", _json(obj)

    # ── API ────────────────────────────────────────────────────────────
    def _limit(self, agent):
        return self.store.limit(agent, self.cfg["budget"]["default_daily_usd"])

    def _read_states(self, directory):
        out = []
        try:
            names = os.listdir(directory)
        except OSError:
            return out
        for name in names:
            if not name.endswith(".json"):
                continue
            path = os.path.join(directory, name)
            try:
                with open(path) as f:
                    state = json.load(f)
                mtime = os.path.getmtime(path)
            except (OSError, ValueError):
                continue
            if isinstance(state, dict) and configmod.valid_agent_id(str(state.get("id", ""))):
                state["_mtime"] = mtime
                out.append(state)
        return out

    def _decorate(self, state):
        agent = state["id"]
        usd = self.store.spend(agent)
        limit = self._limit(agent)
        state.pop("_mtime", None)
        state["usd_today"] = usd
        state["limit_usd"] = limit
        state["budget_pct"] = round(usd / limit * 100, 1) if limit > 0 else None
        return state

    def agents(self, query):
        states = self._read_states(self.state_dir)
        running = sorted((s for s in states if s.get("status") == "running"),
                         key=lambda s: s.get("started_at", 0), reverse=True)
        finished = [s for s in states if s.get("status") != "running"]
        hist = self._read_states(os.path.join(self.state_dir, "history")) + finished
        hist.sort(key=lambda s: s.pop("_mtime", 0), reverse=True)
        return 200, {
            "date": utc_date(self.clock()),
            "running": [self._decorate(s) for s in running],
            "history": [self._decorate(s) for s in hist[:HISTORY_LIMIT]],
        }

    def spend(self, query):
        snap = self.store.snapshot(None, self.cfg["budget"]["default_daily_usd"])
        snap["global_limit_usd"] = float(self.cfg["budget"]["global_daily_usd"])
        snap["default_limit_usd"] = float(self.cfg["budget"]["default_daily_usd"])
        return 200, snap

    def history(self, query):
        days = _int((query.get("days") or ["7"])[0], 7, 1, 35)
        now = self.clock()
        out = []
        for i in range(days):
            date = utc_date(now - i * 86400)
            snap = self.store.snapshot(date, self.cfg["budget"]["default_daily_usd"])
            out.append({
                "date": date,
                "global_usd": snap["global_usd"],
                "agents": {a: v["usd"] for a, v in snap["agents"].items()},
                "models": snap["models"],
            })
        return 200, {"days": out}

    def requests(self, query):
        agent = (query.get("agent") or [""])[0]
        if not configmod.valid_agent_id(agent):
            return 400, {"error": "agent must be a valid agent id"}
        limit = _int((query.get("limit") or ["50"])[0], 50, 1, MAX_REQUESTS)
        return 200, {"agent": agent, "requests": tail_log(self.log_dir, agent, limit)}

    def health(self, query):
        services = {}
        try:
            services["redis"] = {"ok": bool(self.store.r.ping())}
        except Exception as exc:
            services["redis"] = {"ok": False, "error": str(exc)}
        gw = self.cfg["gateway"]
        host = gw["listen"] if gw["listen"] not in ("0.0.0.0", "") else "127.0.0.1"
        services["gateway"] = _probe("http://%s:%s/_agentos/health" % (host, gw["port"]))
        d = self.cfg["daemon"]
        services["daemon"] = _probe("http://%s:%s/metrics" % (d["metrics_listen"], d["metrics_port"]), parse=False)
        return 200, {"ok": all(s["ok"] for s in services.values()), "services": services,
                     "time": self.clock()}


def tail_log(log_dir, agent, limit):
    """Last `limit` entries of <log_dir>/<agent>.log, newest first."""
    path = os.path.join(log_dir, agent + ".log")
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - LOG_TAIL_BYTES))
            data = f.read()
    except OSError:
        return []
    lines = data.splitlines()
    if size > LOG_TAIL_BYTES and lines:
        lines = lines[1:]  # first line is probably cut in half
    out = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            out.append(entry)
            if len(out) >= limit:
                break
    return out


def _probe(url, parse=True):
    try:
        with urllib.request.urlopen(url, timeout=2) as resp:
            body = resp.read(65536)
            result = {"ok": resp.status == 200}
            if parse:
                result["detail"] = json.loads(body)
            return result
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def _int(value, default, lo, hi):
    try:
        return max(lo, min(hi, int(value)))
    except (TypeError, ValueError):
        return default


def _json(obj):
    return json.dumps(obj).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "agentos-dashboard"

    def do_GET(self):
        status, ctype, body = self.server.dashboard.handle(self.path, self.headers.get("Authorization"))
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
                         "connect-src 'self'; base-uri 'none'; form-action 'none'")
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="AgentOS dashboard", charset="UTF-8"')
        self.end_headers()
        self.wfile.write(body)

    def _method_not_allowed(self):
        body = _json({"error": "the dashboard is read-only"})
        self.send_response(405)
        self.send_header("Allow", "GET")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_PUT = do_DELETE = do_PATCH = _method_not_allowed

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.client_address[0], fmt % args)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def serve(cfg, token_file, listen="127.0.0.1", port=8090, store=None):
    store = store or Store(connect(cfg["redis"]["url"]))
    srv = Server((listen, port), Handler)
    srv.dashboard = Dashboard(cfg, store, token_file)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS web dashboard (read-only)")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8090)
    parser.add_argument("--token-file", required=True, help="file holding the access token")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    try:
        with open(args.token_file) as f:
            token = f.read().strip()
    except OSError as exc:
        parser.error("cannot read token file: %s" % exc)
    if len(token) < 8:
        parser.error("the token in %s is empty or shorter than 8 characters" % args.token_file)
    cfg = configmod.load(args.config)
    srv = serve(cfg, args.token_file, args.listen, args.port)
    log.info("listening on http://%s:%d", args.listen, args.port)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        srv.shutdown()


if __name__ == "__main__":
    main()
