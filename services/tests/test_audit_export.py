import datetime
import http.server
import json
import re
import socket
import socketserver
import ssl
import threading
import time

import pytest

from agentos_services import audit as A
from agentos_services import audit_export as X


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


@pytest.fixture
def adir(tmp_path):
    return str(tmp_path / "audit")


def populate(adir, extra=()):
    log = A.AuditLog(adir, clock=Clock())
    log.append("gateway.request", "a1", "gateway", {"method": "POST", "provider": "anthropic", "model": "claude-x",
                                                    "status": 200, "cost_usd": 0.12, "duration_ms": 40,
                                                    "tokens": {"input_tokens": 10, "output_tokens": 3}})
    log.append("auth.failure", None, "gateway", {"claimed_agent": "a2", "client": "10.0.0.9", "reason": "bad_token"},
               peer={"uid": 990, "pid": 77})
    log.append("task.finish", "alice", "orchestrator", {"task": "task-1", "status": "failed", "exit_code": 1})
    log.append("agent.kill", None, "daemon", {"agent": "a1", "reason": "daily budget exceeded"})
    for etype, actor, data in extra:
        log.append(etype, actor, "x", data)
    log.sync()
    return log


def records(adir):
    return list(A.iter_records(adir))


# ── OCSF mapping ───────────────────────────────────────────────────────────
def test_gateway_request_maps_to_api_activity(by_type):
    rec = by_type["gateway.request"]
    ev = X.to_ocsf(rec)
    assert ev["class_uid"] == 6003 and ev["class_name"] == "API Activity"
    assert ev["category_uid"] == 6 and ev["category_name"] == "Application Activity"
    assert ev["activity_id"] == 1 and ev["type_uid"] == 600301
    assert ev["time"] == rec["ts"] and isinstance(ev["time"], int)
    assert ev["severity_id"] == 1 and ev["status_id"] == 1 and ev["status"] == "Success" and ev["status_code"] == "200"
    assert ev["metadata"]["version"] == "1.3.0" and ev["metadata"]["product"]["name"] == "AgentOS"
    assert ev["metadata"]["uid"] == rec["hash"] and ev["metadata"]["sequence"] == rec["seq"]
    assert ev["actor"]["user"]["name"] == "a1"
    assert ev["api"]["operation"] == "gateway.request" and ev["api"]["response"]["code"] == 200
    assert ev["http_response"]["code"] == 200
    assert ev["src_endpoint"]["svc_name"] == "gateway" and ev["dst_endpoint"]["svc_name"] == "anthropic"
    assert ev["unmapped"]["model"] == "claude-x" and ev["unmapped"]["cost_usd"] == 0.12
    assert "message" in ev and "a1" in ev["message"]
    json.dumps(ev)


def test_failures_map_to_failure_status_and_higher_severity(by_type):
    ev = X.to_ocsf(by_type["auth.failure"])
    assert ev["status_id"] == 2 and ev["status"] == "Failure" and ev["severity_id"] == 3
    assert ev["activity_id"] == 99 and ev["type_uid"] == 600399
    assert ev["actor"]["user"]["name"] == "system"
    assert ev["src_endpoint"]["ip"] == "10.0.0.9" and ev["unmapped"]["peer"] == {"uid": 990, "pid": 77}
    ev = X.to_ocsf(by_type["task.finish"])
    assert ev["status_id"] == 2 and ev["activity_id"] == 3 and ev["type_uid"] == 600303
    ev = X.to_ocsf(by_type["agent.kill"])
    assert ev["activity_id"] == 4 and ev["type_uid"] == 600304 and ev["severity_id"] == 3


def test_every_event_type_maps():
    for etype in sorted(A.EVENT_TYPES | A.WRITER_TYPES):
        ev = X.to_ocsf({"seq": 1, "ts": 1_800_000_000_000, "type": etype, "actor": None, "source": "x", "data": {},
                        "hash": "h", "prev": "p"})
        assert ev["class_uid"] == 6003 and ev["type_uid"] // 100 == 6003, etype
        assert ev["activity_id"] in (1, 2, 3, 4, 99) and ev["severity_id"] in range(0, 7)


@pytest.fixture(scope="module")
def by_type(tmp_path_factory):
    d = str(tmp_path_factory.mktemp("ocsf") / "a")
    populate(d)
    return {r["type"]: r for r in A.iter_records(d)}


