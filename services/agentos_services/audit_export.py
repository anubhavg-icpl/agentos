"""SIEM export of the audit log.

Each configured sink runs an export loop inside the audit service: read the
records after a persisted cursor, map them to OCSF API Activity (class 6003,
schema 1.3.0), send a batch, and only then advance the cursor. A failed send
is retried with exponential back-off (1 s to 60 s) from the same cursor, so
delivery is at least once and in order; a SIEM can de-duplicate on
metadata.uid (the record hash) or metadata.sequence.

Sinks (agentos.audit.export.*):

  syslog   RFC 5424 messages, octet-counted framing (RFC 6587), over TCP with
           TLS; the message body is the OCSF JSON
  splunk   HTTP Event Collector (Authorization: Splunk <token>)
  otlp     OTLP/HTTP JSON logs (POST <endpoint>, e.g. http://collector:4318/v1/logs)

The audit log itself is never modified by export; cursors live in
<audit dir>/export/<sink>.cursor.
"""

import datetime
import http.client
import json
import logging
import os
import socket
import ssl
import threading
import time
import urllib.parse

from . import audit

log = logging.getLogger("agentos.audit.export")

OCSF_VERSION = "1.3.0"
CLASS_UID = 6003
CATEGORY_UID = 6
VENDOR = "AgentOS"

# OCSF API Activity activity_id values: 1 Create, 2 Read, 3 Update, 4 Delete, 99 Other
# event type -> (activity_id, activity_name)
ACTIVITY = {
    "gateway.request": (1, "Model request"),
    "budget.refused": (99, "Budget refused"),
    "auth.failure": (99, "Authentication failure"),
    "dlp.detection": (99, "DLP detection"),
    "task.submit": (1, "Task submit"),
    "task.approve": (3, "Task approve"),
    "task.reject": (3, "Task reject"),
    "task.cancel": (3, "Task cancel"),
    "task.retry": (3, "Task retry"),
    "task.finish": (3, "Task finish"),
    "agent.spawn": (1, "Agent spawn"),
    "agent.kill": (4, "Agent kill"),
    "agent.exit": (4, "Agent exit"),
    "publish.pr": (1, "Publish pull request"),
    "audit.checkpoint": (99, "Audit checkpoint"),
    "audit.retention": (99, "Audit retention"),
    "audit.start": (99, "Audit start"),
    "audit.dropped": (99, "Audit events dropped"),
}
ACTIVITY_LABEL = {1: "Create", 2: "Read", 3: "Update", 4: "Delete", 99: "Other", 0: "Unknown"}
SEVERITY = {0: "Unknown", 1: "Informational", 2: "Low", 3: "Medium", 4: "High", 5: "Critical", 6: "Fatal", 99: "Other"}

_SEVERITY_BY_TYPE = {"auth.failure": 3, "agent.kill": 3, "audit.dropped": 4, "budget.refused": 2, "task.reject": 2}


def _severity(rec):
    data = rec.get("data") or {}
    base = _SEVERITY_BY_TYPE.get(rec["type"], 1)
    status = data.get("status")
    if isinstance(status, int) and status >= 500:
        base = max(base, 3)
    elif isinstance(status, int) and status >= 400:
        base = max(base, 2)
    if rec["type"] == "dlp.detection" and data.get("action") == "blocked":
        base = max(base, 3)
    return base


def _status(rec):
    """(status_id, status_code, status detail) in OCSF terms: 1 Success, 2 Failure, 0 Unknown."""
    data = rec.get("data") or {}
    etype = rec["type"]
    if etype in ("auth.failure", "budget.refused", "agent.kill", "task.reject"):
        return 2, str(data.get("status", "")) or None
    status = data.get("status")
    if etype == "gateway.request" and isinstance(status, int):
        return (1 if status < 400 else 2), str(status)
    if etype == "task.finish":
        return (1 if status == "succeeded" else 2), str(status) if status else None
    if etype == "publish.pr":
        return (1 if status in (None, "published") else 2), str(status) if status else None
    return 1, None


def message_for(rec):
    data = rec.get("data") or {}
    actor = rec.get("actor") or "system"
    etype = rec["type"]
    if etype == "gateway.request":
        return "%s requested %s/%s: HTTP %s" % (actor, data.get("provider", "?"), data.get("model") or "-", data.get("status", "?"))
    if etype == "budget.refused":
        return "%s refused for budget (%s limit)" % (actor, data.get("scope", "?"))
    if etype == "auth.failure":
        return "authentication failed (%s)" % data.get("reason", "bad token")
    if etype == "dlp.detection":
        return "DLP %s on %s: %s" % (data.get("action", "?"), data.get("direction", "request"),
                                      ",".join(sorted((data.get("detections") or {}))) or "-")
    return "%s %s" % (etype, data.get("task") or data.get("agent") or actor)


