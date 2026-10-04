"""AgentOS model gateway.

An HTTP proxy between coding agents and LLM provider APIs. Agents started by
`agentos spawn` get base URLs of the form

    http://127.0.0.1:8080/agent/<agent-id>/<provider>/...

e.g. ANTHROPIC_BASE_URL=http://127.0.0.1:8080/agent/a1/anthropic. For every
request the gateway:

  1. rejects it if the agent's circuit is open (503), it exceeded its
     per-minute request limit (429), or it or the whole machine is over the
     daily budget (402);
  2. forwards it upstream, injecting the provider API key when the agent
     sent the placeholder key "agentos-managed";
  3. streams the response back unchanged while extracting token usage;
  4. prices the usage, records spend in Redis, publishes budget alerts, and
     trips the circuit breaker after repeated upstream failures.

Before forwarding, the gateway also refuses an agent stuck repeating the same
request (429 loop_detected), rewrites the requested model per the routing
rules (routing.py), and, when recording is on, stores the request/response
pair under recording.dir/<agent>/ (recorder.py). An agent registered for
replay is answered from a recording instead, without contacting the
provider. /agent/<id>/bus/<topic> is the inter-agent message bus (bus.py).

Requests to /<provider>/... (no agent prefix) are accounted to "unmanaged".

Admin endpoints (served on both listeners unless noted):
  GET    /_agentos/health
  GET    /_agentos/spend[?date=YYYY-MM-DD]
  GET    /_agentos/history[?days=N]
  PUT    /_agentos/budget/<agent>   {"daily_usd": 5.0}   admin socket only
  DELETE /_agentos/budget/<agent>                        admin socket only
  DELETE /_agentos/circuit/<agent>                       admin socket only
  DELETE /_agentos/loop/<agent>                          admin socket only
  GET    /_agentos/routing[?agent=&provider=&model=]     admin socket only
  GET|PUT|DELETE /_agentos/record/<agent>  {"enabled": true}   admin socket only
  GET|PUT|DELETE /_agentos/replay/<agent>  {"recording": "<agent-id>"}   admin socket only
  GET    /_agentos/recordings[/<id>]                     admin socket only
  GET    /_agentos/bus                                   admin socket only
  GET|POST /_agentos/bus/<topic>[?from=]                 admin socket only
"""

import argparse
import hashlib
import hmac
import http.client
import http.server
import json
import logging
import os
import re
import socketserver
import sys
import threading
import time
import urllib.parse

import redis

from . import config as configmod
from .bus import Bus, BusError
from .loops import fingerprint
from .providers import adapter_for
from .recorder import Recorder, body_hash, decode_body
from .routing import Router
from .store import BudgetRefused, Store, connect
from .usage import GENERATION_KEYS, Pricing, UsageParser, estimate_cost, output_cap

log = logging.getLogger("agentos.gateway")

HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailer", "trailers", "transfer-encoding", "upgrade",
}
UNMANAGED = "unmanaged"
TOKEN_HEADER = "x-agentos-token"

# "/agent/<id>:<token>/..." (the colon may be percent-encoded)
_TOKEN_SEGMENT = re.compile(r"(/agent/[^/:%?#\s]*)(?::|%3[aA])[^/?#\s]*")


def redact(text):
    """Hide the agent token in a request path, URL or log line."""
    return _TOKEN_SEGMENT.sub(lambda m: m.group(1) + ":***", text) if text else text


class HTTPError(Exception):
    def __init__(self, status, error_type, message, headers=None, details=None):
        super().__init__(message)
        self.status = status
        self.error_type = error_type
        self.message = message
        self.headers = headers or {}
        self.details = details


