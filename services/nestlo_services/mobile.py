"""Nestlo mobile server: the machine side of the phone app (docs/mobile-protocol.md).

One asyncio process serves HTTPS and WebSocket on one port (default 7443):

  pairing        `nestlo-mobile pair` asks this process, over the admin unix
                 socket, for a single-use code; the phone redeems it at
                 POST /v1/pair and gets a device token. Codes and tokens are
                 kept as SHA-256 only.
  REST           overview, agents, requests, kill, approvals, sessions,
                 devices (data comes from the Dashboard class of the web
                 dashboard and from the orchestrator's approval queue)
  /v1/events     agent, spend and approval changes, polled every 2 s
  /v1/term       a pseudo-terminal: a user's login shell or a TUIOS session
  /v1/desktop    WebSocket <-> TCP bridge to the local wayvnc, plus the
                 static noVNC client under /desktop/

TLS uses a self-signed ECDSA P-256 certificate generated on first start. The
app pins its SHA-256 fingerprint (taken from the pairing QR code), so there is
no CA and no host name check. The HTTP and WebSocket (RFC 6455) code here is
small on purpose: only what the protocol needs, no dependencies.

The process runs as root: it starts terminals as other users with runuser and
stops agents. Everything else about it is locked down by the systemd unit.
A terminal gives whoever holds a paired phone a full shell as that user, which
is why only users on the allowlist can be opened and every open is audited.
"""

import argparse
import asyncio
import base64
import contextlib
import datetime
import fcntl
import grp
import hashlib
import hmac
import html
import http.cookies
import ipaddress
import json
import logging
import mimetypes
import os
import pty
import re
import secrets
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import termios
import time
import urllib.parse
import urllib.request

from . import audit as auditmod
from . import config as configmod
from . import mobile_tunnel as tunnels
from .mobile_tunnel import parse_tunnel_url, write_text_atomic  # noqa: F401

log = logging.getLogger("nestlo.mobile")

PROTOCOL = 1
DEFAULT_PORT = 7443
DEFAULT_STATE_DIR = "/var/lib/nestlo-mobile"
DEFAULT_ADMIN_SOCKET = "/run/nestlo-mobile/admin.sock"
DEFAULT_TTL = 300
MAX_BODY = 64 * 1024
MAX_WS_MESSAGE = 1024 * 1024
MAX_TERMINALS_PER_DEVICE = 8
PAIR_FAIL_LIMIT = 10
PAIR_FAIL_WINDOW = 600
POLL_SEC = 2.0
PING_SEC = 20.0
LAST_SEEN_GRANULARITY = 30.0
COOKIE = "nestlo_mobile"
WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
STATUSES = ("working", "blocked", "idle", "done", "failed", "killed")

_USER_RE = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")
_SESSION_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_DEVICE_RE = re.compile(r"^d_[0-9a-f]{12}$")


class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# ── small helpers ───────────────────────────────────────────────────────────
def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def sha256_hex(text):
    return hashlib.sha256(text.encode()).hexdigest()


def iso(ts):
    """ISO 8601 UTC string for a Unix time (numbers and numeric strings), else ''."""
    try:
        return datetime.datetime.fromtimestamp(float(ts), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def version():
    try:
        from importlib import metadata
        return metadata.version("nestlo-services")
    except Exception:
        return "0.5.0"


def write_json_atomic(path, obj, mode=0o600):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(obj, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


# ── TLS certificate ─────────────────────────────────────────────────────────
def ensure_cert(tls_dir, hostname):
    """(cert_path, key_path); creates a 10 year ECDSA P-256 self-signed pair when missing."""
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    cert_path, key_path = os.path.join(tls_dir, "cert.pem"), os.path.join(tls_dir, "key.pem")
    if os.path.exists(cert_path) and os.path.exists(key_path):
        return cert_path, key_path
    os.makedirs(tls_dir, mode=0o700, exist_ok=True)
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, (hostname or "nestlo")[:64])])
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
               .serial_number(x509.random_serial_number())
               .not_valid_before(now - datetime.timedelta(days=1))
               .not_valid_after(now + datetime.timedelta(days=3650))
               .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True))
    cert = builder.sign(key, hashes.SHA256())
    key_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key_pem)
    with open(cert_path, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))
    return cert_path, key_path


def fingerprint(cert_path):
    """base64url (no padding) SHA-256 over the DER encoding of the certificate."""
    with open(cert_path) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    return b64url(hashlib.sha256(der).digest())


# ── addresses ───────────────────────────────────────────────────────────────
def local_addresses(run=subprocess.run):
    """Non-loopback, non link-local addresses of this machine (IPv4 first)."""
    v4, v6 = [], []
    try:
        out = run(["ip", "-j", "addr"], capture_output=True, text=True, timeout=5)
        for ifc in json.loads(out.stdout or "[]"):
            for a in ifc.get("addr_info", []):
                addr = a.get("local", "")
                if not addr or a.get("scope") != "global":
                    continue
                (v4 if a.get("family") == "inet" else v6).append(addr)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    if not v4 and not v6:           # no `ip`: ask the routing table instead
        for family, probe in ((socket.AF_INET, "192.0.2.1"), (socket.AF_INET6, "2001:db8::1")):
            try:
                with socket.socket(family, socket.SOCK_DGRAM) as s:
                    s.connect((probe, 9))
                    addr = s.getsockname()[0]
                if addr and not addr.startswith(("127.", "::1", "fe80")):
                    (v4 if family == socket.AF_INET else v6).append(addr)
            except OSError:
                pass
    return list(dict.fromkeys(v4 + v6))



# ── hosts for the pairing URL ───────────────────────────────────────────────
ONBOARDING_PORT = 7080
APP_PACKAGE = "dev.nestlo.app"
APK_FALLBACK = "https://github.com/anubhavg-icpl/nestlo/releases/latest/download/nestlo-android.apk"
# RFC 1918, ULA (fc00::/7) and 100.64.0.0/10 (Tailscale, carrier-grade NAT)
_PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
                                               "100.64.0.0/10")]


def is_private(addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip.version == n.version and ip in n for n in _PRIVATE)


def lookup_public_ip(timeout=3, opener=urllib.request.urlopen):
    """The machine's public address from api.ipify.org, or None (failure is tolerated)."""
    try:
        with opener("https://api.ipify.org", timeout=timeout) as resp:
            text = resp.read(64).decode().strip()
        return str(ipaddress.ip_address(text))
    except Exception:
        return None


def order_hosts(addrs, hostname, domain="", advertised=(), public_host="", public_ip=None, first=()):
    """(hosts, entry host) in protocol order: domain, advertised hosts, private
    addresses, public host / public IP, host name, localhost. `first` (Tailscale
    names) goes in front of everything."""
    private = [a for a in addrs if is_private(a)]
    public = [a for a in addrs if not is_private(a)]
    hosts = list(first) + [domain] + list(advertised) + private + [public_host, public_ip] + public + [hostname, "localhost"]
    hosts = [h for h in dict.fromkeys(hosts) if h and h != "localhost"] + ["localhost"]
    entry = domain or public_host or (private[0] if private else "") or (hostname or "localhost")
    return hosts, entry


def _script_hash(script):
    return "sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()


_PAIR_SCRIPT = """
(function () {
  var p = location.hash.replace(/^#/, "");
  var msg = document.getElementById("msg");
  var open = document.getElementById("open");
  if (!p || p.indexOf("code=") < 0) { msg.textContent = "NO PAIRING DATA. SCAN THE QR CODE FROM nestlo-mobile pair."; open.style.display = "none"; return; }
  var fallback = location.origin + "/app";
  var intent = "intent://pair?" + p + "#Intent;scheme=nestlo;package=dev.nestlo.app;S.browser_fallback_url=" + encodeURIComponent(fallback) + ";end";
  open.href = intent;
  var seen = false;
  try { seen = sessionStorage.getItem("nestlo-tried") === "1"; sessionStorage.setItem("nestlo-tried", "1"); } catch (e) {}
  if (!seen) { location.href = intent; }
})();
"""

_STYLE = ("body{margin:0;background:#000;color:#fff;font-family:ui-monospace,Menlo,Consolas,monospace;"
          "min-height:100vh;display:flex;align-items:center;justify-content:center}"
          "main{width:100%;max-width:420px;padding:32px 16px;box-sizing:border-box}"
          "h1{font-size:14px;letter-spacing:.3em;font-weight:400;margin:0 0 32px;color:#bbb}"
          "p,li{font-size:14px;line-height:1.6;color:#ddd}"
          "a.btn{display:block;text-align:center;padding:16px;margin:12px 0;border:1px solid #fff;color:#fff;"
          "text-decoration:none;letter-spacing:.2em;font-size:14px;border-radius:999px}"
          "a.btn.solid{background:#fff;color:#000}"
          "code{word-break:break-all;color:#fff}")


def pair_page():
    return ("<!doctype html><html lang=en><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'><title>Nestlo pairing</title>"
            "<style>%s</style><main><h1>NESTLO</h1><p id=msg>PAIR THIS PHONE WITH YOUR NESTLO MACHINE.</p>"
            "<a class='btn solid' id=open href='/app'>OPEN NESTLO</a>"
            "<a class=btn href='/app'>GET THE APP</a></main><script>%s</script></html>" % (_STYLE, _PAIR_SCRIPT))