# ── syslog (RFC 5424 over TCP, octet counting) ─────────────────────────────
def test_syslog_message_is_rfc5424(by_type):
    rec = by_type["gateway.request"]
    msg = X.syslog_message(rec, "host1").decode()
    m = re.match(r'^<(\d+)>1 (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z) host1 agentos-audit - gateway\.request '
                 r'\[agentos@32473 seq="(\d+)" hash="([0-9a-f]{64})" type="gateway\.request" actor="a1"\] (\{.*\})$', msg)
    assert m, msg
    assert int(m.group(1)) == 13 * 8 + 6                      # facility "log audit", severity informational
    assert int(m.group(3)) == rec["seq"]
    assert json.loads(m.group(5))["class_uid"] == 6003
    assert X.octet_frame(b"abc") == b"3 abc"
    err = X.syslog_message(by_type["auth.failure"], "h").decode()
    assert err.startswith("<108>1 ")                          # 13*8 + 4 (warning)


def test_structured_data_is_escaped(by_type):
    rec = dict(by_type["gateway.request"], actor='we"ird]\\')
    msg = X.syslog_message(rec, "h").decode()
    assert 'actor="we\\"ird\\]\\\\"' in msg


class SyslogServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, context=None):
        self.messages = []
        self.context = context
        self.connections = 0
        outer = self

        class H(socketserver.BaseRequestHandler):
            def handle(self):
                outer.connections += 1
                sock = self.request
                if outer.context:
                    try:
                        sock = outer.context.wrap_socket(sock, server_side=True)
                    except ssl.SSLError:
                        return
                buf = b""
                while True:
                    try:
                        data = sock.recv(65536)
                    except OSError:
                        return
                    if not data:
                        return
                    buf += data
                    while True:
                        head, _, rest = buf.partition(b" ")
                        if not head.isdigit() or len(rest) < int(head):
                            break
                        outer.messages.append(rest[:int(head)].decode())
                        buf = rest[int(head):]

        super().__init__(("127.0.0.1", 0), H)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def port(self):
        return self.server_address[1]


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def test_syslog_sink_sends_octet_counted_frames_over_tcp(adir):
    populate(adir)
    srv = SyslogServer()
    try:
        sink = X.SyslogSink("127.0.0.1", srv.port, tls=False, hostname="h1")
        sink.send(records(adir))
        assert wait_for(lambda: len(srv.messages) == 4)
        assert [json.loads(m.split("] ", 1)[1])["metadata"]["sequence"] for m in srv.messages] == [1, 2, 3, 4]
        sink.send(records(adir)[:1])                            # the connection is reused
        assert wait_for(lambda: len(srv.messages) == 5) and srv.connections == 1
        sink.close()
    finally:
        srv.shutdown()
        srv.server_close()


def tls_material(tmp_path):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    import ipaddress
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "localhost")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("localhost"),
                                                        x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]), False)
            .sign(key, hashes.SHA256()))
    crt, pem = tmp_path / "srv.crt", tmp_path / "srv.key"
    crt.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    pem.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
    return str(crt), str(pem)


def test_syslog_sink_over_tls_verifies_the_server(adir, tmp_path):
    populate(adir)
    crt, key = tls_material(tmp_path)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    srv = SyslogServer(ctx)
    try:
        sink = X.SyslogSink("127.0.0.1", srv.port, tls=True, ca_file=crt, hostname="h1")
        sink.send(records(adir))
        assert wait_for(lambda: len(srv.messages) == 4)
        sink.close()
        # a client that does not trust the certificate refuses to send
        untrusted = X.SyslogSink("127.0.0.1", srv.port, tls=True, hostname="h1")
        with pytest.raises(ssl.SSLError):
            untrusted.send(records(adir))
        assert untrusted.sock is None
    finally:
        srv.shutdown()
        srv.server_close()


# ── Splunk HEC and OTLP over HTTP ──────────────────────────────────────────
class HttpSink(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, responses=None):
        self.requests = []
        self.responses = list(responses or [])
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                outer.requests.append({"path": self.path, "headers": dict(self.headers), "body": body})
                status, payload = outer.responses.pop(0) if outer.responses else (200, {"text": "Success", "code": 0})
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *a):
                pass

        super().__init__(("127.0.0.1", 0), H)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return "http://127.0.0.1:%d" % self.server_address[1]