class Gateway:
    def __init__(self, cfg, store, pricing, clock=time.time):
        self.cfg = cfg
        self.store = store
        self.pricing = pricing
        self.clock = clock
        self.log_dir = cfg["gateway"]["log_dir"]
        self._log_lock = threading.Lock()
        self.router = Router(cfg["routing"], pricing, cfg["providers"])
        self.recorder = Recorder(cfg["recording"]["dir"], cfg["recording"]["max_body_bytes"])
        self.bus = Bus(cfg, store, clock)
        for name, prov in cfg["providers"].items():
            try:
                adapter_for(prov)
            except ValueError as exc:
                raise ValueError("provider %r: %s" % (name, exc))
        self._replay_lock = threading.Lock()

    # ── helpers ────────────────────────────────────────────────────────
    def provider_key(self, provider):
        prov = self.cfg["providers"][provider]
        path = prov.get("key_file")
        if not path:
            return None
        try:
            with open(path) as f:
                key = f.read().strip()
            return key or None
        except OSError:
            return None

    def daily_limit(self, agent):
        return self.store.limit(agent, self.cfg["budget"]["default_daily_usd"])

    def write_log(self, agent, entry):
        if not self.log_dir:
            return
        entry = dict(entry, ts=round(self.clock(), 3), agent=agent)
        line = json.dumps(entry, sort_keys=True) + "\n"
        path = os.path.join(self.log_dir, agent + ".log")
        with self._log_lock:
            try:
                with open(path, "a") as f:
                    f.write(line)
            except OSError as exc:
                log.warning("cannot write %s: %s", path, exc)

    # ── admission control ──────────────────────────────────────────────
    def admit(self, agent):
        now = self.clock()
        until = self.store.circuit_open_until(agent)
        if until:
            raise HTTPError(
                503, "circuit_open",
                "AgentOS circuit breaker is open for agent %s after repeated upstream failures" % agent,
                {"Retry-After": str(max(1, int(until - now)))},
            )
        rpm = int(self.cfg["limits"]["max_requests_per_minute"])
        if rpm > 0 and self.store.rate_hit(agent) > rpm:
            raise HTTPError(
                429, "rate_limited",
                "AgentOS rate limit: more than %d requests per minute for agent %s" % (rpm, agent),
                {"Retry-After": str(max(1, 60 - int(now) % 60))},
            )

    def reserve_budget(self, agent, usd):
        """Hold `usd` against the agent's and the global budget, or refuse with 402."""
        limit = self.daily_limit(agent)
        global_limit = float(self.cfg["budget"]["global_daily_usd"])
        if not self.cfg["budget"].get("reserve", True):
            usd = 0.0
        try:
            return self.store.reserve(agent, usd, limit, global_limit,
                                      float(self.cfg["gateway"]["upstream_timeout_sec"]) + 60)
        except BudgetRefused as exc:
            if exc.scope == "agent":
                if exc.spent >= exc.limit:
                    self._budget_exceeded(agent, exc.spent, exc.limit)
                    message = "AgentOS daily budget exhausted for agent %s: $%.4f of $%.2f" % (
                        agent, exc.spent, exc.limit)
                else:
                    message = ("AgentOS daily budget for agent %s cannot cover this request: $%.4f spent, "
                               "$%.4f reserved by requests in flight, ~$%.4f estimated, limit $%.2f" % (
                                   agent, exc.spent, exc.reserved, usd, exc.limit))
            else:
                if exc.spent >= exc.limit and self.store.mark_alert("_global", "exceeded"):
                    self.store.publish({"type": "global_budget_exceeded", "usd": exc.spent, "limit_usd": exc.limit})
                if exc.spent >= exc.limit:
                    message = "AgentOS global daily budget exhausted: $%.4f of $%.2f" % (exc.spent, exc.limit)
                else:
                    message = ("AgentOS global daily budget cannot cover this request: $%.4f spent, "
                               "$%.4f reserved, ~$%.4f estimated, limit $%.2f" % (
                                   exc.spent, exc.reserved, usd, exc.limit))
            raise HTTPError(402, "budget_exceeded", message)

    def _budget_exceeded(self, agent, spent, limit):
        if self.store.mark_alert(agent, "exceeded"):
            self.store.publish({"type": "budget_exceeded", "agent": agent, "usd": spent, "limit_usd": limit})

    def after_usage(self, agent, model, usage, zero_cost=False, fixed_usd=None):
        if fixed_usd is not None:
            usd, priced = fixed_usd, False
        else:
            usd, priced = (0.0, True) if zero_cost else self.pricing.cost(model, usage)
        agent_total, _ = self.store.record(agent, model, usd, usage)
        limit = self.daily_limit(agent)
        if limit > 0:
            pct = agent_total / limit * 100.0
            for threshold in self.cfg["budget"]["alert_thresholds"]:
                if pct >= threshold and threshold < 100 and self.store.mark_alert(agent, threshold):
                    self.store.publish({
                        "type": "budget_threshold", "agent": agent, "threshold": threshold,
                        "usd": agent_total, "limit_usd": limit,
                    })
        if agent_total >= limit:
            self._budget_exceeded(agent, agent_total, limit)
        return usd, priced

    def after_estimate(self, agent, provider, model, usd):
        log.warning("no usage in the %s response for agent %s; charging the estimate $%.4f", provider, agent, usd)
        self.store.count_unparsed(provider)
        return self.after_usage(agent, model, None, False, usd)

    def check_loop(self, agent, payload):
        """Refuse an agent that keeps sending the same request."""
        limits = self.cfg["limits"]
        if not limits["loop_detection"] or int(limits["loop_repeat_threshold"]) <= 0:
            return
        fp = fingerprint(payload, limits["loop_fingerprint_messages"])
        if fp is None:
            return
        threshold = int(limits["loop_repeat_threshold"])
        count = self.store.loop_hit(agent, fp, float(limits["loop_window_sec"]))
        if count >= threshold:
            if count == threshold:
                self.store.publish({"type": "loop_detected", "agent": agent, "count": count,
                                    "window_sec": limits["loop_window_sec"]})
            raise HTTPError(
                429, "loop_detected",
                "AgentOS loop detection: agent %s sent the same request %d times in a row; "
                "change the request or ask an operator to reset it" % (agent, count),
                {"Retry-After": "30"},
            )

    def used_pct(self, agent):
        limit = self.daily_limit(agent)
        return self.store.spend(agent) / limit * 100.0 if limit > 0 else 0.0

    def upstream_failed(self, agent):
        limits = self.cfg["limits"]
        failures = self.store.record_failure(agent)
        max_failures = int(limits["max_consecutive_failures"])
        if max_failures > 0 and failures >= max_failures:
            until = self.store.open_circuit(agent, float(limits["cooldown_sec"]))
            self.store.publish({"type": "circuit_open", "agent": agent, "failures": failures, "until": until})

    # ── request handling ───────────────────────────────────────────────
    def authenticate(self, segment, admin, header_token=None, client=None):
        """Resolve an "/agent/<id>[:<token>]" path segment to an agent id.

        Tokens are registered by `agentos spawn` through the admin socket,
        so an agent cannot act as another agent or invent new ids to get a
        fresh budget. The token is taken from the segment, or else from the
        x-agentos-token header (which keeps it out of URLs and logs).
        Operators on the admin socket may omit it.

        Failed attempts are counted per client address; once an address has
        failed more than limits.max_auth_failures_per_minute times in a
        minute, further failures answer 429 instead of 401.
        """
        agent, _, token = segment.partition(":")
        token = token or header_token or ""
        if not configmod.valid_agent_id(agent):
            raise HTTPError(400, "invalid_request_error", "invalid agent id")
        if admin or not self.cfg["gateway"].get("require_agent_tokens", True):
            return agent
        expected = self.store.agent_token(agent)
        given = hashlib.sha256(token.encode()).hexdigest()
        if not token or not expected or not hmac.compare_digest(given, expected):
            max_fail = int(self.cfg["limits"].get("max_auth_failures_per_minute", 0))
            if max_fail > 0 and self.store.auth_failure(client or "?") > max_fail:
                raise HTTPError(
                    429, "rate_limited",
                    "AgentOS: too many failed authentications from this address; retry later",
                    {"Retry-After": str(max(1, 60 - int(self.clock()) % 60))},
                )
            raise HTTPError(401, "authentication_error", "unknown agent or wrong agent token")
        return agent

    def dispatch(self, req, admin):
        started = self.clock()
        path = urllib.parse.urlsplit(req.path)
        parts = [urllib.parse.unquote(p) for p in path.path.split("/") if p]
        authed = None
        try:
            if parts[:1] == ["_agentos"]:
                return self.api(req, parts[1:], urllib.parse.parse_qs(path.query), admin)
            if len(parts) >= 3 and parts[0] == "agent" and parts[2] == "bus":
                authed = self.authenticate(parts[1], admin, req.headers.get(TOKEN_HEADER), client_of(req))
                return self.bus_request(req, authed, parts[3:], urllib.parse.parse_qs(path.query), False)
            if len(parts) >= 3 and parts[0] == "agent":
                authed = self.authenticate(parts[1], admin, req.headers.get(TOKEN_HEADER), client_of(req))
                agent, provider, rest = authed, parts[2], parts[3:]
            elif parts and parts[0] in self.cfg["providers"]:
                if not admin and self.cfg["gateway"].get("require_agent_tokens", True):
                    raise HTTPError(403, "permission_error",
                                    "unmanaged requests are only accepted on the admin socket")
                authed = agent = UNMANAGED
                provider, rest = parts[0], parts[1:]
            else:
                raise HTTPError(404, "not_found", "unknown path; use /agent/<id>/<provider>/...")
            if provider not in self.cfg["providers"]:
                raise HTTPError(404, "not_found", "unknown provider %r" % provider)
            self.proxy(req, agent, provider, rest, path.query, started)
        except redis.RedisError as exc:
            # Fail closed: without the store nothing can be authenticated,
            # rate limited or metered, so nothing is forwarded.
            log.error("state store unavailable: %s", exc)
            send_json(req, 503, {"type": "error", "error": {
                "type": "store_unavailable",
                "message": "AgentOS state store (Redis) is unavailable; refusing to proxy unmetered traffic"}},
                {"Retry-After": "5"})
        except HTTPError as exc:
            error = {"type": exc.error_type, "message": exc.message}
            if exc.details:
                error["details"] = exc.details
            send_json(req, exc.status, {"type": "error", "error": error}, exc.headers)
            # Only account errors to agents that proved who they are
            if authed:
                try:
                    self.store.count_request(authed, exc.status)
                except redis.RedisError as err:
                    log.error("cannot count request: %s", err)
                self.write_log(authed, {"method": req.command, "path": redact(path.path), "status": exc.status, "error": exc.error_type})

    def api(self, req, parts, query, admin):
        if req.command == "GET" and parts == ["health"]:
            return send_json(req, 200, {
                "status": "ok",
                "providers": {n: {"managed_key": self.provider_key(n) is not None} for n in self.cfg["providers"]},
            })
        if req.command == "GET" and parts == ["spend"]:
            date = (query.get("date") or [None])[0]
            snap = self.store.snapshot(date, self.cfg["budget"]["default_daily_usd"])
            snap["global_limit_usd"] = float(self.cfg["budget"]["global_daily_usd"])
            snap["default_limit_usd"] = float(self.cfg["budget"]["default_daily_usd"])
            return send_json(req, 200, snap)
        if req.command == "GET" and parts == ["history"]:
            days = int((query.get("days") or ["7"])[0])
            return send_json(req, 200, self.store.history(max(1, min(days, 35))))
        if parts[:1] == ["bus"]:
            if not admin:
                raise HTTPError(403, "permission_error", "use the admin socket to read or post as an operator")
            return self.bus_request(req, query.get("from", ["operator"])[0], parts[1:], query, True)
        if parts[:1] in (["routing"], ["record"], ["replay"], ["recordings"]) or (
                len(parts) == 2 and parts[0] in ("budget", "circuit", "loop", "agents")):
            if not admin:
                raise HTTPError(403, "permission_error", "use the admin socket for this endpoint")
        if parts[:1] == ["routing"] and req.command == "GET":
            q = {k: v[0] for k, v in query.items()}
            agent = q.get("agent", "")
            used = self.used_pct(agent) if configmod.valid_agent_id(agent) else 0.0
            return send_json(req, 200, self.router.describe(agent or None, q.get("provider"), q.get("model"), used))
        if parts[:1] == ["recordings"] and req.command == "GET":
            if len(parts) == 1:
                return send_json(req, 200, {"recordings": self.recorder.list()})
            if len(parts) == 2 and configmod.valid_agent_id(parts[1]) and self.recorder.count(parts[1]):
                return send_json(req, 200, {"id": parts[1], "requests": self.recorder.summary(parts[1])})
            raise HTTPError(404, "not_found", "no such recording")
        if parts[:1] in (["record"], ["replay"]) and len(parts) == 2:
            return self.recording_api(req, parts[0], parts[1])
        if len(parts) == 2 and parts[0] in ("budget", "circuit", "loop", "agents"):
            agent = parts[1]
            if not configmod.valid_agent_id(agent):
                raise HTTPError(400, "invalid_request_error", "invalid agent id")
            if parts[0] == "loop" and req.command == "DELETE":
                self.store.loop_reset(agent)
                return send_json(req, 200, {"agent": agent, "loop": "reset"})
            if parts[0] == "circuit" and req.command == "DELETE":
                self.store.reset_circuit(agent)
                return send_json(req, 200, {"agent": agent, "circuit": "closed"})
            if parts[0] == "agents" and req.command == "PUT":
                try:
                    body = json.loads(read_body(req, 65536) or b"{}")
                    digest = str(body["token_sha256"]).lower()
                except (ValueError, KeyError, TypeError):
                    raise HTTPError(400, "invalid_request_error", 'expected {"token_sha256": "<hex>"}')
                if not re.fullmatch(r"[0-9a-f]{64}", digest):
                    raise HTTPError(400, "invalid_request_error", "token_sha256 must be 64 hex characters")
                self.store.set_agent_token(agent, digest)
                return send_json(req, 200, {"agent": agent, "registered": True})
            if parts[0] == "agents" and req.command == "DELETE":
                self.store.delete_agent_token(agent)
                return send_json(req, 200, {"agent": agent, "registered": False})
            if parts[0] == "budget" and req.command == "DELETE":
                self.store.clear_limit(agent)
                return send_json(req, 200, {"agent": agent, "limit_usd": self.daily_limit(agent)})
            if parts[0] == "budget" and req.command == "PUT":
                try:
                    body = json.loads(read_body(req, 65536) or b"{}")
                    usd = float(body["daily_usd"])
                except (ValueError, KeyError, TypeError):
                    raise HTTPError(400, "invalid_request_error", 'expected {"daily_usd": <number>}')
                if usd < 0:
                    raise HTTPError(400, "invalid_request_error", "daily_usd must be >= 0")
                self.store.set_limit(agent, usd)
                return send_json(req, 200, {"agent": agent, "limit_usd": usd})
        raise HTTPError(404, "not_found", "unknown admin endpoint")

    def recording_api(self, req, kind, agent):
        if not configmod.valid_agent_id(agent):
            raise HTTPError(400, "invalid_request_error", "invalid agent id")
        if kind == "record":
            if req.command == "GET":
                return send_json(req, 200, {"agent": agent, "recording": self.store.record_enabled(agent)})
            if req.command in ("PUT", "DELETE"):
                enabled = req.command == "PUT"
                if enabled:
                    try:
                        body = json.loads(read_body(req, 65536) or b"{}")
                        enabled = bool(body.get("enabled", True))
                    except (ValueError, AttributeError):
                        raise HTTPError(400, "invalid_request_error", 'expected {"enabled": <bool>}')
                self.store.set_record(agent, enabled)
                return send_json(req, 200, {"agent": agent, "recording": enabled})
        else:
            if req.command == "GET":
                return send_json(req, 200, {"agent": agent, "replay": self.store.replay_state(agent)})
            if req.command == "DELETE":
                self.store.clear_replay(agent)
                return send_json(req, 200, {"agent": agent, "replay": None})
            if req.command == "PUT":
                try:
                    recording = json.loads(read_body(req, 65536) or b"{}")["recording"]
                except (ValueError, KeyError, TypeError):
                    raise HTTPError(400, "invalid_request_error", 'expected {"recording": "<agent-id>"}')
                if not isinstance(recording, str) or not configmod.valid_agent_id(recording):
                    raise HTTPError(400, "invalid_request_error", "invalid recording id")
                total = self.recorder.count(recording)
                if not total:
                    raise HTTPError(404, "not_found", "no recording for %s" % recording)
                if recording == agent:
                    raise HTTPError(400, "invalid_request_error", "an agent cannot replay its own recording")
                self.store.set_replay(agent, recording, total)
                return send_json(req, 200, {"agent": agent, "replay": self.store.replay_state(agent)})
        raise HTTPError(404, "not_found", "unknown admin endpoint")

    def bus_request(self, req, agent, rest, query, admin):
        if len(rest) != 1:
            if admin and not rest and req.command == "GET":
                return send_json(req, 200, {"topics": self.store.bus_topics()})
            raise HTTPError(404, "not_found", "use /agent/<id>/bus/<topic>")
        topic, q = rest[0], {k: v[0] for k, v in query.items()}
        try:
            if req.command == "POST":
                raw = read_body(req, int(self.cfg["bus"]["max_message_bytes"])) or b""
                return send_json(req, 200, self.bus.publish(agent, topic, raw))
            if req.command == "GET":
                try:
                    wait, limit = float(q.get("wait", 0)), int(q.get("limit", 100))
                except ValueError:
                    raise BusError(400, "wait and limit must be numbers")
                return send_json(req, 200, self.bus.read(agent, topic, q.get("after", "0"), wait, limit, admin))
        except BusError as exc:
            raise HTTPError(exc.status, "permission_error" if exc.status == 403 else "invalid_request_error", exc.message)
        raise HTTPError(405, "invalid_request_error", "use GET or POST")

    def serve_replay(self, req, agent, rest_path, orig_body, started):
        """Answer from the recording this agent is registered to replay."""
        with self._replay_lock:
            state = self.store.replay_state(agent)
            if state is None:
                raise HTTPError(409, "replay_ended", "replay was cleared for agent %s" % agent)
            seq = state["pos"] + 1
            if seq > state["total"]:
                raise HTTPError(409, "replay_exhausted",
                                "recording %s has only %d requests" % (state["recording"], state["total"]))
            entry = self.recorder.load(state["recording"], seq)
            if entry is None:
                raise HTTPError(500, "api_error", "recording %s/%d is unreadable" % (state["recording"], seq))
            want = entry["request"]
            got = {"method": req.command, "path": "/" + rest_path, "body_sha256": body_hash(orig_body)}
            if any(want[k] != got[k] for k in got):
                raise HTTPError(
                    409, "replay_diverged",
                    "request %d differs from recording %s" % (seq, state["recording"]),
                    details={"seq": seq, "recording": state["recording"],
                             "expected": {k: want[k] for k in got}, "got": got},
                )
            self.store.replay_advance(agent)
        resp = entry["response"]
        # Account before answering, so a client never sees the response first
        self.store.count_request(agent, resp["status"])
        self.write_log(agent, {
            "method": req.command, "path": "/" + rest_path, "status": resp["status"],
            "model": entry.get("model"), "replayed": "%s/%d" % (state["recording"], seq),
            "cost_usd": 0.0, "duration_ms": int((self.clock() - started) * 1000),
        })
        data = decode_body(resp.get("body"), resp.get("body_encoding"))
        req.send_response(resp["status"])
        for name, value in resp.get("headers", {}).items():
            req.send_header(name, value)
        req.send_header("Content-Length", str(len(data)))
        req.send_header("X-AgentOS-Replay", "%s/%d" % (state["recording"], seq))
        req.send_header("Connection", "close")
        req.end_headers()
        write_chunk(req, data)

    def proxy(self, req, agent, provider, rest, query, started):
        replaying = self.store.replay_state(agent) is not None
        if not replaying:
            self.admit(agent)           # circuit breaker and rate limit

        body = read_body(req, int(self.cfg["gateway"]["max_request_bytes"]))
        orig_body = body
        route = None
        if replaying:
            return self.serve_replay(req, agent, "/".join(urllib.parse.quote(p, safe=":") for p in rest),
                                     orig_body, started)
        adapter = adapter_for(self.cfg["providers"][provider])
        payload = None
        if body and "json" in (req.headers.get("Content-Type") or "json"):
            try:
                payload = json.loads(body)
            except ValueError:
                payload = None
        rest = list(rest)
        request_model = adapter.request_model(payload, rest)
        edited = False
        if isinstance(payload, dict):
            self.check_loop(agent, payload)
        if isinstance(payload, dict) or request_model:
            routed, reason = self.router.route(agent, provider, request_model, self._route_pct(agent))
            if reason:
                route = {"original_model": request_model, "routed_model": routed, "route_reason": reason}
                rest = adapter.set_model(payload, rest, routed)
                request_model = routed
                edited = edited or (isinstance(payload, dict) and not adapter.model_in_path)
                target = self.router.provider_for(routed)
                if target and target != provider and self.can_switch(provider, target):
                    route["routed_provider"] = target
                    provider = target
                    adapter = adapter_for(self.cfg["providers"][provider])
        rest_path = "/".join(urllib.parse.quote(p, safe=":") for p in rest)
        if isinstance(payload, dict) and adapter.prepare(payload, rest_path):
            edited = True
        if edited:
            body = json.dumps(payload).encode()
        free = adapter.zero_cost
        resv = self.reserve_budget(agent, 0.0 if free else self.estimate(request_model, payload, body, rest_path))
        resv.estimate = 0.0 if free else self.estimate(request_model, payload, body, rest_path)
        try:
            self.forward(req, agent, provider, adapter, rest_path, query, started, body, orig_body,
                         request_model, route, resv)
        finally:
            resv.release()

    def can_switch(self, source, target):
        """Cost routing may move a request to another provider only when it
        speaks the same wire format and can authenticate."""
        providers = self.cfg["providers"]
        if target not in providers:
            return False
        a, b = adapter_for(providers[source]), adapter_for(providers[target])
        return a.wire == b.wire and not a.model_in_path and not b.model_in_path and (
            b.zero_cost or self.provider_key(target) is not None)

    def estimate(self, model, payload, body, rest_path):
        """Estimated USD of a request, held against the budget while it runs."""
        if not isinstance(payload, dict) or not any(k in payload for k in GENERATION_KEYS):
            return 0.0
        if rest_path.endswith("embeddings"):
            return estimate_cost(self.pricing, model, len(body or b""), 0)
        cap = output_cap(payload, int(self.cfg["budget"].get("default_max_tokens", 4096)))
        return estimate_cost(self.pricing, model, len(body or b""), cap)

    def forward(self, req, agent, provider, adapter, rest_path, query, started, body, orig_body,
                request_model, route, resv):
        prov = self.cfg["providers"][provider]
        api = adapter.wire
        record_seq = None
        captured = bytearray()
        capture_cap = int(self.cfg["recording"]["max_body_bytes"])
        truncated = False
        if self.cfg["recording"]["enabled"] or self.store.record_enabled(agent):
            record_seq = self.recorder.next_seq(agent)

        base = urllib.parse.urlsplit(prov["base_url"])
        target = base.path.rstrip("/") + "/" + rest_path
        query = adapter.query_for(query)
        if query:
            target += "?" + query

        headers = {}
        for name, value in req.headers.items():
            lname = name.lower()
            if lname in HOP_BY_HOP or lname in ("host", "content-length", "accept-encoding", TOKEN_HEADER):
                continue
            headers[name] = value
        headers["Host"] = base.netloc
        headers["Accept-Encoding"] = "identity"
        if body is not None:
            headers["Content-Length"] = str(len(body))
        if route and route.get("routed_provider"):
            adapter.strip_credentials(headers)      # the client's key belongs to the original provider
        adapter.inject_key(headers, self.provider_key(provider))

        conn_cls = http.client.HTTPSConnection if base.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(base.hostname, base.port, timeout=float(self.cfg["gateway"]["upstream_timeout_sec"]))
        try:
            try:
                conn.request(req.command, target, body=body, headers=headers)
                resp = conn.getresponse()
            except (OSError, http.client.HTTPException) as exc:
                try:
                    self.upstream_failed(agent)
                except redis.RedisError as err:
                    log.error("cannot update circuit breaker: %s", err)
                raise HTTPError(502, "api_error", "AgentOS gateway could not reach %s: %s" % (provider, exc))

            try:
                if resp.status >= 500:
                    self.upstream_failed(agent)
                else:
                    self.store.record_success(agent)
            except redis.RedisError as exc:
                log.error("cannot update circuit breaker: %s", exc)     # response is already in hand

            parser = UsageParser(api, resp.getheader("Content-Type", ""), request_model)
            req.send_response(resp.status)
            for name, value in resp.getheaders():
                lname = name.lower()
                if lname in HOP_BY_HOP or lname == "content-length":
                    continue
                req.send_header(name, value)
            length = resp.getheader("Content-Length")
            if length is not None:
                req.send_header("Content-Length", length)
            req.send_header("Connection", "close")
            req.end_headers()
            # Hold back the last chunk until the request is accounted for, so
            # a client never sees the end of a response before its cost is
            # recorded (its next request must see the updated spend).
            client_gone = False
            pending = b""
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                parser.feed(chunk)
                if record_seq is not None:
                    if len(captured) + len(chunk) <= capture_cap:
                        captured += chunk
                    else:
                        truncated = True
                if pending and not client_gone:
                    client_gone = not write_chunk(req, pending)
                pending = chunk
                if client_gone:
                    # Stop reading: closing the upstream connection cancels
                    # generation; usage seen so far is still recorded.
                    break
        finally:
            conn.close()

        try:
            model, usage = parser.finish()
            entry = {
                "method": req.command, "path": "/" + rest_path, "provider": provider,
                "status": resp.status, "model": model,
                "duration_ms": int((self.clock() - started) * 1000),
            }
            if client_gone:
                entry["client_disconnected"] = True
            if route:
                entry.update(route)
            if record_seq is not None:
                rec = self.recorder.build(
                    agent, record_seq, round(self.clock(), 3), provider, req.command, "/" + rest_path, query,
                    orig_body, resp.status, dict(resp.getheaders()), bytes(captured), model, parser.streaming,
                    truncated)
                if client_gone:
                    rec["incomplete"] = True
                if self.recorder.write(agent, record_seq, rec):
                    entry["recorded"] = record_seq
            if usage:
                usd, priced = self.after_usage(agent, model, usage, adapter.zero_cost)
                entry.update(usage=usage, cost_usd=round(usd, 6), priced=priced)
            elif req.command == "POST" and 200 <= resp.status < 300 and resv.estimate > 0:
                # A successful generation whose usage we could not read: it
                # was billed, so count the conservative estimate, not $0
                usd, priced = self.after_estimate(agent, provider, model, resv.estimate)
                entry.update(cost_usd=round(usd, 6), priced=False, usage_estimated=True)
            self.store.count_request(agent, resp.status)
            self.write_log(agent, entry)
        except Exception:
            log.exception("accounting failed for agent %s", agent)
        finally:
            # Spend is recorded; drop the hold before the client sees the end
            resv.release()
            if pending and not client_gone:
                write_chunk(req, pending)

    def _route_pct(self, agent):
        # Only look up spend when a downgrade rule can use it
        if float((self.cfg["routing"].get("downgrade") or {}).get("threshold_pct") or 0) <= 0:
            return 0.0
        return self.used_pct(agent)