def app_page(local_sha256=None):
    link = "/app/nestlo.apk" if local_sha256 else APK_FALLBACK
    sha = ("<p>SHA-256 of this file:<br><code>%s</code></p>" % html.escape(local_sha256)) if local_sha256 else ""
    return ("<!doctype html><html lang=en><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'><title>Get Nestlo</title>"
            "<style>%s</style><main><h1>GET NESTLO</h1>"
            "<a class='btn solid' href='%s'>DOWNLOAD APK</a>%s"
            "<ol><li>Open the downloaded file.</li>"
            "<li>If Android asks, allow your browser to install unknown apps (Settings, Apps, Special access, "
            "Install unknown apps).</li><li>Install, then go back to the pairing page and tap OPEN NESTLO, "
            "or scan the QR code again.</li></ol></main></html>" % (_STYLE, html.escape(link, quote=True), sha))


ONBOARDING_CSP = ("default-src 'none'; style-src 'unsafe-inline'; script-src '%s'; base-uri 'none'; "
                  "form-action 'none'; frame-ancestors 'none'" % _script_hash(_PAIR_SCRIPT))
APP_CSP = "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"



# ── tunnels and Tailscale ───────────────────────────────────────────────────
VIAS = ("lan", "tunnel", "tailscale", "url")
DEFAULT_TUNNEL_DIR = "/run/nestlo-mobile"
def tailscale_hosts(run=subprocess.run):
    """[MagicDNS name, 100.x address] of this machine when Tailscale is up, else []."""
    try:
        res = run(["tailscale", "status", "--json"], capture_output=True, text=True, timeout=5)
        st = json.loads(res.stdout or "{}")
    except (OSError, ValueError, subprocess.SubprocessError):
        return []
    if st.get("BackendState") != "Running":
        return []
    me = st.get("Self") or {}
    name = str(me.get("DNSName") or "").rstrip(".")
    ips = [i for i in me.get("TailscaleIPs") or [] if isinstance(i, str)]
    ips.sort(key=lambda i: ":" in i)                      # IPv4 first
    return [h for h in dict.fromkeys([name] + ips[:1]) if h]


def parse_choice(text, default="lan"):
    """The `via` for an answer to the interactive question (a number, a name or empty)."""
    t = (text or "").strip().lower()
    if not t:
        return default
    if t.isdigit() and 1 <= int(t) <= len(VIAS):
        return VIAS[int(t) - 1]
    aliases = {"quick": "tunnel", "cloudflare": "tunnel", "ts": "tailscale", "own": "url", "network": "lan"}
    t = aliases.get(t, t)
    return t if t in VIAS else None


# ── device and pairing state ────────────────────────────────────────────────
class DeviceStore:
    """Paired devices in a JSON file; only sha256(token) is stored."""

    def __init__(self, path, clock=time.time):
        self.path = path
        self.clock = clock
        self.devices = {}
        self._seen_written = {}
        self.load()

    def load(self):
        try:
            with open(self.path) as f:
                data = json.load(f)
            self.devices = dict(data.get("devices", {}))
        except (OSError, ValueError, AttributeError):
            self.devices = {}

    def save(self):
        write_json_atomic(self.path, {"version": 1, "devices": self.devices})

    def add(self, name, model):
        device_id = "d_" + secrets.token_hex(6)
        token = b64url(secrets.token_bytes(32))
        now = iso(self.clock())
        self.devices[device_id] = {
            "device_id": device_id, "device_name": name, "device_model": model,
            "paired_at": now, "last_seen": now, "token_sha256": sha256_hex(token),
        }
        self.save()
        return device_id, token

    def by_token(self, token):
        if not token:
            return None
        digest = sha256_hex(token)
        for dev in self.devices.values():
            if hmac.compare_digest(dev["token_sha256"], digest):
                return dev
        return None

    def touch(self, device_id):
        now = self.clock()
        if now - self._seen_written.get(device_id, 0) < LAST_SEEN_GRANULARITY:
            return
        dev = self.devices.get(device_id)
        if dev is None:
            return
        self._seen_written[device_id] = now
        dev["last_seen"] = iso(now)
        try:
            self.save()
        except OSError as exc:
            log.warning("could not save last_seen: %s", exc)

    def revoke(self, device_id):
        if self.devices.pop(device_id, None) is None:
            return False
        self.save()
        return True

    def public(self, current=None):
        out = []
        for dev in sorted(self.devices.values(), key=lambda d: d["paired_at"]):
            out.append({"device_id": dev["device_id"], "device_name": dev["device_name"],
                        "device_model": dev["device_model"], "paired_at": dev["paired_at"],
                        "last_seen": dev["last_seen"], "current": dev["device_id"] == current})
        return out


class Pairing:
    """Single-use pairing codes (kept as sha256, in memory) and the failure rate limit."""

    def __init__(self, clock=time.time, fail_limit=PAIR_FAIL_LIMIT, window=PAIR_FAIL_WINDOW):
        self.clock = clock
        self.fail_limit, self.window = fail_limit, window
        self.codes = {}          # sha256(code) -> expires (unix)
        self.fails = {}          # ip -> [unix times]

    def create(self, ttl):
        code = b64url(secrets.token_bytes(16))
        now = self.clock()
        self.codes = {h: e for h, e in self.codes.items() if e > now}
        self.codes[sha256_hex(code)] = now + ttl
        return code, now + ttl

    def limited(self, ip):
        now = self.clock()
        recent = [t for t in self.fails.get(ip, []) if now - t < self.window]
        if recent:
            self.fails[ip] = recent
        else:
            self.fails.pop(ip, None)
        return len(recent) >= self.fail_limit

    def redeem(self, code, ip):
        """True once for a valid code; raises HttpError(429) when `ip` failed too often."""
        if self.limited(ip):
            raise HttpError(429, "too many failed attempts, try again later")
        digest = sha256_hex(code) if isinstance(code, str) else ""
        expires = self.codes.pop(digest, None)
        if expires is not None and expires > self.clock():
            return True
        self.fails.setdefault(ip, []).append(self.clock())
        return False


# ── backend: the data behind the REST API ───────────────────────────────────
def map_status(state):
    """API status of a daemon agent record."""
    st = state.get("status")
    if st == "running":
        return "blocked" if state.get("blocked") or state.get("waiting_input") else "working"
    if st in STATUSES:
        return st
    if st == "exited":
        code = state.get("exit_code")
        return "failed" if isinstance(code, int) and code != 0 else "done"
    if st == "errored":
        return "failed"
    return "idle"


def agent_view(state):
    return {
        "id": state.get("id", ""),
        "agent": state.get("agent", ""),
        "workspace": state.get("workspace", ""),
        "status": map_status(state),
        "spend_usd": float(state.get("usd_today") or 0.0),
        "budget_usd": float(state.get("limit_usd") or 0.0),
        "started_at": iso(state.get("started_at")),
    }


def count_agents(agents):
    counts = {"total": len(agents), "working": 0, "blocked": 0, "idle": 0, "done": 0}
    for a in agents:
        if a["status"] in counts:
            counts[a["status"]] += 1
    return counts


class Backend:
    """Reads agents, spend and health through the dashboard's Dashboard class and
    the approval queue (tasks awaiting approval) from the orchestrator socket."""

    def __init__(self, dashboard, orchestrator_socket=None, terminal_users=(), tuios_bin="nestlo-tuios",
                 clock=time.time, run=subprocess.run, runner_env=None):
        self.dash = dashboard
        self.orch = orchestrator_socket
        self.terminal_users = list(terminal_users)
        self.tuios_bin = tuios_bin
        self.clock = clock
        self.run = run

    # -- agents
    def agents(self):
        _, snap = self.dash.agents({})
        out, seen = [], set()
        for state in list(snap.get("running", [])) + list(snap.get("history", [])):
            if state.get("id") in seen:
                continue
            seen.add(state.get("id"))
            out.append(agent_view(state))
        return out

    def spend(self):
        _, snap = self.dash.spend({})
        return {"today_usd": float(snap.get("global_usd") or 0.0),
                "budget_usd": float(snap.get("global_limit_usd") or 0.0)}

    def overview(self):
        _, health = self.dash.health({})
        services = health.get("services", {})
        return {"agents": count_agents(self.agents()), "spend": self.spend(),
                "health": {k: bool(services.get(k, {}).get("ok")) for k in ("redis", "gateway", "daemon")}}

    def snapshot(self):
        return {"agents": self.agents(), "spend": self.spend(), "approvals": self.approvals()}

    def requests(self, agent_id, limit):
        status, body = self.dash.requests({"agent": [agent_id], "limit": [str(limit)]})
        if status != 200:
            raise HttpError(status, body.get("error", "bad request"))
        out = []
        for e in body.get("requests", []):
            usage = e.get("usage") if isinstance(e.get("usage"), dict) else {}
            out.append({"ts": iso(e.get("ts")), "provider": e.get("provider", ""), "model": e.get("model") or "",
                        "input_tokens": int(usage.get("input_tokens") or 0),
                        "output_tokens": int(usage.get("output_tokens") or 0),
                        "cost_usd": float(e.get("cost_usd") or 0.0), "status": e.get("status", 0)})
        return out

    def kill(self, agent_id):
        """Stop a running agent like `nestlo kill`. Raises HttpError(404/409)."""
        if not configmod.valid_agent_id(agent_id):
            raise HttpError(404, "no such agent")
        path = os.path.join(self.dash.state_dir, agent_id + ".json")
        try:
            with open(path) as f:
                state = json.load(f)
        except (OSError, ValueError):
            raise HttpError(404, "no such agent")
        if state.get("status") != "running":
            raise HttpError(409, "agent %s is not running" % agent_id)
        unit, pid = state.get("unit"), state.get("pid")
        try:
            if unit:
                res = self.run(["systemctl", "stop", unit], capture_output=True, text=True, timeout=60)
                if res.returncode != 0:
                    raise HttpError(500, "could not stop %s" % unit)
            elif pid:
                os.kill(int(pid), signal.SIGTERM)
            else:
                raise HttpError(409, "agent %s has neither a unit nor a pid" % agent_id)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise HttpError(500, "could not stop agent: %s" % exc)
        state.update(status="killed", reason="stopped from the mobile app", ended_at=int(self.clock()))
        write_json_atomic(path, state, mode=0o664)
        return True

    # -- approvals: tasks awaiting approval in the orchestrator
    def approvals(self):
        if not self.orch:
            return []
        from . import unixapi
        try:
            status, body = unixapi.call(self.orch, "GET", "/tasks?status=awaiting_approval&limit=100", timeout=5)
        except OSError:
            return []
        if status != 200:
            return []
        out = []
        for t in body.get("tasks", []):
            prompt = " ".join(str(t.get("prompt", "")).split())
            summary = "%s in %s: %s" % (t.get("agent", "agent"), t.get("workspace", ""), prompt[:160])
            out.append({"id": t.get("id", ""), "kind": "task", "summary": summary,
                        "requested_by": t.get("submitted_by") or "", "created_at": iso(t.get("created_at"))})
        return out

    def decide(self, approval_id, decision, device_name):
        from . import unixapi
        if not self.orch:
            raise HttpError(404, "no approval queue")
        verb = "approve" if decision == "approve" else "reject"
        try:
            status, body = unixapi.call(self.orch, "POST", "/tasks/%s/%s" % (urllib.parse.quote(approval_id, safe=""), verb),
                                        {"note": "via mobile app (%s)" % device_name[:60]}, timeout=15)
        except OSError:
            raise HttpError(503, "the orchestrator is not reachable")
        if status >= 400:
            raise HttpError(status if status in (400, 403, 404, 409) else 502, body.get("error", "refused"))
        return True

    # -- terminals the phone may open
    def sessions(self):
        out = []
        for user in self.terminal_users:
            out.append({"id": "shell:" + user, "title": "%s shell" % user, "kind": "shell", "user": user})
            try:
                res = self.run([self.tuios_bin, "--user", user, "ls", "--json"], capture_output=True, text=True,
                               timeout=8)
                names = [s.get("name") for s in json.loads(res.stdout or "[]") if isinstance(s, dict)] \
                    if res.returncode == 0 else []
            except (OSError, ValueError, subprocess.SubprocessError):
                names = []
            for name in names:
                if isinstance(name, str) and _SESSION_RE.match(name):
                    out.append({"id": "tuios:%s:%s" % (user, name), "title": name, "kind": "tuios", "user": user})
        return out


