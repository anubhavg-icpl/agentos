"""AgentOS agent daemon.

Responsibilities:
  * Registry: `agentos spawn` writes one JSON file per agent into the state
    directory. The daemon marks agents whose systemd unit (or process) is
    gone as exited and moves them to state/history/.
  * Enforcement: on a budget_exceeded event from the gateway it stops the
    agent's systemd unit when auto-shutdown is enabled (sandboxed agents run
    as agentos-agent-<id>.service; a polkit rule lets this daemon stop them).
  * Notifications: forwards selected events to Slack, Discord or generic
    webhooks.
  * Metrics: Prometheus text format on /metrics (default 127.0.0.1:9950).
"""

import argparse
import http.server
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request

from . import config as configmod
from .gpu import Registry as GpuRegistry
from .store import Store, connect

log = logging.getLogger("agentos.daemon")

STARTUP_GRACE_SEC = 15

EVENT_TEXT = {
    "agent_started": "Agent {agent} started ({command})",
    "agent_exited": "Agent {agent} finished",
    "agent_killed": "Agent {agent} was stopped: {reason}",
    "budget_threshold": "Agent {agent} has used {threshold}% of its daily budget (${usd:.2f} of ${limit_usd:.2f})",
    "budget_exceeded": "Agent {agent} exceeded its daily budget (${usd:.2f} of ${limit_usd:.2f})",
    "global_budget_exceeded": "AgentOS global daily budget exhausted (${usd:.2f} of ${limit_usd:.2f})",
    "circuit_open": "Circuit breaker opened for agent {agent} after {failures} upstream failures",
    "loop_detected": "Agent {agent} looks stuck: it sent the same request {count} times in a row",
}


def _run(cmd):
    return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except (TypeError, ValueError):
        return False
    return True