@pytest.fixture
def http_sink():
    made = []

    def make(responses=None):
        srv = HttpSink(responses)
        made.append(srv)
        return srv
    yield make
    for srv in made:
        srv.shutdown()
        srv.server_close()


def test_splunk_hec_sink(adir, tmp_path, http_sink):
    populate(adir)
    token = tmp_path / "hec.token"
    token.write_text("abc-123\n")
    srv = http_sink()
    sink = X.SplunkSink(srv.url + "/services/collector/event", str(token), index="agentos", host="node1")
    sink.send(records(adir))
    req, = srv.requests
    assert req["path"] == "/services/collector/event"
    assert req["headers"]["Authorization"] == "Splunk abc-123"
    events = [json.loads(line) for line in req["body"].decode().splitlines()]
    assert len(events) == 4
    first = events[0]
    assert first["host"] == "node1" and first["index"] == "agentos" and first["sourcetype"] == "agentos:audit:ocsf"
    assert first["time"] == pytest.approx(1_800_000_000.0) and first["event"]["class_uid"] == 6003
    assert [e["event"]["metadata"]["sequence"] for e in events] == [1, 2, 3, 4]


def test_splunk_hec_errors_are_raised(adir, tmp_path, http_sink):
    populate(adir)
    token = tmp_path / "t"
    token.write_text("x")
    srv = http_sink([(503, {"text": "Server is busy", "code": 9}), (200, {"text": "Invalid token", "code": 4})])
    sink = X.SplunkSink(srv.url + "/e", str(token))
    with pytest.raises(OSError, match="HTTP 503"):
        sink.send(records(adir))
    with pytest.raises(OSError, match="Invalid token"):
        sink.send(records(adir))


def test_otlp_logs_sink(adir, tmp_path, http_sink):
    populate(adir)
    srv = http_sink([(200, {})])
    sink = X.OtlpSink(srv.url + "/v1/logs")
    sink.send(records(adir))
    req, = srv.requests
    assert req["path"] == "/v1/logs" and req["headers"]["Content-Type"] == "application/json"
    doc = json.loads(req["body"])
    res, = doc["resourceLogs"]
    attrs = {a["key"]: a["value"] for a in res["resource"]["attributes"]}
    assert attrs["service.name"] == {"stringValue": "agentos-audit"}
    logs = res["scopeLogs"][0]["logRecords"]
    assert len(logs) == 4
    first = logs[0]
    assert first["timeUnixNano"] == str(1_800_000_000_000 * 1_000_000) and first["severityText"] == "INFORMATIONAL"
    assert first["severityNumber"] == 9
    assert json.loads(first["body"]["stringValue"])["class_uid"] == 6003
    fattrs = {a["key"]: a["value"] for a in first["attributes"]}
    assert fattrs["event.name"] == {"stringValue": "gateway.request"} and fattrs["audit.seq"] == {"intValue": "1"}
    assert logs[1]["severityNumber"] == 13                    # auth failure: WARN


def test_otlp_bearer_token_and_errors(adir, tmp_path, http_sink):
    populate(adir)
    token = tmp_path / "t"
    token.write_text("tok\n")
    srv = http_sink([(401, {"error": "no"}), (200, {})])
    sink = X.OtlpSink(srv.url + "/v1/logs", str(token))
    with pytest.raises(OSError, match="HTTP 401"):
        sink.send(records(adir))
    sink.send(records(adir))
    assert srv.requests[1]["headers"]["Authorization"] == "Bearer tok"


def test_url_must_be_http():
    with pytest.raises(ValueError):
        X.OtlpSink("ftp://x/y")


# ── the export loop ────────────────────────────────────────────────────────
class ListSink:
    name = "list"

    def __init__(self, fail=0):
        self.batches = []
        self.fail = fail
        self.closed = False

    def send(self, records):
        if self.fail:
            self.fail -= 1
            raise OSError("collector down")
        self.batches.append([r["seq"] for r in records])

    def close(self):
        self.closed = True