# ── events ──────────────────────────────────────────────────────────────────
def diff_snapshots(old, new, now):
    """Events (protocol: agent, agent_gone, needs_input, approval, approval_done, spend)
    that turn snapshot `old` into `new`. `old` None means baseline: nothing is reported."""
    if old is None:
        return []
    events = []
    olda = {a["id"]: a for a in old["agents"]}
    newa = {a["id"]: a for a in new["agents"]}
    for aid, a in newa.items():
        before = olda.get(aid)
        if before != a:
            events.append({"type": "agent", "agent": a})
        if a["status"] == "blocked" and (before is None or before["status"] != "blocked"):
            events.append({"type": "needs_input", "id": aid, "agent": a["agent"], "workspace": a["workspace"],
                           "since": iso(now)})
    for aid in olda:
        if aid not in newa:
            events.append({"type": "agent_gone", "id": aid})
    if new["spend"] != old["spend"]:
        events.append(dict(type="spend", **new["spend"]))
    oldp = {a["id"]: a for a in old["approvals"]}
    newp = {a["id"]: a for a in new["approvals"]}
    for pid, p in newp.items():
        if pid not in oldp:
            events.append({"type": "approval", "approval": p})
    for pid in oldp:
        if pid not in newp:
            events.append({"type": "approval_done", "id": pid})
    return events


# ── HTTP ────────────────────────────────────────────────────────────────────
REASONS = {101: "Switching Protocols", 200: "OK", 302: "Found", 400: "Bad Request", 401: "Unauthorized",
           403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict",
           413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error",
           502: "Bad Gateway", 503: "Service Unavailable"}


class Request:
    def __init__(self, method, target, headers, body, peer, writer):
        self.method = method
        parts = urllib.parse.urlsplit(target)
        self.path = urllib.parse.unquote(parts.path)
        self.query = urllib.parse.parse_qs(parts.query)
        self.headers = headers
        self.body = body
        self.peer = peer
        self.writer = writer

    def bearer(self):
        scheme, _, value = self.headers.get("authorization", "").partition(" ")
        return value.strip() if scheme.lower() == "bearer" else ""

    def cookie(self):
        jar = http.cookies.SimpleCookie()
        with contextlib.suppress(http.cookies.CookieError):
            jar.load(self.headers.get("cookie", ""))
        morsel = jar.get(COOKIE)
        return morsel.value if morsel else ""

    def json(self):
        if not self.body:
            return {}
        try:
            obj = json.loads(self.body)
        except ValueError:
            raise HttpError(400, "request body is not valid JSON")
        if not isinstance(obj, dict):
            raise HttpError(400, "request body must be a JSON object")
        return obj

    def peer_ip(self):
        return self.peer[0] if isinstance(self.peer, tuple) else "unix"

    def client_ip(self):
        """Address for rate limiting. Behind cloudflared (a connection from loopback)
        the real client is in CF-Connecting-IP or X-Forwarded-For; from anywhere else
        those headers are the client's own claim and are ignored."""
        ip = self.peer_ip()
        if ip not in ("127.0.0.1", "::1"):
            return ip
        for name in ("cf-connecting-ip", "x-forwarded-for"):
            value = self.headers.get(name, "").split(",")[0].strip()
            try:
                return str(ipaddress.ip_address(value))
            except ValueError:
                continue
        return ip

    def qint(self, name, default, lo, hi):
        try:
            return max(lo, min(hi, int(self.query.get(name, [default])[0])))
        except (TypeError, ValueError):
            return default


async def read_request(reader, writer, peer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 30)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
        return None
    lines = head.decode("latin-1").split("\r\n")
    try:
        method, target, _ = lines[0].split(" ", 2)
    except ValueError:
        raise HttpError(400, "bad request line")
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, _, v = line.partition(":")
            headers[k.strip().lower()] = v.strip()
    try:
        length = int(headers.get("content-length") or 0)
    except ValueError:
        raise HttpError(400, "bad Content-Length")
    if length < 0 or length > MAX_BODY:
        raise HttpError(413, "request body too large")
    body = b""
    if length:
        try:
            body = await asyncio.wait_for(reader.readexactly(length), 30)
        except (asyncio.IncompleteReadError, asyncio.TimeoutError, ConnectionError):
            return None
    return Request(method, target, headers, body, peer, writer)


async def send_response(writer, status, body=b"", ctype="application/json", headers=()):
    lines = ["HTTP/1.1 %d %s" % (status, REASONS.get(status, "Status")),
             "Content-Type: " + ctype, "Content-Length: %d" % len(body), "Connection: close",
             "Cache-Control: no-store", "X-Content-Type-Options: nosniff"]
    lines += ["%s: %s" % h for h in headers]
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body)
    with contextlib.suppress(ConnectionError):
        await writer.drain()


async def send_json(writer, status, obj, headers=()):
    await send_response(writer, status, json.dumps(obj).encode(), headers=headers)


# ── WebSocket (RFC 6455) ────────────────────────────────────────────────────
OP_CONT, OP_TEXT, OP_BIN, OP_CLOSE, OP_PING, OP_PONG = 0, 1, 2, 8, 9, 10


def accept_key(key):
    return base64.b64encode(hashlib.sha1(key.encode() + WS_GUID).digest()).decode()


class WebSocket:
    """One end of a WebSocket. `mask` is True for the client side."""

    def __init__(self, reader, writer, mask=False, max_size=MAX_WS_MESSAGE):
        self.reader, self.writer, self.mask, self.max_size = reader, writer, mask, max_size
        self.closed = False
        self.close_code = None

    async def _frame(self, opcode, payload):
        first = 0x80 | opcode
        n = len(payload)
        key = secrets.token_bytes(4) if self.mask else b""
        flag = 0x80 if self.mask else 0
        if n < 126:
            head = struct.pack("!BB", first, flag | n)
        elif n < 65536:
            head = struct.pack("!BBH", first, flag | 126, n)
        else:
            head = struct.pack("!BBQ", first, flag | 127, n)
        if self.mask:
            payload = _xor(payload, key)
        self.writer.write(head + key + payload)
        await self.writer.drain()

    async def send(self, data):
        if self.closed:
            raise ConnectionError("websocket closed")
        if isinstance(data, str):
            await self._frame(OP_TEXT, data.encode())
        else:
            await self._frame(OP_BIN, bytes(data))

    async def close(self, code=1000, reason=""):
        if self.closed:
            return
        self.closed = True
        with contextlib.suppress(ConnectionError, OSError):
            await self._frame(OP_CLOSE, struct.pack("!H", code) + reason.encode()[:100])

    async def _read_frame(self):
        b1, b2 = await self.reader.readexactly(2)
        fin, opcode = bool(b1 & 0x80), b1 & 0x0F
        masked, n = bool(b2 & 0x80), b2 & 0x7F
        if n == 126:
            (n,) = struct.unpack("!H", await self.reader.readexactly(2))
        elif n == 127:
            (n,) = struct.unpack("!Q", await self.reader.readexactly(8))
        if n > self.max_size:
            raise ValueError("frame too large")
        key = await self.reader.readexactly(4) if masked else b""
        data = await self.reader.readexactly(n) if n else b""
        if masked:
            data = _xor(data, key)
        return fin, opcode, data

    async def recv(self):
        """(opcode, payload) of the next text/binary message; None once closed."""
        msg_op, parts, size = None, [], 0
        while True:
            try:
                fin, op, data = await self._read_frame()
            except (asyncio.IncompleteReadError, ConnectionError, OSError, ValueError):
                self.closed = True
                return None
            if op == OP_PING:
                with contextlib.suppress(ConnectionError, OSError):
                    await self._frame(OP_PONG, data)
                continue
            if op == OP_PONG:
                continue
            if op == OP_CLOSE:
                self.close_code = struct.unpack("!H", data[:2])[0] if len(data) >= 2 else 1005
                await self.close(self.close_code if self.close_code != 1005 else 1000)
                return None
            if op in (OP_TEXT, OP_BIN):
                msg_op, parts, size = op, [data], len(data)
            elif op == OP_CONT and msg_op is not None:
                parts.append(data)
                size += len(data)
            else:
                await self.close(1002)
                return None
            if size > self.max_size:
                await self.close(1009)
                return None
            if fin:
                payload = b"".join(parts)
                if msg_op == OP_TEXT:
                    try:
                        payload.decode()
                    except UnicodeDecodeError:
                        await self.close(1007)
                        return None
                return msg_op, payload


