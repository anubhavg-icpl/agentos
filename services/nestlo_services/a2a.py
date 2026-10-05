"""Nestlo A2A server: Nestlo agents as Agent2Agent (A2A) agents.

    A2A client ──HTTP/JSON-RPC, Bearer──▶ nestlo-a2a (127.0.0.1)
                                              │ validate, map message → task
                                              ▼
                       orchestrator socket: POST /tasks  (origin = a2a:<client>/<agent>)
                                              ▲
                       GET /tasks/<id>, POST /tasks/<id>/cancel (state mapping below)

The A2A specification (https://github.com/a2aproject/A2A, Apache-2.0) is at
v1.0: JSON-RPC methods are PascalCase (SendMessage, SendStreamingMessage,
GetTask, ListTasks, CancelTask, SubscribeToTask), enums are SCREAMING_SNAKE
(TASK_STATE_WORKING), parts have no `kind`, and the Agent Card lists
`supportedInterfaces`. v0.3 clients use message/send, message/stream,
tasks/get, tasks/cancel, tasks/resubscribe, lower-case states and `kind`
discriminators. Both are served: the dialect of a response follows the
method name of the request (a name with a "/" is v0.3), and the Agent Card
follows `protocol_version` ("1.0" or "0.3"). Only the JSON-RPC binding is
implemented (no gRPC, no HTTP+JSON).

Endpoints
    GET  /.well-known/agent-card.json               card of `default_agent` (public)
    GET  /agents/<name>/.well-known/agent-card.json card of one agent (public)
    POST /agents/<name>                             JSON-RPC of one agent (Bearer)
    POST /                                          JSON-RPC of `default_agent`
    GET  /health

State mapping (Nestlo task status → A2A TaskState)
    awaiting_approval → INPUT_REQUIRED (an operator must approve; A2A has no
                        closer state, and the client cannot approve it)
    queued → SUBMITTED   running → WORKING   succeeded → COMPLETED
    failed, timeout → FAILED   cancelled → CANCELED
    skipped → REJECTED (a dependency failed; never started)
The agent's output tail is the task's artifact "output".

Security model (docs/a2a.md has the long version)
  * loopback by default; a non-loopback `listen` needs `allow_non_loopback`;
  * every JSON-RPC request needs `Authorization: Bearer <token>`; tokens come
    from a root-only file (`name:token[:agent,agent]` lines) given to the
    service as a systemd credential; comparison is constant-time;
  * a client sees and cancels only the tasks it submitted (origin check) and
    only through the agent they were submitted to;
  * the A2A service has no authority of its own: the orchestrator validates
    every field (agent, workspace, budget, timeout), applies policy, RBAC and
    the approval gate, and the model gateway applies budgets and DLP. What a
    client sends becomes the prompt (one argv element, never a shell) and
    nothing else: agent, workspace, budget, isolation and the rest come from
    the agent's configuration, not from the request;
  * request bodies are size-capped before they are read; the Agent Card is
    the only unauthenticated document (`public_card = false` closes it too).
"""

import argparse
import hmac
import http.server
import json
import logging
import os
import re
import signal
import socket
import sys
import threading
import time

from . import config as configmod
from . import tasks as T
from .unixapi import call

log = logging.getLogger("nestlo.a2a")

DEFAULTS = {
    "listen": "127.0.0.1",
    "port": 9966,
    "allow_non_loopback": False,
    "public_url": "",                 # base URL clients use; default http://<listen>:<port>
    "token_file": "",
    "protocol_version": "1.0",        # Agent Card dialect: "1.0" or "0.3"
    "public_card": True,
    "max_body_bytes": 1024 * 1024,
    "block_timeout_sec": 120.0,       # how long a blocking SendMessage waits
    "poll_sec": 1.0,                  # orchestrator polling for blocking calls and streams
    "stream_timeout_sec": 3600.0,
    "max_connections": 128,           # concurrent HTTP connections (threads); excess ones are dropped
    "max_streams_per_client": 8,      # concurrent SSE streams of one client
    "body_timeout_sec": 30.0,         # a request body must arrive within this long in total
    "keepalive_sec": 15.0,            # SSE comment lines, so a vanished client is noticed
    "default_agent": "",
    "agents": {},
}