def test_cursor_advances_only_after_a_successful_send(adir, tmp_path):
    populate(adir)
    sink = ListSink(fail=1)
    cursor = str(tmp_path / "export" / "list.cursor")
    exp = X.Exporter(adir, sink, cursor, batch=3)
    with pytest.raises(OSError):
        exp.run_once()
    assert X.Cursor(cursor).load() == 0                        # nothing lost
    assert exp.run_once() == 3 and X.Cursor(cursor).load() == 3
    assert exp.run_once() == 1 and exp.run_once() == 0
    assert sink.batches == [[1, 2, 3], [4]]


def test_cursor_survives_a_restart_and_new_records_follow(adir, tmp_path):
    log = populate(adir)
    cursor = str(tmp_path / "c")
    X.Exporter(adir, ListSink(), cursor, batch=100).run_once()
    log.append("task.submit", "alice", "orchestrator", {"task": "t9"})
    log.sync()
    sink = ListSink()
    X.Exporter(adir, sink, cursor, batch=100).run_once()      # a new process, same cursor file
    assert sink.batches == [[5]]


def test_export_spans_segments_and_skips_a_torn_last_line(adir, tmp_path):
    log = A.AuditLog(adir, clock=Clock(), segment_bytes=600)
    for i in range(12):
        log.append("gateway.request", "a", "gateway", {"status": 200, "i": i})
    assert len(A.list_segments(adir)) > 2
    with open(A.list_segments(adir)[-1][1], "ab") as f:
        f.write(b'{"seq":13,"ts":1,')                           # being written right now
    sink = ListSink()
    exp = X.Exporter(adir, sink, str(tmp_path / "c"), batch=100)
    exp.run_once()
    assert sink.batches == [list(range(1, 13))]


def test_loop_retries_with_backoff_until_the_sink_recovers(adir, tmp_path):
    populate(adir)
    sink = ListSink(fail=3)
    exp = X.Exporter(adir, sink, str(tmp_path / "c"), batch=100, interval=0.05, max_backoff=0.05)
    stop = threading.Event()
    t = threading.Thread(target=exp.loop, args=(stop,), daemon=True)
    t.start()
    try:
        assert wait_for(lambda: sink.batches == [[1, 2, 3, 4]])
        assert exp.failures == 0 and exp.exported == 4
    finally:
        stop.set()
        t.join(timeout=3)
    assert sink.closed


def test_build_sinks_from_config(tmp_path):
    cfg = {"syslog": {"enabled": True, "host": "siem.example.org", "port": 6514, "tls": True},
           "splunk": {"enabled": True, "url": "https://splunk:8088/services/collector/event",
                      "token_file": "/run/t", "index": "main"},
           "otlp": {"enabled": False, "endpoint": "http://x/v1/logs"}}
    sinks = dict(X.build_sinks(cfg))
    assert set(sinks) == {"syslog", "splunk"}
    assert sinks["syslog"].port == 6514 and sinks["syslog"].tls
    assert sinks["splunk"].index == "main"
    assert X.build_sinks({}) == []


def test_start_exporters_ships_end_to_end(adir, http_sink, tmp_path):
    populate(adir)
    token = tmp_path / "tok"
    token.write_text("t")
    srv = http_sink()
    cfg = {"audit": {"export": {"interval_sec": 0.05, "batch": 100, "splunk": {
        "enabled": True, "url": srv.url + "/services/collector/event", "token_file": str(token)}}}}
    stop = threading.Event()
    exporters = X.start_exporters(cfg, adir, stop)
    try:
        assert len(exporters) == 1
        assert wait_for(lambda: srv.requests)
        assert wait_for(lambda: X.Cursor(adir + "/export/splunk.cursor").load() == 4)
    finally:
        stop.set()


def test_tokens_are_not_sent_in_clear_text(tmp_path):
    tok = tmp_path / "tok"
    tok.write_text("secret")
    with pytest.raises(ValueError):
        X.SplunkSink("http://splunk.example:8088/services/collector", str(tok))
    with pytest.raises(ValueError):
        X.OtlpSink("http://otel.example:4318/v1/logs", token_file=str(tok))
    X.SplunkSink("http://127.0.0.1:8088/services/collector", str(tok))   # loopback is fine
    X.OtlpSink("http://otel.example:4318/v1/logs")                       # no token, nothing to leak