def _xor(data, key):
    if not data:
        return data
    mask = (key * (len(data) // 4 + 1))[:len(data)]
    return (int.from_bytes(data, "big") ^ int.from_bytes(mask, "big")).to_bytes(len(data), "big")


async def accept_websocket(req, protocols=("binary",)):
    """Complete the server handshake; returns the WebSocket."""
    h = req.headers
    key = h.get("sec-websocket-key", "")
    if "websocket" not in h.get("upgrade", "").lower() or "upgrade" not in h.get("connection", "").lower() or not key:
        raise HttpError(400, "a WebSocket upgrade is required")
    lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade",
             "Sec-WebSocket-Accept: " + accept_key(key)]
    offered = [p.strip() for p in h.get("sec-websocket-protocol", "").split(",") if p.strip()]
    for p in offered:
        if p in protocols:
            lines.append("Sec-WebSocket-Protocol: " + p)
            break
    req.writer.write(("\r\n".join(lines) + "\r\n\r\n").encode())
    await req.writer.drain()
    return WebSocket(req.reader_obj, req.writer)


async def ws_connect(host, port, path, headers=None, ssl_context=None, protocols=()):
    """Client side of the handshake (used by tests and by the VM test).
    Returns (WebSocket, response headers); raises HttpError on a non-101 answer."""
    reader, writer = await asyncio.open_connection(host, port, ssl=ssl_context)
    key = base64.b64encode(secrets.token_bytes(16)).decode()
    lines = ["GET %s HTTP/1.1" % path, "Host: %s:%d" % (host, port), "Upgrade: websocket",
             "Connection: Upgrade", "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13"]
    if protocols:
        lines.append("Sec-WebSocket-Protocol: " + ", ".join(protocols))
    lines += ["%s: %s" % kv for kv in (headers or {}).items()]
    writer.write(("\r\n".join(lines) + "\r\n\r\n").encode())
    await writer.drain()
    head = (await reader.readuntil(b"\r\n\r\n")).decode("latin-1").split("\r\n")
    status = int(head[0].split(" ", 2)[1])
    resp = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in head[1:] if ":" in ln)}
    if status != 101:
        length = int(resp.get("content-length") or 0)
        body = await reader.readexactly(length) if length else b""
        writer.close()
        try:
            msg = json.loads(body).get("error", "")
        except (ValueError, AttributeError):
            msg = body.decode(errors="replace")
        raise HttpError(status, msg)
    if resp.get("sec-websocket-accept") != accept_key(key):
        writer.close()
        raise HttpError(502, "bad Sec-WebSocket-Accept")
    return WebSocket(reader, writer, mask=True), resp


# ── the server ──────────────────────────────────────────────────────────────
class Options:
    def __init__(self, **kw):
        self.name = socket.gethostname()
        self.state_dir = DEFAULT_STATE_DIR
        self.listen = "0.0.0.0"
        self.port = DEFAULT_PORT
        self.admin_socket = DEFAULT_ADMIN_SOCKET
        self.admin_group = "wheel"
        self.terminal_users = []
        self.desktop_dir = None             # directory with noVNC; None: no desktop feature
        self.desktop_addr = ("127.0.0.1", 5900)
        self.advertise_hosts = []
        self.domain = ""
        self.public_host = ""
        self.public_url = ""
        self.discover_public_ip = False
        self.onboarding_port = None         # plain-HTTP landing pages; None: off, 0: any free port
        self.onboarding_apk = None
        self.tunnel_unit = None             # systemd unit of the tunnel; None: no tunnel configured
        self.tunnel_dir = DEFAULT_TUNNEL_DIR
        self.tunnel_config = None           # JSON written by the module: providers and binaries
        self.connect_default = "lan"
        self.approvals = False
        self.runuser = "runuser"
        self.tuios_bin = "nestlo-tuios"
        self.poll_sec = POLL_SEC
        self.ping_sec = PING_SEC
        self.__dict__.update(kw)