def to_ocsf(rec):
    """Map one audit record to an OCSF API Activity (6003) event.

    Field names follow https://schema.ocsf.io/1.3.0/classes/api_activity:
    class_uid, category_uid, activity_id, type_uid (= class_uid * 100 +
    activity_id), time (ms), severity_id, status_id, message, metadata
    (product, version, uid, sequence), actor.user, api.operation/response,
    src_endpoint, dst_endpoint. Everything without a standard field goes to
    `unmapped`.
    """
    data = dict(rec.get("data") or {})
    etype = rec["type"]
    act_id, act_name = ACTIVITY.get(etype, (99, etype))
    status_id, status_code = _status(rec)
    sev = _severity(rec)
    actor_name = rec.get("actor") or "system"
    event = {
        "class_uid": CLASS_UID, "class_name": "API Activity",
        "category_uid": CATEGORY_UID, "category_name": "Application Activity",
        "activity_id": act_id, "activity_name": act_name,
        "type_uid": CLASS_UID * 100 + act_id,
        "type_name": "API Activity: %s" % ACTIVITY_LABEL.get(act_id, "Other"),
        "time": rec.get("ts", 0),
        "severity_id": sev, "severity": SEVERITY[sev],
        "status_id": status_id, "status": {0: "Unknown", 1: "Success", 2: "Failure"}[status_id],
        "message": message_for(rec),
        "metadata": {
            "version": OCSF_VERSION,
            "product": {"name": "AgentOS", "vendor_name": VENDOR},
            "uid": rec.get("hash"), "sequence": rec.get("seq"), "log_name": "agentos-audit",
            "log_provider": rec.get("source") or "agentos", "labels": ["agentos", etype],
        },
        "actor": {"user": {"name": actor_name, "type_id": 0 if rec.get("actor") else 3,
                           "type": "Unknown" if rec.get("actor") else "System"}},
        "api": {"operation": etype, "service": {"name": rec.get("source") or "agentos"}},
        "src_endpoint": {"svc_name": rec.get("source") or "agentos"},
    }
    if status_code:
        event["status_code"] = status_code
    if isinstance(data.get("status"), int):
        event["api"]["response"] = {"code": data["status"]}
        event["http_response"] = {"code": data["status"]}
    if data.get("provider"):
        event["dst_endpoint"] = {"svc_name": str(data["provider"])}
    if data.get("client"):
        event["src_endpoint"]["ip"] = data["client"]
    if data.get("model"):
        event["api"]["request"] = {"uid": rec.get("hash")}
    unmapped = {k: v for k, v in data.items() if k not in ("client",)}
    if rec.get("peer"):
        unmapped["peer"] = rec["peer"]
    if unmapped:
        event["unmapped"] = unmapped
    return event


# ── sinks ───────────────────────────────────────────────────────────────────
def _ssl_context(ca_file=None, verify=True):
    ctx = ssl.create_default_context(cafile=ca_file or None)
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _read_secret(path):
    with open(path) as f:
        return f.read().strip()


def _iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000.0, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + \
        "%03dZ" % (ms % 1000)


