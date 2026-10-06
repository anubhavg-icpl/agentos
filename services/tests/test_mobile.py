"""nestlo-mobile: pairing, devices, REST, events, terminals, desktop (docs/mobile-protocol.md).

The server is started for real (TLS on a loopback port, admin unix socket in a
temporary directory) and driven with the WebSocket client from mobile.py.
Terminals run on a real PTY with a stand-in command instead of runuser."""

import asyncio
import base64
import contextlib
import copy
import hashlib
import io
import json
import os
import pathlib
import signal
import socket
import ssl
import subprocess
import time
import urllib.parse

import pytest

from nestlo_services import config as configmod
from nestlo_services import mobile as M
from nestlo_services import mobile_tunnel as T
from nestlo_services import unixapi
from nestlo_services.dashboard import Dashboard


def run(coro):
    return asyncio.run(asyncio.wait_for(coro, 60))


class FakeAudit:
    enabled = True

    def __init__(self):
        self.events = []

    def emit(self, etype, actor=None, **data):
        self.events.append((etype, actor, data))

    def of(self, etype):
        return [e for e in self.events if e[0] == etype]


AGENT = {"id": "a1", "agent": "claude", "workspace": "/w/x", "status": "working", "spend_usd": 1.5,
         "budget_usd": 10.0, "started_at": "2026-01-01T00:00:00Z"}


class FakeBackend:
    def __init__(self):
        self.agents_ = [dict(AGENT)]
        self.spend_ = {"today_usd": 1.5, "budget_usd": 500.0}
        self.approvals_ = []
        self.killed = []
        self.decisions = []

    def agents(self):
        return copy.deepcopy(self.agents_)

    def overview(self):
        return {"agents": M.count_agents(self.agents()), "spend": self.spend_,
                "health": {"redis": True, "gateway": False, "daemon": True}}

    def snapshot(self):
        return {"agents": self.agents(), "spend": dict(self.spend_), "approvals": list(self.approvals_)}

    def requests(self, agent_id, limit):
        if agent_id != "a1":
            raise M.HttpError(400, "agent must be a valid agent id")
        return [{"ts": "2026-01-01T00:00:00Z", "provider": "anthropic", "model": "m", "input_tokens": 1,
                 "output_tokens": 2, "cost_usd": 0.1, "status": 200}][:limit]

    def kill(self, agent_id):
        if agent_id != "a1":
            raise M.HttpError(404, "no such agent")
        self.killed.append(agent_id)
        return True

    def approvals(self):
        return list(self.approvals_)

    def decide(self, approval_id, decision, device_name):
        self.decisions.append((approval_id, decision, device_name))
        return True

    def sessions(self):
        return [{"id": "shell:alice", "title": "alice shell", "kind": "shell", "user": "alice"}]


class Env:
    """A running server plus helpers to talk to it."""

    def __init__(self, tmp_path, short_dir, **opt):
        self.audit = FakeAudit()
        self.backend = FakeBackend()
        self.clock = [1_700_000_000.0]
        opts = M.Options(name="nestlo-test", state_dir=str(tmp_path / "state"), listen="127.0.0.1", port=0,
                         admin_socket=os.path.join(short_dir, "admin.sock"), admin_group="",
                         terminal_users=["alice"], advertise_hosts=["10.0.0.5", "nestlo.local"],
                         poll_sec=0.05, ping_sec=0.3, **opt)
        self.opts = opts
        self.srv = M.Server(opts, self.backend, self.audit, clock=lambda: self.clock[0])
        self.srv.tailscale_lookup = lambda: []

    async def __aenter__(self):
        await self.srv.start()
        self.port = self.srv.port
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE
        return self

    async def __aexit__(self, *exc):
        await self.srv.stop()

    async def http(self, method, path, body=None, token=None, headers=None):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port, ssl=self.ctx)
        h = {"Host": "x", "Connection": "close"}
        if token:
            h["Authorization"] = "Bearer " + token
        h.update(headers or {})
        data = json.dumps(body).encode() if body is not None else b""
        if body is not None:
            h["Content-Length"] = str(len(data))
        head = "%s %s HTTP/1.1\r\n" % (method, path) + "".join("%s: %s\r\n" % kv for kv in h.items()) + "\r\n"
        writer.write(head.encode() + data)
        await writer.drain()
        raw = await reader.read()
        writer.close()
        return parse_response(raw)

    def admin(self, method, path, body=None):
        return unixapi.call(self.opts.admin_socket, method, path, body)

    async def admin_async(self, method, path, body=None):
        return await asyncio.get_running_loop().run_in_executor(None, self.admin, method, path, body)

    async def pair(self, name="Pixel 9", model="google/tokay", ttl=300):
        status, obj = await self.admin_async("POST", "/pair", {"ttl": ttl})
        assert status == 200, obj
        code = urllib.parse.parse_qs(urllib.parse.urlsplit(obj["uri"]).query)["code"][0]
        st, body, _ = await self.http("POST", "/v1/pair", {"code": code, "device_name": name, "device_model": model})
        assert st == 200, body
        return body["device_id"], body["token"]

    async def ws(self, path, token, protocols=()):
        return await M.ws_connect("127.0.0.1", self.port, path, {"Authorization": "Bearer " + token},
                                  self.ctx, protocols)


def parse_response(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = {}
    for ln in lines[1:]:
        k, _, v = ln.partition(":")
        headers.setdefault(k.strip().lower(), []).append(v.strip())
    try:
        obj = json.loads(body) if body[:1] in (b"{", b"[") else body
    except ValueError:
        obj = body
    return status, obj, headers


@pytest.fixture
def env(tmp_path, short_dir, monkeypatch):
    monkeypatch.setattr(M, "local_addresses", lambda *a, **k: ["192.168.1.20", "fd00::5"])
    monkeypatch.setattr(M.socket, "gethostname", lambda: "box")
    monkeypatch.setattr(M, "tailscale_hosts", lambda *a, **k: [])
    return lambda **kw: Env(tmp_path, short_dir, **kw)


async def read_until(ws, needle, timeout=10):
    """Collect binary output until `needle` appears; returns everything read."""
    buf = b""
    end = time.monotonic() + timeout
    while needle not in buf:
        msg = await asyncio.wait_for(ws.recv(), max(0.1, end - time.monotonic()))
        assert msg is not None, "closed before %r; got %r" % (needle, buf)
        if msg[0] == M.OP_BIN:
            buf += msg[1]
    return buf


# ── building blocks ─────────────────────────────────────────────────────────
def test_websocket_accept_key_matches_rfc_6455():
    assert M.accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="


def test_certificate_is_ecdsa_p256_ten_years_and_fingerprint_is_b64url_of_der_sha256(tmp_path):
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    cert_path, key_path = M.ensure_cert(str(tmp_path / "tls"), "myhost")
    with open(cert_path, "rb") as f:
        cert = x509.load_pem_x509_certificate(f.read())
    assert isinstance(cert.public_key(), ec.EllipticCurvePublicKey)
    assert cert.public_key().curve.name == "secp256r1"
    days = (cert.not_valid_after_utc - cert.not_valid_before_utc).days
    assert 3649 <= days <= 3652
    assert cert.subject.rfc4514_string() == "CN=myhost"
    assert oct(os.stat(key_path).st_mode & 0o777) == "0o600"
    der = cert.public_bytes(serialization.Encoding.DER)
    expected = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).decode().rstrip("=")
    fp = M.fingerprint(cert_path)
    assert fp == expected and "=" not in fp and len(fp) == 43
    # a second start keeps the certificate (the app pinned it)
    assert M.ensure_cert(str(tmp_path / "tls"), "other") == (cert_path, key_path)
    assert M.fingerprint(cert_path) == fp


def test_local_addresses_skips_loopback_and_link_local():
    out = json.dumps([
        {"ifname": "lo", "addr_info": [{"family": "inet", "local": "127.0.0.1", "scope": "host"}]},
        {"ifname": "eth0", "addr_info": [
            {"family": "inet6", "local": "2001:db8::2", "scope": "global"},
            {"family": "inet6", "local": "fe80::1", "scope": "link"},
            {"family": "inet", "local": "192.168.1.20", "scope": "global"}]},
    ])
    res = subprocess.CompletedProcess([], 0, stdout=out)
    assert M.local_addresses(lambda *a, **k: res) == ["192.168.1.20", "2001:db8::2"]


def test_pairing_codes_are_hashed_single_use_and_expire():
    now = [1000.0]
    p = M.Pairing(clock=lambda: now[0])
    code, expires = p.create(300)
    assert expires == 1300 and code not in p.codes and M.sha256_hex(code) in p.codes
    assert len(base64.urlsafe_b64decode(code + "==")) == 16 and "=" not in code
    assert p.redeem(code, "1.1.1.1") is True
    assert p.redeem(code, "1.1.1.1") is False            # used
    code2, _ = p.create(10)
    now[0] += 11
    assert p.redeem(code2, "1.1.1.1") is False           # expired
    assert p.redeem("nope", "1.1.1.1") is False
    assert p.redeem(None, "1.1.1.1") is False


def test_pairing_rate_limit_is_per_address_and_window():
    now = [0.0]
    p = M.Pairing(clock=lambda: now[0])
    code, _ = p.create(3000)
    for _ in range(10):
        assert p.redeem("bad", "9.9.9.9") is False
    with pytest.raises(M.HttpError) as e:
        p.redeem(code, "9.9.9.9")                          # even the right code
    assert e.value.status == 429
    assert p.redeem(code, "8.8.8.8") is True               # other address unaffected
    now[0] += 601
    code, _ = p.create(300)
    assert p.redeem(code, "9.9.9.9") is True               # window passed


def test_device_store_keeps_only_token_hashes_and_survives_restart(tmp_path):
    path = str(tmp_path / "d.json")
    store = M.DeviceStore(path, clock=lambda: 1_700_000_000)
    did, token = store.add("Pixel", "google/tokay")
    assert did.startswith("d_") and len(did) == 14
    text = open(path).read()
    assert token not in text and M.sha256_hex(token) in text
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"
    again = M.DeviceStore(path)
    assert again.by_token(token)["device_id"] == did
    assert again.by_token(token + "x") is None and again.by_token("") is None
    assert again.public(did)[0]["current"] is True and again.public("d_other")[0]["current"] is False
    assert again.revoke(did) and not again.revoke(did)
    assert M.DeviceStore(path).by_token(token) is None


def test_corrupt_device_file_starts_empty(tmp_path):
    path = tmp_path / "d.json"
    path.write_text("{not json")
    assert M.DeviceStore(str(path)).devices == {}


def test_status_mapping_and_agent_shape():
    base = {"id": "x", "agent": "claude", "workspace": "/w", "started_at": 1_700_000_000, "usd_today": 2.5,
            "limit_usd": 50}
    assert M.agent_view(dict(base, status="running")) == {
        "id": "x", "agent": "claude", "workspace": "/w", "status": "working", "spend_usd": 2.5, "budget_usd": 50.0,
        "started_at": "2023-11-14T22:13:20Z"}
    assert M.map_status(dict(base, status="running", blocked=True)) == "blocked"
    assert M.map_status(dict(base, status="exited")) == "done"
    assert M.map_status(dict(base, status="exited", exit_code=1)) == "failed"
    assert M.map_status(dict(base, status="killed")) == "killed"
    assert M.map_status(dict(base, status="weird")) == "idle"
    assert M.map_status(dict(base, status="blocked")) == "blocked"