class Server:
    def __init__(self, opts, backend, audit=None, clock=time.time):
        self.opts = opts
        self.backend = backend
        self.audit = audit or auditmod.NullClient()
        self.clock = clock
        self.devices = DeviceStore(os.path.join(opts.state_dir, "devices.json"), clock)
        self.pairing = Pairing(clock)
        self.started = clock()
        self.cert_path = self.key_path = self.fp = None
        self.servers = []
        self.port = opts.port
        self.conns = {}              # device_id -> {asyncio.Task}
        self.terminals = {}          # device_id -> count
        self.subscribers = set()     # asyncio.Queue of event dicts
        self._bg = set()
        self.public_ip_lookup = lookup_public_ip
        self.tailscale_lookup = tailscale_hosts
        self.systemctl = lambda *a: subprocess.run(["systemctl", *a], capture_output=True, text=True, timeout=30)
        self.onboarding_actual = None
        self._apk_sha = (None, None)
        self._poller = None
        self.nixos = _nixos_version()

    # -- lifecycle
    async def start(self):
        o = self.opts
        self.cert_path, self.key_path = ensure_cert(os.path.join(o.state_dir, "tls"), o.name)
        self.fp = fingerprint(self.cert_path)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(self.cert_path, self.key_path)
        srv = await asyncio.start_server(self._client(self.handle), o.listen, o.port, ssl=ctx)
        self.port = srv.sockets[0].getsockname()[1]
        self.servers.append(srv)
        if o.onboarding_port is not None:
            ob = await asyncio.start_server(self._client(self.handle_onboarding), o.listen, o.onboarding_port)
            self.onboarding_actual = ob.sockets[0].getsockname()[1]
            self.servers.append(ob)
        if o.admin_socket:
            self.servers.append(await self._start_admin())
        log.info("listening on %s:%d (fingerprint %s)", o.listen, self.port, self.fp)

    async def _start_admin(self):
        path = self.opts.admin_socket
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path)
        old = os.umask(0o117)
        try:
            srv = await asyncio.start_unix_server(self._client(self.handle_admin), path)
        finally:
            os.umask(old)
        try:
            gid = grp.getgrnam(self.opts.admin_group).gr_gid if self.opts.admin_group else -1
            os.chown(path, -1, gid)
        except (KeyError, PermissionError, OSError) as exc:
            log.warning("admin socket group %r not applied: %s", self.opts.admin_group, exc)
        os.chmod(path, 0o660)
        return srv

    async def stop(self):
        for task in [t for ts in self.conns.values() for t in ts]:
            task.cancel()
        if self._poller:
            self._poller.cancel()
        for srv in self.servers:
            srv.close()
        for srv in self.servers:
            with contextlib.suppress(Exception):
                await srv.wait_closed()

    def _client(self, handler):
        async def run(reader, writer):
            peer = writer.get_extra_info("peername")
            try:
                req = await read_request(reader, writer, peer)
                if req is not None:
                    req.reader_obj = reader
                    await handler(req)
            except HttpError as exc:
                with contextlib.suppress(Exception):
                    await send_json(writer, exc.status, {"error": exc.message})
            except (ConnectionError, asyncio.CancelledError, ssl.SSLError, OSError):
                pass
            except Exception:
                log.exception("request failed")
                with contextlib.suppress(Exception):
                    await send_json(writer, 500, {"error": "internal error"})
            finally:
                with contextlib.suppress(Exception):
                    writer.close()
        return run

    async def blocking(self, fn, *args):
        return await asyncio.get_running_loop().run_in_executor(None, fn, *args)

    # -- advertised addresses and URIs
    async def hosts(self):
        """(hosts, entry host) for pairing URLs, in protocol order."""
        o = self.opts
        addrs = await self.blocking(local_addresses)
        ts = await self.blocking(self.tailscale_lookup)
        public_ip = await self.blocking(self.public_ip_lookup) if o.discover_public_ip else None
        return order_hosts(addrs, socket.gethostname(), o.domain, o.advertise_hosts, o.public_host, public_ip,
                           first=ts)

    def tunnel_config_data(self):
        try:
            with open(self.opts.tunnel_config) as f:
                return json.load(f)
        except (OSError, ValueError, TypeError):
            return {}

    def read_tunnel(self):
        """The published tunnel endpoint (tunnel.json) or None."""
        try:
            with open(os.path.join(self.opts.tunnel_dir, "tunnel.json")) as f:
                ep = json.load(f)
        except (OSError, ValueError):
            return None
        ok = isinstance(ep, dict) and (str(ep.get("url", "")).startswith("https://") or
                                       (ep.get("host") and isinstance(ep.get("port"), int)))
        return ep if ok else None

    def tunnel_providers(self):
        return tunnels.provider_table(self.tunnel_config_data())

    async def tunnel_start(self, provider=None, timeout=60):
        o = self.opts
        if not o.tunnel_unit:
            raise HttpError(409, "no tunnel is configured (nestlo.mobile.tunnel.enable)")
        cfg = self.tunnel_config_data()
        provider = provider or cfg.get("default") or tunnels.DEFAULT_PROVIDER
        if provider == "tailscale":
            raise HttpError(400, "tailscale needs no tunnel process: use --via tailscale")
        if provider not in tunnels.PROVIDERS:
            raise HttpError(400, "unknown tunnel provider %r (known: %s)" % (provider, ", ".join(tunnels.LISTED)))
        row = [r for r in self.tunnel_providers() if r["name"] == provider][0]
        if not row["configured"]:
            raise HttpError(409, "provider %s is not configured (see nestlo.mobile.tunnel.providers.%s)"
                            % (provider, provider))
        cur = self.read_tunnel()
        status = await self.tunnel_status()
        if cur and status["active"] and cur.get("provider") == provider:
            return cur
        err_path = os.path.join(o.tunnel_dir, "tunnel-error")
        write_text_atomic(os.path.join(o.tunnel_dir, "tunnel-provider"), provider + "\n", 0o644)
        with contextlib.suppress(OSError):
            os.unlink(err_path)
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(o.tunnel_dir, "tunnel.json"))
        res = await self.blocking(self.systemctl, "restart", o.tunnel_unit)
        if res.returncode != 0:
            raise HttpError(500, "could not start %s: %s" % (o.tunnel_unit, (res.stderr or "").strip()[:200]))
        end = time.monotonic() + timeout
        while True:
            ep = self.read_tunnel()
            if ep:
                return ep
            try:
                with open(err_path) as f:
                    raise HttpError(502, "the %s tunnel failed:\n%s" % (provider, f.read().strip()))
            except OSError:
                pass
            if time.monotonic() >= end:
                raise HttpError(504, "the tunnel did not report an endpoint within %d seconds (journalctl -u %s)"
                                % (timeout, o.tunnel_unit))
            await asyncio.sleep(0.25)

    async def tunnel_status(self):
        o = self.opts
        if not o.tunnel_unit:
            return {"configured": False, "active": False, "endpoint": None, "providers": []}
        res = await self.blocking(self.systemctl, "is-active", o.tunnel_unit)
        return {"configured": True, "active": res.stdout.strip() == "active", "endpoint": self.read_tunnel(),
                "default": self.tunnel_config_data().get("default", tunnels.DEFAULT_PROVIDER),
                "providers": self.tunnel_providers()}

    def features(self):
        feats = ["agents"]
        if self.opts.terminal_users:
            feats.append("terminal")
        if self.opts.desktop_dir:
            feats.append("desktop")
        if self.opts.approvals:
            feats.append("approvals")
        return feats

    def pair_params(self, code, hosts, urls=()):
        q = [("v", PROTOCOL), ("name", self.opts.name), ("port", self.port), ("fp", self.fp), ("code", code)]
        q += [("url", u) for u in urls] + [("host", h) for h in hosts]
        return urllib.parse.urlencode(q, quote_via=urllib.parse.quote)

    def pair_uri(self, code, hosts, urls=()):
        return "nestlo://pair?" + self.pair_params(code, hosts, urls)

    def pair_url(self, code, hosts, entry, urls=(), base=None):
        """The URL in the QR code: the landing page with the parameters in the fragment."""
        o = self.opts
        if base:
            pass
        elif o.public_url:
            base = o.public_url
        elif o.onboarding_port is not None:
            base = "http://%s:%d" % (_bracket(entry), self.onboarding_actual or o.onboarding_port)
        else:
            return None
        return "%s/pair#%s" % (base.rstrip("/"), self.pair_params(code, hosts, urls))

    # -- auth
    def authenticate(self, req, cookie_ok=False):
        token = req.bearer()
        if not token and cookie_ok:
            token = req.cookie()
        dev = self.devices.by_token(token)
        if dev is None:
            raise HttpError(401, "unauthorized")
        self.devices.touch(dev["device_id"])
        return dev

    def track(self, device_id):
        task = asyncio.current_task()
        self.conns.setdefault(device_id, set()).add(task)
        return task

    def untrack(self, device_id, task):
        ts = self.conns.get(device_id)
        if ts:
            ts.discard(task)
            if not ts:
                self.conns.pop(device_id, None)

    def revoke(self, device_id, by):
        if not self.devices.revoke(device_id):
            return False
        for task in list(self.conns.get(device_id, ())):
            task.cancel()
        self.audit.emit("mobile.revoke", by, device_id=device_id)
        return True

    # -- routing (phone side)
    async def handle(self, req):
        p, m = req.path, req.method
        if p == "/v1/pair":
            if m != "POST":
                raise HttpError(405, "method not allowed")
            return await self.pair(req)
        if p in ("/pair", "/pair/", "/app", "/app/", "/app/nestlo.apk"):
            return await self.handle_onboarding(req)        # one port (and one tunnel) carries everything
        if p == "/desktop" or p.startswith("/desktop/"):
            return await self.desktop_static(req)
        if not p.startswith("/v1/"):
            raise HttpError(404, "not found")
        dev = self.authenticate(req, cookie_ok=(p == "/v1/desktop"))
        writer = req.writer
        if p == "/v1/events":
            return await self.events(req, dev)
        if p == "/v1/term":
            return await self.terminal(req, dev)
        if p == "/v1/desktop":
            return await self.desktop_bridge(req, dev)
        status, obj = await self.rest(req, dev)
        await send_json(writer, status, obj)

    async def rest(self, req, dev):
        p, m = req.path, req.method
        parts = [x for x in p.split("/") if x][1:]          # after "v1"
        b = self.backend
        if parts == ["info"] and m == "GET":
            return 200, {"name": self.opts.name, "version": version(), "nixos": self.nixos,
                         "uptime_s": _uptime(), "features": self.features()}
        if parts == ["overview"] and m == "GET":
            return 200, await self.backend_call(b.overview)
        if parts == ["agents"] and m == "GET":
            return 200, await self.backend_call(b.agents)
        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "requests" and m == "GET":
            return 200, await self.backend_call(b.requests, parts[1], req.qint("limit", 50, 1, 500))
        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "kill" and m == "POST":
            await self.backend_call(b.kill, parts[1])
            self.audit.emit("agent.kill", dev["device_name"], agent=parts[1], reason="mobile app",
                            device_id=dev["device_id"])
            return 200, {"ok": True}
        if parts == ["approvals"] and m == "GET":
            return 200, (await self.backend_call(b.approvals)) if self.opts.approvals else []
        if len(parts) == 2 and parts[0] == "approvals" and m == "POST":
            if not self.opts.approvals:
                raise HttpError(404, "this machine has no approval queue")
            decision = req.json().get("decision")
            if decision not in ("approve", "deny"):
                raise HttpError(400, 'decision must be "approve" or "deny"')
            await self.backend_call(b.decide, parts[1], decision, dev["device_name"])
            return 200, {"ok": True}
        if parts == ["sessions"] and m == "GET":
            return 200, await self.backend_call(b.sessions)
        if parts == ["devices"] and m == "GET":
            return 200, self.devices.public(dev["device_id"])
        if len(parts) == 2 and parts[0] == "devices" and m == "DELETE":
            if not self.revoke(parts[1], dev["device_name"]):
                raise HttpError(404, "no such device")
            return 200, {"ok": True}
        raise HttpError(404, "not found")

    async def backend_call(self, fn, *args):
        try:
            return await self.blocking(fn, *args)
        except HttpError:
            raise
        except Exception as exc:        # Redis down etc.: report, don't crash
            log.warning("%s failed: %s", getattr(fn, "__name__", fn), exc)
            raise HttpError(500, "%s: %s" % (type(exc).__name__, exc))

    # -- pairing
    async def pair(self, req):
        body = req.json()
        code = body.get("code")
        if not self.pairing.redeem(code if isinstance(code, str) else "", req.client_ip()):
            raise HttpError(403, "the pairing code is wrong, used or expired")
        name = str(body.get("device_name") or "phone")[:64]
        model = str(body.get("device_model") or "")[:64]
        device_id, token = self.devices.add(name, model)
        self.audit.emit("mobile.pair", name, stage="device", device_id=device_id, model=model, peer=req.client_ip())
        await send_json(req.writer, 200, {"device_id": device_id, "token": token, "server_name": self.opts.name,
                                          "server_version": version()})

    # -- admin socket (nestlo-mobile CLI)
    async def handle_admin(self, req):
        who = _peer_user(req.writer)
        p, m = req.path, req.method
        parts = [x for x in p.split("/") if x]
        if parts == ["pair"] and m == "POST":
            body = req.json()
            ttl = body.get("ttl", DEFAULT_TTL)
            if not isinstance(ttl, int) or isinstance(ttl, bool) or not 10 <= ttl <= 86400:
                raise HttpError(400, "ttl must be between 10 and 86400 seconds")
            via = body.get("via") or "lan"
            if via not in VIAS:
                raise HttpError(400, "via must be one of: " + ", ".join(VIAS))
            hosts, entry = await self.hosts()
            urls, base = [], None
            if via == "tunnel":
                ep = self.read_tunnel()
                if not ep:
                    raise HttpError(409, "the tunnel is not running (nestlo-mobile tunnel start)")
                if ep.get("url"):
                    base = ep["url"]
                    if not ep.get("landing_only"):
                        urls = [base]
                else:
                    tcp = fmt_host(ep["host"], ep["port"])
                    hosts = [tcp] + [h for h in hosts if h != tcp]
                    base = "https://" + tcp
            elif via == "tailscale":
                ts = await self.blocking(self.tailscale_lookup)
                if not ts:
                    raise HttpError(409, "tailscale is not installed or not up on this machine")
                entry = ts[0]
            elif via == "url":
                if not self.opts.public_url:
                    raise HttpError(409, "nestlo.mobile.publicUrl is not set")
                base = self.opts.public_url
                urls = [base.rstrip("/")]
            code, expires = self.pairing.create(ttl)
            self.audit.emit("mobile.pair", who, stage="code", ttl=ttl, via=via)
            return await send_json(req.writer, 200, {"uri": self.pair_uri(code, hosts, urls),
                                                     "url": self.pair_url(code, hosts, entry, urls, base),
                                                     "ttl": ttl, "via": via, "expires_at": iso(expires),
                                                     "hosts": hosts, "entry": entry})
        if parts == ["tunnel", "start"] and m == "POST":
            prov = req.json().get("provider")
            ep = await self.tunnel_start(prov if isinstance(prov, str) else None)
            self.audit.emit("mobile.pair", who, stage="tunnel-start", provider=ep.get("provider"))
            return await send_json(req.writer, 200, ep)
        if parts == ["tunnel", "stop"] and m == "POST":
            if not self.opts.tunnel_unit:
                raise HttpError(409, "no tunnel is configured (nestlo.mobile.tunnel.enable)")
            res = await self.blocking(self.systemctl, "stop", self.opts.tunnel_unit)
            if res.returncode != 0:
                raise HttpError(500, "could not stop the tunnel: %s" % (res.stderr or "").strip()[:200])
            self.audit.emit("mobile.pair", who, stage="tunnel-stop")
            return await send_json(req.writer, 200, {"ok": True})
        if parts == ["tunnel"] and m == "GET":
            return await send_json(req.writer, 200, await self.tunnel_status())
        if parts == ["devices"] and m == "GET":
            return await send_json(req.writer, 200, self.devices.public())
        if len(parts) == 2 and parts[0] == "devices" and m == "DELETE":
            if not self.revoke(parts[1], who):
                raise HttpError(404, "no such device")
            return await send_json(req.writer, 200, {"ok": True})
        if parts == ["url"] and m == "GET":
            hosts, _ = await self.hosts()
            return await send_json(req.writer, 200, {"name": self.opts.name, "port": self.port, "fp": self.fp,
                                                     "hosts": hosts, "default_via": self.opts.connect_default,
                                                     "tunnel": self.opts.tunnel_unit is not None,
                                                     "public_url": self.opts.public_url or None,
                                                     "urls": ["https://%s:%d" % (_bracket(h), self.port) for h in hosts]})
        raise HttpError(404, "not found")

    # -- plain-HTTP onboarding pages (no auth, nothing secret: the pairing data stays in the URL fragment)
    def _apk_digest(self):
        path = self.opts.onboarding_apk
        if not path:
            return None
        try:
            st = os.stat(path)
        except OSError:
            return None
        if self._apk_sha[0] != (st.st_mtime_ns, st.st_size):
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            self._apk_sha = ((st.st_mtime_ns, st.st_size), h.hexdigest())
        return self._apk_sha[1]

    async def handle_onboarding(self, req):
        if req.method not in ("GET", "HEAD"):
            raise HttpError(405, "method not allowed")
        sec = lambda csp: [("Content-Security-Policy", csp), ("Referrer-Policy", "no-referrer"),
                           ("X-Frame-Options", "DENY")]
        p = req.path.rstrip("/") or "/"
        if p == "/pair":
            return await send_response(req.writer, 200, pair_page().encode(), "text/html; charset=utf-8",
                                       sec(ONBOARDING_CSP))
        digest = await self.blocking(self._apk_digest)
        if p == "/app":
            return await send_response(req.writer, 200, app_page(digest).encode(), "text/html; charset=utf-8",
                                       sec(APP_CSP))
        if p == "/app/nestlo.apk" and digest:
            size = os.path.getsize(self.opts.onboarding_apk)
            head = ["HTTP/1.1 200 OK", "Content-Type: application/vnd.android.package-archive",
                    "Content-Length: %d" % size, "Content-Disposition: attachment; filename=nestlo.apk",
                    "Cache-Control: no-store", "Connection: close"]
            req.writer.write(("\r\n".join(head) + "\r\n\r\n").encode())
            if req.method == "GET":
                with open(self.opts.onboarding_apk, "rb") as f:
                    while True:
                        chunk = await self.blocking(f.read, 1 << 20)
                        if not chunk:
                            break
                        req.writer.write(chunk)
                        await req.writer.drain()
            return
        raise HttpError(404, "not found")

    # -- /v1/events
    def _subscribe(self):
        q = asyncio.Queue(maxsize=1000)
        self.subscribers.add(q)
        if self._poller is None or self._poller.done():
            self._poller = asyncio.ensure_future(self._poll_loop())
        return q

    def _unsubscribe(self, q):
        self.subscribers.discard(q)

    async def _poll_loop(self):
        prev = None
        while self.subscribers:
            try:
                snap = await self.blocking(self.backend.snapshot)
            except Exception as exc:
                log.debug("event poll failed: %s", exc)
                snap = None
            if snap is not None:
                for ev in diff_snapshots(prev, snap, self.clock()):
                    for q in list(self.subscribers):
                        with contextlib.suppress(asyncio.QueueFull):
                            q.put_nowait(ev)
                prev = snap
            await asyncio.sleep(self.opts.poll_sec)

    async def events(self, req, dev):
        ws = await accept_websocket(req)
        task = self.track(dev["device_id"])
        q = self._subscribe()
        reader = asyncio.ensure_future(self._drain_client(ws))
        try:
            await ws.send(json.dumps({"type": "hello", "server_name": self.opts.name, "version": version()}))
            while not reader.done():
                get = asyncio.ensure_future(q.get())
                done, _ = await asyncio.wait({get, reader}, timeout=self.opts.ping_sec,
                                             return_when=asyncio.FIRST_COMPLETED)
                if get in done:
                    await ws.send(json.dumps(get.result()))
                else:
                    get.cancel()
                    if reader.done():
                        break
                    await ws.send(json.dumps({"type": "ping"}))
        except (ConnectionError, OSError):
            pass
        finally:
            reader.cancel()
            self._unsubscribe(q)
            self.untrack(dev["device_id"], task)
            await ws.close()

    @staticmethod
    async def _drain_client(ws):
        while await ws.recv() is not None:
            pass

    # -- /v1/term
    def term_command(self, session):
        """(argv, user) for a session id; HttpError for invalid or not allowed ones."""
        kind, _, rest = session.partition(":")
        o = self.opts
        if kind == "shell":
            user, name = rest, None
        elif kind == "tuios":
            user, _, name = rest.partition(":")
            if not _SESSION_RE.match(name):
                raise HttpError(400, "invalid TUIOS session name")
        else:
            raise HttpError(400, "unknown session")
        if not _USER_RE.match(user):
            raise HttpError(400, "invalid user name")
        if user not in o.terminal_users:
            raise HttpError(403, "terminals of %s are not enabled" % user)
        if kind == "shell":
            return [o.runuser, "-l", user], user
        return [o.tuios_bin, "--user", user, "attach", name], user

    async def terminal(self, req, dev):
        session = req.query.get("session", [""])[0]
        cols = req.qint("cols", 80, 1, 1000)
        rows = req.qint("rows", 24, 1, 1000)
        argv, user = self.term_command(session)
        did = dev["device_id"]
        if self.terminals.get(did, 0) >= MAX_TERMINALS_PER_DEVICE:
            raise HttpError(429, "at most %d terminals per device" % MAX_TERMINALS_PER_DEVICE)
        master, slave = pty.openpty()
        try:
            _set_winsize(slave, rows, cols)
            env = {"TERM": "xterm-256color", "COLORTERM": "truecolor",
                   "PATH": os.environ.get("PATH", "/run/wrappers/bin:/run/current-system/sw/bin"),
                   "LANG": os.environ.get("LANG", "C.UTF-8")}
            proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True,
                                    start_new_session=True,
                                    preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        except OSError as exc:
            os.close(master)
            raise HttpError(500, "could not start the terminal: %s" % exc)
        finally:
            os.close(slave)
        self.terminals[did] = self.terminals.get(did, 0) + 1
        task = self.track(did)
        self.audit.emit("mobile.terminal", dev["device_name"], event="open", user=user, session=session,
                        device_id=did, pid=proc.pid)
        code = None
        ws = None
        try:
            ws = await accept_websocket(req)
            code = await self._pump_terminal(ws, master, proc)
            if code is not None:
                with contextlib.suppress(Exception):
                    await ws.send(json.dumps({"type": "exit", "code": code}))
        except (ConnectionError, OSError):
            pass
        finally:
            # synchronous bookkeeping first: this also runs when the task is cancelled (revoke)
            with contextlib.suppress(OSError):
                os.close(master)
            self.terminals[did] = max(0, self.terminals.get(did, 1) - 1)
            self.untrack(did, task)
            bg = asyncio.ensure_future(self._finish(proc, dev, user, session))
            self._bg.add(bg)
            bg.add_done_callback(self._bg.discard)
        if ws is not None:
            await ws.close(1000)

    async def _finish(self, proc, dev, user, session):
        await self._reap(proc)
        self.audit.emit("mobile.terminal", dev["device_name"], event="close", user=user, session=session,
                        device_id=dev["device_id"], code=proc.returncode)

    async def _pump_terminal(self, ws, master, proc):
        loop = asyncio.get_running_loop()
        out = asyncio.Queue()
        os.set_blocking(master, False)

        def readable():
            try:
                data = os.read(master, 65536)
            except BlockingIOError:
                return
            except OSError:
                data = b""
            if data:
                out.put_nowait(data)
            else:
                loop.remove_reader(master)
                out.put_nowait(None)

        loop.add_reader(master, readable)

        async def to_client():
            while True:
                data = await out.get()
                if data is None:
                    return
                await ws.send(data)

        async def from_client():
            while True:
                msg = await ws.recv()
                if msg is None:
                    return
                op, payload = msg
                if op == OP_BIN:
                    await _write_all(master, payload)
                else:
                    try:
                        ctl = json.loads(payload)
                    except ValueError:
                        continue
                    if isinstance(ctl, dict) and ctl.get("type") == "resize":
                        with contextlib.suppress(OSError, ValueError, TypeError, KeyError, OverflowError):
                            _set_winsize(master, max(1, min(1000, int(ctl["rows"]))),
                                         max(1, min(1000, int(ctl["cols"]))))
                            with contextlib.suppress(ProcessLookupError):
                                os.killpg(proc.pid, signal.SIGWINCH)

        async def exited():
            while proc.poll() is None:
                await asyncio.sleep(0.05)

        t_out, t_in, t_exit = (asyncio.ensure_future(c()) for c in (to_client, from_client, exited))
        try:
            await asyncio.wait({t_in, t_exit, t_out}, return_when=asyncio.FIRST_COMPLETED)
            if t_in.done():
                return None                         # the phone went away
            if t_exit.done() and not t_out.done():  # drain what is left of the output
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(asyncio.shield(t_out), 1.0)
            if t_out.done() and not t_exit.done():  # output ended: the process is on its way out
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(asyncio.shield(t_exit), 2.0)
            while not out.empty():                  # flush anything queued behind EOF
                data = out.get_nowait()
                if data:
                    await ws.send(data)
            rc = proc.returncode
            if rc is None:
                return None
            return 128 - rc if rc < 0 else rc
        finally:
            with contextlib.suppress(Exception):
                loop.remove_reader(master)
            for t in (t_in, t_exit, t_out):
                t.cancel()

    @staticmethod
    async def _reap(proc):
        """Hang up the session if it still runs, kill it if it ignores that."""
        if proc.poll() is None:
            for sig, wait in ((signal.SIGHUP, 2.0), (signal.SIGKILL, 2.0)):
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(proc.pid, sig)
                deadline = time.monotonic() + wait
                while proc.poll() is None and time.monotonic() < deadline:
                    await asyncio.sleep(0.05)
                if proc.poll() is not None:
                    break
        else:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(proc.pid, signal.SIGHUP)       # stragglers of the session

    # -- desktop
    async def desktop_bridge(self, req, dev):
        if not self.opts.desktop_dir:
            raise HttpError(404, "the desktop is not enabled")
        host, port = self.opts.desktop_addr
        try:
            r, w = await asyncio.wait_for(asyncio.open_connection(host, port), 5)
        except (OSError, asyncio.TimeoutError):
            raise HttpError(502, "the desktop (wayvnc) is not reachable")
        ws = await accept_websocket(req)
        task = self.track(dev["device_id"])

        async def up():
            while True:
                msg = await ws.recv()
                if msg is None:
                    return
                w.write(msg[1])
                await w.drain()

        async def down():
            while True:
                data = await r.read(65536)
                if not data:
                    return
                await ws.send(data)

        tasks = [asyncio.ensure_future(up()), asyncio.ensure_future(down())]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for t in tasks:
                t.cancel()
            self.untrack(dev["device_id"], task)
            w.close()
            await ws.close()

    async def desktop_static(self, req):
        if not self.opts.desktop_dir:
            raise HttpError(404, "the desktop is not enabled")
        if req.method != "GET":
            raise HttpError(405, "method not allowed")
        token = req.query.get("t", [""])[0]
        if token:
            if self.devices.by_token(token) is None:
                raise HttpError(401, "unauthorized")
            cookie = "%s=%s; HttpOnly; Secure; SameSite=Strict; Path=/" % (COOKIE, token)
            return await send_response(req.writer, 302, b"", headers=[("Set-Cookie", cookie), ("Location", "/desktop/")])
        self.authenticate(req, cookie_ok=True)
        rel = req.path[len("/desktop"):].lstrip("/")
        if rel == "":
            page = (b"<!doctype html><meta charset=utf-8><title>Nestlo desktop</title>"
                    b"<script>location.replace('vnc.html?autoconnect=true&reconnect=true&resize=scale"
                    b"&path=v1/desktop')</script>")
            return await send_response(req.writer, 200, page, "text/html; charset=utf-8")
        root = os.path.realpath(self.opts.desktop_dir)
        full = os.path.realpath(os.path.join(root, rel))
        if not (full == root or full.startswith(root + os.sep)) or not os.path.isfile(full):
            raise HttpError(404, "not found")
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".js") or full.endswith(".mjs"):
            ctype = "text/javascript"
        with open(full, "rb") as f:
            data = f.read()
        await send_response(req.writer, 200, data, ctype)


