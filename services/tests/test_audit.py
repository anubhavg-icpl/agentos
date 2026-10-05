import json
import os
import socket
import threading
import time

import pytest

from agentos_services import audit as A
from agentos_services import tasks as T
from conftest import request
from orchfix import cfg, clock, complete, orch, runtime, submit, systemctl, taskstore  # noqa: F401
from test_daemon import FakeRunner, make_daemon, register  # noqa: F401


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class FakeAudit:
    enabled = True
    dropped = 0

    def __init__(self):
        self.events = []

    def emit(self, etype, actor=None, **data):
        self.events.append((etype, actor, {k: v for k, v in data.items() if v is not None}))

    def of(self, etype):
        return [e for e in self.events if e[0] == etype]

    def require(self):
        pass

    def healthy(self):
        return True

    def stats(self):
        return {"enabled": True}


@pytest.fixture
def signer():
    from cryptography.hazmat.primitives.asymmetric import ed25519
    return A.Signer(ed25519.Ed25519PrivateKey.generate())


@pytest.fixture
def adir(tmp_path):
    return str(tmp_path / "audit")


def make_log(adir, signer=None, n=0, clock=None, **kw):
    log = A.AuditLog(adir, signer, clock=clock or Clock(), **kw)
    for i in range(n):
        log.append("gateway.request", "agent-%d" % (i % 3), "gateway", {"status": 200, "i": i})
    log.sync()
    return log


def seg(adir, index=0):
    return A.list_segments(adir)[index][1]


def read_lines(path):
    with open(path, "rb") as f:
        return f.read().split(b"\n")[:-1]


def write_lines(path, lines):
    with open(path, "wb") as f:
        f.write(b"\n".join(lines) + b"\n")


def kinds(res):
    return [e["kind"] for e in res.errors]


# ── the chain ──────────────────────────────────────────────────────────────
def test_records_are_chained_and_verify(adir):
    make_log(adir, n=20)
    lines = read_lines(seg(adir))
    recs = [json.loads(line) for line in lines]
    assert [r["seq"] for r in recs] == list(range(1, 21))
    assert recs[0]["prev"] == A.GENESIS
    for prev_line, rec in zip(lines, recs[1:]):
        assert rec["prev"] == A.sha256_hex(prev_line)         # prev = sha256 of the previous line
    assert all(r["hash"] == A.record_hash(r) for r in recs)
    assert set(recs[0]) >= {"seq", "ts", "prev", "hash", "type", "actor", "data"}
    res = A.verify(adir)
    assert res.ok and res.records == 20 and res.first_seq == 1 and res.last_seq == 20


def test_edited_record_is_detected(adir):
    make_log(adir, n=10)
    lines = read_lines(seg(adir))
    lines[4] = lines[4].replace(b'"status":200', b'"status":403')
    write_lines(seg(adir), lines)
    res = A.verify(adir, max_errors=100)
    assert not res.ok and res.errors[0]["kind"] == "hash_mismatch" and res.errors[0]["seq"] == 5
    assert "chain_broken" in kinds(res)                          # and the next record no longer links


def test_edited_record_with_recomputed_hash_breaks_the_next_link(adir):
    make_log(adir, n=10)
    lines = read_lines(seg(adir))
    rec = json.loads(lines[4])
    rec["data"]["status"] = 500
    rec["hash"] = A.record_hash(rec)
    lines[4] = A.canonical(rec)
    write_lines(seg(adir), lines)
    res = A.verify(adir, max_errors=100)
    assert kinds(res) == ["chain_broken"] and res.errors[0]["seq"] == 6


def test_deleted_record_is_detected(adir):
    make_log(adir, n=10)
    lines = read_lines(seg(adir))
    del lines[3]
    write_lines(seg(adir), lines)
    res = A.verify(adir, max_errors=100)
    assert not res.ok and res.errors[0]["kind"] == "seq_gap" and res.errors[0]["seq"] == 5


def test_reordered_records_are_detected(adir):
    make_log(adir, n=10)
    lines = read_lines(seg(adir))
    lines[3], lines[4] = lines[4], lines[3]
    write_lines(seg(adir), lines)
    res = A.verify(adir, max_errors=100)
    assert not res.ok
    assert res.errors[0]["seq"] == 5 and res.errors[0]["kind"] in ("seq_gap", "out_of_order")