AGENT_FIELDS = {"agent", "workspace", "description", "version", "skills", "budget_usd", "timeout_sec",
                "isolate", "gate", "model", "max_retries", "priority", "input_modes", "output_modes"}

_NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
_CLIENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,31}")
_TOKEN = re.compile(r"[A-Za-z0-9._~+/=-]{16,256}")
_TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
_KEY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/@#-]{0,99}")

# JSON-RPC and A2A error codes (spec §5.4, §9.5)
PARSE_ERROR, INVALID_REQUEST, METHOD_NOT_FOUND, INVALID_PARAMS, INTERNAL = -32700, -32600, -32601, -32602, -32603
TASK_NOT_FOUND, TASK_NOT_CANCELABLE, PUSH_UNSUPPORTED, UNSUPPORTED_OP = -32001, -32002, -32003, -32004
CONTENT_TYPE, EXT_CARD_UNCONFIGURED, VERSION_UNSUPPORTED = -32005, -32007, -32009
POLICY_DENIED = -32000
_REASONS = {TASK_NOT_FOUND: "TASK_NOT_FOUND", TASK_NOT_CANCELABLE: "TASK_NOT_CANCELABLE",
            PUSH_UNSUPPORTED: "PUSH_NOTIFICATION_NOT_SUPPORTED", UNSUPPORTED_OP: "UNSUPPORTED_OPERATION",
            CONTENT_TYPE: "CONTENT_TYPE_NOT_SUPPORTED", EXT_CARD_UNCONFIGURED: "EXTENDED_AGENT_CARD_NOT_CONFIGURED",
            VERSION_UNSUPPORTED: "VERSION_NOT_SUPPORTED"}


class RpcError(Exception):
    def __init__(self, code, message, **meta):
        super().__init__(message)
        self.code, self.message, self.meta = code, message, meta


class ConfigError(ValueError):
    pass


def settings(cfg):
    """DEFAULTS with the [a2a] table of the services config on top."""
    return configmod._merge(json.loads(json.dumps(DEFAULTS)), cfg.get("a2a", {}))


# ── clients (bearer tokens) ──────────────────────────────────────────────
def parse_tokens(text):
    """`name:token[:agent,agent]` lines → {name: (token, agents|None)}."""
    clients = {}
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(":", 2)
        if len(parts) < 2 or not _CLIENT.fullmatch(parts[0]) or not _TOKEN.fullmatch(parts[1]):
            raise ConfigError("token file line %d: expected name:token (token 16-256 chars of [A-Za-z0-9._~+/=-])" % n)
        agents = None
        if len(parts) == 3 and parts[2].strip():
            agents = {a.strip() for a in parts[2].split(",") if a.strip()}
            if not all(_NAME.fullmatch(a) for a in agents):
                raise ConfigError("token file line %d: bad agent name" % n)
        if parts[0] in clients:
            raise ConfigError("token file line %d: duplicate client %s" % (n, parts[0]))
        clients[parts[0]] = (parts[1], agents)
    return clients


class Clients:
    """The token file, re-read when it changes."""

    def __init__(self, path):
        self.path, self._mtime, self._clients, self._lock = path, None, {}, threading.Lock()

    def get(self):
        with self._lock:
            try:
                mtime = os.stat(self.path).st_mtime_ns
            except OSError as exc:
                if self._clients:
                    log.error("token file unreadable (%s); keeping the last good copy", exc)
                    return self._clients
                raise ConfigError("cannot read token file %s: %s" % (self.path, exc))
            if mtime != self._mtime:
                with open(self.path) as f:
                    self._clients = parse_tokens(f.read())
                self._mtime = mtime
                log.info("loaded %d client token(s)", len(self._clients))
            return self._clients

    def authenticate(self, header):
        """(client, allowed agents|None) for an Authorization header, else None."""
        if not header or not header.lower().startswith("bearer "):
            return None
        presented = header[7:].strip().encode()
        found = None
        for name, (token, agents) in self.get().items():     # no early exit: constant work per client
            if hmac.compare_digest(presented, token.encode()) and found is None:
                found = (name, agents)
        return found


