"""OpenTelemetry GenAI traces for the model gateway.

Every request the gateway handles ends in one per-request log entry
(Gateway.write_log). `Tracer.record(entry)` turns such an entry into one
OTLP span that follows the OpenTelemetry GenAI semantic conventions and
ships it, in batches, to any OTLP/HTTP endpoint (the Nestlo OTel collector,
Langfuse, OpenLIT, Tempo, ...). Standard library only.

Never in the way of a request: record() builds the span, puts it on a
bounded queue and returns; a background thread batches and POSTs with a
timeout. A full queue drops the span (counted), an unreachable endpoint
drops the batch (counted, logged at most once a minute). Nothing raises into
the caller. Prompts and completions are never exported: the gateway does not
keep them in the log entry, and this module has no option to add them.

Attribute names follow the GenAI conventions at
https://github.com/open-telemetry/semantic-conventions-genai (the spans moved
there from the main semantic-conventions repo; status: Development):
  span name       "{gen_ai.operation.name} {gen_ai.request.model}", kind CLIENT
  required        gen_ai.operation.name, gen_ai.provider.name
  conditional     error.type (if the operation ended in an error),
                  gen_ai.request.model
  recommended     gen_ai.response.model, gen_ai.usage.input_tokens,
                  gen_ai.usage.output_tokens, gen_ai.usage.cache_read.input_tokens,
                  gen_ai.usage.cache_creation.input_tokens, server.address
`gen_ai.usage.input_tokens` includes cached tokens by the convention, while
the gateway's usage counters exclude them (usage.py); the sum is exported.
`gen_ai.system` is deprecated in favour of gen_ai.provider.name and only
emitted when tracing.legacy_system_attribute is set (some older backends
still key on it). Everything Nestlo-specific is under `nestlo.*`.

Config (services.toml [tracing], defaults in config.py): see TRACING_DEFAULTS.
"""

import http.client
import json
import logging
import os
import queue
import random
import ssl
import threading
import time
import urllib.parse

log = logging.getLogger("nestlo.genai_trace")

TRACING_DEFAULTS = {
    "enabled": False,
    # Full OTLP/HTTP traces URL (JSON encoding). The Nestlo collector
    # (nestlo.observability) listens on 127.0.0.1:4318.
    "endpoint": "http://127.0.0.1:4318/v1/traces",
    "headers": {},                      # extra request headers, e.g. {"Authorization": "Bearer ..."}
    "headers_file": "",                 # file of "Name: value" lines, re-read when it changes (keeps secrets out of services.toml)
    "ca_file": "",                      # CA bundle for an https endpoint
    "service_name": "nestlo-model-gateway",
    "timeout_sec": 5,
    "queue": 2048,                      # spans held while the exporter is busy; more are dropped
    "batch": 128,
    "flush_interval_sec": 2,
    "sample_ratio": 1.0,                # fraction of requests traced (by trace id)
    "legacy_system_attribute": False,   # also emit the deprecated gen_ai.system
}

SPAN_KIND_CLIENT = 3
STATUS_ERROR = 2

# Gateway provider api kind -> gen_ai.provider.name well-known value
PROVIDER_NAMES = {
    "anthropic": "anthropic",
    "openai": "openai",
    "azure-openai": "azure.ai.openai",
    "gemini": "gcp.gemini",
}

LOOPBACK = ("127.0.0.1", "localhost", "::1")


def operation_for(path, method="POST"):
    """gen_ai.operation.name for a proxied path, or None when the request is
    not a model call (listing models, token counting, ...)."""
    if method != "POST":
        return None
    p = (path or "").lower().split("?", 1)[0]
    if "embed" in p:
        return "embeddings"
    if ":generatecontent" in p or ":streamgeneratecontent" in p:
        return "generate_content"
    if p.endswith("/chat/completions") or p.endswith("/messages") or p.endswith("/responses"):
        return "chat"
    if p.endswith("/completions"):
        return "text_completion"
    return None