def test_inserted_and_duplicated_records_are_detected(adir):
    make_log(adir, n=6)
    lines = read_lines(seg(adir))
    write_lines(seg(adir), lines[:3] + [lines[2]] + lines[3:])
    res = A.verify(adir, max_errors=100)
    assert not res.ok and res.errors[0]["kind"] == "out_of_order"


def test_garbage_line_is_reported(adir):
    make_log(adir, n=3)
    lines = read_lines(seg(adir))
    write_lines(seg(adir), lines[:1] + [b"not json"] + lines[1:])
    assert "bad_record" in kinds(A.verify(adir, max_errors=100))


def test_verify_from_seq_checks_only_that_range_but_anchors_on_the_previous_segment(adir):
    make_log(adir, n=40, segment_bytes=1500)
    segments = A.list_segments(adir)
    assert len(segments) > 3
    first_of_third = segments[2][0]
    res = A.verify(adir, from_seq=first_of_third)
    assert res.ok and res.first_seq == first_of_third and res.segments == len(segments) - 2
    # damage before the range is not looked at ...
    lines = read_lines(segments[0][1])
    lines[0] = lines[0].replace(b'"status":200', b'"status":999')
    write_lines(segments[0][1], lines)
    assert A.verify(adir, from_seq=first_of_third).ok
    # ... but the full check finds it
    assert not A.verify(adir).ok


def test_rotation_keeps_the_chain_across_segments(adir):
    make_log(adir, n=40, segment_bytes=1500)
    segments = A.list_segments(adir)
    assert len(segments) > 3
    res = A.verify(adir)
    assert res.ok and res.records == 40 and res.segments == len(segments)
    # the first record of each later segment links to the last line of the previous one
    for (_, a), (first, b) in zip(segments, segments[1:]):
        assert json.loads(read_lines(b)[0])["prev"] == A.sha256_hex(read_lines(a)[-1])
        assert json.loads(read_lines(b)[0])["seq"] == first
    # a removed segment is a gap
    os.unlink(segments[1][1])
    res = A.verify(adir, max_errors=100)
    assert not res.ok and {"segment_gap", "seq_gap"} & set(kinds(res))


def test_rotation_on_a_new_utc_day(adir):
    clock = Clock()
    log = make_log(adir, n=2, clock=clock)
    clock.advance(86400)
    log.append("gateway.request", "a", "gateway", {"status": 200})
    assert len(A.list_segments(adir)) == 2 and A.verify(adir).ok


def test_log_resumes_the_chain_after_restart_and_trims_a_torn_write(adir):
    log = make_log(adir, n=5)
    path = seg(adir)
    os.close(log.fd)
    with open(path, "ab") as f:
        f.write(b'{"seq":6,"ts":1,"prev":"abc')              # crash mid-write
    log2 = A.AuditLog(adir, clock=Clock())
    assert log2.seq == 5
    log2.append("gateway.request", "a", "gateway", {"status": 200})
    res = A.verify(adir)
    assert res.ok and res.last_seq == 6


def test_unreadable_last_record_stops_the_writer(adir):
    make_log(adir, n=2)
    with open(seg(adir), "ab") as f:
        f.write(b"garbage\n")
    with pytest.raises(A.AuditError):
        A.AuditLog(adir)


def test_empty_directory_does_not_verify(adir):
    os.makedirs(adir)
    assert kinds(A.verify(adir)) == ["empty"]


# ── checkpoints ────────────────────────────────────────────────────────────
def test_checkpoints_are_signed_and_verified(adir, signer):
    log = A.AuditLog(adir, signer, clock=Clock(), checkpoint_every=4)
    for i in range(12):
        log.append("gateway.request", "a", "gateway", {"status": 200, "i": i})
        log.housekeeping()                                    # what the writer does after each batch
    log.checkpoint()
    recs = [json.loads(line) for line in read_lines(seg(adir))]
    cps = [r for r in recs if r["type"] == A.CHECKPOINT]
    assert len(cps) >= 3
    first = cps[0]["data"]
    assert first["key_id"] == signer.key_id and len(first["sig"]) == 128
    assert first["upto_hash"] == next(r["hash"] for r in recs if r["seq"] == first["upto_seq"])
    res = A.verify(adir, pubkeys={signer.key_id: signer.public_hex})
    assert res.ok and res.checkpoints == len(cps) and res.last_checkpoint_seq == cps[-1]["data"]["upto_seq"]


def test_checkpoint_on_timer(adir, signer):
    clock = Clock()
    log = make_log(adir, signer, n=3, clock=clock, checkpoint_every=1000, checkpoint_interval=300)
    log.housekeeping()
    assert not [r for r in A.iter_records(adir) if r["type"] == A.CHECKPOINT]
    clock.advance(301)
    log.housekeeping()
    assert [r for r in A.iter_records(adir) if r["type"] == A.CHECKPOINT]


