"""AgentOS tamper-evident audit log.

Records who did what, in a form that makes after-the-fact edits detectable
(EU AI Act Art. 12 record-keeping, SOC 2 CC7.2, ISO 27001 A.8.15).

Storage. Append-only JSONL segments in the audit directory, written only by
the writer process (`agentos-audit serve`, user agentos-audit):

    audit-000000000001.jsonl      named by the seq of their first record
    audit-000000004217.jsonl

Every record is one canonical JSON line with

    seq    1, 2, 3, ... with no gaps, continuing across segments
    ts     Unix time in milliseconds, set by the writer
    prev   sha256 of the previous record's line (64 zeros for the first)
    hash   sha256 of this record's canonical JSON without the hash field
    type, actor, source, data, peer    what happened (see EVENT_TYPES)

so editing a record breaks its hash and the next record's prev; deleting or
reordering records breaks seq and prev. Every few minutes (or N records) the
writer appends an `audit.checkpoint` record carrying an Ed25519 signature over
(seq, hash) of the last record, made with a key only the writer can read. A
verifier with the public key can then also tell a rewritten tail from a
genuine one.

Producers (gateway, orchestrator, daemon, task runner) never touch the files.
They send JSON events over a unix socket (AuditClient); the writer stamps
seq/ts/prev/hash and records the sender's uid/pid from SO_PEERCRED. The client
never blocks the request path: it buffers in memory and, when the writer is
unreachable and the buffer is full, drops events and counts them; the count is
written into the chain as an `audit.dropped` record once the writer is back.
With audit.strict the gateway and orchestrator refuse work instead while the
writer is unreachable (AuditClient.require()).

CLI:
    agentos-audit serve                    the writer (systemd service)
    agentos-audit verify [--from SEQ]      check chain and checkpoint signatures
    agentos-audit tail [-n N] [-f]         show records
    agentos-audit keygen --out FILE        create the signing key (first boot)
"""

import argparse
import collections
import hashlib
import json
import logging
import os
import queue
import re
import signal
import socket
import socketserver
import struct
import sys
import threading
import time

from . import config as configmod

log = logging.getLogger("agentos.audit")

GENESIS = "0" * 64
SEGMENT_RE = re.compile(r"^audit-(\d{12})\.jsonl$")
MAX_EVENT_BYTES = 32 * 1024
CHECKPOINT = "audit.checkpoint"
SIG_CONTEXT = b"agentos-audit-checkpoint-v1"

# Events producers may send. audit.* records written by the writer itself
# (checkpoint, retention, start) are rejected when a client claims them.
EVENT_TYPES = frozenset({
    "gateway.request",      # agent, provider, model, status, cost; never prompt bodies
    "budget.refused",       # a request refused for lack of budget
    "auth.failure",         # bad or missing agent token
    "dlp.detection",        # DLP findings (types and counts only)
    "task.submit", "task.approve", "task.reject", "task.cancel", "task.retry", "task.finish",
    "agent.spawn", "agent.kill", "agent.exit",
    "publish.pr",
    "publish.merge",        # auto-merge outcome (merged, skipped, error)
    "factory.item.created", "factory.item.state", "factory.item.decision", "factory.item.publish",
    "factory.line.pause",
    "audit.dropped",        # client-side loss counter
})
WRITER_TYPES = frozenset({CHECKPOINT, "audit.retention", "audit.start"})


# ── canonical form ──────────────────────────────────────────────────────────
def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def record_hash(rec):
    return sha256_hex(canonical({k: v for k, v in rec.items() if k != "hash"}))


def checkpoint_message(seq, digest):
    return b"%s\n%d\n%s" % (SIG_CONTEXT, seq, digest.encode())


class AuditError(Exception):
    pass


class AuditUnavailable(AuditError):
    """The audit writer cannot be reached (strict mode refuses work)."""


# ── signing ─────────────────────────────────────────────────────────────────
def _ed25519():
    try:
        from cryptography.hazmat.primitives.asymmetric import ed25519
        return ed25519
    except ImportError as exc:       # pragma: no cover - dependency is declared
        raise AuditError("the 'cryptography' package is required for audit signatures") from exc


def generate_key(path, public_path=None):
    """Write a new Ed25519 private key (PEM, mode 0400) unless `path` exists."""
    from cryptography.hazmat.primitives import serialization
    if os.path.exists(path):
        return False
    key = _ed25519().Ed25519PrivateKey.generate()
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    with os.fdopen(fd, "wb") as f:
        f.write(pem)
    if public_path:
        with open(public_path, "w") as f:
            f.write(Signer(key).public_hex + "\n")
    return True