# ── backend: the orchestrator ────────────────────────────────────────────
class SocketBackend:
    """The orchestrator's unix socket API."""

    def __init__(self, socket_path, timeout=15):
        self.socket, self.timeout = socket_path, timeout

    def _call(self, method, url, body=None):
        try:
            return call(self.socket, method, url, body, timeout=self.timeout)
        except OSError as exc:
            log.error("orchestrator unreachable: %s", exc)
            raise RpcError(INTERNAL, "The Nestlo orchestrator is unavailable")

    def submit(self, body):
        return self._call("POST", "/tasks", body)

    def get(self, task_id):
        return self._call("GET", "/tasks/" + task_id)

    def cancel(self, task_id):
        return self._call("POST", "/tasks/%s/cancel" % task_id, {})

    def list(self, limit):
        return self._call("GET", "/tasks?limit=%d" % limit)


# ── mapping ──────────────────────────────────────────────────────────────
V1_STATE = {T.QUEUED: "TASK_STATE_SUBMITTED", T.RUNNING: "TASK_STATE_WORKING", T.AWAITING: "TASK_STATE_INPUT_REQUIRED",
            T.SUCCEEDED: "TASK_STATE_COMPLETED", T.FAILED: "TASK_STATE_FAILED", T.TIMEOUT: "TASK_STATE_FAILED",
            T.CANCELLED: "TASK_STATE_CANCELED", T.SKIPPED: "TASK_STATE_REJECTED"}
LEGACY_STATE = {T.QUEUED: "submitted", T.RUNNING: "working", T.AWAITING: "input-required",
                T.SUCCEEDED: "completed", T.FAILED: "failed", T.TIMEOUT: "failed",
                T.CANCELLED: "canceled", T.SKIPPED: "rejected"}
INTERRUPTED = {T.AWAITING}


def iso(ts):
    ts = float(ts)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ts)) + ".%03dZ" % int((ts % 1) * 1000)


def _text_part(text, legacy):
    return {"kind": "text", "text": text} if legacy else {"text": text, "mediaType": "text/plain"}


def status_message(task, legacy):
    """The human-readable note of a task's status, as an agent Message."""
    result = task.get("result") or {}
    status = task["status"]
    if status == T.AWAITING:
        note = "Waiting for operator approval (nestlo task approve %s)" % task["id"]
    elif status == T.TIMEOUT:
        note = "Timed out: %s" % (result.get("error") or "the task exceeded its time limit")
    elif status in (T.FAILED, T.CANCELLED, T.SKIPPED):
        note = str(result.get("error") or status)
    else:
        return None
    msg = {"messageId": "%s-status" % task["id"], "role": "agent" if legacy else "ROLE_AGENT",
           "parts": [_text_part(note[:2000], legacy)], "taskId": task["id"], "contextId": context_id(task)}
    if legacy:
        msg["kind"] = "message"
    return msg


def context_id(task):
    return task.get("group") or task["id"]


def artifacts(task, legacy):
    out = (task.get("result") or {}).get("output_tail") or ""
    if not out.strip():
        return []
    return [{"artifactId": "%s-output" % task["id"], "name": "output",
             "description": "Tail of the agent's output", "parts": [_text_part(out, legacy)]}]


def status_obj(task, legacy):
    state = (LEGACY_STATE if legacy else V1_STATE)[task["status"]]
    stamp = task.get("finished_at") or task.get("started_at") or task.get("created_at") or time.time()
    obj = {"state": state, "timestamp": iso(stamp)}
    msg = status_message(task, legacy)
    if msg:
        obj["message"] = msg
    return obj


def task_view(task, legacy):
    result = task.get("result") or {}
    view = {"id": task["id"], "contextId": context_id(task), "status": status_obj(task, legacy)}
    arts = artifacts(task, legacy)
    if arts:
        view["artifacts"] = arts
    meta = {k: result[k] for k in ("exit_code", "branch", "error") if result.get(k) not in (None, "")}
    meta.update(nestlo_status=task["status"], agent=task.get("agent"), attempt=task.get("attempt"))
    view["metadata"] = {"nestlo": meta}
    if legacy:
        view["kind"] = "task"
    return view


def status_event(task, legacy):
    ev = {"taskId": task["id"], "contextId": context_id(task), "status": status_obj(task, legacy)}
    if legacy:
        ev["kind"] = "status-update"
        ev["final"] = task["status"] in T.TERMINAL or task["status"] in INTERRUPTED
        return ev
    return {"statusUpdate": ev}