def _attr(key, value):
    if isinstance(value, bool):
        v = {"boolValue": value}
    elif isinstance(value, int):
        v = {"intValue": str(value)}                # OTLP/JSON: int64 as string
    elif isinstance(value, float):
        v = {"doubleValue": value}
    elif isinstance(value, (list, tuple)):
        v = {"arrayValue": {"values": [_attr("", x)["value"] for x in value]}}
    else:
        v = {"stringValue": str(value)}
    return {"key": key, "value": v}


def _int(v):
    try:
        return max(0, int(v))
    except (TypeError, ValueError):
        return 0


def _hex(n):
    return "%0*x" % (n * 2, random.getrandbits(n * 8))


def _parse_traceparent(value):
    """(trace_id, parent_span_id) of a W3C traceparent header, or None."""
    try:
        ver, tid, sid, _flags = str(value).strip().split("-")
        int(tid, 16), int(sid, 16)
        if ver == "ff" or len(tid) != 32 or len(sid) != 16 or int(tid, 16) == 0 or int(sid, 16) == 0:
            return None
        return tid.lower(), sid.lower()
    except ValueError:
        return None


class Tracer:
    """Disabled tracer: record() does nothing. Enabled ones are Exporters."""
    enabled = False

    def record(self, entry):
        return False

    def flush(self, timeout=5.0):
        return True

    def close(self):
        return None

    def stats(self):
        return {}