class Daemon:
    def __init__(self, cfg, store, runner=_run, clock=time.time, sender=None):
        self.cfg = cfg
        self.store = store
        self.run_cmd = runner
        self.clock = clock
        self.send = sender or self._http_post
        self.state_dir = cfg["daemon"]["state_dir"]
        self.history_dir = os.path.join(self.state_dir, "history")
        self._lock = threading.Lock()
        self.gpus = GpuRegistry(cfg["gpu"]["lock_dir"], clock=clock)

    # ── registry ───────────────────────────────────────────────────────
    def _path(self, agent_id):
        return os.path.join(self.state_dir, agent_id + ".json")

    def load(self, agent_id):
        if not configmod.valid_agent_id(agent_id):
            return None
        try:
            with open(self._path(agent_id)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def save(self, state, directory=None):
        directory = directory or self.state_dir
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, state["id"] + ".json")
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=2, sort_keys=True)
        os.chmod(tmp, 0o664)
        os.replace(tmp, path)

    def agents(self):
        out = []
        try:
            names = sorted(os.listdir(self.state_dir))
        except OSError:
            return out
        for name in names:
            if name.endswith(".json"):
                state = self.load(name[:-5])
                if state:
                    out.append(state)
        return out

    def is_alive(self, state):
        unit = state.get("unit")
        if unit:
            return self.run_cmd(["systemctl", "is-active", "--quiet", unit]).returncode == 0
        return _pid_alive(state.get("pid"))

    def reap(self):
        """Archive agents that are no longer running."""
        with self._lock:
            for state in self.agents():
                if state.get("status") == "running" and self.is_alive(state):
                    if not state.get("announced"):
                        state["announced"] = True
                        self.save(state)
                        self.emit({"type": "agent_started", "agent": state["id"], "command": state.get("command", "")})
                    continue
                if state.get("status") == "running":
                    # The CLI registers the agent just before starting it
                    if self.clock() - float(state.get("started_at", 0)) < STARTUP_GRACE_SEC:
                        continue
                    state["status"] = "exited"
                    self.emit({"type": "agent_exited", "agent": state["id"]})
                state.setdefault("ended_at", self.clock())
                self.save(state, self.history_dir)
                try:
                    os.unlink(self._path(state["id"]))
                except OSError:
                    pass
                # A finished agent's gateway credentials stop working
                try:
                    self.store.delete_agent_token(state["id"])
                except Exception as exc:
                    log.warning("could not revoke token of %s: %s", state["id"], exc)
            self.release_stale_gpus()

    def release_stale_gpus(self):
        """Safety net for GPU locks the agent unit's ExecStopPost did not free."""
        if not os.path.isdir(self.gpus.dir):
            return  # GPU scheduling is not enabled
        running = {s["id"] for s in self.agents() if s.get("status") == "running"}
        try:
            freed = self.gpus.release_stale(running.__contains__, float(self.cfg["gpu"]["stale_grace_sec"]))
        except OSError as exc:
            log.warning("could not release stale GPU locks: %s", exc)
            return
        if freed:
            log.info("released stale GPU locks: %s", freed)

    # ── enforcement ────────────────────────────────────────────────────
    def kill(self, agent_id, reason):
        with self._lock:
            state = self.load(agent_id)
            if not state or state.get("status") != "running":
                return False
            unit = state.get("unit")
            if unit:
                result = self.run_cmd(["systemctl", "stop", unit])
                ok = result.returncode == 0
                if not ok:
                    log.error("could not stop %s: %s", unit, (result.stderr or "").strip())
            else:
                try:
                    os.kill(int(state["pid"]), signal.SIGTERM)
                    ok = True
                except (OSError, KeyError, ValueError) as exc:
                    log.error("could not signal agent %s: %s", agent_id, exc)
                    ok = False
            if ok:
                state["status"] = "killed"
                state["reason"] = reason
                state["ended_at"] = self.clock()
                self.save(state)
        if ok:
            self.emit({"type": "agent_killed", "agent": agent_id, "reason": reason})
        return ok

    def handle(self, event):
        kind = event.get("type")
        if kind == "budget_exceeded" and self.cfg["budget"].get("auto_shutdown", True):
            agent = event.get("agent", "")
            if self.load(agent):
                self.kill(agent, "daily budget exceeded ($%.2f of $%.2f)" % (event.get("usd", 0), event.get("limit_usd", 0)))
        self.notify(event)

    def emit(self, event):
        """Publish an event the daemon itself produced."""
        try:
            self.store.publish(event)
        except Exception as exc:  # Redis down must not break reaping
            log.warning("could not publish %s: %s", event.get("type"), exc)

    # ── notifications ──────────────────────────────────────────────────
    def notify(self, event):
        ncfg = self.cfg.get("notify", {})
        if event.get("type") not in ncfg.get("events", []):
            return
        try:
            text = EVENT_TEXT.get(event["type"], event["type"]).format(**{
                "agent": "?", "reason": "", "threshold": "?", "usd": 0.0, "limit_usd": 0.0,
                "failures": "?", "command": "", "count": "?", **event,
            })
        except (KeyError, ValueError):
            text = event["type"]
        for target in ncfg.get("targets", []):
            url = target.get("url")
            if target.get("url_file"):
                try:
                    with open(target["url_file"]) as f:
                        url = f.read().strip()
                except OSError as exc:
                    log.warning("cannot read %s: %s", target["url_file"], exc)
                    continue
            if not url:
                continue
            kind = target.get("kind", "webhook")
            if kind == "slack":
                payload = {"text": "AgentOS: " + text}
            elif kind == "discord":
                payload = {"content": "AgentOS: " + text}
            else:
                payload = dict(event, text=text)
            threading.Thread(target=self._safe_send, args=(url, payload), daemon=True).start()

    def _safe_send(self, url, payload):
        try:
            self.send(url, payload)
        except Exception as exc:
            log.warning("notification to %s failed: %s", url.split("?")[0], exc)

    @staticmethod
    def _http_post(url, payload):
        data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()

    # ── metrics ────────────────────────────────────────────────────────
    def metrics(self):
        lines = []

        def metric(name, kind, help_text, samples):
            lines.append("# HELP %s %s" % (name, help_text))
            lines.append("# TYPE %s %s" % (name, kind))
            for labels, value in samples:
                label = ",".join('%s="%s"' % (k, str(v).replace("\\", "\\\\").replace('"', '\\"')) for k, v in labels.items())
                lines.append("%s%s %s" % (name, "{%s}" % label if label else "", value))

        agents = self.agents()
        running = [a for a in agents if a.get("status") == "running"]
        metric("agentos_agents_running", "gauge", "Agents currently running", [({}, len(running))])
        default_limit = self.cfg["budget"]["default_daily_usd"]
        try:
            snap = self.store.snapshot(default_limit=default_limit)
        except Exception as exc:
            log.warning("metrics: redis unavailable: %s", exc)
            snap = {"global_usd": 0.0, "agents": {}, "models": {}}
        metric("agentos_spend_usd_today", "gauge", "USD spent today by all agents", [({}, snap["global_usd"])])
        metric("agentos_budget_global_usd", "gauge", "Global daily budget", [({}, self.cfg["budget"]["global_daily_usd"])])
        metric("agentos_agent_spend_usd_today", "gauge", "USD spent today per agent",
               [({"agent": a}, v["usd"]) for a, v in snap["agents"].items()])
        metric("agentos_agent_budget_usd", "gauge", "Daily budget per agent",
               [({"agent": a}, v["limit_usd"]) for a, v in snap["agents"].items()])
        metric("agentos_agent_tokens_today", "gauge", "Tokens used today per agent",
               [({"agent": a, "kind": k}, n) for a, v in snap["agents"].items() for k, n in v["tokens"].items()])
        metric("agentos_agent_requests_today", "gauge", "Gateway responses today per agent and status class",
               [({"agent": a, "status": k}, n) for a, v in snap["agents"].items() for k, n in v["requests"].items()])
        metric("agentos_model_spend_usd_today", "gauge", "USD spent today per model",
               [({"model": m}, v) for m, v in snap["models"].items()])
        return "\n".join(lines) + "\n"

    # ── main loops ─────────────────────────────────────────────────────
    def listen_forever(self, stop):
        while not stop.is_set():
            try:
                pubsub = self.store.subscribe()
                while not stop.is_set():
                    msg = pubsub.get_message(timeout=1.0)
                    if msg and msg.get("type") == "message":
                        try:
                            self.handle(json.loads(msg["data"]))
                        except ValueError:
                            log.warning("ignoring malformed event")
            except Exception as exc:
                log.warning("event listener error (retrying): %s", exc)
                stop.wait(2)

    def reap_forever(self, stop):
        interval = float(self.cfg["daemon"]["reap_interval_sec"])
        while not stop.is_set():
            try:
                self.reap()
            except Exception:
                log.exception("reaper error")
            stop.wait(interval)


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/metrics":
            self.send_error(404)
            return
        body = self.server.daemon_obj.metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS agent daemon")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    daemon = Daemon(cfg, Store(connect(cfg["redis"]["url"])))
    stop = threading.Event()
    threads = [
        threading.Thread(target=daemon.listen_forever, args=(stop,), daemon=True),
        threading.Thread(target=daemon.reap_forever, args=(stop,), daemon=True),
    ]
    metrics = http.server.ThreadingHTTPServer((cfg["daemon"]["metrics_listen"], int(cfg["daemon"]["metrics_port"])), MetricsHandler)
    metrics.daemon_threads = True
    metrics.daemon_obj = daemon
    threads.append(threading.Thread(target=metrics.serve_forever, daemon=True))
    for t in threads:
        t.start()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    log.info("agent daemon running; state in %s", daemon.state_dir)
    try:
        while not stop.is_set():
            stop.wait(1)
    except KeyboardInterrupt:
        stop.set()
    metrics.shutdown()


if __name__ == "__main__":
    main()