def test_forged_signature_is_detected(adir, signer):
    make_log(adir, signer, n=5).checkpoint()
    lines = read_lines(seg(adir))
    rec = json.loads(lines[-1])
    rec["data"]["sig"] = "0" * 128
    rec["hash"] = A.record_hash(rec)
    lines[-1] = A.canonical(rec)
    write_lines(seg(adir), lines)
    res = A.verify(adir, pubkeys={signer.key_id: signer.public_hex})
    assert kinds(res) == ["bad_signature"]


def test_rewritten_history_with_a_consistent_chain_fails_the_checkpoint(adir, signer):
    """An attacker with write access re-computes every hash after the edit; only the signature gives it away."""
    make_log(adir, signer, n=8).checkpoint()
    recs = [json.loads(line) for line in read_lines(seg(adir))]
    recs[2]["data"]["status"] = 401                         # rewrite history
    lines = [A.canonical(r) for r in recs[:2]]
    prev_line_hash = A.sha256_hex(lines[-1])
    for r in recs[2:]:
        r["prev"] = prev_line_hash
        r["hash"] = A.record_hash(r)
        line = A.canonical(r)
        lines.append(line)
        prev_line_hash = A.sha256_hex(line)
    write_lines(seg(adir), lines)
    res = A.verify(adir, pubkeys={signer.key_id: signer.public_hex}, max_errors=100)
    assert not res.ok
    assert kinds(res) == ["checkpoint_mismatch"]            # the chain itself is internally consistent
    # without a trusted key the checkpoint cannot vouch for anything either
    assert "unknown_key" in kinds(A.verify(adir, pubkeys={}, max_errors=100))


def test_a_key_the_attacker_made_is_not_trusted(adir, signer):
    from cryptography.hazmat.primitives.asymmetric import ed25519
    make_log(adir, signer, n=4).checkpoint()
    other = A.Signer(ed25519.Ed25519PrivateKey.generate())
    res = A.verify(adir, pubkeys={other.key_id: other.public_hex})
    assert kinds(res) == ["unknown_key"]


def test_public_keys_file_and_keygen(adir, tmp_path):
    key = str(tmp_path / "keys" / "signing.key")
    assert A.generate_key(key, str(tmp_path / "pub.hex"))
    assert oct(os.stat(key).st_mode & 0o777) == "0o400"
    assert not A.generate_key(key)                           # never overwritten
    signer = A.Signer.load(key)
    assert open(str(tmp_path / "pub.hex")).read().strip() == signer.public_hex
    os.makedirs(adir)
    A._register_public_key(adir, signer)
    A._register_public_key(adir, signer)
    assert A.load_public_keys(adir) == {signer.key_id: signer.public_hex}
    assert open(os.path.join(adir, "public.keys")).read().count("\n") == 1


def test_cli_verify_and_tail(adir, signer, capsys):
    make_log(adir, signer, n=6).checkpoint()
    A._register_public_key(adir, signer)
    assert A.main(["--dir", adir, "verify"]) == 0
    assert "OK: 7 records" in capsys.readouterr().out
    assert A.main(["--dir", adir, "tail", "-n", "3"]) == 0
    out = capsys.readouterr().out
    assert len(out.strip().splitlines()) == 3 and "audit.checkpoint" in out
    assert A.main(["--dir", adir, "tail", "-n", "2", "--json"]) == 0
    assert [json.loads(l)["seq"] for l in capsys.readouterr().out.splitlines()] == [6, 7]
    lines = read_lines(seg(adir))
    lines[2] = lines[2].replace(b'"status":200', b'"status":418')
    write_lines(seg(adir), lines)
    assert A.main(["--dir", adir, "verify"]) == 1
    assert "FAIL hash_mismatch at seq 3" in capsys.readouterr().err


# ── retention ──────────────────────────────────────────────────────────────
def test_retention_prunes_old_segments_and_the_rest_still_verifies(adir, signer):
    clock = Clock()
    log = make_log(adir, signer, n=30, clock=clock, segment_bytes=1500, retention_days=183)
    old = len(A.list_segments(adir))
    assert old > 3
    clock.advance(100 * 86400)
    assert log.prune() == []                                  # inside the retention period
    clock.advance(100 * 86400)
    log.append("gateway.request", "a", "gateway", {"status": 200})   # a segment in the new period
    removed = log.prune()
    assert removed and len(A.list_segments(adir)) < old
    assert [r for r in A.iter_records(adir) if r["type"] == "audit.retention"]
    res = A.verify(adir, pubkeys={signer.key_id: signer.public_hex})
    assert res.ok and res.anchored is False and res.first_seq > 1