class Exporter(Tracer):
    enabled = True

    def __init__(self, cfg=None, providers=None, clock=time.time, autostart=True):
        c = dict(TRACING_DEFAULTS)
        c.update(cfg or {})
        self.cfg = c
        self.url = urllib.parse.urlsplit(c["endpoint"])
        if self.url.scheme not in ("http", "https") or not self.url.hostname:
            raise ValueError("tracing.endpoint %r must be http:// or https://" % c["endpoint"])
        creds = bool(c["headers"]) or bool(c["headers_file"])
        if creds and self.url.scheme != "https" and self.url.hostname not in LOOPBACK:
            raise ValueError("tracing.endpoint %r must be https:// when headers are sent" % c["endpoint"])
        self.clock = clock
        self.providers = providers or {}
        self.q = queue.Queue(maxsize=max(1, int(c["queue"])))
        self.timeout = float(c["timeout_sec"])
        self.counters = {"queued": 0, "exported": 0, "dropped_full": 0, "dropped_failed": 0, "errors": 0}
        self._lock = threading.Lock()
        self._pending = 0                    # spans queued or in flight
        self._idle = threading.Condition(self._lock)
        self._ctx = None
        self._hf_mtime = None
        self._hf_headers = {}
        self._last_warn = 0.0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="genai-trace", daemon=True)
        if autostart:
            self._thread.start()

    # ── producer side: cheap, non-blocking, never raises ────────────────
    def record(self, entry):
        try:
            span = self.span_for(entry)
            if span is None:
                return False
            with self._lock:
                self._pending += 1
            try:
                self.q.put_nowait(span)
            except queue.Full:
                with self._lock:
                    self._pending -= 1
                    self.counters["dropped_full"] += 1
                    self._idle.notify_all()
                return False
            with self._lock:
                self.counters["queued"] += 1
            return True
        except Exception:                    # tracing must never break a request
            log.debug("cannot build span", exc_info=True)
            return False

    def stats(self):
        with self._lock:
            return dict(self.counters, pending=self._pending)

    def span_for(self, entry):
        """OTLP span (a dict) for one gateway log entry, or None."""
        op = entry.get("operation") or operation_for(entry.get("path"), entry.get("method", "POST"))
        status = entry.get("status")
        error = entry.get("error")
        if op is None and not (error and entry.get("path")):
            return None
        if op is None:
            op = "chat"                      # a refused call to an unrecognised path: nothing better to say
        ctx = None
        if entry.get("traceparent"):
            ctx = _parse_traceparent(entry["traceparent"])
        trace_id, parent = ctx if ctx else (_hex(16), None)
        ratio = float(self.cfg["sample_ratio"])
        if ratio < 1.0 and int(trace_id[16:], 16) / float(1 << 64) >= ratio:
            return None

        # entry["provider"] is already the provider that answered (after routing and fallback)
        provider = entry.get("provider") or entry.get("fallback_provider") or entry.get("routed_provider")
        # The model the gateway asked the provider for: after routing, the routed one
        req_model = entry.get("routed_model") or entry.get("original_model") or entry.get("model")
        resp_model = entry.get("model")
        attrs = [_attr("gen_ai.operation.name", op)]
        if provider:
            api = (self.providers.get(provider) or {}).get("api", "openai")
            pname = PROVIDER_NAMES.get(api, provider)           # openai-compatible: the gateway's own provider name
            attrs.append(_attr("gen_ai.provider.name", pname))
            if self.cfg["legacy_system_attribute"]:
                attrs.append(_attr("gen_ai.system", pname))
            host = urllib.parse.urlsplit((self.providers.get(provider) or {}).get("base_url", "")).hostname
            if host:
                attrs.append(_attr("server.address", host))
        if req_model:
            attrs.append(_attr("gen_ai.request.model", req_model))
        if resp_model:
            attrs.append(_attr("gen_ai.response.model", resp_model))
        usage = entry.get("usage") or {}
        if usage:
            read = _int(usage.get("cache_read_tokens"))
            wrote = _int(usage.get("cache_write_tokens")) + _int(usage.get("cache_write_1h_tokens"))
            attrs.append(_attr("gen_ai.usage.input_tokens", _int(usage.get("input_tokens")) + read + wrote))
            attrs.append(_attr("gen_ai.usage.output_tokens", _int(usage.get("output_tokens"))))
            if read:
                attrs.append(_attr("gen_ai.usage.cache_read.input_tokens", read))
            if wrote:
                attrs.append(_attr("gen_ai.usage.cache_creation.input_tokens", wrote))
        failed = bool(error) or (isinstance(status, int) and status >= 400)
        if failed:
            attrs.append(_attr("error.type", str(error or status)))
        if isinstance(status, int):
            attrs.append(_attr("http.response.status_code", status))
        if entry.get("method"):
            attrs.append(_attr("http.request.method", entry["method"]))
        if entry.get("path"):
            attrs.append(_attr("url.path", str(entry["path"]).split("?", 1)[0]))
        if entry.get("agent"):
            attrs.append(_attr("nestlo.agent.id", entry["agent"]))
        if "cost_usd" in entry:
            attrs.append(_attr("nestlo.cost_usd", float(entry["cost_usd"] or 0.0)))
            if "priced" in entry:
                attrs.append(_attr("nestlo.cost.priced", bool(entry["priced"])))
        for key in ("original_model", "routed_model", "route_reason", "routed_provider", "fallback_provider"):
            if entry.get(key):
                attrs.append(_attr("nestlo.route." + key.replace("route_", ""), str(entry[key])))
        if entry.get("fallbacks_failed"):
            attrs.append(_attr("nestlo.route.fallbacks_failed", [str(x) for x in entry["fallbacks_failed"]]))
        for key in ("replayed", "client_disconnected", "usage_estimated"):
            if entry.get(key):
                attrs.append(_attr("nestlo." + key, entry[key] if isinstance(entry[key], bool) else str(entry[key])))
        if entry.get("dlp"):
            found = entry["dlp"]
            attrs.append(_attr("nestlo.dlp.types", [str(x) for x in (found if isinstance(found, (list, tuple)) else found.keys() if isinstance(found, dict) else [found])]))
        if entry.get("dlp_response"):
            attrs.append(_attr("nestlo.dlp.response", str(entry["dlp_response"])))

        end = float(entry.get("ts") or self.clock())
        start = end - max(0, _int(entry.get("duration_ms"))) / 1000.0
        span = {
            "traceId": trace_id, "spanId": _hex(8),
            "name": ("%s %s" % (op, req_model)) if req_model else op,
            "kind": SPAN_KIND_CLIENT,
            "startTimeUnixNano": str(int(start * 1e9)),
            "endTimeUnixNano": str(int(end * 1e9)),
            "attributes": attrs,
        }
        if parent:
            span["parentSpanId"] = parent
        if failed:
            span["status"] = {"code": STATUS_ERROR, "message": str(error or ("HTTP %s" % status))[:200]}
        return span

    # ── consumer side ───────────────────────────────────────────────────
    def _run(self):
        interval = max(0.05, float(self.cfg["flush_interval_sec"]))
        batch_size = max(1, int(self.cfg["batch"]))
        while True:
            batch = []
            deadline = time.monotonic() + interval
            while len(batch) < batch_size:
                wait = deadline - time.monotonic()
                if wait <= 0 or (self._stop.is_set() and self.q.empty()):
                    break
                try:
                    batch.append(self.q.get(timeout=min(wait, 0.2)))
                except queue.Empty:
                    if self._stop.is_set():
                        break
            if batch:
                self._send(batch)
            if self._stop.is_set() and self.q.empty():
                return

    def _headers(self):
        h = {"Content-Type": "application/json", "User-Agent": "nestlo-genai-trace"}
        h.update({str(k): str(v) for k, v in (self.cfg["headers"] or {}).items()})
        path = self.cfg["headers_file"]
        if path:
            try:
                mtime = os.stat(path).st_mtime_ns
                if mtime != self._hf_mtime:
                    parsed = {}
                    with open(path) as f:
                        for line in f:
                            if ":" in line and not line.lstrip().startswith("#"):
                                k, v = line.split(":", 1)
                                parsed[k.strip()] = v.strip()
                    self._hf_headers, self._hf_mtime = parsed, mtime
            except OSError:
                pass                         # not written yet (the backend is still starting): keep what we have
            h.update(self._hf_headers)
        return h

    def _tls(self):
        if self._ctx is None:
            ca = self.cfg["ca_file"]
            self._ctx = ssl.create_default_context(cafile=ca or None)
        return self._ctx

    def payload(self, spans):
        return {"resourceSpans": [{
            "resource": {"attributes": [_attr("service.name", self.cfg["service_name"]),
                                        _attr("service.namespace", "nestlo")]},
            "scopeSpans": [{"scope": {"name": "nestlo.gateway.genai"}, "spans": spans}],
        }]}

    def _post(self, body):
        u = self.url
        if u.scheme == "https":
            conn = http.client.HTTPSConnection(u.hostname, u.port, timeout=self.timeout, context=self._tls())
        else:
            conn = http.client.HTTPConnection(u.hostname, u.port, timeout=self.timeout)
        try:
            conn.request("POST", (u.path or "/") + ("?" + u.query if u.query else ""), body=body,
                         headers=self._headers())
            resp = conn.getresponse()
            data = resp.read(4096)
            return resp.status, data
        finally:
            conn.close()

    def _send(self, spans):
        n = len(spans)
        try:
            status, data = self._post(json.dumps(self.payload(spans), separators=(",", ":")).encode())
            ok = 200 <= status < 300
            err = None if ok else "HTTP %d %s" % (status, data[:120].decode("utf-8", "replace"))
        except Exception as exc:             # network, TLS, timeout, bad header file
            ok, err = False, "%s: %s" % (type(exc).__name__, exc)
        with self._lock:
            self._pending -= n
            if ok:
                self.counters["exported"] += n
            else:
                self.counters["dropped_failed"] += n
                self.counters["errors"] += 1
            self._idle.notify_all()
        if not ok and self.clock() - self._last_warn > 60:
            self._last_warn = self.clock()
            log.warning("cannot export %d span(s) to %s: %s", n, self.cfg["endpoint"], err)

    def flush(self, timeout=5.0):
        """Wait until everything queued so far has been sent (or dropped)."""
        end = time.monotonic() + timeout
        with self._idle:
            while self._pending > 0:
                left = end - time.monotonic()
                if left <= 0:
                    return False
                self._idle.wait(left)
        return True

    def close(self):
        self.flush(self.timeout + 1)
        self._stop.set()
        if self._thread.is_alive():
            self._thread.join(self.timeout + 1)


def from_config(cfg):
    """Tracer for a loaded services config: Exporter when [tracing] is
    enabled and valid, else a no-op Tracer. A bad config logs and disables
    tracing rather than stopping the gateway."""
    t = dict(TRACING_DEFAULTS)
    t.update(cfg.get("tracing") or {})
    if not t["enabled"]:
        return Tracer()
    try:
        return Exporter(t, providers=cfg.get("providers"))
    except (ValueError, TypeError) as exc:
        log.error("tracing disabled: %s", exc)
        return Tracer()