def fmt_host(host, port=None):
    """`host`, `host:port` or `[v6]:port` as it appears in a `host` entry."""
    return _bracket(host) + (":%d" % port if port else "")


def _bracket(host):
    return "[%s]" % host if ":" in host else host


async def _write_all(fd, data):
    while data:
        try:
            n = os.write(fd, data)
        except BlockingIOError:
            await asyncio.sleep(0.005)
            continue
        data = data[n:]


def _set_winsize(fd, rows, cols):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def _uptime():
    try:
        with open("/proc/uptime") as f:
            return int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def _nixos_version():
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("VERSION_ID="):
                    return line.partition("=")[2].strip().strip('"')
    except OSError:
        pass
    return ""


def _peer_user(writer):
    try:
        sock = writer.get_extra_info("socket")
        pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        import pwd
        return pwd.getpwuid(uid).pw_name
    except Exception:
        return "unknown"


# ── server entry point ──────────────────────────────────────────────────────
def build_backend(args, terminal_users):
    from .dashboard import Dashboard
    from .store import Store, connect
    cfg = configmod.load(args.config)
    store = Store(connect(cfg["redis"]["url"]))
    return Backend(Dashboard(cfg, store, ""), args.orchestrator_socket or None, terminal_users, args.tuios_bin), cfg