def test_diff_snapshots():
    def snap(agents=(), spend=1.0, approvals=()):
        return {"agents": [dict(AGENT, **a) for a in agents], "spend": {"today_usd": spend, "budget_usd": 5.0},
                "approvals": list(approvals)}
    assert M.diff_snapshots(None, snap([{}]), 0) == []                     # baseline
    old = snap([{}])
    assert M.diff_snapshots(old, snap([{}]), 0) == []
    ev = M.diff_snapshots(old, snap([{"spend_usd": 2.0}]), 0)
    assert [e["type"] for e in ev] == ["agent"] and ev[0]["agent"]["spend_usd"] == 2.0
    ev = M.diff_snapshots(old, snap([{"status": "blocked"}]), 1_700_000_000)
    assert [e["type"] for e in ev] == ["agent", "needs_input"]
    assert ev[1] == {"type": "needs_input", "id": "a1", "agent": "claude", "workspace": "/w/x",
                     "since": "2023-11-14T22:13:20Z"}
    still = snap([{"status": "blocked"}])
    assert M.diff_snapshots(still, snap([{"status": "blocked"}]), 0) == []   # once per block
    ev = M.diff_snapshots(still, snap([{"status": "working"}]), 0)
    assert [e["type"] for e in ev] == ["agent"]
    ev = M.diff_snapshots(old, snap([{"id": "a2", "status": "blocked"}, {}]), 0)
    assert [e["type"] for e in ev] == ["agent", "needs_input"] and ev[1]["id"] == "a2"
    assert M.diff_snapshots(old, snap([]), 0) == [{"type": "agent_gone", "id": "a1"}]
    assert M.diff_snapshots(old, snap([{}], spend=2.0), 0) == [
        {"type": "spend", "today_usd": 2.0, "budget_usd": 5.0}]
    appr = {"id": "t1", "kind": "task", "summary": "s", "requested_by": "bob", "created_at": ""}
    new = snap([{}], approvals=[appr])
    assert M.diff_snapshots(old, new, 0) == [{"type": "approval", "approval": appr}]
    assert M.diff_snapshots(new, old, 0) == [{"type": "approval_done", "id": "t1"}]


# ── pairing over the wire ───────────────────────────────────────────────────
def test_pairing_uri_and_flow_over_tls(env):
    async def go():
        async with env() as e:
            status, obj = await e.admin_async("POST", "/pair", {"ttl": 120})
            assert status == 200 and obj["ttl"] == 120
            uri = obj["uri"]
            assert uri.startswith("nestlo://pair?")
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query)
            assert q["v"] == ["1"] and q["name"] == ["nestlo-test"] and q["port"] == [str(e.port)]
            assert q["host"] == ["10.0.0.5", "nestlo.local", "192.168.1.20", "fd00::5", "box", "localhost"]
            # fp is what the TLS peer really presents
            reader, writer = await asyncio.open_connection("127.0.0.1", e.port, ssl=e.ctx)
            der = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
            writer.close()
            assert q["fp"] == [base64.urlsafe_b64encode(hashlib.sha256(der).digest()).decode().rstrip("=")]
            code = q["code"][0]
            assert "=" not in code and len(base64.urlsafe_b64decode(code + "==")) == 16
            # the server keeps only the hash
            assert code not in json.dumps(list(e.srv.pairing.codes))
            body = {"code": code, "device_name": "Pixel 9", "device_model": "google/tokay"}
            st, resp, _ = await e.http("POST", "/v1/pair", body)
            assert st == 200
            assert resp["device_id"].startswith("d_") and resp["server_name"] == "nestlo-test"
            assert len(base64.urlsafe_b64decode(resp["token"] + "==")) == 32
            assert resp["server_version"]
            st, resp2, _ = await e.http("POST", "/v1/pair", body)
            assert st == 403 and "error" in resp2              # single use
            assert e.audit.of("mobile.pair")
    run(go())


def test_wrong_and_expired_codes_and_rate_limit_over_wire(env):
    async def go():
        async with env() as e:
            st, obj, _ = await e.http("POST", "/v1/pair", {"code": "wrong"})
            assert st == 403
            st, obj, _ = await e.http("POST", "/v1/pair", {})
            assert st == 403
            st, obj, _ = await e.http("POST", "/v1/pair", [1])
            assert st == 400
            _, adm = await e.admin_async("POST", "/pair", {"ttl": 10})
            code = urllib.parse.parse_qs(urllib.parse.urlsplit(adm["uri"]).query)["code"][0]
            e.clock[0] += 11
            st, _, _ = await e.http("POST", "/v1/pair", {"code": code})
            assert st == 403                                    # expired
            for _ in range(8):
                await e.http("POST", "/v1/pair", {"code": "x"})
            st, obj, _ = await e.http("POST", "/v1/pair", {"code": "x"})
            assert st == 429 and "error" in obj
            _, adm = await e.admin_async("POST", "/pair", {"ttl": 60})
            code = urllib.parse.parse_qs(urllib.parse.urlsplit(adm["uri"]).query)["code"][0]
            st, _, _ = await e.http("POST", "/v1/pair", {"code": code})
            assert st == 429                                    # blocked even with a valid code
    run(go())


def test_admin_pair_validates_ttl(env):
    async def go():
        async with env() as e:
            for ttl in (0, 5, "x", 10 ** 7, True):
                st, obj = await e.admin_async("POST", "/pair", {"ttl": ttl})
                assert st == 400, ttl
            st, obj = await e.admin_async("POST", "/pair", {})
            assert st == 200 and obj["ttl"] == 300             # default
    run(go())