class Signer:
    def __init__(self, private_key):
        self.key = private_key
        from cryptography.hazmat.primitives import serialization
        raw = private_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.public_hex = raw.hex()
        self.key_id = sha256_hex(raw)[:16]

    @classmethod
    def load(cls, path):
        from cryptography.hazmat.primitives import serialization
        with open(path, "rb") as f:
            key = serialization.load_pem_private_key(f.read(), password=None)
        return cls(key)

    def sign(self, seq, digest):
        return self.key.sign(checkpoint_message(seq, digest)).hex()


def verify_signature(public_hex, seq, digest, sig_hex):
    from cryptography.exceptions import InvalidSignature
    pub = _ed25519().Ed25519PublicKey.from_public_bytes(bytes.fromhex(public_hex))
    try:
        pub.verify(bytes.fromhex(sig_hex), checkpoint_message(seq, digest))
        return True
    except (InvalidSignature, ValueError):
        return False


def key_id_of(public_hex):
    return sha256_hex(bytes.fromhex(public_hex))[:16]


def load_public_keys(directory, extra=None):
    """{key_id: public_hex} from <dir>/public.keys (one hex key per line) and `extra` files."""
    keys = {}
    for path in [os.path.join(directory, "public.keys")] + list(extra or []):
        try:
            with open(path) as f:
                for line in f:
                    line = line.split("#")[0].strip().split()
                    if line and re.fullmatch(r"[0-9a-f]{64}", line[-1]):
                        keys[key_id_of(line[-1])] = line[-1]
        except OSError:
            continue
    return keys


# ── files ───────────────────────────────────────────────────────────────────
def list_segments(directory):
    """[(first_seq, path)] sorted by first_seq."""
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    out = []
    for name in names:
        m = SEGMENT_RE.match(name)
        if m:
            out.append((int(m.group(1)), os.path.join(directory, name)))
    return sorted(out)