def artifact_event(task, art, legacy):
    ev = {"taskId": task["id"], "contextId": context_id(task), "artifact": art, "append": False, "lastChunk": True}
    if legacy:
        ev["kind"] = "artifact-update"
        return ev
    return {"artifactUpdate": ev}


def message_text(message):
    """The prompt of an A2A Message: its text parts, and data parts as JSON.
    Files are refused (an agent run takes a prompt only)."""
    if not isinstance(message, dict):
        raise RpcError(INVALID_PARAMS, "message must be an object")
    parts = message.get("parts")
    if not isinstance(parts, list) or not parts or len(parts) > 64:
        raise RpcError(INVALID_PARAMS, "message.parts must be a non-empty list")
    role = message.get("role")
    if role not in (None, "user", "ROLE_USER"):
        raise RpcError(INVALID_PARAMS, "message.role must be the user role")
    chunks = []
    for part in parts:
        if not isinstance(part, dict):
            raise RpcError(INVALID_PARAMS, "each part must be an object")
        if isinstance(part.get("text"), str):
            chunks.append(part["text"])
        elif "data" in part:
            chunks.append("Data (application/json):\n" + json.dumps(part["data"], indent=2, sort_keys=True))
        elif {"url", "raw", "file"} & set(part):
            raise RpcError(CONTENT_TYPE, "file parts are not supported; send text or JSON data")
        else:
            raise RpcError(INVALID_PARAMS, "unrecognised part")
    return "\n\n".join(chunks)


def validate_agents(agents):
    """The [a2a.agents.<name>] tables → {name: normalized}. Raises ConfigError."""
    out = {}
    for name, a in (agents or {}).items():
        if not _NAME.fullmatch(name):
            raise ConfigError("a2a agent name %r must match [a-z0-9][a-z0-9-]{0,31}" % name)
        if not isinstance(a, dict) or not a.get("agent") or not a.get("workspace"):
            raise ConfigError("a2a agent %s needs `agent` and `workspace`" % name)
        unknown = sorted(set(a) - AGENT_FIELDS)
        if unknown:
            raise ConfigError("a2a agent %s: unknown field(s) %s" % (name, ", ".join(unknown)))
        out[name] = a
    return out


# ── the service ──────────────────────────────────────────────────────────
class StreamBody:
    """An SSE body; close() releases the client's stream slot (also if never iterated)."""

    def __init__(self, gen, on_close):
        self.gen, self._on_close, self._closed = gen, on_close, False

    def __iter__(self):
        return self.gen

    def close(self):
        if not self._closed:
            self._closed = True
            self.gen.close()
            self._on_close()