def server_main(argv=None):
    p = argparse.ArgumentParser(description="Nestlo mobile server (docs/mobile-protocol.md)")
    p.add_argument("--config", default=None, help="services.toml path")
    p.add_argument("--state-dir", default=DEFAULT_STATE_DIR)
    p.add_argument("--listen", default="0.0.0.0")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--name", default=socket.gethostname())
    p.add_argument("--admin-socket", default=DEFAULT_ADMIN_SOCKET)
    p.add_argument("--admin-group", default="wheel")
    p.add_argument("--terminal-user", action="append", default=[], help="user whose terminals may be opened (repeatable)")
    p.add_argument("--desktop-dir", default=None, help="directory with the noVNC client; enables the desktop feature")
    p.add_argument("--desktop-addr", default="127.0.0.1:5900", help="host:port of wayvnc")
    p.add_argument("--advertise-host", action="append", default=[], help="host put in pairing URIs (repeatable)")
    p.add_argument("--domain", default="", help="first host in pairing URLs and the entry host")
    p.add_argument("--public-host", default="", help="fixed public address or name")
    p.add_argument("--public-url", default="", help="base URL of the landing page when behind a reverse proxy")
    p.add_argument("--discover-public-ip", action="store_true", help="look up the public IP once per pairing")
    p.add_argument("--onboarding-port", type=int, default=None, help="port of the plain-HTTP landing pages (off if unset)")
    p.add_argument("--onboarding-apk", default=None, help="APK served at /app/nestlo.apk")
    p.add_argument("--tunnel-unit", default=None, help="systemd unit that runs the tunnel (enables `--via tunnel`)")
    p.add_argument("--tunnel-dir", default=DEFAULT_TUNNEL_DIR, help="directory of tunnel.json (shared with the tunnel unit)")
    p.add_argument("--tunnel-config", default=None, help="JSON with the tunnel providers (written by the module)")
    p.add_argument("--connect-default", choices=VIAS, default="lan", help="`pair` default when it cannot ask")
    p.add_argument("--orchestrator-socket", default=None, help="enables approvals (tasks awaiting approval)")
    p.add_argument("--tuios-bin", default="nestlo-tuios")
    p.add_argument("--runuser", default=shutil.which("runuser") or "runuser")
    p.add_argument("--audit-socket", default=None)
    p.add_argument("--ping-interval", type=float, default=PING_SEC, help="seconds between pings on /v1/events")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    host, _, port = args.desktop_addr.rpartition(":")
    users = list(dict.fromkeys(args.terminal_user))
    for u in users:
        if not _USER_RE.match(u):
            p.error("invalid terminal user %r" % u)
    backend, _ = build_backend(args, users)
    opts = Options(name=args.name, state_dir=args.state_dir, listen=args.listen, port=args.port,
                   admin_socket=args.admin_socket, admin_group=args.admin_group, terminal_users=users,
                   desktop_dir=args.desktop_dir, desktop_addr=(host or "127.0.0.1", int(port)),
                   advertise_hosts=args.advertise_host, approvals=bool(args.orchestrator_socket),
                   runuser=args.runuser, tuios_bin=args.tuios_bin, ping_sec=args.ping_interval,
                   domain=args.domain, public_host=args.public_host, public_url=args.public_url,
                   discover_public_ip=args.discover_public_ip, onboarding_port=args.onboarding_port,
                   onboarding_apk=args.onboarding_apk, tunnel_unit=args.tunnel_unit,
                   tunnel_dir=args.tunnel_dir, tunnel_config=args.tunnel_config, connect_default=args.connect_default)
    audit = auditmod.AuditClient(args.audit_socket, source="mobile") if args.audit_socket else auditmod.NullClient()

    async def run():
        srv = Server(opts, backend, audit)
        await srv.start()
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        await stop.wait()
        await srv.stop()

    asyncio.run(run())
    with contextlib.suppress(Exception):
        audit.close()