def test_retention_never_removes_the_active_segment(adir):
    clock = Clock()
    log = make_log(adir, n=3, clock=clock, retention_days=1)
    clock.advance(30 * 86400)
    assert log.prune() == [] and A.verify(adir).ok


# ── writer over a unix socket ──────────────────────────────────────────────
@pytest.fixture
def writer(adir, short_dir, signer):
    sock = os.path.join(short_dir, "audit.sock")
    w = A.Writer(A.AuditLog(adir, signer, checkpoint_every=5), sock)
    w.serve_socket()
    w.start()
    w.sock = sock
    w.signer = signer
    yield w
    w.shutdown()


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return False


def test_events_over_the_socket_are_chained_with_the_sender_identity(writer, adir):
    client = A.AuditClient(writer.sock, source="gateway")
    for i in range(12):
        assert client.emit("gateway.request", "a1", provider="anthropic", model="m", status=200, cost_usd=0.01, i=i)
    assert wait_for(lambda: len([r for r in A.iter_records(adir) if r["type"] == "gateway.request"]) == 12)
    recs = [r for r in A.iter_records(adir) if r["type"] == "gateway.request"]
    assert recs[0]["actor"] == "a1" and recs[0]["source"] == "gateway"
    assert recs[0]["peer"]["uid"] == os.getuid() and recs[0]["peer"]["pid"] == os.getpid()
    assert recs[0]["data"]["provider"] == "anthropic" and "ets" in recs[0]
    writer.shutdown()
    res = A.verify(adir, pubkeys={writer.signer.key_id: writer.signer.public_hex})
    assert res.ok and res.checkpoints >= 1
    client.close()


def test_writer_rejects_forged_and_oversized_events(writer, adir):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(writer.sock)
    s.sendall(b'{"type":"audit.checkpoint","data":{"sig":"x"}}\n')           # only the writer writes checkpoints
    s.sendall(b'{"type":"nonsense"}\nnot json\n[1,2]\n')
    s.sendall(b'{"type":"task.finish","actor":"a","data":{"task":"t1"}}\n')
    assert wait_for(lambda: any(r["type"] == "task.finish" for r in A.iter_records(adir)))
    assert not [r for r in A.iter_records(adir) if r["type"] == A.CHECKPOINT and r["source"] != "audit"]
    assert writer.rejected == 4
    s.sendall(b'{"type":"task.finish","data":{"x":"' + b"a" * (A.MAX_EVENT_BYTES + 10) + b'"}}\n')
    s.close()
    assert wait_for(lambda: writer.rejected == 5)


def test_socket_is_not_group_or_world_writable_beyond_660(writer):
    assert oct(os.stat(writer.sock).st_mode & 0o777) == "0o660"


# ── the client never blocks ────────────────────────────────────────────────
def test_client_never_blocks_and_counts_drops_when_the_writer_is_down(short_dir):
    client = A.AuditClient(os.path.join(short_dir, "nope.sock"), source="gateway", buffer=50, retry_sec=0.05)
    start = time.time()
    results = [client.emit("gateway.request", "a", status=200, i=i) for i in range(2000)]
    assert time.time() - start < 1.0                          # no connect attempt on the caller's thread
    assert results.count(True) == 50 and client.dropped == 1950
    assert client.stats()["buffered"] == 50 and not client.healthy()
    client.close()


def test_client_flushes_its_buffer_and_records_the_loss_when_the_writer_returns(short_dir, adir, signer):
    sock = os.path.join(short_dir, "late.sock")
    client = A.AuditClient(sock, source="gateway", buffer=10, retry_sec=0.05)
    for i in range(25):
        client.emit("gateway.request", "a", status=200, i=i)
    assert client.dropped == 15
    w = A.Writer(A.AuditLog(adir, signer), sock)
    w.serve_socket()
    w.start()
    try:
        assert wait_for(lambda: len([r for r in A.iter_records(adir) if r["type"] == "gateway.request"]) == 10)
        assert wait_for(lambda: any(r["type"] == "audit.dropped" for r in A.iter_records(adir)))
        dropped = next(r for r in A.iter_records(adir) if r["type"] == "audit.dropped")
        assert dropped["data"]["dropped"] == 15
        assert wait_for(client.healthy)
    finally:
        w.shutdown()
        client.close()