class A2AService:
    def __init__(self, opts, backend, clients, clock=time.time, sleep=time.sleep):
        self.opts = opts
        self.backend, self.clients, self.clock, self.sleep = backend, clients, clock, sleep
        self.agents = validate_agents(opts.get("agents"))
        self.default = opts.get("default_agent") or (next(iter(self.agents)) if len(self.agents) == 1 else "")
        if self.default and self.default not in self.agents:
            raise ConfigError("default_agent %r is not a configured a2a agent" % self.default)
        if opts.get("protocol_version") not in ("1.0", "0.3"):
            raise ConfigError("protocol_version must be \"1.0\" or \"0.3\"")
        self.legacy_card = opts["protocol_version"] == "0.3"
        self._streams, self._streams_lock = {}, threading.Lock()
        self.base = (opts.get("public_url") or "http://%s:%d" % (opts["listen"], opts["port"])).rstrip("/")

    # Agent Card ---------------------------------------------------------
    def card(self, name):
        a = self.agents[name]
        url = "%s/agents/%s" % (self.base, name)
        skills = [{"id": s.get("id") or "run", "name": s.get("name") or s.get("id") or "run",
                   "description": s.get("description") or a.get("description") or name,
                   "tags": list(s.get("tags") or ["nestlo"]), **({"examples": list(s["examples"])} if s.get("examples") else {})}
                  for s in (a.get("skills") or [{}])]
        card = {
            "name": "Nestlo %s" % name,
            "description": a.get("description") or "A Nestlo coding agent",
            "version": str(a.get("version") or "1.0.0"),
            "capabilities": {"streaming": True, "pushNotifications": False},
            "defaultInputModes": list(a.get("input_modes") or ["text/plain", "application/json"]),
            "defaultOutputModes": list(a.get("output_modes") or ["text/plain"]),
            "skills": skills,
        }
        if self.legacy_card:
            card.update(protocolVersion="0.3.0", url=url, preferredTransport="JSONRPC",
                        supportsAuthenticatedExtendedCard=False,
                        securitySchemes={"bearer": {"type": "http", "scheme": "bearer"}},
                        security=[{"bearer": []}])
        else:
            card["capabilities"]["extendedAgentCard"] = False
            card.update(supportedInterfaces=[{"url": url, "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
                        securitySchemes={"bearer": {"httpAuthSecurityScheme": {"scheme": "Bearer"}}},
                        securityRequirements=[{"schemes": {"bearer": {"list": []}}}])
        return card

    # HTTP ---------------------------------------------------------------
    def handle(self, method, path, headers, read_body):
        """→ (status, extra_headers, body) where body is bytes or an iterator of bytes (SSE)."""
        path = path.split("?", 1)[0]
        if method == "GET" and path == "/health":
            return self._json(200, {"status": "ok"})
        if method == "GET" and (path == "/.well-known/agent-card.json" or path == "/.well-known/agent.json"):
            return self._card(headers, self.default)
        m = re.fullmatch(r"/agents/([^/]+)/\.well-known/agent-card\.json", path)
        if method == "GET" and m:
            return self._card(headers, m.group(1))
        m = re.fullmatch(r"/agents/([^/]+)/?", path)
        if m or path == "/":
            name = m.group(1) if m else self.default
            if method != "POST":
                return self._json(405, {"error": "use POST for JSON-RPC"}, {"Allow": "POST"})
            return self._rpc(name, headers, read_body)
        return self._json(404, {"error": "not found"})

    def _json(self, status, obj, extra=None):
        return status, dict(extra or {}, **{"Content-Type": "application/json"}), json.dumps(obj).encode()

    def _unauthorized(self):
        return self._json(401, {"error": "a valid bearer token is required"}, {"WWW-Authenticate": 'Bearer realm="nestlo-a2a"'})

    def _card(self, headers, name):
        if not name or name not in self.agents:
            return self._json(404, {"error": "no such agent"})
        if not self.opts.get("public_card") and self.clients.authenticate(headers.get("Authorization")) is None:
            return self._unauthorized()
        status, hdrs, body = self._json(200, self.card(name))
        hdrs["Cache-Control"] = "public, max-age=300"
        return status, hdrs, body

    def _rpc(self, name, headers, read_body):
        try:
            auth = self.clients.authenticate(headers.get("Authorization"))
        except ConfigError as exc:
            log.error("%s", exc)
            return self._json(503, {"error": "client tokens are unavailable"})
        if auth is None:
            return self._unauthorized()
        client, allowed = auth
        if not name or name not in self.agents or (allowed is not None and name not in allowed):
            # indistinguishable: a client learns nothing about agents it may not use
            return self._json(404, {"error": "no such agent"})
        length = headers.get("Content-Length")
        if length is None or not (length.isascii() and length.isdigit()) or len(length) > 12:
            return self._json(411, {"error": "Content-Length required"})
        if int(length) > int(self.opts["max_body_bytes"]):
            return self._json(413, {"error": "request body too large"})
        raw = read_body(int(length))
        req_id = None
        legacy = False
        try:
            try:
                req = json.loads(raw)
            except ValueError:
                raise RpcError(PARSE_ERROR, "Invalid JSON payload")
            if not isinstance(req, dict) or req.get("jsonrpc") != "2.0" or not isinstance(req.get("method"), str):
                raise RpcError(INVALID_REQUEST, "Request payload validation error")
            req_id = req.get("id")
            if isinstance(req_id, bool) or not isinstance(req_id, (str, int, float, type(None))):
                req_id = None
                raise RpcError(INVALID_REQUEST, "id must be a string or number")
            method = req["method"]
            legacy = "/" in method
            params = req.get("params") or {}
            if not isinstance(params, dict):
                raise RpcError(INVALID_PARAMS, "params must be an object")
            version = headers.get("A2A-Version")
            if version and not re.match(r"(1|0\.3)(\.\d+)*$", version.strip()):
                raise RpcError(VERSION_UNSUPPORTED, "A2A version %s is not supported (1.0, 0.3)" % version.strip()[:20])
            handler, streaming = self._method(method)
            if streaming:
                self._open_stream(client)
                try:
                    events = handler(client, name, params, legacy)
                except BaseException:
                    self._close_stream(client)
                    raise
                return 200, {"Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"}, \
                    StreamBody(self._sse(events, req_id, legacy), lambda: self._close_stream(client))
            return self._json(200, {"jsonrpc": "2.0", "id": req_id, "result": handler(client, name, params, legacy)})
        except RpcError as exc:
            return self._json(200, self._error(req_id, exc, legacy))
        except Exception:
            log.exception("error handling a request from %s", client)
            return self._json(200, self._error(req_id, RpcError(INTERNAL, "Internal error"), legacy))

    def _error(self, req_id, exc, legacy):
        err = {"code": exc.code, "message": exc.message}
        if not legacy and exc.code in _REASONS:
            err["data"] = [{"@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": _REASONS[exc.code],
                            "domain": "a2a-protocol.org", "metadata": {k: str(v) for k, v in exc.meta.items()}}]
        return {"jsonrpc": "2.0", "id": req_id, "error": err}

    def _open_stream(self, client):
        with self._streams_lock:
            if self._streams.get(client, 0) >= int(self.opts["max_streams_per_client"]):
                raise RpcError(UNSUPPORTED_OP, "Too many open streams for this client")
            self._streams[client] = self._streams.get(client, 0) + 1

    def _close_stream(self, client):
        with self._streams_lock:
            self._streams[client] = max(0, self._streams.get(client, 1) - 1)

    def _sse(self, events, req_id, legacy):
        try:
            for ev in events:
                if ev is None:                      # keep-alive comment
                    yield b": keepalive\n\n"
                    continue
                yield b"data: " + json.dumps({"jsonrpc": "2.0", "id": req_id, "result": ev}).encode() + b"\n\n"
        except RpcError as exc:
            yield b"data: " + json.dumps(self._error(req_id, exc, legacy)).encode() + b"\n\n"
        except Exception:
            log.exception("error in an event stream")
            yield b"data: " + json.dumps(self._error(req_id, RpcError(INTERNAL, "Internal error"), legacy)).encode() + b"\n\n"

    def _method(self, method):
        table = {
            "SendMessage": (self.send_message, False), "message/send": (self.send_message, False),
            "SendStreamingMessage": (self.send_streaming, True), "message/stream": (self.send_streaming, True),
            "GetTask": (self.get_task, False), "tasks/get": (self.get_task, False),
            "ListTasks": (self.list_tasks, False),
            "CancelTask": (self.cancel_task, False), "tasks/cancel": (self.cancel_task, False),
            "SubscribeToTask": (self.subscribe, True), "tasks/resubscribe": (self.subscribe, True),
        }
        if method in table:
            return table[method]
        if method.startswith(("tasks/pushNotificationConfig/", "CreateTaskPushNotificationConfig",
                              "GetTaskPushNotificationConfig", "ListTaskPushNotificationConfigs",
                              "DeleteTaskPushNotificationConfig")):
            raise RpcError(PUSH_UNSUPPORTED, "Push notifications are not supported")
        if method in ("GetExtendedAgentCard", "agent/getAuthenticatedExtendedCard"):
            raise RpcError(EXT_CARD_UNCONFIGURED, "No extended Agent Card is configured")
        raise RpcError(METHOD_NOT_FOUND, "Method not found")

    # tasks --------------------------------------------------------------
    @staticmethod
    def origin(client, name):
        return "a2a:%s/%s" % (client, name)

    def _owned(self, client, name, task_id):
        if not isinstance(task_id, str) or not _TASK_ID.fullmatch(task_id):
            raise RpcError(INVALID_PARAMS, "id must be a task id")
        status, task = self.backend.get(task_id)
        # A task of another client or agent is reported as unknown
        if status != 200 or task.get("origin") != self.origin(client, name):
            raise RpcError(TASK_NOT_FOUND, "Task not found", taskId=task_id)
        return task

    def _submit(self, client, name, params):
        cfg = self.agents[name]
        message = params.get("message")
        prompt = message_text(message)
        if not prompt.strip():
            raise RpcError(INVALID_PARAMS, "the message has no text")
        if message.get("taskId"):
            raise RpcError(UNSUPPORTED_OP, "Nestlo tasks are single-shot: send a new message without taskId "
                                           "(operators approve gated tasks with `nestlo task approve`)")
        body = {"agent": cfg["agent"], "workspace": cfg["workspace"], "prompt": prompt,
                "origin": self.origin(client, name)}
        for key in ("budget_usd", "timeout_sec", "isolate", "gate", "model", "max_retries", "priority"):
            if cfg.get(key) is not None:
                body[key] = cfg[key]
        mid = message.get("messageId")
        if isinstance(mid, str):
            key = "a2a-%s-%s-%s" % (client, name, mid)
            if _KEY.fullmatch(key):
                body["dedupe_key"] = key          # a retried message returns the live task
        status, out = self.backend.submit(body)
        if status in (200, 201):
            return out["tasks"][0]
        text = str(out.get("error", "")) if isinstance(out, dict) else ""
        if status == 400:
            raise RpcError(INVALID_PARAMS, text[:500] or "the request was rejected")
        if status == 403:
            raise RpcError(POLICY_DENIED, "Refused by Nestlo policy: %s" % text[:300])
        log.error("orchestrator answered %s to a task submission: %s", status, text[:300])
        raise RpcError(INTERNAL, "The Nestlo orchestrator could not accept the task")

    def _wait(self, client, name, task, timeout):
        """Poll until the task is finished or waiting for approval, or `timeout` passes."""
        deadline = self.clock() + timeout
        while task["status"] not in T.TERMINAL and task["status"] not in INTERRUPTED and self.clock() < deadline:
            self.sleep(min(float(self.opts["poll_sec"]), max(0.0, deadline - self.clock())))
            task = self._owned(client, name, task["id"])
        return task

    def send_message(self, client, name, params, legacy):
        task = self._submit(client, name, params)
        config = params.get("configuration") or {}
        if not isinstance(config, dict):
            raise RpcError(INVALID_PARAMS, "configuration must be an object")
        # v1: blocking unless returnImmediately; v0.3: blocking only when asked
        blocking = bool(config.get("blocking")) if legacy else not config.get("returnImmediately", False)
        if blocking:
            task = self._wait(client, name, task, float(self.opts["block_timeout_sec"]))
        view = task_view(task, legacy)
        return view if legacy else {"task": view}

    def _stream(self, client, name, task, legacy):
        """Task, then status updates (and the artifact) until the task ends."""
        first = task_view(task, legacy)
        yield first if legacy else {"task": first}
        last = task["status"]
        deadline = self.clock() + float(self.opts["stream_timeout_sec"])
        beat = self.clock()
        while True:
            if task["status"] in T.TERMINAL or task["status"] in INTERRUPTED:
                for art in artifacts(task, legacy):
                    yield artifact_event(task, art, legacy)
                if task["status"] != last or task["status"] in T.TERMINAL:
                    yield status_event(task, legacy)
                return
            if self.clock() >= deadline:
                return
            self.sleep(float(self.opts["poll_sec"]))
            if self.clock() - beat >= float(self.opts["keepalive_sec"]):
                beat = self.clock()
                yield None
            task = self._owned(client, name, task["id"])
            if task["status"] != last and task["status"] not in T.TERMINAL and task["status"] not in INTERRUPTED:
                last = task["status"]
                yield status_event(task, legacy)

    def send_streaming(self, client, name, params, legacy):
        task = self._submit(client, name, params)
        return self._stream(client, name, task, legacy)

    def subscribe(self, client, name, params, legacy):
        task = self._owned(client, name, params.get("id"))
        if task["status"] in T.TERMINAL:
            raise RpcError(UNSUPPORTED_OP, "Task is in a terminal state", taskId=task["id"])
        return self._stream(client, name, task, legacy)

    def get_task(self, client, name, params, legacy):
        view = task_view(self._owned(client, name, params.get("id")), legacy)
        return view

    def cancel_task(self, client, name, params, legacy):
        task = self._owned(client, name, params.get("id"))
        if task["status"] in T.TERMINAL:
            raise RpcError(TASK_NOT_CANCELABLE, "Task cannot be canceled: it is %s" % task["status"], taskId=task["id"])
        status, out = self.backend.cancel(task["id"])
        if status not in (200, 409):
            log.error("orchestrator answered %s to a cancel", status)
            raise RpcError(INTERNAL, "The Nestlo orchestrator could not cancel the task")
        return task_view(self._owned(client, name, task["id"]), legacy)

    def list_tasks(self, client, name, params, legacy):
        size = params.get("pageSize", 50)
        if isinstance(size, bool) or not isinstance(size, int) or not 1 <= size <= 100:
            raise RpcError(INVALID_PARAMS, "pageSize must be between 1 and 100")
        status, out = self.backend.list(1000)
        if status != 200:
            log.error("orchestrator answered %s to a list", status)
            raise RpcError(INTERNAL, "The Nestlo orchestrator could not list tasks")
        wanted = params.get("status")
        mine = [t for t in out.get("tasks", []) if t.get("origin") == self.origin(client, name)]
        if wanted:
            mine = [t for t in mine if V1_STATE[t["status"]] == wanted or LEGACY_STATE[t["status"]] == wanted]
        if params.get("contextId"):
            mine = [t for t in mine if context_id(t) == params["contextId"]]
        page = [task_view(t, False) for t in mine[:size]]
        return {"tasks": page, "nextPageToken": "", "pageSize": size, "totalSize": len(mine)}


# ── HTTP server ──────────────────────────────────────────────────────────
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "nestlo-a2a"
    timeout = 30                      # slowloris: a request must arrive within 30 s

    def _read_body(self, n):
        """Read n bytes within body_timeout_sec in total (a trickling client cannot hold a thread)."""
        limit = time.monotonic() + float(self.server.service.opts["body_timeout_sec"])
        buf = b""
        while len(buf) < n:
            if time.monotonic() > limit:
                raise TimeoutError("request body too slow")
            chunk = self.rfile.read1(n - len(buf))
            if not chunk:
                break
            buf += chunk
        return buf

    def _serve(self):
        service = self.server.service
        try:
            status, headers, body = service.handle(self.command, self.path, self.headers, self._read_body)
        except Exception:
            log.exception("error handling %s %s", self.command, self.path)
            status, headers, body = 500, {"Content-Type": "application/json"}, b'{"error": "internal error"}'
        # a request body may be unread (401, 413): never reuse the connection
        self.close_connection = True
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        if isinstance(body, bytes):
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return
        # Server-Sent Events: no length, closed when the stream ends
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            for chunk in body:
                self.wfile.write(chunk)
                self.wfile.flush()
        except OSError:                               # client gone or too slow to read (socket timeout)
            pass
        finally:
            body.close()

    do_GET = do_POST = do_HEAD = _serve

    def do_PUT(self):
        self.send_error(405)

    do_DELETE = do_PATCH = do_PUT

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64
    slots = threading.BoundedSemaphore(128)

    def process_request(self, request, client_address):
        # one thread per connection, at most max_connections of them
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def make_server(service, listen, port):
    class Bound(Server):
        address_family = socket.AF_INET6 if ":" in listen else socket.AF_INET

    server = Bound((listen, port), Handler)
    server.slots = threading.BoundedSemaphore(max(1, int(service.opts.get("max_connections", 128))))
    server.service = service
    return server


def is_loopback(address):
    return address == "::1" or address.startswith("127.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Nestlo A2A server (Agent2Agent protocol)")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--listen", default=None)
    parser.add_argument("--port", type=int, default=None)
    parser.add_argument("--token-file", default=None)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    opts = settings(cfg)
    if args.listen:
        opts["listen"] = args.listen
    if args.port is not None:
        opts["port"] = args.port
    token_file = args.token_file or opts["token_file"]
    if not token_file:
        print("no client tokens: set nestlo.a2a.tokenFile", file=sys.stderr)
        return 2
    if not is_loopback(opts["listen"]) and not opts["allow_non_loopback"]:
        print("refusing to listen on %s: A2A is loopback-only unless allow_non_loopback is set" % opts["listen"],
              file=sys.stderr)
        return 2
    try:
        clients = Clients(token_file)
        if not clients.get():
            print("the token file has no clients", file=sys.stderr)
            return 2
        service = A2AService(opts, SocketBackend(T.settings(cfg, "orchestrator")["socket"]), clients)
    except (ConfigError, OSError) as exc:
        print("cannot start: %s" % exc, file=sys.stderr)
        return 2
    server = make_server(service, opts["listen"], int(opts["port"]))
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    log.info("A2A listening on %s:%d with %d agent(s)", *server.server_address[:2], len(service.agents))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