# ── CLI: nestlo-mobile ──────────────────────────────────────────────────────
VIA_MENU = (
    ("lan", "same network (LAN)", "phone and machine on the same Wi-Fi"),
    ("tunnel", "tunnel", "works anywhere; you pick the provider next (Cloudflare quick tunnel needs no account)"),
    ("tailscale", "tailscale", "both devices on your tailnet"),
    ("url", "my own URL", "nestlo.mobile.publicUrl (reverse proxy, named tunnel)"),
)

EXPOSURE_WARNING = (
    "WARNING: this tunnel exposes the Nestlo API of this machine to the internet.\n"
    "Only someone with a pairing code or a device token can use it. When you are done:\n"
    "  nestlo-mobile tunnel stop")


def ask_via(default, inp=None, out=None):
    inp, out = inp or input, out or sys.stderr
    """Interactive `how should the phone reach this machine?`; returns a `via`."""
    print("How should your phone reach this machine?", file=out)
    for i, (key, label, hint) in enumerate(VIA_MENU, 1):
        print("  [%d] %-26s %s%s" % (i, label, hint, "  (default)" if key == default else ""), file=out)
    while True:
        choice = parse_choice(inp("> "), default)
        if choice:
            return choice
        print("choose 1-%d" % len(VIA_MENU), file=out)


def ask_provider(rows, default, inp=None, out=None):
    inp, out = inp or input, out or sys.stderr
    """Interactive tunnel provider choice over the rows of provider_table()."""
    names = [r["name"] for r in rows if r["name"] != "tailscale"]
    print("Tunnel provider:", file=out)
    for i, r in enumerate(rows, 1):
        if r["name"] == "tailscale":
            continue
        need = {"none": "no account", "token": "needs a token", "account": "needs an account",
                "server": "needs your own server"}[r["account"]]
        state = "" if r["account"] == "none" else ("configured" if r["configured"] else "NOT configured")
        print("  [%d] %-17s %-22s %-14s %s" % (i, r["name"], need, state, r["note"]), file=out)
    while True:
        t = inp("> ").strip().lower()
        if not t:
            return default
        if t.isdigit() and 1 <= int(t) <= len(rows) and rows[int(t) - 1]["name"] in names:
            return rows[int(t) - 1]["name"]
        if t in names:
            return t
        print("choose a number or a provider name", file=out)


def cli_main(argv=None, stdin_isatty=None):
    from . import unixapi
    p = argparse.ArgumentParser(prog="nestlo-mobile", description="Pair and manage phones (nestlo.mobile)")
    p.add_argument("--socket", default=os.environ.get("NESTLO_MOBILE_SOCKET", DEFAULT_ADMIN_SOCKET))
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("pair", help="print a QR code and link that pair one phone")
    pp.add_argument("--ttl", type=int, default=DEFAULT_TTL, help="seconds the code is valid (default 300)")
    pp.add_argument("--via", choices=VIAS, help="how the phone reaches this machine (default: ask, or the configured default)")
    pp.add_argument("--provider", help="tunnel provider for --via tunnel (%s)" % ", ".join(tunnels.LISTED))
    dp = sub.add_parser("devices", help="list paired phones")
    dp.add_argument("--json", action="store_true")
    rp = sub.add_parser("revoke", help="revoke a paired phone")
    rp.add_argument("device_id")
    sub.add_parser("url", help="show the address and certificate fingerprint of this machine")
    tp = sub.add_parser("tunnel", help="control the tunnel")
    tsub = tp.add_subparsers(dest="tcmd", required=True)
    ts = tsub.add_parser("start", help="start a tunnel and print its endpoint")
    ts.add_argument("--provider")
    tsub.add_parser("stop", help="stop the tunnel")
    tsub.add_parser("status", help="show the tunnel and the providers")
    tsub.add_parser("url", help="print the tunnel endpoint")
    tr = sub.add_parser("tunnel-run", help=argparse.SUPPRESS)       # run by the nestlo-mobile-tunnel unit
    tr.add_argument("--config", required=True)
    tr.add_argument("--run-dir", default=DEFAULT_TUNNEL_DIR)
    tr.add_argument("--state-dir", default=os.environ.get("STATE_DIRECTORY", "/var/lib/nestlo-mobile-tunnel"))
    tr.add_argument("--provider", default=None)
    args = p.parse_args(argv)

    if args.cmd == "tunnel-run":
        with open(args.config) as f:
            config = json.load(f)
        name = args.provider
        if not name:
            try:
                with open(os.path.join(args.run_dir, "tunnel-provider")) as f:
                    name = f.read().strip()
            except OSError:
                name = config.get("default") or tunnels.DEFAULT_PROVIDER
        sys.exit(tunnels.run_provider(name, config, args.run_dir, args.state_dir,
                                      os.environ.get("CREDENTIALS_DIRECTORY", "")))

    def call(method, path, body=None, timeout=15):
        try:
            status, obj = unixapi.call(args.socket, method, path, body, timeout=timeout)
        except OSError as exc:
            sys.exit("nestlo-mobile: the server is not reachable on %s (%s); is nestlo.mobile enabled and are you "
                     "in its admin group?" % (args.socket, exc))
        if status != 200:
            sys.exit("nestlo-mobile: %s" % (obj.get("error") if isinstance(obj, dict) else obj))
        return obj

    def show_endpoint(ep):
        return ep.get("url") or fmt_host(ep["host"], ep["port"])

    # ask only at a terminal: not when stdout goes to a file or a pipe
    interactive = (sys.stdin.isatty() and sys.stdout.isatty()) if stdin_isatty is None else stdin_isatty

    if args.cmd == "pair":
        info = call("GET", "/url")
        via = args.via
        provider = args.provider
        if via is None and provider:
            via = "tunnel"
        if via is None:
            via = ask_via(info.get("default_via", "lan")) if interactive else info.get("default_via", "lan")
        if via == "tunnel":
            status = call("GET", "/tunnel")
            if not provider and interactive:
                provider = ask_provider(status["providers"], status.get("default", tunnels.DEFAULT_PROVIDER))
            if provider == "tailscale":
                via, provider = "tailscale", None
        if via == "tunnel":
            print("starting the tunnel (up to 60 seconds)...", file=sys.stderr)
            call("POST", "/tunnel/start", {"provider": provider} if provider else {}, timeout=90)
        res = call("POST", "/pair", {"ttl": args.ttl, "via": via})
        target = res.get("url") or res["uri"]
        qr = shutil.which("qrencode")
        if qr:
            subprocess.run([qr, "-t", "ANSIUTF8", target], check=False)
        else:
            print("(qrencode not found: open the link below on the phone)", file=sys.stderr)
        print(target)
        if res.get("url"):
            print(res["uri"])
        print("valid for %d seconds, single use" % res["ttl"], file=sys.stderr)
        if via == "tunnel":
            print(EXPOSURE_WARNING, file=sys.stderr)
    elif args.cmd == "tunnel":
        if args.tcmd == "start":
            print(show_endpoint(call("POST", "/tunnel/start", {"provider": args.provider} if args.provider else {},
                                     timeout=90)))
            print(EXPOSURE_WARNING, file=sys.stderr)
        elif args.tcmd == "stop":
            call("POST", "/tunnel/stop", {})
            print("tunnel stopped")
        elif args.tcmd == "url":
            ep = call("GET", "/tunnel").get("endpoint")
            if not ep:
                sys.exit("nestlo-mobile: no tunnel is running")
            print(show_endpoint(ep))
        else:
            st = call("GET", "/tunnel")
            if not st["configured"]:
                print("no tunnel configured (nestlo.mobile.tunnel.enable)")
            else:
                ep = st["endpoint"]
                print("tunnel: %s" % ("running, %s via %s" % (show_endpoint(ep), ep["provider"]) if st["active"] and ep
                                      else "active, waiting for an endpoint" if st["active"] else "stopped"))
                print("%-17s %-10s %-14s %s" % ("PROVIDER", "TRUST", "CONFIGURED", ""))
                for r in st["providers"]:
                    print("%-17s %-10s %-14s %s" % (r["name"], r["trust"], "yes" if r["configured"] else "no", r["note"]))
    elif args.cmd == "devices":
        devs = call("GET", "/devices")
        if args.json:
            print(json.dumps(devs, indent=1))
        elif not devs:
            print("no paired devices")
        else:
            print("%-16s %-24s %-20s %-21s %s" % ("ID", "NAME", "MODEL", "PAIRED", "LAST SEEN"))
            for d in devs:
                print("%-16s %-24s %-20s %-21s %s" % (d["device_id"], d["device_name"][:24], d["device_model"][:20],
                                                      d["paired_at"], d["last_seen"]))
    elif args.cmd == "revoke":
        call("DELETE", "/devices/" + urllib.parse.quote(args.device_id, safe=""))
        print("revoked " + args.device_id)
    elif args.cmd == "url":
        res = call("GET", "/url")
        for u in res["urls"]:
            print(u)
        print("fingerprint (sha256 of the DER certificate, base64url): " + res["fp"])


if __name__ == "__main__":
    server_main()