def test_client_reconnects_after_the_writer_restarts(short_dir, adir, signer):
    sock = os.path.join(short_dir, "re.sock")
    client = A.AuditClient(sock, source="gateway", retry_sec=0.05)
    w = A.Writer(A.AuditLog(adir, signer), sock)
    w.serve_socket()
    w.start()
    client.emit("gateway.request", "a", status=200, n=1)
    assert wait_for(lambda: any(r["type"] == "gateway.request" for r in A.iter_records(adir)))
    w.shutdown()
    time.sleep(0.2)
    w = A.Writer(A.AuditLog(adir, signer), sock)
    w.serve_socket()
    w.start()
    try:
        for n in range(2, 8):
            client.emit("gateway.request", "a", status=200, n=n)
            time.sleep(0.1)
        assert wait_for(lambda: max([r["data"].get("n", 0) for r in A.iter_records(adir)
                                     if r["type"] == "gateway.request"]) == 7)
        assert A.verify(adir, pubkeys={signer.key_id: signer.public_hex}).ok
    finally:
        w.shutdown()
        client.close()


def test_strict_mode_fails_closed(short_dir, writer):
    down = A.AuditClient(os.path.join(short_dir, "nope.sock"), strict=True, retry_sec=0.05)
    with pytest.raises(A.AuditUnavailable):
        down.require()
    lax = A.AuditClient(os.path.join(short_dir, "nope.sock"), strict=False, retry_sec=0.05)
    lax.require()                                             # non-strict: never raises
    up = A.AuditClient(writer.sock, strict=True)
    up.require()
    up.emit("gateway.request", "a", status=200)
    up.require()
    for c in (down, lax, up):
        c.close()


def test_null_client_and_config():
    null = A.client_from_config({}, "gateway")
    assert not null.enabled and null.emit("x") is None and null.healthy()
    on = A.client_from_config({"audit": {"enabled": True, "socket": "/nonexistent/s", "strict": True, "buffer": 5}}, "daemon")
    assert on.enabled and on.strict and on.capacity == 5 and on.source == "daemon"
    on.close()


# ── the hooks in the services ──────────────────────────────────────────────
def test_gateway_audits_requests_without_prompt_bodies(make_gateway, store):
    gw = make_gateway()
    gw.audit = FakeAudit()
    secret_prompt = "the launch codes are 0000-top-secret"
    status, _, _ = request(gw, "POST", "/agent/a1/anthropic/v1/messages",
                           {"model": "claude-test", "messages": [{"role": "user", "content": secret_prompt}],
                            "mock_tokens": {"input_tokens": 1000, "output_tokens": 100}})
    assert status == 200
    (etype, actor, data), = gw.audit.of("gateway.request")
    assert actor == "a1" and data["provider"] == "anthropic" and data["model"] == "claude-test"
    assert data["status"] == 200 and data["cost_usd"] > 0 and data["tokens"]["input_tokens"] == 1000
    assert secret_prompt not in json.dumps(gw.audit.events)


def test_gateway_audits_budget_refusals_and_refused_requests(make_gateway):
    gw = make_gateway(budget={"default_daily_usd": 0.0001})
    gw.audit = FakeAudit()
    big = {"model": "claude-test", "mock_tokens": {"input_tokens": 1_000_000, "output_tokens": 0}}
    request(gw, "POST", "/agent/a1/anthropic/v1/messages", big)
    status, _, _ = request(gw, "POST", "/agent/a1/anthropic/v1/messages", big)
    assert status == 402
    refused, = gw.audit.of("budget.refused")
    assert refused[1] == "a1" and refused[2]["scope"] == "agent" and refused[2]["limit_usd"] == 0.0001
    assert any(e[2].get("error") == "budget_exceeded" and e[2]["status"] == 402 for e in gw.audit.of("gateway.request"))


def test_gateway_audits_auth_failures(make_gateway):
    gw = make_gateway(gateway={"require_agent_tokens": True})
    gw.audit = FakeAudit()
    status, _, _ = request(gw, "POST", "/agent/a1:wrong/anthropic/v1/messages", {"model": "claude-test"})
    assert status == 401
    (_, actor, data), = gw.audit.of("auth.failure")
    assert actor is None and data["claimed_agent"] == "a1" and data["reason"] == "bad_token"
    assert "wrong" not in json.dumps(gw.audit.events)