def _sd_escape(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("]", "\\]")


def syslog_message(rec, hostname, app="agentos-audit", facility=13):
    """One RFC 5424 message (without framing). facility 13 is "log audit"."""
    ocsf = to_ocsf(rec)
    severity = {1: 6, 2: 5, 3: 4, 4: 3, 5: 2, 6: 1}.get(ocsf["severity_id"], 6)   # OCSF -> syslog severity
    pri = facility * 8 + severity
    sd = '[agentos@32473 seq="%d" hash="%s" type="%s" actor="%s"]' % (
        rec["seq"], _sd_escape(rec.get("hash", "")), _sd_escape(rec["type"]), _sd_escape(rec.get("actor") or "-"))
    host = (hostname or "-").replace(" ", "")[:255] or "-"
    line = "<%d>1 %s %s %s - %s %s %s" % (pri, _iso(rec.get("ts", 0)), host, app, rec["type"].replace(" ", "_")[:32], sd,
                                          json.dumps(ocsf, sort_keys=True, separators=(",", ":")))
    return line.encode()


def octet_frame(msg):
    return b"%d %s" % (len(msg), msg)


class SyslogSink:
    name = "syslog"

    def __init__(self, host, port=6514, tls=True, ca_file=None, hostname=None, timeout=10.0, verify=True):
        self.host, self.port, self.tls = host, int(port), tls
        self.ca_file, self.verify = ca_file, verify
        self.hostname = hostname or socket.gethostname()
        self.timeout = timeout
        self.sock = None

    def _connect(self):
        raw = socket.create_connection((self.host, self.port), timeout=self.timeout)
        if self.tls:
            try:
                return _ssl_context(self.ca_file, self.verify).wrap_socket(raw, server_hostname=self.host)
            except Exception:
                raw.close()
                raise
        return raw

    def send(self, records):
        data = b"".join(octet_frame(syslog_message(r, self.hostname)) for r in records)
        try:
            if self.sock is None:
                self.sock = self._connect()
            self.sock.sendall(data)
        except Exception:
            self.close()
            raise

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


class _HttpSink:
    def __init__(self, url, ca_file=None, timeout=15.0, verify=True):
        self.url = urllib.parse.urlsplit(url)
        if self.url.scheme not in ("http", "https") or not self.url.hostname:
            raise ValueError("export URL %r must be http:// or https://" % url)
        self.ca_file, self.timeout, self.verify = ca_file, timeout, verify

    def _post(self, body, headers):
        u = self.url
        if u.scheme == "https":
            conn = http.client.HTTPSConnection(u.hostname, u.port, timeout=self.timeout,
                                               context=_ssl_context(self.ca_file, self.verify))
        else:
            conn = http.client.HTTPConnection(u.hostname, u.port, timeout=self.timeout)
        try:
            path = (u.path or "/") + ("?" + u.query if u.query else "")
            conn.request("POST", path, body=body, headers=headers)
            resp = conn.getresponse()
            payload = resp.read(65536)
            return resp.status, payload
        finally:
            conn.close()

    def close(self):
        return None


class SplunkSink(_HttpSink):
    name = "splunk"

    def __init__(self, url, token_file, ca_file=None, source="agentos-audit", sourcetype="agentos:audit:ocsf",
                 index=None, host=None, timeout=15.0, verify=True):
        super().__init__(url, ca_file, timeout, verify)
        self.token_file, self.source, self.sourcetype, self.index = token_file, source, sourcetype, index
        self.host = host or socket.gethostname()

    def event(self, rec):
        out = {"time": round(rec.get("ts", 0) / 1000.0, 3), "host": self.host, "source": self.source,
               "sourcetype": self.sourcetype, "event": to_ocsf(rec)}
        if self.index:
            out["index"] = self.index
        return out

    def send(self, records):
        body = "\n".join(json.dumps(self.event(r), sort_keys=True, separators=(",", ":")) for r in records).encode()
        status, payload = self._post(body, {"Authorization": "Splunk " + _read_secret(self.token_file),
                                            "Content-Type": "application/json"})
        if status != 200:
            raise OSError("Splunk HEC answered HTTP %d: %s" % (status, payload[:200].decode("utf-8", "replace")))
        try:
            code = json.loads(payload).get("code", 0)
        except ValueError:
            code = 0
        if code != 0:
            raise OSError("Splunk HEC refused the batch: %s" % payload[:200].decode("utf-8", "replace"))


def _attr(key, value):
    if isinstance(value, bool):
        return {"key": key, "value": {"boolValue": value}}
    if isinstance(value, int):
        return {"key": key, "value": {"intValue": str(value)}}
    return {"key": key, "value": {"stringValue": str(value)}}


class OtlpSink(_HttpSink):
    name = "otlp"

    def __init__(self, endpoint, token_file=None, ca_file=None, timeout=15.0, verify=True, service="agentos-audit"):
        super().__init__(endpoint, ca_file, timeout, verify)
        self.token_file, self.service = token_file, service

    def log_record(self, rec):
        ocsf = to_ocsf(rec)
        sev = ocsf["severity_id"]
        number = {1: 9, 2: 13, 3: 13, 4: 17, 5: 21, 6: 24}.get(sev, 9)          # INFO / WARN / ERROR / FATAL
        ns = str(rec.get("ts", 0) * 1000000)
        return {
            "timeUnixNano": ns, "observedTimeUnixNano": ns,
            "severityNumber": number, "severityText": SEVERITY.get(sev, "Informational").upper(),
            "body": {"stringValue": json.dumps(ocsf, sort_keys=True, separators=(",", ":"))},
            "attributes": [_attr("event.name", rec["type"]), _attr("audit.seq", rec["seq"]),
                           _attr("audit.hash", rec.get("hash", "")), _attr("ocsf.class_uid", CLASS_UID),
                           _attr("agentos.actor", rec.get("actor") or "system")],
        }

    def send(self, records):
        doc = {"resourceLogs": [{
            "resource": {"attributes": [_attr("service.name", self.service), _attr("service.namespace", "agentos")]},
            "scopeLogs": [{"scope": {"name": "agentos.audit", "version": OCSF_VERSION},
                           "logRecords": [self.log_record(r) for r in records]}],
        }]}
        headers = {"Content-Type": "application/json"}
        if self.token_file:
            headers["Authorization"] = "Bearer " + _read_secret(self.token_file)
        status, payload = self._post(json.dumps(doc, separators=(",", ":")).encode(), headers)
        if not 200 <= status < 300:
            raise OSError("OTLP endpoint answered HTTP %d: %s" % (status, payload[:200].decode("utf-8", "replace")))


# ── the export loop ─────────────────────────────────────────────────────────
class Cursor:
    def __init__(self, path):
        self.path = path

    def load(self):
        try:
            with open(self.path) as f:
                return int(json.load(f)["seq"])
        except (OSError, ValueError, KeyError, TypeError):
            return 0

    def save(self, seq):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"seq": seq, "at": int(time.time())}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)