def read_last_line(path):
    """Last complete line of a file (bytes without the newline), or None."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        size = f.tell()
        pos, buf = size, b""
        while pos > 0:
            step = min(65536, pos)
            pos -= step
            f.seek(pos)
            buf = f.read(step) + buf
            body = buf[:-1] if buf.endswith(b"\n") else buf
            if b"\n" in body or pos == 0:
                if not buf.endswith(b"\n"):
                    # an unterminated tail is not a complete record
                    cut = buf.rfind(b"\n")
                    if cut < 0:
                        return None
                    buf = buf[:cut + 1]
                    body = buf[:-1]
                return body.rsplit(b"\n", 1)[-1] or None
        return None


def iter_lines(path):
    """(line_no, bytes) for each newline-terminated line; an unterminated tail is skipped."""
    with open(path, "rb") as f:
        for n, raw in enumerate(f, 1):
            if raw.endswith(b"\n"):
                yield n, raw[:-1]


def iter_records(directory, after_seq=0):
    """Parsed records with seq > after_seq, in order (unparseable lines are skipped)."""
    segments = list_segments(directory)
    start = 0
    for i, (first, _) in enumerate(segments):
        if first <= after_seq + 1:
            start = i
    for _, path in segments[start:]:
        try:
            for _, line in iter_lines(path):
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if isinstance(rec, dict) and isinstance(rec.get("seq"), int) and rec["seq"] > after_seq:
                    yield rec
        except OSError:
            return


# ── the log ─────────────────────────────────────────────────────────────────
class AuditLog:
    """Single-writer append-only chain. Not thread safe: callers serialise."""

    def __init__(self, directory, signer=None, segment_bytes=64 * 1024 * 1024, checkpoint_every=100,
                 checkpoint_interval=300.0, retention_days=183, clock=time.time, fsync=True):
        self.dir = directory
        self.signer = signer
        self.segment_bytes = int(segment_bytes)
        self.checkpoint_every = int(checkpoint_every)
        self.checkpoint_interval = float(checkpoint_interval)
        self.retention_days = int(retention_days)
        self.clock = clock
        self.fsync = fsync
        self.seq = 0
        self.prev = GENESIS
        self.hash = None
        self.fd = None
        self.size = 0
        self.seg_first = None
        self.seg_day = None
        self.last_checkpoint_seq = 0
        self.last_checkpoint_at = clock()
        self.dirty = False
        self.open()

    # -- recovery
    def open(self):
        os.makedirs(self.dir, mode=0o750, exist_ok=True)
        segments = list_segments(self.dir)
        for first, path in reversed(segments):
            self._trim_partial(path)
            line = read_last_line(path)
            if line is None:
                if os.path.getsize(path) == 0:
                    # Created by _rotate but never written (or its only line was torn):
                    # drop it, or the next rotation to this seq fails on O_EXCL
                    log.warning("%s: removing an empty segment left by a crash", path)
                    os.unlink(path)
                continue
            try:
                rec = json.loads(line)
                self.seq, self.prev, self.hash = int(rec["seq"]), sha256_hex(line), rec["hash"]
            except (ValueError, KeyError, TypeError) as exc:
                raise AuditError("the last record of %s is damaged (%s); run `agentos-audit verify` and "
                                 "investigate before restarting the writer" % (path, exc))
            self.last_checkpoint_seq = self.seq
            self.seg_first = first
            self.seg_day = _day(rec.get("ts", 0) / 1000.0)
            self.size = os.path.getsize(path)
            self.fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o640)
            return
        self.seg_first = None

    @staticmethod
    def _trim_partial(path):
        """A crash can leave a half-written last line; drop it (it was never acknowledged)."""
        with open(path, "rb") as f:
            data = f.read()
        if data and not data.endswith(b"\n"):
            keep = data.rfind(b"\n") + 1
            log.warning("%s: dropping a %d byte partial record left by a crash", path, len(data) - keep)
            os.truncate(path, keep)

    # -- writing
    def _segment_path(self, first):
        return os.path.join(self.dir, "audit-%012d.jsonl" % first)

    def _rotate(self, next_seq, now):
        if self.fd is not None:
            os.fsync(self.fd)
            os.close(self.fd)
        self.seg_first = next_seq
        self.seg_day = _day(now)
        self.fd = os.open(self._segment_path(next_seq), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_EXCL, 0o640)
        self.size = 0

    def append(self, etype, actor=None, source=None, data=None, peer=None, ets=None):
        """Append one record; returns it."""
        now = self.clock()
        seq = self.seq + 1
        rec = {"seq": seq, "ts": int(now * 1000), "prev": self.prev, "type": etype,
               "actor": actor, "source": source, "data": data or {}}
        if peer:
            rec["peer"] = peer
        if ets is not None:
            rec["ets"] = ets
        rec["hash"] = record_hash(rec)
        line = canonical(rec) + b"\n"
        if self.fd is None or (self.size > 0 and (self.size + len(line) > self.segment_bytes or _day(now) != self.seg_day)):
            self._rotate(seq, now)
        os.write(self.fd, line)
        self.size += len(line)
        self.seq = seq
        self.prev = sha256_hex(line[:-1])
        self.hash = rec["hash"]
        self.dirty = True
        return rec

    def sync(self):
        if self.fd is not None and self.dirty and self.fsync:
            os.fsync(self.fd)
        self.dirty = False

    def checkpoint(self):
        """Append a signed checkpoint over the last record."""
        if self.signer is None or self.seq == 0 or self.seq == self.last_checkpoint_seq:
            return None
        upto, digest = self.seq, self.hash        # the signature covers the record's own hash
        rec = self.append(CHECKPOINT, source="audit", data={
            "upto_seq": upto, "upto_hash": digest, "key_id": self.signer.key_id,
            "public_key": self.signer.public_hex, "sig": self.signer.sign(upto, digest)})
        self.last_checkpoint_seq = rec["seq"]
        self.last_checkpoint_at = self.clock()
        return rec

    def housekeeping(self):
        """Checkpoint when due, then sync."""
        due = (self.seq - self.last_checkpoint_seq >= self.checkpoint_every or
               (self.seq > self.last_checkpoint_seq and
                self.clock() - self.last_checkpoint_at >= self.checkpoint_interval))
        if due:
            self.checkpoint()
        self.sync()

    def prune(self):
        """Delete closed segments whose newest record is older than the retention period."""
        if self.retention_days <= 0:
            return []
        cutoff = (self.clock() - self.retention_days * 86400) * 1000
        removed = []
        segments = list_segments(self.dir)
        for first, path in segments[:-1]:          # never the newest segment
            line = read_last_line(path)
            try:
                newest = json.loads(line)["ts"] if line else 0
            except (ValueError, KeyError):
                break
            if newest >= cutoff:
                break                              # segments are in time order
            os.unlink(path)
            removed.append(os.path.basename(path))
        if removed:
            kept = list_segments(self.dir)
            self.append("audit.retention", source="audit", data={
                "removed_segments": removed, "retention_days": self.retention_days,
                "first_seq_kept": kept[0][0] if kept else self.seq + 1})
        return removed

    def close(self):
        if self.fd is not None:
            try:
                self.checkpoint()
                self.sync()
            finally:
                os.close(self.fd)
                self.fd = None


def _day(ts):
    return time.strftime("%Y-%m-%d", time.gmtime(ts))


# ── verification ────────────────────────────────────────────────────────────
class VerifyResult:
    def __init__(self):
        self.errors = []
        self.records = 0
        self.segments = 0
        self.first_seq = None
        self.last_seq = None
        self.checkpoints = 0
        self.checkpoints_unchecked = 0
        self.last_checkpoint_seq = 0       # seq the newest verified checkpoint signs
        self.last_checkpoint_record = 0    # seq of that checkpoint record itself
        self.anchored = True           # first record chained to the genesis value (nothing pruned/skipped)

    @property
    def ok(self):
        return not self.errors

    def error(self, kind, seq, segment, line, message):
        self.errors.append({"kind": kind, "seq": seq, "segment": os.path.basename(segment) if segment else None,
                            "line": line, "message": message})

    def summary(self):
        out = {"ok": self.ok, "records": self.records, "segments": self.segments,
               "first_seq": self.first_seq, "last_seq": self.last_seq, "checkpoints_verified": self.checkpoints,
               "checkpoints_unchecked": self.checkpoints_unchecked,
               "last_checkpoint_seq": self.last_checkpoint_seq,
               "records_after_last_checkpoint": (self.last_seq or 0) - self.last_checkpoint_record,
               "errors": self.errors}
        return out


def verify(directory, from_seq=None, pubkeys=None, max_errors=20):
    """Check the hash chain and the checkpoint signatures.

    from_seq starts at the segment holding that seq (its first record is
    trusted as the anchor unless the previous segment is present). pubkeys is
    {key_id: public_hex}; by default <dir>/public.keys. A checkpoint whose key
    is unknown is reported as an error: an attacker must not be able to pass
    verification with a key of their own.
    """
    res = VerifyResult()
    segments = list_segments(directory)
    if not segments:
        res.error("empty", None, None, None, "no audit segments in %s" % directory)
        return res
    keys = pubkeys if pubkeys is not None else load_public_keys(directory)
    start = 0
    if from_seq:
        for i, (first, _) in enumerate(segments):
            if first <= from_seq:
                start = i
    prev_hash, expect = None, None
    if start > 0:
        tail = read_last_line(segments[start - 1][1])
        if tail:
            prev_hash = sha256_hex(tail)
            try:
                expect = json.loads(tail)["seq"] + 1
            except (ValueError, KeyError, TypeError):
                pass
    elif segments[0][0] != 1:
        res.anchored = False           # older segments were pruned by retention
    hashes = collections.OrderedDict()  # recent seq -> record hash, for checkpoint targets
    for first, path in segments[start:]:
        res.segments += 1
        if expect is not None and first != expect:
            res.error("segment_gap", first, path, None,
                      "segment starts at seq %d but seq %d was expected: a segment is missing or was renamed" % (first, expect))
            expect = first
        seen_first = False
        try:
            lines = list(iter_lines(path))
        except OSError as exc:
            res.error("unreadable", first, path, None, str(exc))
            continue
        for n, line in lines:
            try:
                rec = json.loads(line)
                seq = rec["seq"]
                if not isinstance(seq, int) or not isinstance(rec.get("prev"), str) or not isinstance(rec.get("hash"), str):
                    raise ValueError("missing fields")
            except (ValueError, KeyError, TypeError):
                res.error("bad_record", None, path, n, "line is not a valid audit record")
                prev_hash = sha256_hex(line)
                if len(res.errors) >= max_errors:
                    return res
                continue
            if not seen_first:
                seen_first = True
                if seq != first:
                    res.error("segment_name", seq, path, n, "first record is seq %d but the file is named for %d" % (seq, first))
            if expect is None:
                expect = seq
                if seq == 1 and rec["prev"] != GENESIS:
                    res.error("chain_broken", seq, path, n, "first record does not start from the genesis value")
            elif seq != expect:
                kind = "seq_gap" if seq > expect else "out_of_order"
                res.error(kind, seq, path, n, "expected seq %d, found %d (%s)" % (
                    expect, seq, "records are missing" if seq > expect else "records were duplicated or reordered"))
            if prev_hash is not None and rec["prev"] != prev_hash:
                res.error("chain_broken", seq, path, n, "prev does not match the previous record: "
                          "the previous record was modified, removed or reordered")
            if record_hash(rec) != rec["hash"]:
                res.error("hash_mismatch", seq, path, n, "record content does not match its hash: the record was modified")
            if from_seq is None or seq >= from_seq:
                res.records += 1
                res.first_seq = seq if res.first_seq is None else res.first_seq
                res.last_seq = seq
            hashes[seq] = rec["hash"]
            while len(hashes) > 20000:
                hashes.popitem(last=False)
            if rec.get("type") == CHECKPOINT:
                _check_checkpoint(res, rec, hashes, keys, path, n)
            prev_hash, expect = sha256_hex(line), seq + 1
            if len(res.errors) >= max_errors:
                return res
    return res


def _check_checkpoint(res, rec, hashes, keys, path, n):
    data = rec.get("data") or {}
    try:
        upto, digest, kid, sig = int(data["upto_seq"]), data["upto_hash"], data["key_id"], data["sig"]
    except (KeyError, TypeError, ValueError):
        res.error("bad_checkpoint", rec["seq"], path, n, "checkpoint record is malformed")
        return
    pub = keys.get(kid)
    if pub is None:
        res.error("unknown_key", rec["seq"], path, n, "checkpoint is signed with unknown key %s; "
                  "supply its public key with --pubkey" % kid)
        return
    try:
        good = verify_signature(pub, upto, digest, sig)
    except AuditError as exc:
        res.error("no_crypto", rec["seq"], path, n, str(exc))
        return
    if not good:
        res.error("bad_signature", rec["seq"], path, n, "checkpoint signature is invalid")
        return
    if upto in hashes:
        if hashes[upto] != digest:
            res.error("checkpoint_mismatch", rec["seq"], path, n,
                      "checkpoint signed the hash of seq %d, but that record now has a different hash" % upto)
            return
    else:
        res.checkpoints_unchecked += 1
        return
    res.checkpoints += 1
    res.last_checkpoint_seq = max(res.last_checkpoint_seq, upto)
    res.last_checkpoint_record = max(res.last_checkpoint_record, rec["seq"])


# ── the writer service ──────────────────────────────────────────────────────
def _peer(sock):
    try:
        pid, uid, _gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return {"pid": pid, "uid": uid}
    except (OSError, AttributeError, struct.error):
        return None


def _clean_event(raw):
    """Validate one line from a producer; returns (type, actor, source, data, ets) or raises ValueError."""
    ev = json.loads(raw)
    if not isinstance(ev, dict):
        raise ValueError("event is not an object")
    etype = ev.get("type")
    if etype not in EVENT_TYPES:
        raise ValueError("unknown event type %r" % (str(etype)[:40],))
    actor, source, data = ev.get("actor"), ev.get("source"), ev.get("data", {})
    if actor is not None and (not isinstance(actor, str) or len(actor) > 128):
        raise ValueError("invalid actor")
    if source is not None and (not isinstance(source, str) or len(source) > 64):
        raise ValueError("invalid source")
    if not isinstance(data, dict):
        raise ValueError("data must be an object")
    ets = ev.get("ets")
    if ets is not None and (not isinstance(ets, int) or isinstance(ets, bool)):
        ets = None
    return etype, actor, source, data, ets


class Writer:
    """Receives events on a unix socket and appends them to the chain."""

    def __init__(self, auditlog, socket_path, group=None, queue_size=10000):
        self.log = auditlog
        self.socket_path = socket_path
        self.group = group
        self.q = queue.Queue(maxsize=queue_size)
        self.stop = threading.Event()
        self.server = None
        self.rejected = 0
        self.last_prune = 0.0
        self.thread = None

    # -- socket side
    def serve_socket(self):
        writer = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                peer = _peer(self.request)
                while not writer.stop.is_set():
                    raw = self.rfile.readline(MAX_EVENT_BYTES + 1)
                    if not raw:
                        return
                    if len(raw) > MAX_EVENT_BYTES:
                        writer.rejected += 1
                        return              # cannot resynchronise after an oversized line
                    try:
                        event = _clean_event(raw)
                    except ValueError as exc:
                        writer.rejected += 1
                        log.warning("rejected an event from %s: %s", peer, exc)
                        continue
                    writer.q.put((event, peer))

        class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
            daemon_threads = True

        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        self.server = Server(self.socket_path, Handler)
        os.chmod(self.socket_path, 0o660)
        if self.group:
            try:
                os.chown(self.socket_path, -1, self.group)
            except OSError as exc:
                log.warning("cannot set the socket group: %s", exc)
        threading.Thread(target=self.server.serve_forever, daemon=True, name="audit-socket").start()

    # -- appender
    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True, name="audit-appender")
        self.thread.start()

    def drain(self, limit=512):
        """Append what is queued; returns how many records were written."""
        n = 0
        while n < limit:
            try:
                (etype, actor, source, data, ets), peer = self.q.get_nowait()
            except queue.Empty:
                break
            self.log.append(etype, actor, source, data, peer, ets)
            n += 1
        return n

    def run(self):
        while not self.stop.is_set():
            try:
                item = self.q.get(timeout=1.0)
            except queue.Empty:
                item = None
            try:
                if item is not None:
                    (etype, actor, source, data, ets), peer = item
                    self.log.append(etype, actor, source, data, peer, ets)
                    self.drain()
                self.log.housekeeping()
                now = time.time()
                if now - self.last_prune > 3600:
                    self.last_prune = now
                    self.log.prune()
            except Exception:
                log.exception("audit append failed")
                time.sleep(1)

    def shutdown(self):
        self.stop.set()
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        if self.thread:
            self.thread.join(timeout=5)
        self.drain(10 ** 9)
        self.log.close()


# ── the client ──────────────────────────────────────────────────────────────
class NullClient:
    """Audit disabled."""
    enabled = False
    dropped = 0

    def emit(self, etype, actor=None, **data):
        return None

    def healthy(self):
        return True

    def require(self):
        return None

    def stats(self):
        return {"enabled": False}

    def close(self):
        return None


class AuditClient:
    """Sends events to the writer without ever blocking the caller.

    emit() appends to a bounded in-memory buffer and returns. A background
    thread connects (and reconnects) to the unix socket and sends. When the
    buffer is full the new event is dropped and counted; after reconnecting
    the client first records an `audit.dropped` event with the count, so the
    chain shows that events were lost. require() is the strict-mode gate.
    """
    enabled = True

    def __init__(self, path, source="", strict=False, buffer=1000, retry_sec=1.0, send_timeout=2.0,
                 clock=time.time):
        self.path = path
        self.source = source
        self.strict = strict
        self.capacity = int(buffer)
        self.retry_sec = retry_sec
        self.send_timeout = send_timeout
        self.clock = clock
        self.dropped = 0
        self.sent = 0
        self._unreported = 0
        self._buf = collections.deque()
        self._cond = threading.Condition()
        self._connected = False
        self._sock = None
        self._thread = None
        self._closed = False

    # -- producer side (the request path)
    def emit(self, etype, actor=None, **data):
        data = {k: v for k, v in data.items() if v is not None}
        event = {"type": etype, "actor": actor, "source": self.source, "data": data, "ets": int(self.clock() * 1000)}
        try:
            line = json.dumps(event, default=str, separators=(",", ":")).encode() + b"\n"
        except (TypeError, ValueError):
            self._drop()
            return False
        if len(line) > MAX_EVENT_BYTES:
            self._drop()
            return False
        with self._cond:
            if len(self._buf) >= self.capacity:
                self.dropped += 1
                self._unreported += 1
                return False
            self._buf.append(line)
            self._ensure_thread()
            self._cond.notify()
        return True

    def _drop(self):
        with self._cond:
            self.dropped += 1
            self._unreported += 1

    def healthy(self):
        """True when events are flowing: connected (or nothing to send yet) and nothing lost."""
        with self._cond:
            return self._connected and self._unreported == 0 and len(self._buf) < self.capacity * 0.9

    def require(self):
        """Strict mode: refuse to proceed while the audit trail cannot be recorded."""
        if not self.strict:
            return
        if self._thread is None:
            self._ensure_thread()
            self.probe()
        if not self.healthy():
            raise AuditUnavailable("the audit writer is unreachable; refusing work in strict audit mode")

    def probe(self, wait=0.2):
        """Give a not-yet-connected client a moment to connect (first call in strict mode)."""
        end = self.clock() + wait
        with self._cond:
            self._cond.notify()
            while not self._connected and self.clock() < end:
                self._cond.wait(0.02)

    def stats(self):
        with self._cond:
            return {"enabled": True, "connected": self._connected, "buffered": len(self._buf),
                    "dropped": self.dropped, "sent": self.sent, "strict": self.strict}

    # -- sender thread
    def _ensure_thread(self):
        if self._thread is None and not self._closed:
            self._thread = threading.Thread(target=self._run, daemon=True, name="audit-client")
            self._thread.start()

    def _connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.send_timeout)
        try:
            s.connect(self.path)
        except OSError:
            s.close()
            return None
        return s

    def _disconnect(self):
        self._connected = False
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def _run(self):
        pending = None
        while not self._closed:
            if self._sock is None:
                sock = self._connect()
                if sock is None:
                    with self._cond:
                        self._connected = False
                        self._cond.notify_all()
                        self._cond.wait(self.retry_sec)
                    continue
                with self._cond:
                    self._sock = sock
                    self._connected = True
                    if self._unreported:
                        note = json.dumps({"type": "audit.dropped", "actor": None, "source": self.source,
                                           "data": {"dropped": self._unreported}, "ets": int(self.clock() * 1000)},
                                          separators=(",", ":")).encode() + b"\n"
                        self._buf.appendleft(note)
                        self._unreported = 0
                    self._cond.notify_all()
            if pending is None:
                with self._cond:
                    if not self._buf:
                        self._cond.wait(1.0)
                    if self._buf:
                        pending = self._buf.popleft()
                if pending is None:
                    self._check_alive()
                    continue
            try:
                sock = self._sock
                if sock is None:
                    raise OSError("not connected")
                sock.sendall(pending)
                self.sent += 1
                pending = None
            except OSError:
                with self._cond:
                    self._disconnect()
                    self._cond.notify_all()
                time.sleep(min(self.retry_sec, 0.5))

    def _check_alive(self):
        """Notice a writer that went away while we were idle (peek sees EOF)."""
        sock = self._sock
        if sock is None:
            return
        try:
            sock.setblocking(False)
            if sock.recv(1, socket.MSG_PEEK) == b"":
                self._disconnect()
        except BlockingIOError:
            pass
        except OSError:
            self._disconnect()
        finally:
            try:
                sock.settimeout(self.send_timeout)
            except OSError:
                pass

    def close(self):
        self._closed = True
        with self._cond:
            self._cond.notify_all()
        sock = self._sock
        if sock is not None:
            try:
                sock.close()            # the sender thread sees the error and exits
            except OSError:
                pass


def client_from_config(cfg, source):
    """An AuditClient for [audit] in the services config, or NullClient when disabled."""
    a = (cfg or {}).get("audit") or {}
    if not a.get("enabled"):
        return NullClient()
    return AuditClient(a.get("socket", "/run/agentos-audit/audit.sock"), source=source,
                       strict=bool(a.get("strict")), buffer=int(a.get("buffer", 1000)))


# ── CLI ─────────────────────────────────────────────────────────────────────
def format_record(rec):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(rec.get("ts", 0) / 1000.0)) + ".%03dZ" % (rec.get("ts", 0) % 1000)
    data = rec.get("data") or {}
    detail = " ".join("%s=%s" % (k, json.dumps(v) if not isinstance(v, str) else v) for k, v in sorted(data.items())
                      if k not in ("sig", "public_key"))
    return "%8d %s %-18s %-14s %s" % (rec.get("seq", 0), ts, rec.get("type", "?"), rec.get("actor") or "-", detail)


def _tail(args):
    if not list_segments(args.dir):
        print("no audit segments in %s" % args.dir, file=sys.stderr)
        return 1
    last = max(0, _last_seq(args.dir) - max(0, args.n))
    while True:
        for rec in iter_records(args.dir, last):
            print(json.dumps(rec, sort_keys=True) if args.json else format_record(rec))
            last = rec["seq"]
        sys.stdout.flush()
        if not args.follow:
            return 0
        time.sleep(0.5)


def _last_seq(directory):
    segments = list_segments(directory)
    for _, path in reversed(segments):
        line = read_last_line(path)
        if line:
            try:
                return json.loads(line)["seq"]
            except (ValueError, KeyError):
                return 0
    return 0


def _verify(args):
    extra = [args.pubkey] if args.pubkey else []
    keys = load_public_keys(args.dir, extra) if not args.pubkey_only else load_public_keys("/nonexistent", extra)
    res = verify(args.dir, args.from_seq, keys, max_errors=100 if args.all else 1)
    if args.json:
        print(json.dumps(res.summary(), indent=2))
    elif res.ok:
        print("OK: %d records in %d segment(s), seq %s..%s; %d checkpoint signature(s) verified" % (
            res.records, res.segments, res.first_seq, res.last_seq, res.checkpoints))
        after = (res.last_seq or 0) - res.last_checkpoint_record
        if res.checkpoints == 0:
            print("warning: no signed checkpoint was verified in the checked range")
        elif after:
            print("note: the last %d record(s) are not yet covered by a signed checkpoint" % after)
        if not res.anchored:
            print("note: segments before seq %s were removed by retention; the chain is verified from there" % res.first_seq)
    else:
        for err in res.errors:
            where = "%s:%s" % (err["segment"], err["line"]) if err["segment"] else "-"
            print("FAIL %s at seq %s (%s): %s" % (err["kind"], err["seq"], where, err["message"]), file=sys.stderr)
    return 0 if res.ok else 1


def _keygen(args):
    created = generate_key(args.out, args.public)
    print("created %s" % args.out if created else "%s already exists; left unchanged" % args.out)
    return 0


def _serve(args):
    cfg = configmod.load(args.config)
    a = cfg["audit"]
    directory = args.dir or a["dir"]
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    key_path = a.get("signing_key") or (os.path.join(creds, "audit-signing-key") if creds else "")
    signer = None
    if key_path and os.path.exists(key_path):
        signer = Signer.load(key_path)
    else:
        log.error("no signing key (%s): checkpoints will NOT be written", key_path or "unset")
    alog = AuditLog(directory, signer, a["segment_bytes"], a["checkpoint_every"], a["checkpoint_interval_sec"],
                    a["retention_days"])
    if signer:
        _register_public_key(directory, signer)
    alog.append("audit.start", source="audit", data={"key_id": signer.key_id if signer else None,
                                                     "retention_days": a["retention_days"],
                                                     "last_seq": alog.seq})
    group = None
    try:
        import grp
        group = grp.getgrnam("agentos-audit").gr_gid
    except (ImportError, KeyError):
        pass
    writer = Writer(alog, a["socket"], group)
    writer.serve_socket()
    writer.start()
    stop = threading.Event()
    exporters = []
    try:
        from . import audit_export
        exporters = audit_export.start_exporters(cfg, directory, stop)
    except ImportError:             # pragma: no cover
        pass
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    log.info("audit writer on %s, log in %s (retention %s days)", a["socket"], directory, a["retention_days"])
    try:
        stop.wait()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        writer.shutdown()
    return 0


def _register_public_key(directory, signer):
    path = os.path.join(directory, "public.keys")
    existing = load_public_keys(directory)
    if signer.key_id not in existing:
        with open(path, "a") as f:
            f.write("%s\n" % signer.public_hex)
        os.chmod(path, 0o640)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agentos-audit", description="AgentOS tamper-evident audit log")
    parser.add_argument("--dir", default=None, help="audit directory (default: from services.toml)")
    parser.add_argument("--config", default=None, help="services.toml path")
    parser.add_argument("--verbose", action="store_true")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("serve", help="run the audit writer")
    v = sub.add_parser("verify", help="check the hash chain and checkpoint signatures")
    v.add_argument("--from", dest="from_seq", type=int, default=None, help="start at this seq")
    v.add_argument("--pubkey", default=None, help="file with a trusted public key (hex) in addition to public.keys")
    v.add_argument("--pubkey-only", action="store_true", help="trust only --pubkey, not <dir>/public.keys")
    v.add_argument("--all", action="store_true", help="report every error, not just the first")
    v.add_argument("--json", action="store_true")
    t = sub.add_parser("tail", help="show the latest records")
    t.add_argument("-n", type=int, default=20)
    t.add_argument("-f", "--follow", action="store_true")
    t.add_argument("--json", action="store_true")
    k = sub.add_parser("keygen", help="create the Ed25519 signing key if it does not exist")
    k.add_argument("--out", required=True)
    k.add_argument("--public", default=None, help="also write the public key (hex) here")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    if args.cmd != "keygen" and args.dir is None:
        args.dir = configmod.load(args.config)["audit"]["dir"]
    return {"serve": _serve, "verify": _verify, "tail": _tail, "keygen": _keygen}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