# ── HTTP plumbing ─────────────────────────────────────────────────────────
def read_body(req, limit):
    if req.headers.get("Transfer-Encoding", "").lower() == "chunked":
        chunks, total = [], 0
        while True:
            line = req.rfile.readline(1024)
            size = int(line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                # trailers until blank line
                while req.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                    pass
                break
            total += size
            if total > limit:
                raise HTTPError(413, "request_too_large", "request body too large")
            chunks.append(req.rfile.read(size))
            req.rfile.readline(1024)
        return b"".join(chunks)
    length = req.headers.get("Content-Length")
    if length is None:
        return None if req.command in ("GET", "HEAD", "DELETE", "OPTIONS") else b""
    length = int(length)
    if length > limit:
        raise HTTPError(413, "request_too_large", "request body too large")
    return req.rfile.read(length)


def client_of(req):
    addr = req.client_address
    return addr[0] if isinstance(addr, tuple) else "unix"


def write_chunk(req, data):
    try:
        req.wfile.write(data)
        req.wfile.flush()
        return True
    except OSError:
        return False


def send_json(req, status, obj, headers=None):
    data = json.dumps(obj).encode()
    req.send_response(status)
    req.send_header("Content-Type", "application/json")
    req.send_header("Content-Length", str(len(data)))
    req.send_header("Connection", "close")
    for name, value in (headers or {}).items():
        req.send_header(name, value)
    req.end_headers()
    req.wfile.write(data)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "agentos-gateway"

    def _dispatch(self):
        self.close_connection = True
        try:
            self.server.gateway.dispatch(self, self.server.admin)
        except Exception:  # never let one request kill the server
            log.exception("error handling %s %s", self.command, redact(self.path))

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _dispatch

    def address_string(self):
        return self.client_address[0] if isinstance(self.client_address, tuple) else "unix"

    def log_message(self, fmt, *args):
        log.debug("%s %s", self.address_string(), redact(fmt % args))


class TCPServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    admin = False


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    admin = True


def listen_addresses(cfg):
    """`gateway.listen` is one address or a list (e.g. loopback + the agent bridge)."""
    listen = cfg["gateway"]["listen"]
    return [listen] if isinstance(listen, str) else list(listen)


def serve(cfg, store=None, pricing=None):
    """Start the TCP listeners and the admin socket; returns the servers."""
    store = store or Store(connect(cfg["redis"]["url"]))
    pricing = pricing or Pricing.from_file(cfg["gateway"]["pricing_file"])
    gw = Gateway(cfg, store, pricing)
    servers = []
    for addr in listen_addresses(cfg):
        tcp = TCPServer((addr, int(cfg["gateway"]["port"])), Handler)
        tcp.gateway = gw
        servers.append(tcp)
    sock_path = cfg["gateway"].get("admin_socket")
    if sock_path:
        if os.path.exists(sock_path):
            os.unlink(sock_path)
        unix = UnixServer(sock_path, Handler)
        os.chmod(sock_path, 0o660)
        unix.gateway = gw
        servers.append(unix)
    for srv in servers:
        threading.Thread(target=srv.serve_forever, daemon=True).start()
    return gw, servers


def main(argv=None):
    parser = argparse.ArgumentParser(description="AgentOS model gateway")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    _, servers = serve(cfg)
    log.info("listening on %s port %s", ", ".join(listen_addresses(cfg)), cfg["gateway"]["port"])
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        for srv in servers:
            srv.shutdown()


if __name__ == "__main__":
    main()