class Exporter:
    """Ships records after the cursor to one sink."""

    def __init__(self, directory, sink, cursor_path, batch=200, interval=5.0, max_backoff=60.0, sleep=None):
        self.dir = directory
        self.sink = sink
        self.cursor = Cursor(cursor_path)
        self.batch = int(batch)
        self.interval = float(interval)
        self.max_backoff = float(max_backoff)
        self.failures = 0
        self.exported = 0

    def pending(self, limit):
        after = self.cursor.load()
        out = []
        for rec in audit.iter_records(self.dir, after):
            out.append(rec)
            if len(out) >= limit:
                break
        return out

    def run_once(self):
        """Send one batch. Returns the number of records sent; raises on a failed send."""
        records = self.pending(self.batch)
        if not records:
            return 0
        self.sink.send(records)
        self.cursor.save(records[-1]["seq"])
        self.exported += len(records)
        return len(records)

    def backoff(self):
        return min(self.max_backoff, 2.0 ** min(self.failures, 10))

    def loop(self, stop):
        while not stop.is_set():
            try:
                sent = self.run_once()
                self.failures = 0
                if sent >= self.batch:
                    continue            # more waiting
                stop.wait(self.interval)
            except Exception as exc:
                self.failures += 1
                delay = self.backoff()
                log.warning("%s export failed (%s); retrying in %.0fs", self.sink.name, exc, delay)
                stop.wait(delay)
        self.sink.close()


def build_sinks(export_cfg):
    """[(name, sink)] for the enabled sinks of [audit.export]."""
    sinks = []
    sc = export_cfg.get("syslog") or {}
    if sc.get("enabled") and sc.get("host"):
        sinks.append(("syslog", SyslogSink(sc["host"], sc.get("port", 6514), sc.get("tls", True),
                                           sc.get("ca_file") or None, sc.get("hostname") or None)))
    hc = export_cfg.get("splunk") or {}
    if hc.get("enabled") and hc.get("url"):
        sinks.append(("splunk", SplunkSink(hc["url"], hc["token_file"], hc.get("ca_file") or None,
                                           hc.get("source") or "agentos-audit",
                                           hc.get("sourcetype") or "agentos:audit:ocsf", hc.get("index") or None)))
    oc = export_cfg.get("otlp") or {}
    if oc.get("enabled") and oc.get("endpoint"):
        sinks.append(("otlp", OtlpSink(oc["endpoint"], oc.get("token_file") or None, oc.get("ca_file") or None)))
    return sinks


def start_exporters(cfg, directory, stop):
    """Start one export thread per enabled sink; returns the Exporters."""
    ecfg = cfg["audit"].get("export") or {}
    out = []
    for name, sink in build_sinks(ecfg):
        exp = Exporter(directory, sink, os.path.join(directory, "export", name + ".cursor"),
                       ecfg.get("batch", 200), ecfg.get("interval_sec", 5))
        threading.Thread(target=exp.loop, args=(stop,), daemon=True, name="audit-export-" + name).start()
        out.append(exp)
        log.info("exporting audit records to %s", name)
    return out