class DownAudit(FakeAudit):
    def require(self):
        raise A.AuditUnavailable("the audit writer is unreachable; refusing work in strict audit mode")


def test_gateway_in_strict_mode_refuses_while_audit_is_down(make_gateway, upstream):
    gw = make_gateway()
    gw.audit = DownAudit()
    status, headers, raw = request(gw, "POST", "/agent/a1/anthropic/v1/messages", {"model": "claude-test"})
    assert status == 503 and json.loads(raw)["error"]["type"] == "audit_unavailable"
    assert upstream.requests == []


def test_health_reports_audit_counters(make_gateway):
    gw = make_gateway()
    gw.audit = FakeAudit()
    status, _, raw = request(gw, "GET", "/_agentos/health")
    assert json.loads(raw)["audit"] == {"enabled": True}
    gw.audit = A.NullClient()
    assert "audit" not in json.loads(request(gw, "GET", "/_agentos/health")[2])


def test_orchestrator_audits_submit_approve_reject_cancel_and_finish(orch):
    fake = FakeAudit()
    orch.audit = fake
    orch.tasks.audit = fake
    peer = {"pid": 1, "uid": os.getuid(), "gid": 0}
    g, = orch.submit({"agent": "fake", "workspace": "demo", "prompt": "SECRET PROMPT TEXT", "gate": True}, peer)
    h, = orch.submit({"agent": "fake", "workspace": "other", "prompt": "x", "gate": True}, peer)
    sub = fake.of("task.submit")
    assert [e[2]["task"] for e in sub] == [g["id"], h["id"]] and sub[0][2]["gated"] is True and sub[0][1]
    orch.decide(g["id"], True, peer, "ok")
    orch.decide(h["id"], False, peer, "no")
    (_, who, data), = fake.of("task.approve")
    assert data["task"] == g["id"] and data["note"] == "ok" and data["uid"] == os.getuid() and who
    assert fake.of("task.reject")[0][2]["task"] == h["id"]
    orch.tick()
    complete(orch, g["id"], T.SUCCEEDED)
    fin, = fake.of("task.finish")
    assert fin[2]["task"] == g["id"] and fin[2]["status"] == "succeeded" and fin[2]["exit_code"] == 0
    c, = orch.submit({"agent": "fake", "workspace": "demo", "prompt": "later"}, peer)
    orch.cancel(c["id"], peer)
    assert fake.of("task.cancel")[0][2]["task"] == c["id"]
    assert "SECRET PROMPT TEXT" not in json.dumps(fake.events)


def test_task_retry_is_audited(orch):
    fake = FakeAudit()
    orch.audit = orch.tasks.audit = fake
    t, = orch.submit({"agent": "fake", "workspace": "demo", "prompt": "x", "max_retries": 1, "backoff_sec": 1})
    orch.tick()
    complete(orch, t["id"], T.FAILED)
    assert [e[0] for e in fake.events if e[0] in ("task.retry", "task.finish")] == ["task.retry"]


def test_orchestrator_in_strict_mode_refuses_changes_while_audit_is_down(orch):
    from agentos_services.unixapi import ApiError
    orch.audit = DownAudit()
    with pytest.raises(ApiError) as exc:
        orch.submit({"agent": "fake", "workspace": "demo", "prompt": "x"})
    assert exc.value.status == 503
    assert orch.tasks.active_ids() == []


def test_daemon_audits_spawn_kill_and_exit(make_daemon):
    fake = FakeAudit()
    runner = FakeRunner(active={"agentos-agent-live.service", "agentos-agent-doomed.service"})
    d = make_daemon(runner)
    d.audit = fake
    register(d, "live", unit="agentos-agent-live.service", operator="alice", workspace="/ws/a", isolation="sandbox",
             sandboxed=True)
    register(d, "doomed", unit="agentos-agent-doomed.service")
    register(d, "gone", unit="agentos-agent-gone.service")
    d.reap()
    spawned = {e[2]["agent"]: e for e in fake.of("agent.spawn")}
    assert set(spawned) == {"live", "doomed"} and spawned["live"][1] == "alice"
    assert spawned["live"][2]["isolation"] == "sandbox"
    assert [e[2]["agent"] for e in fake.of("agent.exit")] == ["gone"]
    assert d.kill("doomed", "daily budget exceeded")
    (_, _, kill), = fake.of("agent.kill")
    assert kill["agent"] == "doomed" and kill["reason"] == "daily budget exceeded"
    assert "command" not in json.dumps(fake.events)           # command lines may carry prompts