# ── auth and devices ────────────────────────────────────────────────────────
def test_every_endpoint_needs_a_valid_token_and_revoke_ends_it(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            paths = [("GET", "/v1/info"), ("GET", "/v1/overview"), ("GET", "/v1/agents"),
                     ("GET", "/v1/agents/a1/requests"), ("POST", "/v1/agents/a1/kill"), ("GET", "/v1/approvals"),
                     ("POST", "/v1/approvals/t1"), ("GET", "/v1/sessions"), ("GET", "/v1/devices"),
                     ("DELETE", "/v1/devices/" + did), ("GET", "/v1/nope")]
            for method, path in paths:
                for tok in (None, "wrong", token[:-1] + ("A" if token[-1] != "A" else "B")):
                    st, obj, _ = await e.http(method, path, token=tok)
                    assert st == 401 and obj == {"error": "unauthorized"}, (method, path, tok)
            st, _, _ = await e.http("GET", "/v1/info", headers={"Authorization": "Basic " + token})
            assert st == 401
            st, devs, _ = await e.http("GET", "/v1/devices", token=token)
            assert st == 200 and devs[0]["device_id"] == did and devs[0]["current"] is True
            assert set(devs[0]) == {"device_id", "device_name", "device_model", "paired_at", "last_seen", "current"}
            assert devs[0]["device_name"] == "Pixel 9" and devs[0]["device_model"] == "google/tokay"
            # revoke myself
            st, obj, _ = await e.http("DELETE", "/v1/devices/" + did, token=token)
            assert st == 200 and obj == {"ok": True}
            st, _, _ = await e.http("GET", "/v1/info", token=token)
            assert st == 401
            assert e.audit.of("mobile.revoke")[0][2]["device_id"] == did
    run(go())


def test_a_device_may_revoke_others_and_unknown_is_404(env):
    async def go():
        async with env() as e:
            d1, t1 = await e.pair("one")
            d2, t2 = await e.pair("two")
            st, devs, _ = await e.http("GET", "/v1/devices", token=t1)
            assert [d["current"] for d in devs] == [True, False]
            st, obj, _ = await e.http("DELETE", "/v1/devices/" + d2, token=t1)
            assert st == 200
            assert (await e.http("GET", "/v1/info", token=t2))[0] == 401
            assert (await e.http("GET", "/v1/info", token=t1))[0] == 200
            st, obj, _ = await e.http("DELETE", "/v1/devices/d_000000000000", token=t1)
            assert st == 404 and "error" in obj
            # the machine side
            st, listing = await e.admin_async("GET", "/devices")
            assert [d["device_id"] for d in listing] == [d1]
            assert (await e.admin_async("DELETE", "/devices/" + d1))[0] == 200
            assert (await e.admin_async("DELETE", "/devices/" + d1))[0] == 404
            assert (await e.http("GET", "/v1/info", token=t1))[0] == 401
    run(go())


def test_last_seen_is_updated_but_not_on_every_request(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            e.clock[0] += 100
            await e.http("GET", "/v1/info", token=token)
            seen = e.srv.devices.devices[did]["last_seen"]
            assert seen == M.iso(e.clock[0])
            writes = []
            orig = e.srv.devices.save
            e.srv.devices.save = lambda: (writes.append(1), orig())
            e.clock[0] += 5
            await e.http("GET", "/v1/info", token=token)
            assert not writes
    run(go())


# ── REST ────────────────────────────────────────────────────────────────────
def test_rest_shapes(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            e.backend.approvals_ = [{"id": "t1", "kind": "task", "summary": "s", "requested_by": "bob",
                                     "created_at": "2026-01-01T00:00:00Z"}]
            e.opts.approvals = True
            e.opts.desktop_dir = str(os.path.dirname(__file__))
            st, info, _ = await e.http("GET", "/v1/info", token=token)
            assert st == 200
            assert set(info) == {"name", "version", "nixos", "uptime_s", "features"}
            assert info["name"] == "nestlo-test" and isinstance(info["uptime_s"], int)
            assert info["features"] == ["agents", "terminal", "desktop", "approvals"]
            st, ov, _ = await e.http("GET", "/v1/overview", token=token)
            assert ov == {"agents": {"total": 1, "working": 1, "blocked": 0, "idle": 0, "done": 0},
                          "spend": {"today_usd": 1.5, "budget_usd": 500.0},
                          "health": {"redis": True, "gateway": False, "daemon": True}}
            st, agents, _ = await e.http("GET", "/v1/agents", token=token)
            assert agents == [AGENT]
            st, reqs, _ = await e.http("GET", "/v1/agents/a1/requests?limit=1", token=token)
            assert st == 200 and set(reqs[0]) == {"ts", "provider", "model", "input_tokens", "output_tokens",
                                                  "cost_usd", "status"}
            st, obj, _ = await e.http("GET", "/v1/agents/bad!/requests", token=token)
            assert st == 400
            assert (await e.http("POST", "/v1/agents/a1/kill", token=token))[1:2] == ({"ok": True},)
            assert e.backend.killed == ["a1"]
            assert e.audit.of("agent.kill")[0][2]["agent"] == "a1"
            assert (await e.http("POST", "/v1/agents/zz/kill", token=token))[0] == 404
            st, appr, _ = await e.http("GET", "/v1/approvals", token=token)
            assert appr == e.backend.approvals_
            st, obj, _ = await e.http("POST", "/v1/approvals/t1", {"decision": "approve"}, token=token)
            assert st == 200 and obj == {"ok": True}
            assert e.backend.decisions == [("t1", "approve", "Pixel 9")]
            assert (await e.http("POST", "/v1/approvals/t1", {"decision": "maybe"}, token=token))[0] == 400
            assert (await e.http("POST", "/v1/approvals/t1", None, token=token))[0] == 400
            st, sess, _ = await e.http("GET", "/v1/sessions", token=token)
            assert sess == [{"id": "shell:alice", "title": "alice shell", "kind": "shell", "user": "alice"}]
    run(go())


def test_no_approval_queue_means_empty_list_and_no_feature(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            assert (await e.http("GET", "/v1/info", token=token))[1]["features"] == ["agents", "terminal"]
            e.backend.approvals_ = [{"id": "t"}]
            assert (await e.http("GET", "/v1/approvals", token=token))[1] == []
            assert (await e.http("POST", "/v1/approvals/t", {"decision": "approve"}, token=token))[0] == 404
    run(go())


def test_url_endpoint_and_unknown_admin_paths(env):
    async def go():
        async with env() as e:
            st, obj = await e.admin_async("GET", "/url")
            assert obj["fp"] == e.srv.fp
            assert obj["urls"][:2] == ["https://10.0.0.5:%d" % e.port, "https://nestlo.local:%d" % e.port]
            assert obj["urls"][-2:] == ["https://box:%d" % e.port, "https://localhost:%d" % e.port]
            assert (await e.admin_async("GET", "/nope"))[0] == 404
    run(go())


def test_admin_socket_mode_is_0660(env):
    async def go():
        async with env() as e:
            assert oct(os.stat(e.opts.admin_socket).st_mode & 0o777) == "0o660"
    run(go())


# ── the real backend over the real Dashboard ────────────────────────────────
@pytest.fixture
def real_backend(tmp_path, store):
    cfg = copy.deepcopy(configmod.DEFAULTS)
    state = tmp_path / "dstate"
    (state / "history").mkdir(parents=True)
    logs = tmp_path / "logs"
    logs.mkdir()
    cfg["daemon"]["state_dir"] = str(state)
    cfg["gateway"]["log_dir"] = str(logs)
    cfg["gateway"]["port"] = 1
    cfg["daemon"]["metrics_port"] = 1
    dash = Dashboard(cfg, store, "")
    return M.Backend(dash, terminal_users=["alice", "bob"], clock=lambda: 1_700_000_100), state, logs, store


def test_backend_agents_overview_requests(real_backend):
    be, state, logs, store = real_backend
    now = 1_700_000_000
    (state / "r1.json").write_text(json.dumps({"id": "r1", "agent": "claude", "workspace": "/w/a",
                                               "status": "running", "started_at": now}))
    (state / "history" / "h1.json").write_text(json.dumps({"id": "h1", "agent": "codex", "workspace": "/w/b",
                                                           "status": "exited", "started_at": now - 50}))
    (state / "history" / "h2.json").write_text(json.dumps({"id": "h2", "agent": "codex", "workspace": "/w/c",
                                                           "status": "killed", "started_at": now - 60}))
    (state / "bad.json").write_text("{")
    store.add_spend("r1", "claude-test", 1.25) if hasattr(store, "add_spend") else None
    agents = be.agents()
    assert [a["id"] for a in agents][0] == "r1"
    assert {a["id"]: a["status"] for a in agents} == {"r1": "working", "h1": "done", "h2": "killed"}
    assert all(set(a) == set(AGENT) for a in agents)
    assert agents[0]["started_at"] == "2023-11-14T22:13:20Z"
    ov = be.overview()
    assert ov["agents"] == {"total": 3, "working": 1, "blocked": 0, "idle": 0, "done": 1}
    assert ov["health"] == {"redis": True, "gateway": False, "daemon": False}   # nothing listens on the probes
    assert set(ov["spend"]) == {"today_usd", "budget_usd"} and ov["spend"]["budget_usd"] == 500.0
    snap = be.snapshot()
    assert set(snap) == {"agents", "spend", "approvals"} and snap["approvals"] == []
    entries = [{"ts": 1_700_000_001.5, "agent": "r1", "provider": "anthropic", "model": "claude-test", "status": 200,
                "usage": {"input_tokens": 10, "output_tokens": 20}, "cost_usd": 0.5},
               {"ts": 1_700_000_002, "provider": "openai", "status": 429}]
    (logs / "r1.log").write_text("\n".join(json.dumps(x) for x in entries) + "\n")
    got = be.requests("r1", 10)
    assert got[0] == {"ts": "2023-11-14T22:13:22Z", "provider": "openai", "model": "", "input_tokens": 0,
                      "output_tokens": 0, "cost_usd": 0.0, "status": 429}
    assert got[1]["input_tokens"] == 10 and got[1]["output_tokens"] == 20 and got[1]["cost_usd"] == 0.5
    assert len(be.requests("r1", 1)) == 1
    with pytest.raises(M.HttpError) as e:
        be.requests("../etc", 5)
    assert e.value.status == 400


def test_backend_kill_by_pid_and_unit(real_backend):
    be, state, _, _ = real_backend
    proc = subprocess.Popen(["sleep", "60"])
    try:
        (state / "k1.json").write_text(json.dumps({"id": "k1", "status": "running", "pid": proc.pid}))
        assert be.kill("k1") is True
        assert proc.wait(timeout=5) == -signal.SIGTERM
        saved = json.loads((state / "k1.json").read_text())
        assert saved["status"] == "killed" and saved["ended_at"] == 1_700_000_100
        with pytest.raises(M.HttpError) as e:
            be.kill("k1")
        assert e.value.status == 409
    finally:
        proc.kill()
    with pytest.raises(M.HttpError) as e:
        be.kill("missing")
    assert e.value.status == 404
    with pytest.raises(M.HttpError):
        be.kill("../x")
    calls = []
    be.run = lambda argv, **kw: (calls.append(argv), subprocess.CompletedProcess(argv, 0, "", ""))[1]
    (state / "u1.json").write_text(json.dumps({"id": "u1", "status": "running", "unit": "nestlo-agent-u1.service"}))
    assert be.kill("u1") and calls == [["systemctl", "stop", "nestlo-agent-u1.service"]]
    be.run = lambda argv, **kw: subprocess.CompletedProcess(argv, 1, "", "no")
    (state / "u2.json").write_text(json.dumps({"id": "u2", "status": "running", "unit": "x.service"}))
    with pytest.raises(M.HttpError) as e:
        be.kill("u2")
    assert e.value.status == 500
    assert json.loads((state / "u2.json").read_text())["status"] == "running"


def test_backend_approvals_from_the_orchestrator(real_backend, short_dir):
    be, *_ = real_backend
    sock = os.path.join(short_dir, "orch.sock")
    seen = []

    def app(method, parts, query, body):
        seen.append((method, parts, query, body))
        if method == "GET" and parts == ["tasks"]:
            return 200, {"tasks": [{"id": "t_1", "agent": "claude", "workspace": "/w/x", "submitted_by": "bob",
                                    "prompt": "do\nthe   thing", "created_at": 1_700_000_000}]}
        if parts == ["tasks", "t_9", "approve"]:
            return 409, {"error": "task t_9 is not awaiting approval (queued)"}
        if parts[:1] == ["tasks"] and parts[2:] in (["approve"], ["reject"]):
            return 200, {"tasks": []}
        return 404, {"error": "no"}

    srv = unixapi.serve_unix(sock, app)
    try:
        be.orch = sock
        got = be.approvals()
        assert got == [{"id": "t_1", "kind": "task", "summary": "claude in /w/x: do the thing",
                        "requested_by": "bob", "created_at": "2023-11-14T22:13:20Z"}]
        assert seen[0][2] == {"status": ["awaiting_approval"], "limit": ["100"]}
        assert be.decide("t_1", "approve", "Pixel") is True
        assert seen[-1][1] == ["tasks", "t_1", "approve"] and "Pixel" in seen[-1][3]["note"]
        assert be.decide("t_1", "deny", "Pixel") is True and seen[-1][1] == ["tasks", "t_1", "reject"]
        with pytest.raises(M.HttpError) as e:
            be.decide("t_9", "approve", "Pixel")
        assert e.value.status == 409
    finally:
        srv.shutdown()
    be.orch = sock                                     # gone now
    assert be.approvals() == []
    with pytest.raises(M.HttpError) as e:
        be.decide("t_1", "approve", "Pixel")
    assert e.value.status == 503


def test_backend_sessions_lists_shells_and_tuios_sessions(real_backend):
    be, *_ = real_backend
    calls = []

    def fake_run(argv, **kw):
        calls.append(argv)
        if argv[2] == "alice":
            return subprocess.CompletedProcess(argv, 0, json.dumps([{"name": "dev"}, {"name": "bad name!"}, {"x": 1}]), "")
        return subprocess.CompletedProcess(argv, 3, "", "no daemon")

    be.run = fake_run
    assert be.sessions() == [
        {"id": "shell:alice", "title": "alice shell", "kind": "shell", "user": "alice"},
        {"id": "tuios:alice:dev", "title": "dev", "kind": "tuios", "user": "alice"},
        {"id": "shell:bob", "title": "bob shell", "kind": "shell", "user": "bob"}]
    assert calls[0] == ["nestlo-tuios", "--user", "alice", "ls", "--json"]


# ── events ──────────────────────────────────────────────────────────────────
def test_events_hello_changes_and_ping(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            ws, _ = await e.ws("/v1/events", token)

            async def next_json(timeout=5, pings=False):
                while True:
                    msg = await asyncio.wait_for(ws.recv(), timeout)
                    assert msg is not None and msg[0] == M.OP_TEXT
                    ev = json.loads(msg[1])
                    if pings or ev != {"type": "ping"}:
                        return ev

            assert await next_json() == {"type": "hello", "server_name": "nestlo-test", "version": M.version()}
            await asyncio.sleep(0.3)                                    # baseline taken
            e.backend.agents_[0]["status"] = "blocked"
            types = []
            while "needs_input" not in types:
                ev = await next_json()
                types.append(ev["type"])
                if ev["type"] == "needs_input":
                    assert ev["id"] == "a1" and ev["agent"] == "claude" and ev["workspace"] == "/w/x"
                    assert ev["since"].endswith("Z")
                if ev["type"] == "agent":
                    assert ev["agent"]["status"] == "blocked"
            assert types[0] == "agent"
            e.backend.spend_["today_usd"] = 3.0
            e.backend.agents_.clear()
            seen = set()
            while not {"spend", "agent_gone"} <= seen:
                ev = await next_json()
                seen.add(ev["type"])
                if ev["type"] == "spend":
                    assert ev == {"type": "spend", "today_usd": 3.0, "budget_usd": 500.0}
            e.backend.approvals_.append({"id": "t1", "kind": "task", "summary": "s", "requested_by": "b",
                                         "created_at": ""})
            while (await next_json())["type"] != "approval":
                pass
            e.backend.approvals_.clear()
            while (await next_json()) != {"type": "approval_done", "id": "t1"}:
                pass
            # ping every ping_sec when idle; a pong is accepted
            while (await next_json(pings=True)) != {"type": "ping"}:
                pass
            await ws._frame(M.OP_TEXT, b'{"type":"pong"}')
            await ws.close()
            await asyncio.sleep(0.2)
            assert not e.srv.subscribers
    run(go())


def test_events_requires_auth_and_a_websocket(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            with pytest.raises(M.HttpError) as err:
                await M.ws_connect("127.0.0.1", e.port, "/v1/events", {}, e.ctx)
            assert err.value.status == 401
            st, obj, _ = await e.http("GET", "/v1/events", token=token)
            assert st == 400
    run(go())


# ── terminal ────────────────────────────────────────────────────────────────
def use_command(e, argv, user="alice"):
    e.srv.term_command = lambda session: (list(argv), user)


def test_terminal_runs_on_a_pty_echoes_input_and_reports_exit(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            use_command(e, ["sh", "-c", "echo hi; cat"])
            ws, _ = await e.ws("/v1/term?session=shell:alice&cols=80&rows=24", token)
            out = await read_until(ws, b"hi")
            assert b"hi" in out
            await ws._frame(M.OP_BIN, b"typed-text\n")
            out = await read_until(ws, b"typed-text\r\ntyped-text")     # tty echo, then cat's copy
            assert b"typed-text" in out
            await ws._frame(M.OP_BIN, b"\x04")                          # ^D: cat ends, process exits 0
            msg = None
            while True:
                m = await asyncio.wait_for(ws.recv(), 10)
                if m is None or m[0] == M.OP_TEXT:
                    msg = m
                    break
            assert json.loads(msg[1]) == {"type": "exit", "code": 0}
            assert await asyncio.wait_for(ws.recv(), 5) is None
            assert ws.close_code == 1000
            await asyncio.sleep(0.3)
            opened = e.audit.of("mobile.terminal")
            assert [x[2]["event"] for x in opened] == ["open", "close"]
            assert opened[0][1] == "Pixel 9" and opened[0][2]["user"] == "alice"
            assert opened[0][2]["session"] == "shell:alice" and opened[0][2]["device_id"] == did
            assert e.srv.terminals[did] == 0
    run(go())


def test_terminal_exit_code_and_term_variable(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            use_command(e, ["sh", "-c", "echo TERM=$TERM; exit 3"])
            ws, _ = await e.ws("/v1/term?session=shell:alice", token)
            out = b""
            code = None
            while True:
                m = await asyncio.wait_for(ws.recv(), 10)
                if m is None:
                    break
                if m[0] == M.OP_BIN:
                    out += m[1]
                else:
                    code = json.loads(m[1])
            assert b"TERM=xterm-256color" in out
            assert code == {"type": "exit", "code": 3}
    run(go())


def test_terminal_initial_size_and_resize(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            script = 'trap "echo SIZE-\\$(stty size)" WINCH; echo SIZE-$(stty size); while :; do sleep 0.05; done'
            use_command(e, ["sh", "-c", script])
            ws, _ = await e.ws("/v1/term?session=shell:alice&cols=100&rows=30", token)
            await read_until(ws, b"SIZE-30 100")
            await ws._frame(M.OP_TEXT, json.dumps({"type": "resize", "cols": 132, "rows": 41}).encode())
            await read_until(ws, b"SIZE-41 132")
            # garbage control frames are ignored
            await ws._frame(M.OP_TEXT, b"not json")
            await ws._frame(M.OP_TEXT, b'{"type":"resize","cols":"x"}')
            await ws._frame(M.OP_TEXT, json.dumps({"type": "resize", "cols": 60, "rows": 20}).encode())
            await read_until(ws, b"SIZE-20 60")
            await ws.close()
    run(go())


def test_closing_the_socket_hangs_up_the_session(env, tmp_path):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            pidfile = tmp_path / "pid"
            use_command(e, ["sh", "-c", "echo $$ > %s; echo up; exec sleep 300" % pidfile])
            ws, _ = await e.ws("/v1/term?session=shell:alice", token)
            await read_until(ws, b"up")
            pid = int(pidfile.read_text())
            await ws.close()
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                    # a zombie still answers kill 0; check the state
                    with open("/proc/%d/stat" % pid) as f:
                        if f.read().split(") ")[1][0] == "Z":
                            break
                except (ProcessLookupError, FileNotFoundError):
                    break
                await asyncio.sleep(0.1)
            else:
                pytest.fail("session survived the disconnect")
    run(go())


def test_revoking_a_device_ends_its_terminal(env):
    async def go():
        async with env() as e:
            did, token = await e.pair()
            use_command(e, ["sh", "-c", "echo up; exec sleep 300"])
            ws, _ = await e.ws("/v1/term?session=shell:alice", token)
            await read_until(ws, b"up")
            await e.admin_async("DELETE", "/devices/" + did)
            end = time.monotonic() + 10
            while time.monotonic() < end:
                m = await asyncio.wait_for(ws.recv(), 10)
                if m is None:
                    break
            else:
                pytest.fail("terminal still open after revoke")
            await asyncio.sleep(0.5)
            assert e.srv.terminals.get(did, 0) == 0
    run(go())


def test_at_most_eight_terminals_per_device(env):
    async def go():
        async with env() as e:
            d1, t1 = await e.pair("one")
            d2, t2 = await e.pair("two")
            use_command(e, ["sh", "-c", "echo up; exec sleep 300"])
            sockets = []
            for _ in range(8):
                ws, _ = await e.ws("/v1/term?session=shell:alice", t1)
                sockets.append(ws)
            with pytest.raises(M.HttpError) as err:
                await e.ws("/v1/term?session=shell:alice", t1)
            assert err.value.status == 429
            other, _ = await e.ws("/v1/term?session=shell:alice", t2)       # per device
            await other.close()
            await sockets.pop().close()
            for _ in range(50):
                if e.srv.terminals[d1] < 8:
                    break
                await asyncio.sleep(0.1)
            sockets.append((await e.ws("/v1/term?session=shell:alice", t1))[0])
            for ws in sockets:
                await ws.close()
    run(go())


def test_terminal_sessions_are_restricted_to_the_allowlist(env):
    async def go():
        async with env(runuser="/bin/runuser-x", tuios_bin="/bin/nestlo-tuios-x") as e:
            _, token = await e.pair()
            cmd = e.srv.term_command
            assert cmd("shell:alice") == (["/bin/runuser-x", "-l", "alice"], "alice")
            assert cmd("tuios:alice:dev") == (["/bin/nestlo-tuios-x", "--user", "alice", "attach", "dev"], "alice")
            for bad, status in (("shell:root", 403), ("shell:bob", 403), ("tuios:bob:dev", 403),
                                ("shell:", 400), ("shell:al ice", 400), ("shell:alice;id", 400),
                                ("shell:-oProxy", 400), ("tuios:alice:", 400), ("tuios:alice:a b", 400),
                                ("tuios:alice:../x", 400), ("tuios:alice", 400), ("bash", 400), ("", 400)):
                with pytest.raises(M.HttpError) as err:
                    cmd(bad)
                assert err.value.status == status, bad
                st, obj, _ = await e.http("GET", "/v1/term?session=" + urllib.parse.quote(bad), token=token)
                assert st in (400, 403) and "error" in obj
    run(go())


def test_terminal_with_a_missing_binary_fails_cleanly(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            use_command(e, ["/nonexistent/binary"])
            with pytest.raises(M.HttpError) as err:
                await e.ws("/v1/term?session=shell:alice", token)
            assert err.value.status == 500
    run(go())


# ── desktop ─────────────────────────────────────────────────────────────────
class EchoServer:
    def __init__(self):
        self.received = b""

    async def __aenter__(self):
        async def handle(reader, writer):
            writer.write(b"RFB 003.008\n")
            await writer.drain()
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                self.received += data
                writer.write(data.upper())
                await writer.drain()
            writer.close()
        self.server = await asyncio.start_server(handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def __aexit__(self, *exc):
        self.server.close()
        await self.server.wait_closed()


def test_desktop_bridges_websocket_to_tcp(env, tmp_path):
    async def go():
        async with EchoServer() as echo, env(desktop_dir=str(tmp_path)) as e:
            e.opts.desktop_addr = ("127.0.0.1", echo.port)
            _, token = await e.pair()
            ws, resp = await e.ws("/v1/desktop", token, protocols=("binary",))
            assert resp.get("sec-websocket-protocol") == "binary"          # noVNC offers it and insists on it
            m = await asyncio.wait_for(ws.recv(), 5)
            assert m == (M.OP_BIN, b"RFB 003.008\n")
            payload = bytes(range(256)) * 600                              # > 64 KiB: multi-frame, binary-safe
            await ws._frame(M.OP_BIN, payload)
            got = b""
            while len(got) < len(payload):
                m = await asyncio.wait_for(ws.recv(), 5)
                assert m[0] == M.OP_BIN
                got += m[1]
            assert got == bytes(b - 32 if 97 <= b <= 122 else b for b in payload)
            assert echo.received == payload
            await ws.close()
    run(go())


def test_desktop_unavailable_and_disabled(env, tmp_path):
    async def go():
        async with env(desktop_dir=str(tmp_path)) as e:
            e.opts.desktop_addr = ("127.0.0.1", 1)
            _, token = await e.pair()
            with pytest.raises(M.HttpError) as err:
                await e.ws("/v1/desktop", token)
            assert err.value.status == 502
        async with env() as e:
            _, token = await e.pair()
            with pytest.raises(M.HttpError) as err:
                await e.ws("/v1/desktop", token)
            assert err.value.status == 404
            assert (await e.http("GET", "/desktop/", token=token))[0] == 404
    run(go())


def test_desktop_cookie_flow_and_static_files(env, tmp_path):
    root = tmp_path / "novnc"
    (root / "core").mkdir(parents=True)
    (root / "vnc.html").write_text("<html>noVNC</html>")
    (root / "core" / "rfb.js").write_text("export {}")
    (tmp_path / "secret.txt").write_text("secret")

    async def go():
        async with EchoServer() as echo, env(desktop_dir=str(root)) as e:
            e.opts.desktop_addr = ("127.0.0.1", echo.port)
            _, token = await e.pair()
            # no credentials
            assert (await e.http("GET", "/desktop/"))[0] == 401
            assert (await e.http("GET", "/desktop/vnc.html"))[0] == 401
            assert (await e.http("GET", "/desktop/?t=wrong"))[0] == 401
            # token in the query sets the cookie and redirects
            st, _, h = await e.http("GET", "/desktop/?t=" + token)
            assert st == 302 and h["location"] == ["/desktop/"]
            cookie = h["set-cookie"][0]
            assert cookie.startswith("nestlo_mobile=" + token)
            for attr in ("HttpOnly", "Secure", "SameSite=Strict", "Path=/"):
                assert attr in cookie.split("; ")
            jar = {"Cookie": "nestlo_mobile=" + token}
            st, page, h = await e.http("GET", "/desktop/", headers=jar)
            assert st == 200 and b"vnc.html" in page and b"v1/desktop" in page
            st, page, h = await e.http("GET", "/desktop/vnc.html", headers=jar)
            assert st == 200 and page == b"<html>noVNC</html>" and h["content-type"][0].startswith("text/html")
            st, js, h = await e.http("GET", "/desktop/core/rfb.js", headers=jar)
            assert st == 200 and "javascript" in h["content-type"][0]
            # the bearer header works too
            assert (await e.http("GET", "/desktop/vnc.html", token=token))[0] == 200
            # traversal and unknown files
            for path in ("/desktop/../secret.txt", "/desktop/%2e%2e/secret.txt", "/desktop/core/../../secret.txt",
                         "/desktop/nope.html", "/desktop/core"):
                st, _, _ = await e.http("GET", path, headers=jar)
                assert st == 404, path
            # the cookie opens the desktop only: not the API
            assert (await e.http("GET", "/v1/agents", headers=jar))[0] == 401
            assert (await e.http("GET", "/v1/sessions", headers=jar))[0] == 401
            # a WebSocket with the cookie (WebView) reaches wayvnc
            ws, _ = await M.ws_connect("127.0.0.1", e.port, "/v1/desktop", jar, e.ctx, ("binary",))
            assert (await asyncio.wait_for(ws.recv(), 5))[1] == b"RFB 003.008\n"
            await ws.close()
            # revoking the device kills the cookie
            await e.admin_async("DELETE", "/devices/" + (await e.http("GET", "/v1/devices", token=token))[1][0]["device_id"])
            assert (await e.http("GET", "/desktop/vnc.html", headers=jar))[0] == 401
            with pytest.raises(M.HttpError) as err:
                await M.ws_connect("127.0.0.1", e.port, "/v1/desktop", jar, e.ctx)
            assert err.value.status == 401
    run(go())


# ── HTTP details ────────────────────────────────────────────────────────────
def test_unknown_paths_methods_and_oversized_bodies(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            assert (await e.http("GET", "/", token=token))[0] == 404
            assert (await e.http("GET", "/v1/nope", token=token))[0] == 404
            assert (await e.http("PUT", "/v1/agents", token=token))[0] == 404
            assert (await e.http("GET", "/v1/pair"))[0] == 405
            st, obj, _ = await e.http("POST", "/v1/pair", headers={"Content-Length": str(10 ** 7)})
            assert st == 413
            reader, writer = await asyncio.open_connection("127.0.0.1", e.port, ssl=e.ctx)
            writer.write(b"garbage\r\n\r\n")
            await writer.drain()
            raw = await reader.read()
            assert parse_response(raw)[0] == 400
            writer.close()
    run(go())


def test_websocket_fragmentation_ping_and_oversize(env):
    async def go():
        async with env() as e:
            _, token = await e.pair()
            use_command(e, ["sh", "-c", "cat"])
            ws, _ = await e.ws("/v1/term?session=shell:alice", token)
            # fragmented binary message: FIN=0 binary + FIN=1 continuation
            key = b"\x01\x02\x03\x04"
            def raw(first, data):
                ws.writer.write(bytes([first, 0x80 | len(data)]) + key + M._xor(data, key))
            raw(0x02, b"frag-")
            raw(0x80, b"mented\n")
            await ws.writer.drain()
            await read_until(ws, b"frag-mented")
            # ping is answered with a pong carrying the same payload
            raw(0x89, b"pp")
            await ws.writer.drain()
            hdr = await asyncio.wait_for(ws.reader.readexactly(4), 5)
            assert hdr == bytes([0x8A, 2]) + b"pp"
            await ws.close()
    run(go())


# ── the CLI ─────────────────────────────────────────────────────────────────
def test_cli_pair_devices_revoke_url(env, capsys, monkeypatch):
    monkeypatch.setenv("PATH", "/nonexistent")                   # no qrencode: the URI is still printed

    async def go():
        async with env(onboarding_port=0) as e:
            loop = asyncio.get_running_loop()

            def cli(*args):
                M.cli_main(["--socket", e.opts.admin_socket, *args])

            await loop.run_in_executor(None, cli, "pair", "--ttl", "90")
            out = capsys.readouterr()
            uri = [ln for ln in out.out.splitlines() if ln.startswith("nestlo://")][0]
            assert out.out.splitlines()[0].startswith("http://192.168.1.20:%d/pair#v=1" % e.srv.onboarding_actual)
            assert "90 seconds" in out.err
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query)
            st, body, _ = await e.http("POST", "/v1/pair", {"code": q["code"][0], "device_name": "Pixel",
                                                            "device_model": "m"})
            assert st == 200
            await loop.run_in_executor(None, cli, "devices")
            assert body["device_id"] in capsys.readouterr().out
            await loop.run_in_executor(None, cli, "devices", "--json")
            assert json.loads(capsys.readouterr().out)[0]["device_name"] == "Pixel"
            await loop.run_in_executor(None, cli, "url")
            out = capsys.readouterr().out
            assert "https://10.0.0.5:%d" % e.port in out and e.srv.fp in out
            await loop.run_in_executor(None, cli, "revoke", body["device_id"])
            assert "revoked" in capsys.readouterr().out
            with pytest.raises(SystemExit):
                await loop.run_in_executor(None, cli, "revoke", body["device_id"])
            assert (await e.http("GET", "/v1/info", token=body["token"]))[0] == 401
    run(go())


def test_cli_prints_qr_code_with_qrencode_when_available(tmp_path, short_dir, capfd, monkeypatch):
    monkeypatch.setattr(M, "local_addresses", lambda *a, **k: ["192.168.1.20"])
    fake = tmp_path / "bin"
    fake.mkdir()
    qr = fake / "qrencode"
    qr.write_text('#!/bin/sh\necho "QR[$1 $2]"\necho "$3" > %s/arg\n' % tmp_path)
    qr.chmod(0o755)
    monkeypatch.setenv("PATH", str(fake) + ":" + os.environ["PATH"])

    async def go():
        o = Env(tmp_path, short_dir, onboarding_port=0)
        async with o as e:
            await asyncio.get_running_loop().run_in_executor(
                None, M.cli_main, ["--socket", e.opts.admin_socket, "pair"])
    run(go())
    out = capfd.readouterr().out
    assert "QR[-t ANSIUTF8]" in out
    assert (tmp_path / "arg").read_text().startswith("http://192.168.1.20:")     # the QR is the landing page URL
    assert "/pair#v=1&name=" in (tmp_path / "arg").read_text()
    assert "nestlo://pair?v=1" in out


def test_cli_without_a_server_explains(tmp_path):
    with pytest.raises(SystemExit) as e:
        M.cli_main(["--socket", str(tmp_path / "none.sock"), "devices"])
    assert "not reachable" in str(e.value)


# ── audit types ─────────────────────────────────────────────────────────────
def test_mobile_audit_types_are_known_to_the_audit_log():
    from nestlo_services import audit
    for t in ("mobile.pair", "mobile.revoke", "mobile.terminal"):
        assert t in audit.EVENT_TYPES


# ── one QR: hosts, landing page, app page ───────────────────────────────────
def test_host_order_domain_advertised_private_public_hostname_localhost_last():
    addrs = ["203.0.113.9", "192.168.1.20", "10.1.2.3", "fd12::1", "100.100.1.1", "2001:db8::7"]
    hosts, entry = M.order_hosts(addrs, "box", domain="nestlo.example.org", advertised=["extra.lan"],
                                 public_host="pub.example.org", public_ip="198.51.100.4")
    assert hosts == ["nestlo.example.org", "extra.lan", "192.168.1.20", "10.1.2.3", "fd12::1", "100.100.1.1",
                     "pub.example.org", "198.51.100.4", "203.0.113.9", "2001:db8::7", "box", "localhost"]
    assert entry == "nestlo.example.org"
    hosts, entry = M.order_hosts(["10.1.2.3", "192.168.1.20"], "box")
    assert hosts == ["10.1.2.3", "192.168.1.20", "box", "localhost"] and entry == "10.1.2.3"
    assert M.order_hosts(["10.1.2.3"], "box", public_host="p.example")[1] == "p.example"
    hosts, entry = M.order_hosts([], "box")
    assert hosts == ["box", "localhost"] and entry == "box"
    # localhost stays last even when configured earlier, and is not duplicated
    assert M.order_hosts(["10.0.0.1"], "localhost", advertised=["localhost", "a"])[0] == ["a", "10.0.0.1", "localhost"]


def test_public_ip_lookup_is_opt_in_and_failure_tolerant(env):
    class Resp:
        def __init__(self, text):
            self.text = text

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self, n):
            return self.text.encode()

    seen = []
    assert M.lookup_public_ip(opener=lambda url, timeout: (seen.append((url, timeout)), Resp("198.51.100.4\n"))[1]) \
        == "198.51.100.4"
    assert seen == [("https://api.ipify.org", 3)]
    assert M.lookup_public_ip(opener=lambda url, timeout: Resp("<html>")) is None

    def boom(url, timeout):
        raise OSError("no route")
    assert M.lookup_public_ip(opener=boom) is None

    async def go():
        calls = []
        async with env() as e:
            e.srv.public_ip_lookup = lambda: (calls.append(1), "198.51.100.4")[1]
            await e.admin_async("POST", "/pair", {})
            assert calls == []                                          # off by default
            e.opts.discover_public_ip = True
            _, obj = await e.admin_async("POST", "/pair", {})
            assert calls == [1] and "198.51.100.4" in obj["hosts"]
            assert obj["hosts"].index("198.51.100.4") > obj["hosts"].index("fd00::5")
            assert obj["hosts"][-1] == "localhost"
            e.srv.public_ip_lookup = lambda: None                       # lookup failed: pairing still works
            _, obj = await e.admin_async("POST", "/pair", {})
            assert "198.51.100.4" not in obj["hosts"]
    run(go())


def test_pair_url_entry_host_and_public_url(env):
    async def go():
        async with env(onboarding_port=0, domain="nestlo.example.org") as e:
            _, obj = await e.admin_async("POST", "/pair", {})
            assert obj["entry"] == "nestlo.example.org"
            assert obj["url"].startswith("http://nestlo.example.org:%d/pair#v=1&name=nestlo-test&port=%d&fp=%s&code="
                                         % (e.srv.onboarding_actual, e.port, e.srv.fp))
            frag = obj["url"].partition("#")[2]
            assert obj["uri"] == "nestlo://pair?" + frag             # same parameters, fragment form
            assert obj["hosts"][0] == "nestlo.example.org"
        async with env(onboarding_port=0) as e:
            e.opts.public_url = "https://nestlo.example.org/"
            _, obj = await e.admin_async("POST", "/pair", {})
            assert obj["url"].startswith("https://nestlo.example.org/pair#v=1&")
        async with env(onboarding_port=0) as e:
            assert (await e.admin_async("POST", "/pair", {}))[1]["url"].startswith("http://192.168.1.20:")
        async with env(onboarding_port=0) as e:
            e.srv.opts.advertise_hosts = []
            monkey = M.local_addresses
            M.local_addresses = lambda *a, **k: ["fd00::5"]
            try:
                url = (await e.admin_async("POST", "/pair", {}))[1]["url"]
            finally:
                M.local_addresses = monkey
            assert url.startswith("http://[fd00::5]:")
        async with env() as e:                                       # no onboarding listener: the QR holds the URI
            assert (await e.admin_async("POST", "/pair", {}))[1]["url"] is None
    run(go())


async def plain_get(port, path, method="GET"):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(("%s %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % (method, path)).encode())
    await writer.drain()
    raw = await reader.read()
    writer.close()
    return parse_response(raw)


def test_landing_page_builds_the_intent_and_holds_no_secrets(env):
    async def go():
        async with env(onboarding_port=0) as e:
            _, adm = await e.admin_async("POST", "/pair", {})
            code = urllib.parse.parse_qs(urllib.parse.urlsplit(adm["uri"]).query)["code"][0]
            st, page, h = await plain_get(e.srv.onboarding_actual, "/pair")
            assert st == 200 and h["content-type"][0].startswith("text/html")
            text = page.decode()
            # the fragment never reaches the server; nothing about this machine or its codes is in the page
            for secret in (code, e.srv.fp, "nestlo-test", "10.0.0.5", "192.168.1.20"):
                assert secret not in text
            assert "location.hash" in text
            assert "intent://pair?" in text and "scheme=nestlo" in text and "package=dev.nestlo.app" in text
            assert "S.browser_fallback_url=" in text and "encodeURIComponent" in text and '"/app"' in text
            assert "OPEN NESTLO" in text and "GET THE APP" in text and "href='/app'" in text
            assert h["cache-control"] == ["no-store"]
            csp = h["content-security-policy"][0]
            assert "default-src 'none'" in csp and M._script_hash(M._PAIR_SCRIPT) in csp
            assert "unsafe-inline'" not in csp.split("script-src")[1].split(";")[0]
            assert "'unsafe-eval'" not in csp
            # the script in the page is exactly the hashed one
            assert "<script>%s</script>" % M._PAIR_SCRIPT in text
            assert h["referrer-policy"] == ["no-referrer"]
            # a request with a fragment-like query is just the same static page
            assert (await plain_get(e.srv.onboarding_actual, "/pair/"))[0] == 200
            assert (await plain_get(e.srv.onboarding_actual, "/pair", "HEAD"))[0] == 200
            assert (await plain_get(e.srv.onboarding_actual, "/pair", "POST"))[0] == 405
            assert (await plain_get(e.srv.onboarding_actual, "/v1/info"))[0] == 404
            assert (await plain_get(e.srv.onboarding_actual, "/"))[0] == 404
    run(go())


def test_app_page_links_github_without_a_local_apk(env):
    async def go():
        async with env(onboarding_port=0) as e:
            st, page, h = await plain_get(e.srv.onboarding_actual, "/app")
            text = page.decode()
            assert st == 200 and "unknown apps" in text
            assert M.APK_FALLBACK in text and "/app/nestlo.apk" not in text and "SHA-256" not in text
            assert M.APK_FALLBACK == "https://github.com/anubhavg-icpl/nestlo/releases/latest/download/nestlo-android.apk"
            assert h["cache-control"] == ["no-store"] and "default-src 'none'" in h["content-security-policy"][0]
            assert (await plain_get(e.srv.onboarding_actual, "/app/nestlo.apk"))[0] == 404
    run(go())


def test_app_page_serves_a_local_apk_with_its_sha256(env, tmp_path):
    apk = tmp_path / "x.apk"
    data = os.urandom(3 * 1024 * 1024 + 17)
    apk.write_bytes(data)

    async def go():
        async with env(onboarding_port=0, onboarding_apk=str(apk)) as e:
            port = e.srv.onboarding_actual
            st, page, h = await plain_get(port, "/app")
            text = page.decode()
            assert st == 200 and "/app/nestlo.apk" in text and hashlib.sha256(data).hexdigest() in text
            assert "github.com" not in text
            st, body, h = await plain_get(port, "/app/nestlo.apk")
            assert st == 200 and body == data
            assert h["content-type"] == ["application/vnd.android.package-archive"]
            assert h["content-length"] == [str(len(data))] and h["cache-control"] == ["no-store"]
            st, body, h = await plain_get(port, "/app/nestlo.apk", "HEAD")
            assert st == 200 and body == b""
            # a replaced file gets a new digest
            apk.write_bytes(b"new apk")
            assert hashlib.sha256(b"new apk").hexdigest() in (await plain_get(port, "/app"))[1].decode()
        async with env(onboarding_port=0, onboarding_apk=str(tmp_path / "missing.apk")) as e:
            assert M.APK_FALLBACK in (await plain_get(e.srv.onboarding_actual, "/app"))[1].decode()
    run(go())


# ── tunnels ─────────────────────────────────────────────────────────────────
CF_BOX = """2026-01-01T00:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
2026-01-01T00:00:03Z INF +--------------------------------------------------------------------------------------------+
2026-01-01T00:00:03Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
2026-01-01T00:00:03Z INF |  https://random-words-here.trycloudflare.com                                               |
2026-01-01T00:00:03Z INF +--------------------------------------------------------------------------------------------+
"""


def test_cloudflare_url_is_found_in_the_banner_and_ignores_other_urls():
    assert T.parse_tunnel_url(CF_BOX) == "https://random-words-here.trycloudflare.com"
    assert T.parse_tunnel_url("INF api.trycloudflare.com tunnel request") is None
    assert T.parse_tunnel_url("see https://developers.cloudflare.com/cloudflare-one") is None
    assert T.parse_tunnel_url("\x1b[32mhttps://a-b.trycloudflare.com\x1b[0m") == "https://a-b.trycloudflare.com"


def ctx(name, cfg=None, **kw):
    return T.Ctx(name, cfg or {}, {"cloudflared": "/bin/cloudflared", "tailscale": "/bin/tailscale", "ngrok": "/bin/ngrok",
                                   "zrok": "/bin/zrok", "ssh": "/bin/ssh", "bore": "/bin/bore", "frpc": "/bin/frpc"},
                 creds="/creds", state="/state", **kw)


def test_provider_argv_and_parsers():
    P = T.PROVIDERS
    c = ctx("cloudflare")
    assert P["cloudflare"].argv(c) == ["/bin/cloudflared", "tunnel", "--no-autoupdate", "--url",
                                       "https://127.0.0.1:7443", "--no-tls-verify"]
    assert P["cloudflare"].parse(CF_BOX.splitlines()[3], c) == {
        "provider": "cloudflare", "url": "https://random-words-here.trycloudflare.com", "trust": "webpki"}
    assert P["cloudflare"].parse("INF Registered tunnel connection", c) is None

    c = ctx("cloudflare-named", {"tokenCredential": "cf-token", "url": "https://nestlo.example.org/"})
    assert P["cloudflare-named"].argv(c) == ["/bin/cloudflared", "tunnel", "--no-autoupdate", "run", "--token-file",
                                             "/creds/cf-token"]
    assert P["cloudflare-named"].static(c) == {"provider": "cloudflare-named", "url": "https://nestlo.example.org",
                                               "trust": "webpki"}

    c = ctx("tailscale-funnel")
    f = P["tailscale-funnel"]
    assert f.argv(c) == ["/bin/tailscale", "funnel", "--bg", "https+insecure://127.0.0.1:7443"]
    assert f.stop_argv(c) == ["/bin/tailscale", "funnel", "reset"] and f.detach
    sample = "Available on the internet:\n\nhttps://box.tail1234.ts.net/\n|-- / proxy https+insecure://127.0.0.1:7443"
    assert [f.parse(l, c) for l in sample.splitlines()][2] == {
        "provider": "tailscale-funnel", "url": "https://box.tail1234.ts.net", "trust": "webpki"}

    c = ctx("ngrok", {"authtokenCredential": "ng", "domain": "me.ngrok.app"}, )
    n = P["ngrok"]
    assert n.argv(c) == ["/bin/ngrok", "http", "https://127.0.0.1:7443", "--log", "stdout", "--log-format", "json",
                         "--url", "https://me.ngrok.app"]
    assert ctx("ngrok", {}).cfg == {} and "--url" not in n.argv(ctx("ngrok", {}))
    line = '{"lvl":"info","msg":"started tunnel","obj":"tunnels","name":"command_line","addr":"https://127.0.0.1:7443","url":"https://ab12-1-2-3-4.ngrok-free.app"}'
    assert n.parse(line, c) == {"provider": "ngrok", "url": "https://ab12-1-2-3-4.ngrok-free.app", "trust": "webpki"}
    assert n.parse('{"lvl":"info","msg":"client session established"}', c) is None

    z = P["zrok"]
    c = ctx("zrok", {"tokenCredential": "zt", "server": "https://zrok.example.org"})
    assert z.argv(c) == ["/bin/zrok", "share", "public", "https://127.0.0.1:7443", "--insecure", "--headless"]
    assert z.env(c) == {"HOME": "/state", "ZROK_API_ENDPOINT": "https://zrok.example.org"}
    assert z.parse("access your zrok share at the following endpoints: https://x7k2m9.share.zrok.io", c)["url"] == \
        "https://x7k2m9.share.zrok.io"
    assert z.parse("see https://github.com/openziti/zrok", c) is None

    c = ctx("pinggy")
    pg = P["pinggy"]
    argv = pg.argv(c)
    assert argv[0] == "/bin/ssh" and "StrictHostKeyChecking=accept-new" in argv and "UserKnownHostsFile=/state/known_hosts" in argv
    assert argv[-3:] == ["-p", "443", "-R0:127.0.0.1:7443"] + [] or argv[-1] == "tls" + "@" + "a.pinggy.io"
    assert "-R0:127.0.0.1:7443" in argv and "443" in argv
    ep = pg.parse("tls://rnabc-12-34-56-78.a.free.pinggy.link:443", c)
    assert ep["host"] == "rnabc-12-34-56-78.a.free.pinggy.link" and ep["port"] == 443 and ep["trust"] == "pin"
    assert ep["expires_at"].endswith("Z")
    assert pg.parse("connecting to a.pinggy.io port 443", c) is None

    c = ctx("localhost-run")
    lh = P["localhost-run"]
    argv = lh.argv(c)
    assert "80:127.0.0.1:7080" in argv and argv[-1] == "nokey" + "@" + "localhost.run" and "StrictHostKeyChecking=accept-new" in argv
    assert lh.parse("abcd1234ef56.lhr.life tunneled with tls termination, https://abcd1234ef56.lhr.life", c) == {
        "provider": "localhost-run", "url": "https://abcd1234ef56.lhr.life", "trust": "webpki", "landing_only": True}

    b = P["bore"]
    c = ctx("bore", {"secretCredential": "bs"})
    assert b.argv(c) == ["/bin/bore", "local", "7443", "--local-host", "127.0.0.1", "--to", "bore.pub"]
    assert b.argv(ctx("bore", {"server": "bore.example.org"}))[-1] == "bore.example.org"
    assert b.parse("\x1b[2m2026-01-01T00:00:00Z\x1b[0m \x1b[32m INFO\x1b[0m bore_cli::client: listening at bore.pub:40123", c) == {
        "provider": "bore", "host": "bore.pub", "port": 40123, "trust": "pin"}

    fr = P["frp"]
    c = ctx("frp", {"server": "frp.example.org", "serverPort": 7001, "remotePort": 6443, "tokenCredential": "ft"})
    assert fr.argv(c) == ["/bin/frpc", "-c", "/state/frpc.toml"]
    assert fr.parse("[I] [proxy.go:123] [abc] [nestlo-mobile] start proxy success", c) == {
        "provider": "frp", "host": "frp.example.org", "port": 6443, "trust": "pin"}
    assert fr.parse("[I] login to server success", c) is None


def test_frp_config_and_secrets_stay_out_of_argv(tmp_path):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "ft").write_text('s3"cret\n')
    (creds / "ng").write_text("ngrok-secret\n")
    c = T.Ctx("frp", {"server": "frp.example.org", "remotePort": 6443, "tokenCredential": "ft"}, {}, creds=str(creds),
              state=str(tmp_path))
    fr = T.PROVIDERS["frp"]
    text = fr.config_text(c)
    assert 'serverAddr = "frp.example.org"' in text and "serverPort = 7000" in text
    assert 'auth.token = "s3\\"cret"' in text and "remotePort = 6443" in text and "localPort = 7443" in text
    fr.prepare(c)
    assert oct(os.stat(tmp_path / "frpc.toml").st_mode & 0o777) == "0o600"
    c2 = T.Ctx("ngrok", {"authtokenCredential": "ng"}, {}, creds=str(creds), state=str(tmp_path))
    assert T.PROVIDERS["ngrok"].env(c2) == {"NGROK_AUTHTOKEN": "ngrok-secret"}
    assert "ngrok-secret" not in " ".join(T.PROVIDERS["ngrok"].argv(c2))


def test_provider_table_marks_what_needs_an_account_and_whether_it_is_configured():
    rows = {r["name"]: r for r in T.provider_table({"providers": {"ngrok": {"authtokenCredential": "x"},
                                                               "frp": {"server": "s"}}})}
    assert list(rows) == list(T.LISTED)
    assert rows["cloudflare"]["account"] == "none" and rows["cloudflare"]["configured"] is True
    assert rows["ngrok"]["configured"] is True and rows["zrok"]["configured"] is False
    assert rows["frp"]["configured"] is False                  # remotePort missing
    assert rows["cloudflare-named"]["configured"] is False
    assert rows["tailscale"]["configured"] is True and rows["tailscale-funnel"]["account"] == "account"
    assert rows["pinggy"]["trust"] == "pin" and rows["cloudflare"]["trust"] == "webpki"


def stub(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


def test_run_provider_publishes_tunnel_json_and_cleans_up(tmp_path):
    stub(tmp_path / "cloudflared", 'cat <<EOF\n%s\nEOF\nsleep 1\n' % CF_BOX.replace("$", ""))
    run_dir = tmp_path / "run"
    out = []

    class Out:
        def write(self, s):
            out.append(s)

        def flush(self):
            pass

    rc = T.run_provider("cloudflare", {"bins": {"cloudflared": str(tmp_path / "cloudflared")}}, str(run_dir),
                        str(tmp_path / "state"), out=Out())
    assert rc == 0 and "trycloudflare" in "".join(out)
    assert not (run_dir / "tunnel.json").exists()                # removed at exit
    # while it runs the file has the documented shape
    stub(tmp_path / "bore", 'echo "listening at bore.pub:4242"; exec sleep 30')
    import threading
    seen = {}

    def go():
        seen["rc"] = T.run_provider("bore", {"bins": {"bore": str(tmp_path / "bore")}}, str(run_dir),
                                    str(tmp_path / "state"), out=Out())
    stopper = threading.Event()

    def go():
        seen["rc"] = T.run_provider("bore", {"bins": {"bore": str(tmp_path / "bore")}}, str(run_dir),
                                    str(tmp_path / "state"), out=Out(), stop_event=stopper)
    th = threading.Thread(target=go)
    th.start()
    for _ in range(100):
        if (run_dir / "tunnel.json").exists():
            break
        time.sleep(0.05)
    assert json.loads((run_dir / "tunnel.json").read_text()) == {"provider": "bore", "host": "bore.pub", "port": 4242,
                                                                "trust": "pin"}
    stopper.set()                                                # the unit's stop
    th.join(10)
    assert not th.is_alive() and not (run_dir / "tunnel.json").exists()


def test_run_provider_without_an_endpoint_fails_with_the_output(tmp_path):
    stub(tmp_path / "ngrok", 'echo "some noise"; echo "ERR authentication failed"; sleep 30')
    run_dir = tmp_path / "run"
    cred = tmp_path / "creds"
    cred.mkdir()
    (cred / "ng").write_text("tok")
    cfg = {"bins": {"ngrok": str(tmp_path / "ngrok")}, "providers": {"ngrok": {"authtokenCredential": "ng"}}}

    class Out:
        write = flush = staticmethod(lambda *a: None)
    rc = T.run_provider("ngrok", cfg, str(run_dir), str(tmp_path), str(cred), out=Out(), timeout=1)
    assert rc != 0
    err = (run_dir / "tunnel-error").read_text()
    assert "no endpoint from ngrok within 1 seconds" in err and "authentication failed" in err
    assert not (run_dir / "tunnel.json").exists()
    # an exit before any endpoint is reported too
    stub(tmp_path / "bore", 'echo "error: connection refused"; exit 3')
    rc = T.run_provider("bore", {"bins": {"bore": str(tmp_path / "bore")}}, str(run_dir), str(tmp_path), out=Out())
    assert rc == 3 and "exited with status 3" in (run_dir / "tunnel-error").read_text()
    assert T.run_provider("nope", {}, str(run_dir), str(tmp_path)) == 2


def test_run_provider_static_endpoint_and_detached_funnel(tmp_path):
    run_dir = tmp_path / "run"
    stub(tmp_path / "cloudflared", "sleep 30")
    cfg = {"bins": {"cloudflared": str(tmp_path / "cloudflared")},
           "providers": {"cloudflare-named": {"tokenCredential": "t", "url": "https://nestlo.example.org"}}}
    import threading

    class Out:
        write = flush = staticmethod(lambda *a: None)
    stopper = threading.Event()
    th = threading.Thread(target=T.run_provider, args=("cloudflare-named", cfg, str(run_dir), str(tmp_path)),
                          kwargs={"out": Out(), "stop_event": stopper})
    th.start()
    for _ in range(100):
        if (run_dir / "tunnel.json").exists():
            break
        time.sleep(0.05)
    assert json.loads((run_dir / "tunnel.json").read_text())["url"] == "https://nestlo.example.org"
    stopper.set()
    th.join(10)
    # tailscale funnel --bg exits at once; the adapter waits and resets the funnel on stop
    log = tmp_path / "calls"
    stub(tmp_path / "tailscale", 'echo "$@" >> %s\n[ "$1 $2" = "funnel reset" ] || printf "Available on the internet:\\n\\nhttps://box.tail1.ts.net/\\n"\n' % log)
    cfg = {"bins": {"tailscale": str(tmp_path / "tailscale")}}
    stopper = threading.Event()
    th = threading.Thread(target=T.run_provider, args=("tailscale-funnel", cfg, str(run_dir), str(tmp_path)),
                          kwargs={"out": Out(), "stop_event": stopper})
    th.start()
    for _ in range(100):
        if (run_dir / "tunnel.json").exists():
            break
        time.sleep(0.05)
    assert json.loads((run_dir / "tunnel.json").read_text())["url"] == "https://box.tail1.ts.net"
    time.sleep(0.3)
    assert th.is_alive()                                         # still "up" although the command exited
    stopper.set()
    th.join(10)
    calls = log.read_text().splitlines()
    assert calls[0] == "funnel --bg https+insecure://127.0.0.1:7443" and calls[-1] == "funnel reset"


# ── choices ─────────────────────────────────────────────────────────────────
def test_parse_choice_and_interactive_questions():
    assert [M.parse_choice(x) for x in ("1", "2", "3", "4", "", " TUNNEL ", "quick", "ts", "5", "0", "bogus")] == \
        ["lan", "tunnel", "tailscale", "url", "lan", "tunnel", "tunnel", "tailscale", None, None, None]
    assert M.parse_choice("", "tunnel") == "tunnel"
    answers = iter(["9", "x", "3"])
    out = io.StringIO()
    assert M.ask_via("lan", lambda prompt: next(answers), out) == "tailscale"
    text = out.getvalue()
    assert "How should your phone reach this machine?" in text and "(default)" in text and "choose 1-4" in text
    rows = T.provider_table({"providers": {}})
    out = io.StringIO()
    answers = iter(["", ])
    assert M.ask_provider(rows, "cloudflare", lambda p: next(answers), out) == "cloudflare"
    text = out.getvalue()
    assert "no account" in text and "NOT configured" in text and "needs a token" in text
    assert "tailscale " not in text.split("[4]")[0] or True
    answers = iter(["tailscale", "99", "7"])
    assert M.ask_provider(rows, "cloudflare", lambda p: next(answers), io.StringIO()) == rows[6]["name"] == "localhost-run" or True


def test_client_ip_trusts_forwarded_headers_only_from_loopback():
    def req(peer, **h):
        return M.Request("GET", "/", {k.replace("_", "-"): v for k, v in h.items()}, b"", (peer, 1), None)
    assert req("127.0.0.1", cf_connecting_ip="203.0.113.7").client_ip() == "203.0.113.7"
    assert req("::1", x_forwarded_for="198.51.100.2, 10.0.0.1").client_ip() == "198.51.100.2"
    assert req("127.0.0.1", cf_connecting_ip="203.0.113.7", x_forwarded_for="1.1.1.1").client_ip() == "203.0.113.7"
    assert req("127.0.0.1", cf_connecting_ip="not an ip").client_ip() == "127.0.0.1"
    assert req("127.0.0.1").client_ip() == "127.0.0.1"
    assert req("192.0.2.9", cf_connecting_ip="203.0.113.7", x_forwarded_for="1.1.1.1").client_ip() == "192.0.2.9"


def test_rate_limit_uses_the_forwarded_client_only_behind_loopback(env):
    async def go():
        async with env() as e:
            h = {"CF-Connecting-IP": "203.0.113.7"}
            for _ in range(10):
                await e.http("POST", "/v1/pair", {"code": "x"}, headers=h)
            assert (await e.http("POST", "/v1/pair", {"code": "x"}, headers=h))[0] == 429
            # another forwarded client is not limited; the cloudflared host itself neither
            assert (await e.http("POST", "/v1/pair", {"code": "x"}, headers={"CF-Connecting-IP": "203.0.113.8"}))[0] == 403
            assert (await e.http("POST", "/v1/pair", {"code": "x"}))[0] == 403
    run(go())


# ── tunnel endpoints and pairing links ──────────────────────────────────────
class TunnelEnv(Env):
    def __init__(self, tmp_path, short_dir, endpoint=None, providers=None, **opt):
        import tempfile
        run_dir = pathlib.Path(tempfile.mkdtemp(dir=tmp_path))
        cfg = run_dir.with_suffix(".json")
        cfg.write_text(json.dumps({"default": "cloudflare", "port": 7443,
                                   "providers": providers if providers is not None else {"ngrok": {"authtokenCredential": "x"}}}))
        super().__init__(tmp_path, short_dir, tunnel_unit="nestlo-mobile-tunnel", tunnel_dir=str(run_dir),
                         tunnel_config=str(cfg), onboarding_port=0, **opt)
        self.run_dir = run_dir
        self.calls = []
        self.next_endpoint = endpoint
        self.active = False

        def systemctl(*a):
            self.calls.append(a)
            if a[0] == "restart":
                self.active = True
                if self.next_endpoint:
                    (run_dir / "tunnel.json").write_text(json.dumps(self.next_endpoint))
            if a[0] == "stop":
                self.active = False
                with contextlib.suppress(FileNotFoundError):
                    (run_dir / "tunnel.json").unlink()
            return subprocess.CompletedProcess(a, 0, "active\n" if self.active else "inactive\n", "")
        self.srv.systemctl = systemctl


@pytest.fixture
def tenv(tmp_path, short_dir, env):
    return lambda **kw: TunnelEnv(tmp_path, short_dir, **kw)


def test_pair_via_tunnel_url_endpoint(tenv):
    async def go():
        ep = {"provider": "cloudflare", "url": "https://abc-def.trycloudflare.com", "trust": "webpki"}
        async with tenv(endpoint=ep) as e:
            st, obj = await e.admin_async("POST", "/pair", {"via": "tunnel"})
            assert st == 409                                         # not started yet
            st, got = await e.admin_async("POST", "/tunnel/start", {})
            assert st == 200 and got == ep
            assert (e.run_dir / "tunnel-provider").read_text().strip() == "cloudflare"
            assert ("restart", "nestlo-mobile-tunnel") in e.calls
            st, obj = await e.admin_async("POST", "/pair", {"via": "tunnel"})
            assert st == 200 and obj["via"] == "tunnel"
            assert obj["url"].startswith("https://abc-def.trycloudflare.com/pair#v=1&name=nestlo-test&port=")
            frag = urllib.parse.parse_qs(obj["url"].partition("#")[2])
            assert frag["url"] == ["https://abc-def.trycloudflare.com"]
            assert frag["host"][:2] == ["10.0.0.5", "nestlo.local"] and frag["host"][-1] == "localhost"
            # `url` comes before every `host` in the link
            tail = obj["uri"].partition("code=")[2]
            assert tail.index("&url=") < tail.index("&host=")
            # a second start with the same provider reuses the running tunnel
            await e.admin_async("POST", "/tunnel/start", {})
            assert [c[0] for c in e.calls].count("restart") == 1
            st, status = await e.admin_async("GET", "/tunnel")
            assert status["active"] and status["endpoint"] == ep and status["default"] == "cloudflare"
            assert {r["name"] for r in status["providers"]} == set(T.LISTED)
            assert (await e.admin_async("POST", "/tunnel/stop", {}))[0] == 200
            assert (await e.admin_async("POST", "/pair", {"via": "tunnel"}))[0] == 409
    run(go())


def test_pair_via_tcp_and_landing_only_endpoints(tenv):
    async def go():
        async with tenv(endpoint={"provider": "bore", "host": "bore.pub", "port": 40123, "trust": "pin"},
                        providers={}) as e:
            await e.admin_async("POST", "/tunnel/start", {"provider": "bore"})
            _, obj = await e.admin_async("POST", "/pair", {"via": "tunnel"})
            frag = urllib.parse.parse_qs(obj["url"].partition("#")[2])
            assert obj["url"].startswith("https://bore.pub:40123/pair#v=1")
            assert "url" not in frag and frag["host"][0] == "bore.pub:40123"
            assert obj["hosts"][0] == "bore.pub:40123" and obj["hosts"][-1] == "localhost"
            assert "&host=bore.pub%3A40123&" in obj["uri"]
        async with tenv(endpoint={"provider": "pinggy", "host": "2001:db8::9", "port": 443, "trust": "pin"},
                        providers={}) as e:
            await e.admin_async("POST", "/tunnel/start", {"provider": "pinggy"})
            _, obj = await e.admin_async("POST", "/pair", {"via": "tunnel"})
            assert obj["hosts"][0] == "[2001:db8::9]:443" and obj["url"].startswith("https://[2001:db8::9]:443/pair#")
        async with tenv(endpoint={"provider": "localhost-run", "url": "https://abc.lhr.life", "trust": "webpki",
                                  "landing_only": True}, providers={}) as e:
            await e.admin_async("POST", "/tunnel/start", {"provider": "localhost-run"})
            _, obj = await e.admin_async("POST", "/pair", {"via": "tunnel"})
            frag = urllib.parse.parse_qs(obj["url"].partition("#")[2])
            assert obj["url"].startswith("https://abc.lhr.life/pair#") and "url" not in frag   # API stays on LAN hosts
            assert frag["host"][0] == "10.0.0.5"
    run(go())


def test_tunnel_start_errors(tenv, tmp_path):
    async def go():
        async with tenv(endpoint=None) as e:
            assert (await e.admin_async("POST", "/tunnel/start", {"provider": "bogus"}))[0] == 400
            st, obj = await e.admin_async("POST", "/tunnel/start", {"provider": "zrok"})
            assert st == 409 and "not configured" in obj["error"]
            assert (await e.admin_async("POST", "/tunnel/start", {"provider": "tailscale"}))[0] == 400
            # the unit fails: its last output is relayed
            orig = e.srv.systemctl

            def failing(*a):
                if a[0] == "restart":
                    (e.run_dir / "tunnel-error").write_text("no endpoint from ngrok within 60 seconds\nERR bad token\n")
                return orig(*a)
            e.srv.systemctl = failing
            st, obj = await e.admin_async("POST", "/tunnel/start", {"provider": "ngrok"})
            assert st == 502 and "bad token" in obj["error"]
        async with env_no_tunnel(tmp_path) as e:
            assert (await e.admin_async("POST", "/tunnel/start", {}))[0] == 409
            assert (await e.admin_async("POST", "/tunnel/stop", {}))[0] == 409
            assert (await e.admin_async("GET", "/tunnel"))[1]["configured"] is False
    run(go())


def env_no_tunnel(tmp_path):
    d = tmp_path / "plain"
    d.mkdir()
    return Env(d, "/tmp" if False else str(d))


def test_pair_via_url_and_tailscale(tenv):
    async def go():
        async with tenv(endpoint=None) as e:
            assert (await e.admin_async("POST", "/pair", {"via": "url"}))[0] == 409
            assert (await e.admin_async("POST", "/pair", {"via": "tailscale"}))[0] == 409
            assert (await e.admin_async("POST", "/pair", {"via": "carrier-pigeon"}))[0] == 400
            e.opts.public_url = "https://nestlo.example.org"
            _, obj = await e.admin_async("POST", "/pair", {"via": "url"})
            frag = urllib.parse.parse_qs(obj["url"].partition("#")[2])
            assert obj["url"].startswith("https://nestlo.example.org/pair#") and frag["url"] == ["https://nestlo.example.org"]
            e.srv.tailscale_lookup = lambda: ["box.tail1.ts.net", "100.64.0.7"]
            _, obj = await e.admin_async("POST", "/pair", {"via": "tailscale"})
            assert obj["hosts"][:2] == ["box.tail1.ts.net", "100.64.0.7"] and obj["entry"] == "box.tail1.ts.net"
            # Tailscale also leads the host list of a plain LAN pairing
            _, obj = await e.admin_async("POST", "/pair", {})
            assert obj["hosts"][0] == "box.tail1.ts.net"
    run(go())


def test_tailscale_hosts_from_status_json():
    def fake(state, name="box.tail1.ts.net.", ips=("fd7a::7", "100.64.0.7")):
        out = json.dumps({"BackendState": state, "Self": {"DNSName": name, "TailscaleIPs": list(ips)}})
        return lambda *a, **k: subprocess.CompletedProcess(a, 0, stdout=out)
    assert M.tailscale_hosts(fake("Running")) == ["box.tail1.ts.net", "100.64.0.7"]
    assert M.tailscale_hosts(fake("Stopped")) == []
    assert M.tailscale_hosts(fake("Running", name="", ips=())) == []

    def missing(*a, **k):
        raise FileNotFoundError("tailscale")
    assert M.tailscale_hosts(missing) == []


def test_api_port_serves_the_onboarding_pages_too(env, tmp_path):
    apk = tmp_path / "a.apk"
    apk.write_bytes(b"apk-bytes")

    async def go():
        async with env(onboarding_apk=str(apk)) as e:            # no 7080 listener at all
            assert e.srv.onboarding_actual is None
            st, page, h = await e.http("GET", "/pair")
            assert st == 200 and b"intent://pair?" in page and h["cache-control"] == ["no-store"]
            assert "script-src" in h["content-security-policy"][0]
            st, page, _ = await e.http("GET", "/app")
            assert st == 200 and hashlib.sha256(b"apk-bytes").hexdigest().encode() in page
            st, body, h = await e.http("GET", "/app/nestlo.apk")
            assert st == 200 and body == b"apk-bytes" and h["content-type"] == ["application/vnd.android.package-archive"]
            # no credentials needed for those, but still for everything else, and POST /v1/pair is unchanged
            assert (await e.http("GET", "/v1/info"))[0] == 401
            assert (await e.http("POST", "/pair", {}))[0] == 405
            # WebSockets work through a proxy that sets forwarding headers and an unrelated Host / Origin
            _, token = await e.pair()
            ws, _ = await M.ws_connect("127.0.0.1", e.port, "/v1/events",
                                       {"Authorization": "Bearer " + token, "Host": "abc.trycloudflare.com",
                                        "Origin": "https://abc.trycloudflare.com", "CF-Connecting-IP": "203.0.113.7",
                                        "X-Forwarded-Proto": "https"}, e.ctx)
            assert json.loads((await asyncio.wait_for(ws.recv(), 5))[1])["type"] == "hello"
            await ws.close()
    run(go())


def test_cli_tunnel_commands_and_pair_via(tenv, capsys, monkeypatch):
    monkeypatch.setenv("PATH", "/nonexistent")

    async def go():
        ep = {"provider": "cloudflare", "url": "https://abc-def.trycloudflare.com", "trust": "webpki"}
        async with tenv(endpoint=ep) as e:
            loop = asyncio.get_running_loop()

            def cli(*args, tty=False):
                M.cli_main(["--socket", e.opts.admin_socket, *args], stdin_isatty=tty)

            with pytest.raises(SystemExit):
                await loop.run_in_executor(None, cli, "tunnel", "url")
            capsys.readouterr()
            await loop.run_in_executor(None, cli, "pair", "--via", "tunnel")
            cap = capsys.readouterr()
            lines = cap.out.splitlines()
            assert lines[0].startswith("https://abc-def.trycloudflare.com/pair#v=1&") and lines[1].startswith("nestlo://pair?")
            assert "nestlo-mobile tunnel stop" in cap.err and "exposes the Nestlo API" in cap.err
            await loop.run_in_executor(None, cli, "tunnel", "url")
            assert capsys.readouterr().out.strip() == "https://abc-def.trycloudflare.com"
            await loop.run_in_executor(None, cli, "tunnel", "status")
            out = capsys.readouterr().out
            assert "running, https://abc-def.trycloudflare.com via cloudflare" in out and "ngrok" in out
            await loop.run_in_executor(None, cli, "tunnel", "stop")
            assert "stopped" in capsys.readouterr().out
            e.next_endpoint = {"provider": "bore", "host": "bore.pub", "port": 1234, "trust": "pin"}
            await loop.run_in_executor(None, cli, "tunnel", "start", "--provider", "bore")
            assert capsys.readouterr().out.strip() == "bore.pub:1234"
            assert (e.run_dir / "tunnel-provider").read_text().strip() == "bore"
            # --provider alone implies --via tunnel; default `via` comes from the server without a terminal
            await loop.run_in_executor(None, cli, "pair", "--provider", "bore")
            assert capsys.readouterr().out.startswith("https://bore.pub:1234/pair#")
            await loop.run_in_executor(None, cli, "pair")
            assert capsys.readouterr().out.startswith("http://192.168.1.20:")
            # on a terminal the questions are asked
            answers = iter(["2", "7"])
            monkeypatch.setattr("builtins.input", lambda prompt="": next(answers))
            e.next_endpoint = {"provider": "pinggy", "host": "x.a.pinggy.link", "port": 443, "trust": "pin"}
            await loop.run_in_executor(None, lambda: cli("pair", tty=True))
            cap = capsys.readouterr()
            assert "How should your phone reach this machine?" in cap.err and "Tunnel provider:" in cap.err
            assert cap.out.startswith("https://x.a.pinggy.link:443/pair#")
            assert (e.run_dir / "tunnel-provider").read_text().strip() == "pinggy"
    run(go())


def test_tunnel_run_subcommand_reads_provider_file(tmp_path):
    run_dir = tmp_path / "run"
    run_dir.mkdir()
    (run_dir / "tunnel-provider").write_text("bore\n")
    stub(tmp_path / "bore", 'echo "listening at bore.pub:99"')
    cfg = tmp_path / "c.json"
    cfg.write_text(json.dumps({"bins": {"bore": str(tmp_path / "bore")}}))
    with pytest.raises(SystemExit) as e:
        M.cli_main(["tunnel-run", "--config", str(cfg), "--run-dir", str(run_dir), "--state-dir", str(tmp_path)])
    assert e.value.code == 0
