"""agentos-cloudd: the AgentOS Cloud control plane.

Listeners:
  web (loopback, behind Caddy)
      <domain>                  POST /exec, the web page, login, logout,
                                magic links, OIDC, /__agentos/tls-ask
      <vm>.<domain>,            /__auth (Caddy forward_auth): who may reach
      <vm>-<port>.<domain>,     the VM; /__agentos/{login,callback,logout,share}
      custom domains
  integrations (the VM bridge address, port 80)
      <name>.<int domain>       the integration proxy: identifies the VM by
                                its source address and injects the secrets
  lobby (unix socket, the lobby SSH user only)
      the commands of `ssh lobby@host ...`, key lookup for sshd, invites,
      `ssh <vm>` (stdio passed on to the VM helper) and `tunnel`
  metrics (loopback)
"""

import argparse
import base64
import fnmatch
import hashlib
import hmac
import html
import http.client
import http.cookies
import http.server
import json
import logging
import os
import re
import secrets
import shutil
import socket
import socketserver
import ssl
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

from .. import audit as auditmod
from .. import config as configmod
from .. import health as healthmod
from . import backend as B
from . import commands as C
from . import tokens as TK
from .state import State, StateError, connect, secret_box

log = logging.getLogger("agentos.cloud")

COOKIE = "agentos_session"
EXEC_MAX = 64 * 1024
EXEC_TIMEOUT = 30
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length"}
IDENTITY_HEADERS = ("X-AgentOS-Email", "X-AgentOS-UserID", "X-AgentOS-Token-Ctx",
                    "X-ExeDev-Email", "X-ExeDev-UserID", "X-ExeDev-Token-Ctx")

DEFAULTS = {
    "domain": "agentos.localhost",
    "region": "local",
    "lobby_user": "lobby",
    "tls": "internal",                 # internal | acme | off
    "vm_network": "10.210.0.0/16",
    "gateway_ip": "10.210.0.1",
    "default_port": 80,
    "default_image": "agentos",
    "default_plan": "work",
    "default_disk_gb": 20,
    "allow_oci_images": True,
    "verify_dns": True,
    "extra_ports": [],
    "session_days": 30,
    "exec_rate_per_minute": 120,
    "exec_timeout_sec": EXEC_TIMEOUT,
    "agent_ui_port": 9999,
    "exe_compat_headers": True,
    "lobby_socket": "/run/agentos-cloud/lobby.sock",
    "web_listen": "127.0.0.1",
    "web_port": 9940,
    "integrations_port": 9942,
    "metrics_listen": "127.0.0.1",
    "metrics_port": 9941,
    "secret_key_file": "/var/lib/agentos-cloud/secret.key",
    "gateway_url": None,
    "pricing_file": "/etc/agentos/pricing.json",
    "metadata_ip": "169.254.169.254",
    "gateway_admin_socket": None,
    "tick_sec": 60,
    "users_create_teams": True,
    "users_invite": True,
    "open_signup": False,
    "admins": [],
    "users": [],
    "integrations": [],
    "oidc": {},
    "vmd": {},
}


def options(cfg):
    out = dict(DEFAULTS)
    out.update(cfg.get("cloud") or {})
    return out


# ── HTTP helpers ───────────────────────────────────────────────────────

def read_body(req, limit):
    """Request body (Content-Length or chunked), refusing more than `limit` bytes."""
    if "chunked" in (req.headers.get("Transfer-Encoding") or "").lower():
        out = b""
        while True:
            line = req.rfile.readline(1024)
            size = int(line.split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while req.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                    pass
                return out
            out += req.rfile.read(size)
            req.rfile.readline(4)
            if len(out) > limit:
                raise OverflowError
    n = int(req.headers.get("Content-Length") or 0)
    if n > limit:
        raise OverflowError
    return req.rfile.read(n) if n else b""


def spool_body(req, limit):
    """Request body into a temporary file (git pushes can be large) -> (file, size)."""
    f = tempfile.TemporaryFile()
    total = 0
    if "chunked" in (req.headers.get("Transfer-Encoding") or "").lower():
        while True:
            size = int(req.rfile.readline(1024).split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while req.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                    pass
                break
            remaining = size
            while remaining:
                chunk = req.rfile.read(min(remaining, 65536))
                if not chunk:
                    raise ConnectionError("client went away")
                f.write(chunk)
                remaining -= len(chunk)
            req.rfile.readline(4)
            total += size
            if total > limit:
                raise OverflowError
    else:
        n = int(req.headers.get("Content-Length") or 0)
        if n > limit:
            raise OverflowError
        remaining = n
        while remaining:
            chunk = req.rfile.read(min(remaining, 65536))
            if not chunk:
                raise ConnectionError("client went away")
            f.write(chunk)
            remaining -= len(chunk)
        total = n
    f.seek(0)
    return f, total


def send(req, status, body=b"", ctype="application/json", headers=None):
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
    elif isinstance(body, str):
        body = body.encode()
    req.send_response(status)
    req.send_header("Content-Type", ctype)
    req.send_header("Content-Length", str(len(body)))
    req.send_header("Cache-Control", "no-store")
    for k, v in (headers or []):
        req.send_header(k, v)
    req.end_headers()
    if req.command != "HEAD":
        req.wfile.write(body)


def redirect(req, location, headers=None):
    send(req, 302, b"", "text/plain", [("Location", location)] + list(headers or []))


def cookies(req):
    c = http.cookies.SimpleCookie()
    try:
        c.load(req.headers.get("Cookie") or "")
    except http.cookies.CookieError:
        return {}
    return {k: m.value for k, m in c.items()}


def page(title, body):
    return ("<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>%s</title><style>body{font:15px/1.5 system-ui,sans-serif;max-width:860px;margin:2rem auto;padding:0 16px;"
            "color:#1d1d1f;background:#fff}@media(prefers-color-scheme:dark){body{color:#e8e8ea;background:#141416}"
            "a{color:#8ab4ff}table td,table th{border-color:#333}}table{border-collapse:collapse;width:100%%}"
            "td,th{text-align:left;padding:6px 8px;border-bottom:1px solid #ddd}code,pre{font-family:ui-monospace,monospace;"
            "font-size:13px}pre{white-space:pre-wrap;word-break:break-all}input,textarea,button{font:inherit}"
            "textarea{width:100%%;box-sizing:border-box}</style></head><body><h1>%s</h1>%s</body></html>"
            % (html.escape(title), html.escape(title), body))


# ── the service ────────────────────────────────────────────────────────

class CloudService:
    def __init__(self, cfg, state, cloud, clock=time.time, gateway=None):
        self.cfg = cfg
        self.st = state
        self.cloud = cloud
        self.clock = clock
        self.gateway = gateway          # GatewayLink or None
        self.counters = {}
        self.lock = threading.Lock()
        self.oidc_meta = None

    def bump(self, name, n=1):
        with self.lock:
            self.counters[name] = self.counters.get(name, 0) + n

    @property
    def domain(self):
        return self.cfg["domain"]

    def secure(self):
        return self.cfg.get("tls") != "off"

    def scheme(self):
        return "https" if self.secure() else "http"

    # ── declarative users and integrations ────────────────────────────
    def apply_declarative(self):
        for u in self.cfg.get("users") or []:
            try:
                user = self.st.user_by_email(u["email"]) or self.st.create_user(
                    u["email"], plan=u.get("plan") or self.cfg["default_plan"], admin=bool(u.get("admin")))
            except StateError as exc:
                log.warning("user %s: %s", u.get("email"), exc.message)
                continue
            changed = False
            for field in ("plan", "admin"):
                if field in u and u[field] is not None and user.get(field) != u[field]:
                    user[field] = u[field]
                    changed = True
            if changed:
                self.st.save_user(user)
            for line in u.get("keys") or []:
                try:
                    kind, blob, comment = TK.parse_public_key(line)
                    self.st.add_key(user["id"], TK.fingerprint(blob), "%s %s" % (kind, line.split()[1]),
                                    comment or "declared", tag=None)
                except (ValueError, StateError):
                    pass
        for email in self.cfg.get("admins") or []:
            user = self.st.user_by_email(email)
            if user and not user["admin"]:
                user["admin"] = True
                self.st.save_user(user)
        wanted = set()
        for i in self.cfg.get("integrations") or []:
            integ = {"name": i["name"], "type": i["type"], "scope": "system", "created_by": "system",
                     "created": int(self.clock()), "attach": list(i.get("attach") or []), "comment": i.get("comment", ""),
                     "headers": {}, "act_as_user": bool(i.get("act_as_user")),
                     "repositories": list(i.get("repositories") or []), "read_only": bool(i.get("read_only")),
                     "target": i.get("target") or ("gateway" if i["type"] == "llm" else self.cfg.get("github_url", "https://github.com")
                                                   if i["type"] == "github" else None),
                     "secret_files": {"bearer": i.get("bearer_file"), "headers": i.get("header_files") or {}}}
            existing = self.st.integration("system", i["name"])
            self.st.put_integration(integ, new=existing is None)
            wanted.add(i["name"])
        for integ in self.st.integrations():
            if integ["scope"] == "system" and integ["name"] not in wanted:
                self.st.delete_integration(integ)

    # ── identities ─────────────────────────────────────────────────────
    def user_by_key(self, fp):
        k = self.st.key(fp)
        if not k:
            return None
        user = self.st.user(k["uid"])
        return user if user and not user.get("disabled") else None

    def token_user(self, token, namespace):
        """(user, permissions, fingerprint) for a bearer token, or raise TokenError."""
        vm_scope = None
        if any(token.startswith(p) for p in TK.ALIASES1):
            if not token.startswith("agentos1."):
                token = "agentos1." + token.split(".", 1)[1]
            doc = self.st.short_token(token)
            if not doc:
                raise TK.TokenError("unknown or expired token")
            token, vm_scope = doc["token"], doc.get("vm")
        perms, fp = TK.decode(token, namespace, now=self.clock())
        user = self.user_by_key(fp)
        if user is None:
            raise TK.TokenError("token signed by an unknown key")
        return user, perms, fp, vm_scope

    # ── /exec ──────────────────────────────────────────────────────────
    def handle_exec(self, req):
        if req.command != "POST":
            return send(req, 405, {"error": "use POST"}, headers=[("Allow", "POST")])
        auth = req.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            return send(req, 401, {"error": "missing bearer token"}, headers=[("WWW-Authenticate", "Bearer")])
        try:
            user, perms, fp, vm_scope = self.token_user(auth[7:].strip(), "v0@" + self.domain)
        except TK.TokenError as exc:
            self.bump("exec_unauthorized")
            return send(req, 401, {"error": exc.message}, headers=[("WWW-Authenticate", "Bearer")])
        if vm_scope:
            return send(req, 401, {"error": "this token is scoped to a VM, not to the API"})
        if self.st.rate_limited("exec:" + fp, int(self.cfg.get("exec_rate_per_minute", 120))):
            return send(req, 429, {"error": "rate limit: too many requests for this key; use a separate key per workload"})
        try:
            body = read_body(req, EXEC_MAX)
        except OverflowError:
            return send(req, 413, {"error": "request body exceeds 64KB"})
        line = body.decode("utf-8", "replace").strip()
        if not line:
            return send(req, 400, {"error": "empty command"})
        ctx = C.Ctx(user, via="http", key=fp, perms=perms)
        result = {}

        def work():
            try:
                result["ok"] = self.cloud.run_line(ctx, line)
            except C.CommandError as exc:
                result["err"] = exc
            except Exception as exc:
                log.exception("exec %r failed", line[:80])
                result["err"] = C.CommandError("internal error: %s" % exc.__class__.__name__, 500)

        t = threading.Thread(target=work, daemon=True)
        t.start()
        t.join(float(self.cfg.get("exec_timeout_sec", EXEC_TIMEOUT)))
        self.bump("exec_requests")
        if t.is_alive():
            return send(req, 504, {"error": "the command did not finish in %ss; it keeps running (check `ls`)" %
                                   self.cfg.get("exec_timeout_sec", EXEC_TIMEOUT)})
        if "err" in result:
            e = result["err"]
            return send(req, e.status, {"error": e.message})
        name, obj = result["ok"]
        return send(req, 200, obj)

    # ── sessions ───────────────────────────────────────────────────────
    def session_user(self, req, host):
        return self.st.session(cookies(req).get(COOKIE), host)

    def set_cookie(self, sid, max_age):
        parts = ["%s=%s" % (COOKIE, sid), "Path=/", "HttpOnly", "SameSite=Lax", "Max-Age=%d" % max_age]
        if self.secure():
            parts.append("Secure")
        return ("Set-Cookie", "; ".join(parts))

    def start_session(self, uid, host):
        ttl = int(self.cfg.get("session_days", 30)) * 86400
        return self.set_cookie(self.st.put_session(uid, host, ttl), ttl)

    def csrf(self, req):
        sid = cookies(req).get(COOKIE) or ""
        return hmac.new(sid.encode(), b"csrf", hashlib.sha256).hexdigest()[:32]

    def check_csrf(self, req, form):
        token = (form.get("csrf") or [""])[0]
        origin = req.headers.get("Origin")
        if origin and urllib.parse.urlsplit(origin).hostname != self.domain:
            return False
        return bool(token) and hmac.compare_digest(token, self.csrf(req))

    # ── host classification ────────────────────────────────────────────
    def vm_for_host(self, host):
        """(vm, port or None) for a request host, or (None, None)."""
        host = (host or "").split(":")[0].lower().rstrip(".")
        suffix = "." + self.domain
        if host.endswith(suffix):
            label = host[:-len(suffix)]
            if "." in label:
                return None, None
            m = re.fullmatch(r"(.+)-(\d{2,5})", label)
            if m:
                vm = self.st.vm_by_name(m.group(1))
                if vm is not None:
                    return vm, int(m.group(2))
            return self.st.vm_by_name(label), None
        return self.st.vm_by_domain(host), None

    def safe_next(self, nxt):
        """A login 'next' URL must point at a VM host (or the lobby) of this system."""
        try:
            u = urllib.parse.urlsplit(nxt or "")
        except ValueError:
            return None
        if u.scheme not in ("http", "https") or not u.hostname:
            return None
        if u.hostname == self.domain:
            return nxt
        vm, _ = self.vm_for_host(u.hostname)
        return nxt if vm is not None else None

    # ── the lobby web ──────────────────────────────────────────────────
    def handle_lobby(self, req, path, query):
        user = self.session_user(req, self.domain)
        if path == "/exec":
            return self.handle_exec(req)
        if path in ("/healthz", "/__agentos/healthz"):
            return send(req, 200, {"status": "ok"})
        if path == "/__agentos/tls-ask":
            return self.tls_ask(req, query)
        if path.startswith("/__agentos/magic/"):
            doc = self.st.take_once("magic", path.rsplit("/", 1)[1])
            if not doc or not self.st.user(doc["uid"]):
                return send(req, 403, page("Link expired", "<p>This login link was used or has expired. Run "
                                           "<code>ssh %s@%s browser</code> for a new one.</p>" % (
                                               html.escape(self.cfg["lobby_user"]), html.escape(self.ssh_host()))),
                            "text/html; charset=utf-8")
            self.bump("logins")
            return redirect(req, "/", [self.start_session(doc["uid"], self.domain)])
        if path == "/__agentos/login":
            nxt = self.safe_next((query.get("next") or [""])[0])
            if user is None:
                return self.login_page(req, nxt)
            if nxt is None:
                return redirect(req, "/")
            u = urllib.parse.urlsplit(nxt)
            if u.hostname == self.domain:
                return redirect(req, nxt)
            code = self.st.put_once("login", {"uid": user["id"], "host": u.hostname}, ttl=120)
            back = "%s://%s/__agentos/callback?%s" % (self.scheme(), u.netloc, urllib.parse.urlencode(
                {"code": code, "next": (u.path or "/") + ("?" + u.query if u.query else "")}))
            return redirect(req, back)
        if path == "/__agentos/oidc/start":
            return self.oidc_start(req, query)
        if path == "/__agentos/oidc/callback":
            return self.oidc_callback(req, query)
        if path == "/__agentos/logout" and req.command == "POST":
            sid = cookies(req).get(COOKIE)
            if sid:
                self.st.delete_session(sid)
            return redirect(req, "/", [self.set_cookie("", 0)])
        if path == "/__agentos/keys" and req.command == "POST":
            return self.add_key_form(req, user)
        if path == "/":
            return self.home(req, user)
        return send(req, 404, page("Not found", "<p>Nothing here.</p>"), "text/html; charset=utf-8")

    def ssh_host(self):
        return self.cfg.get("ssh_host") or self.domain

    def login_page(self, req, nxt):
        parts = ["<p>Log in to %s.</p>" % html.escape(self.domain)]
        if (self.cfg.get("oidc") or {}).get("issuer"):
            q = urllib.parse.urlencode({"next": nxt or "/"})
            parts.append("<p><a href='/__agentos/oidc/start?%s'><button>Log in with %s</button></a></p>" % (
                html.escape(q), html.escape(self.cfg["oidc"].get("name") or "single sign-on")))
        parts.append("<p>Or run this in a terminal with your SSH key and open the link it prints:</p>"
                     "<pre>ssh %s@%s browser</pre>" % (html.escape(self.cfg["lobby_user"]), html.escape(self.ssh_host())))
        if nxt:
            parts.append("<p>Then open <a href='%s'>%s</a> again.</p>" % (html.escape(nxt), html.escape(nxt)))
        return send(req, 401 if nxt else 200, page("AgentOS Cloud", "".join(parts)), "text/html; charset=utf-8")

    def home(self, req, user):
        if user is None:
            return self.login_page(req, None)
        rows = "".join("<tr><td><a href='%s'>%s</a></td><td>%s</td><td>%s</td><td><code>%s</code></td></tr>" % (
            html.escape(v["https_url"]), html.escape(v["vm_name"]), html.escape(v["status"]),
            html.escape(v.get("access") or ""), html.escape(self.cloud.ssh_command(self.st.vm_by_name(v["vm_name"]))))
            for v in self.cloud.c_ls(C.Ctx(user), {"pattern": None}, {"--shared": True})["vms"])
        keys = "".join("<tr><td>%s</td><td><code>%s</code></td></tr>" % (html.escape(k["name"]), html.escape(k["fp"]))
                       for k in self.st.keys_of(user["id"]))
        csrf = self.csrf(req)
        body = ("<p>Logged in as <b>%s</b>. <form method=post action='/__agentos/logout' style='display:inline'>"
                "<input type=hidden name=csrf value='%s'><button>Log out</button></form></p>"
                "<h2>VMs</h2><table><tr><th>Name</th><th>Status</th><th>Access</th><th>Shell</th></tr>%s</table>"
                "<p>Create one: <code>ssh %s@%s new</code></p>"
                "<h2>SSH keys</h2><table>%s</table>"
                "<form method=post action='/__agentos/keys'><input type=hidden name=csrf value='%s'>"
                "<p><textarea name=key rows=3 placeholder='ssh-ed25519 AAAA... you@laptop'></textarea></p>"
                "<button>Add SSH key</button></form>") % (
            html.escape(user["email"]), csrf, rows or "<tr><td colspan=4>none yet</td></tr>",
            html.escape(self.cfg["lobby_user"]), html.escape(self.ssh_host()), keys or "<tr><td>none</td></tr>", csrf)
        return send(req, 200, page("AgentOS Cloud", body), "text/html; charset=utf-8")

    def add_key_form(self, req, user):
        if user is None:
            return send(req, 401, page("Log in first", "<p>Log in first.</p>"), "text/html; charset=utf-8")
        try:
            form = urllib.parse.parse_qs(read_body(req, 16384).decode())
        except OverflowError:
            return send(req, 413, "too large", "text/plain")
        if not self.check_csrf(req, form):
            return send(req, 403, "bad request token", "text/plain")
        try:
            self.cloud.c_key_add(C.Ctx(user, via="web"), {"public_key": (form.get("key") or [""])[0].strip()}, {})
        except (C.CommandError, StateError) as exc:
            return send(req, 400, page("Not added", "<p>%s</p><p><a href='/'>Back</a></p>" % html.escape(exc.message)),
                        "text/html; charset=utf-8")
        return redirect(req, "/")

    # ── OIDC (authorization code flow; identity from the userinfo endpoint)
    def oidc(self):
        o = self.cfg.get("oidc") or {}
        if not o.get("issuer"):
            return None
        if self.oidc_meta is None:
            url = o["issuer"].rstrip("/") + "/.well-known/openid-configuration"
            with urllib.request.urlopen(url, timeout=10) as r:
                self.oidc_meta = json.load(r)
        return o

    def oidc_start(self, req, query):
        try:
            o = self.oidc()
        except Exception as exc:
            return send(req, 502, page("Login unavailable", "<p>%s</p>" % html.escape(str(exc))), "text/html; charset=utf-8")
        if o is None:
            return send(req, 404, "no single sign-on configured", "text/plain")
        nxt = self.safe_next((query.get("next") or [""])[0]) or "/"
        state = self.st.put_once("oidc", {"next": nxt}, ttl=600)
        params = {"response_type": "code", "client_id": o["client_id"], "redirect_uri": self.oidc_redirect(),
                  "scope": "openid email profile", "state": state, "nonce": secrets.token_urlsafe(16)}
        return redirect(req, self.oidc_meta["authorization_endpoint"] + "?" + urllib.parse.urlencode(params))

    def oidc_redirect(self):
        return "%s://%s/__agentos/oidc/callback" % (self.scheme(), self.domain)

    def oidc_callback(self, req, query):
        o = self.oidc()
        st = self.st.take_once("oidc", (query.get("state") or [""])[0])
        code = (query.get("code") or [""])[0]
        if o is None or st is None or not code:
            return send(req, 400, page("Login failed", "<p>The login expired; try again.</p>"), "text/html; charset=utf-8")
        with open(o["client_secret_file"]) as f:
            secret = f.read().strip()
        data = urllib.parse.urlencode({"grant_type": "authorization_code", "code": code, "redirect_uri": self.oidc_redirect(),
                                       "client_id": o["client_id"], "client_secret": secret}).encode()
        try:
            with urllib.request.urlopen(urllib.request.Request(self.oidc_meta["token_endpoint"], data=data), timeout=15) as r:
                tok = json.load(r)
            info_req = urllib.request.Request(self.oidc_meta["userinfo_endpoint"],
                                              headers={"Authorization": "Bearer " + tok["access_token"]})
            with urllib.request.urlopen(info_req, timeout=15) as r:
                info = json.load(r)
        except Exception as exc:
            log.warning("OIDC exchange failed: %s", exc)
            return send(req, 502, page("Login failed", "<p>The identity provider did not answer.</p>"), "text/html; charset=utf-8")
        email = (info.get("email") or "").strip()
        if not email or info.get("email_verified") is False:
            return send(req, 403, page("Login refused", "<p>The identity provider gave no verified email.</p>"),
                        "text/html; charset=utf-8")
        user = self.st.user_by_email(email)
        domains = [d.lower() for d in o.get("allowed_domains") or []]
        if user is None:
            if not o.get("create_users", True) or (domains and email.rsplit("@", 1)[1].lower() not in domains):
                return send(req, 403, page("Login refused", "<p>%s has no account here.</p>" % html.escape(email)),
                            "text/html; charset=utf-8")
            user = self.st.create_user(email, plan=o.get("plan") or self.cfg["default_plan"])
        if user.get("disabled"):
            return send(req, 403, page("Login refused", "<p>This account is disabled.</p>"), "text/html; charset=utf-8")
        cookie = self.start_session(user["id"], self.domain)
        nxt = st.get("next") or "/"
        if urllib.parse.urlsplit(nxt).hostname not in (None, self.domain):
            nxt = "/__agentos/login?" + urllib.parse.urlencode({"next": nxt})
        return redirect(req, nxt, [cookie])

    # ── on-demand TLS ──────────────────────────────────────────────────
    def tls_ask(self, req, query):
        """Caddy asks before issuing a certificate: only for names this system serves."""
        name = (query.get("domain") or [""])[0].lower().rstrip(".")
        if name == self.domain:
            return send(req, 200, {"ok": True})
        vm, _ = self.vm_for_host(name)
        if vm is not None:
            return send(req, 200, {"ok": True})
        if name.endswith("." + self.cloud.int_domain()):
            return send(req, 403, {"ok": False})
        return send(req, 403, {"ok": False})

    # ── VM hosts ───────────────────────────────────────────────────────
    def handle_vm_host(self, req, host, path, query):
        vm, port = self.vm_for_host(host)
        if vm is None:
            return send(req, 404, page("No such VM", "<p>There is no VM at %s.</p>" % html.escape(host)),
                        "text/html; charset=utf-8")
        hostname = host.split(":")[0].lower()
        if path == "/__agentos/callback":
            doc = self.st.take_once("login", (query.get("code") or [""])[0])
            nxt = (query.get("next") or ["/"])[0]
            if not nxt.startswith("/") or nxt.startswith("//"):
                nxt = "/"
            if not doc or doc.get("host") != hostname:
                return send(req, 403, page("Login failed", "<p>The login expired; reload the page.</p>"), "text/html; charset=utf-8")
            return redirect(req, nxt, [self.start_session(doc["uid"], hostname)])
        if path == "/__agentos/login":
            target = (query.get("redirect") or ["/"])[0]
            if not target.startswith("/") or target.startswith("//"):
                target = "/"
            return redirect(req, self.login_url(hostname, target))
        if path == "/__agentos/logout" and req.command == "POST":
            sid = cookies(req).get(COOKIE)
            if sid:
                self.st.delete_session(sid)
            return redirect(req, "/", [self.set_cookie("", 0)])
        if path.startswith("/__agentos/share/"):
            tok = path.rsplit("/", 1)[1]
            link_vm = self.st.link_vm(tok)
            if link_vm is None or link_vm["id"] != vm["id"]:
                return send(req, 404, page("Link revoked", "<p>This share link does not exist (any more).</p>"),
                            "text/html; charset=utf-8")
            user = self.session_user(req, hostname)
            if user is None:
                return redirect(req, self.login_url(hostname, path))
            role = vm["links"][tok].get("role", "web")
            if self.cloud.access(user, vm) is None or (role == "root" and self.cloud.access(user, vm) != "root"):
                vm.setdefault("shares", {})[user["email"].lower()] = role
                self.st.save_vm(vm)
                if role == "root":
                    self.cloud.sync(vm)
                self.cloud.emit("cloud.share.link.used", C.Ctx(user), vm=vm["name"], role=role)
            return redirect(req, "/")
        return send(req, 404, "unknown endpoint", "text/plain")

    def login_url(self, hostname, path):
        nxt = "%s://%s%s" % (self.scheme(), hostname, path)
        return "%s://%s/__agentos/login?%s" % (self.scheme(), self.domain, urllib.parse.urlencode({"next": nxt}))

    def handle_auth(self, req):
        """Caddy forward_auth: may this request reach the VM, and where is it?"""
        host = req.headers.get("X-Forwarded-Host") or req.headers.get("Host") or ""
        uri = req.headers.get("X-Forwarded-Uri") or "/"
        method = req.headers.get("X-Forwarded-Method") or "GET"
        vm, port = self.vm_for_host(host)
        if vm is None:
            return send(req, 404, "no such VM", "text/plain")
        if port is None:
            fwd_port = req.headers.get("X-Forwarded-Port") or ""
            if fwd_port.isdigit() and int(fwd_port) in (self.cfg.get("extra_ports") or []):
                port = int(fwd_port)
        target_port = port or vm.get("port") or 80
        hostname = host.split(":")[0].lower()
        user, ctx_header = None, None
        token = self._vm_token(req)
        if token:
            try:
                user, perms, _fp, vm_scope = self.token_user(token, "v0@%s.%s" % (vm["name"], self.domain))
                if vm_scope and vm_scope != vm["name"]:
                    raise TK.TokenError("token is scoped to another VM")
                if "ctx" in perms:
                    ctx_header = json.dumps(perms["ctx"], separators=(",", ":"))
            except TK.TokenError as exc:
                self.bump("proxy_unauthorized")
                return send(req, 401, {"error": exc.message}, headers=[("WWW-Authenticate", 'Basic realm="%s"' % vm["name"])])
        else:
            user = self.session_user(req, hostname)
        allowed = vm.get("public") or (user is not None and self.cloud.access(user, vm) is not None)
        if not allowed:
            self.bump("proxy_denied")
            if user is None and method in ("GET", "HEAD") and "text/html" in (req.headers.get("Accept") or ""):
                return redirect(req, self.login_url(hostname, uri))
            return send(req, 401 if user is None else 403,
                        page("Private VM", "<p>%s is private.%s</p>" % (html.escape(vm["name"]),
                             "" if user else " <a href='%s'>Log in</a>." % html.escape(self.login_url(hostname, uri)))),
                        "text/html; charset=utf-8")
        if vm.get("desired") != "running" or not vm.get("ip"):
            return send(req, 503, page("VM stopped", "<p>%s is not running.</p>" % html.escape(vm["name"])),
                        "text/html; charset=utf-8")
        headers = [("X-AgentOS-Upstream", "%s:%d" % (vm["ip"], target_port))]
        if user is not None:
            ident = [("Email", user["email"]), ("UserID", user["id"])]
            if ctx_header:
                ident.append(("Token-Ctx", ctx_header))
            for name, value in ident:
                headers.append(("X-AgentOS-" + name, value))
                if self.cfg.get("exe_compat_headers", True):
                    headers.append(("X-ExeDev-" + name, value))
        self.bump("proxy_allowed")
        return send(req, 200, b"", "text/plain", headers)

    def _vm_token(self, req):
        for name in ("X-AgentOS-Authorization", "X-Exedev-Authorization", "Authorization"):
            value = req.headers.get(name) or ""
            if value.startswith("Bearer ") and any(value[7:].startswith(p) for p in TK.ALIASES0 + TK.ALIASES1):
                return value[7:].strip()
            if value.startswith("Basic "):
                try:
                    _, _, pw = base64.b64decode(value[6:]).decode().partition(":")
                except (ValueError, UnicodeDecodeError):
                    continue
                if any(pw.startswith(p) for p in TK.ALIASES0 + TK.ALIASES1):
                    return pw
        return None

    # ── integrations proxy ─────────────────────────────────────────────
    def handle_integration(self, req):
        client = req.client_address[0]
        vm = self.st.vm_by_ip(client)
        if vm is None:
            return send(req, 403, {"error": "integrations are only reachable from AgentOS Cloud VMs"})
        host = (req.headers.get("Host") or "").split(":")[0].lower()
        if host in (self.cfg.get("metadata_ip", "169.254.169.254"), "metadata", "metadata.internal"):
            return send(req, 200, self.metadata(vm))
        team_suffix = ".team." + self.domain
        suffix = "." + self.cloud.int_domain()
        team = host.endswith(team_suffix)
        if not team and not host.endswith(suffix):
            return send(req, 404, {"error": "unknown integration host %s" % host})
        name = host[:-len(team_suffix if team else suffix)]
        if not team and name == self.cfg.get("reflection_name", "reflection"):
            path = urllib.parse.urlsplit(req.path).path.rstrip("/")
            refl = self.reflection(vm)
            if path == "/integrations":
                return send(req, 200, {"integrations": refl["integrations"]})
            return send(req, 200, refl)
        integ = self.cloud.integration_for(vm, name, team=team)
        if integ is None:
            return send(req, 404, {"error": "no integration %r is attached to %s" % (name, vm["name"])})
        self.bump("integration_requests")
        try:
            if integ["type"] == "http-proxy":
                return self.forward(req, integ["target"], req.path, self.secret_headers(integ, vm))
            if integ["type"] == "github":
                return self.forward_github(req, integ)
            if integ["type"] == "llm":
                return self.forward_llm(req, vm)
            if integ["type"] == "peer":
                peer = self.st.vm(integ["peer"]["vm"])
                if peer is None or not peer.get("ip") or not self.same_owner(vm, peer):
                    return send(req, 404, {"error": "the peer VM is gone"})
                return self.forward(req, "http://%s:%d" % (peer["ip"], integ["peer"]["port"]), req.path,
                                    {"X-AgentOS-Peer": vm["name"]})
        except OverflowError:
            return send(req, 413, {"error": "request body too large"})
        return send(req, 500, {"error": "unknown integration type"})

    def metadata(self, vm):
        """The link-local metadata service (169.254.169.254), as on exe.dev VMs."""
        return {"reflection_url": "http://%s.%s" % (self.cfg.get("reflection_name", "reflection"), self.cloud.int_domain()),
                "vm_name": vm["name"], "https_url": self.cloud.vm_url(vm), "domain": self.domain,
                "region": vm.get("region") or self.cfg.get("region")}

    def reflection(self, vm):
        """What a VM may know about itself: its settings and its integrations."""
        owner = self.st.user(vm["owner"]) or {}
        view = self.cloud.view(vm, None, long=True)
        view.pop("ip", None)
        integs = []
        for i in self.cloud.attached_integrations(vm):
            team = i["scope"].startswith("team:")
            url = "http://%s.%s.%s" % (i["name"], "team" if team else "int", self.domain)
            entry = {"name": i["name"], "type": i["type"], "team": team, "url": url, "comment": i.get("comment", "")}
            if i["type"] == "github":
                entry["help"] = "\n".join("git clone %s/%s.git" % (url, r) for r in i.get("repositories", []) if "*" not in r)
                entry["details"] = {"repositories": [{"name": r, "url": "https://github.com/" + r,
                                                      "clone_command": "git clone %s/%s.git" % (url, r)}
                                                     for r in i.get("repositories", []) if "*" not in r]}
            integs.append(entry)
        return {"vm": view, "name": vm["name"], "owner": owner.get("email"), "integrations": integs,
                "llm": self.cloud.llm_env(vm), "domain": self.domain}

    def same_owner(self, a, b):
        if a["owner"] == b["owner"]:
            return True
        return bool(a.get("team")) and a.get("team") == b.get("team")

    def _secret(self, integ, kind, value):
        files = integ.get("secret_files") or {}
        path = files.get("bearer") if kind == "bearer" else (files.get("headers") or {}).get(value)
        if path:
            with open(path) as f:
                return f.read().strip()
        return self.cloud._open(value)

    def secret_headers(self, integ, vm):
        out = {}
        for k, v in (integ.get("headers") or {}).items():
            out[k] = self.cloud._open(v)
        for k in ((integ.get("secret_files") or {}).get("headers") or {}):
            out[k] = self._secret(integ, "header", k)
        if integ.get("bearer") or (integ.get("secret_files") or {}).get("bearer"):
            out["Authorization"] = "Bearer " + self._secret(integ, "bearer", integ.get("bearer"))
        if integ.get("act_as_user"):
            owner = self.st.user(vm["owner"]) or {}
            out["X-AgentOS-Email"] = owner.get("email", "")
        return out

    def forward_github(self, req, integ):
        m = re.fullmatch(r"/([A-Za-z0-9][A-Za-z0-9._-]{0,99})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?(/.*)", urllib.parse.urlsplit(req.path).path)
        if not m:
            return send(req, 404, {"error": "use http://%s.%s/<owner>/<repo>.git" % (integ["name"], self.cloud.int_domain())})
        owner, repo, rest = m.groups()
        full = "%s/%s" % (owner, repo)
        if not any(fnmatch.fnmatchcase(full.lower(), p.lower()) for p in integ.get("repositories") or []):
            return send(req, 403, {"error": "%s is not one of this integration's repositories" % full})
        query = urllib.parse.urlsplit(req.path).query
        pushing = rest.endswith("/git-receive-pack") or "service=git-receive-pack" in query
        if not (rest in ("/info/refs", "/git-upload-pack", "/git-receive-pack") or rest.startswith("/info/lfs")):
            return send(req, 404, {"error": "only the git smart HTTP protocol is proxied"})
        if pushing and integ.get("read_only"):
            return send(req, 403, {"error": "this integration is read-only"})
        token = self._secret(integ, "bearer", integ.get("bearer"))
        auth = "Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode()
        target = (integ.get("target") or "https://github.com").rstrip("/")
        return self.forward(req, target, "/%s.git%s%s" % (full, rest, "?" + query if query else ""), {"Authorization": auth})

    def llm_catalog(self):
        """models.json (schema 1, as exe.dev LLM integrations serve it) from the gateway's price list."""
        try:
            with open(self.cfg.get("pricing_file") or "/etc/agentos/pricing.json") as f:
                models = json.load(f).get("models") or {}
        except (OSError, ValueError):
            models = {}
        apis = {"anthropic": ["anthropic_messages"], "openai": ["openai_responses", "openai_chat"]}
        out = []
        for mid, m in sorted(models.items()):
            provider = (m or {}).get("provider")
            if provider in apis:
                out.append({"id": mid, "provider": provider, "apis": apis[provider],
                            "architecture": {"input_modalities": ["text", "image"]}, "exe_dev": {"mode": "managed"}})
        return {"schema_version": 1, "models": out}

    LLM_ROUTES = (("/v1/messages", "/anthropic"), ("/v1/chat/completions", "/openai"), ("/v1/responses", "/openai"),
                  ("/v1/models", "/openai"), ("/v1/embeddings", "/openai"))

    def forward_llm(self, req, vm):
        path = urllib.parse.urlsplit(req.path).path
        if path == "/models.json":
            return send(req, 200, self.llm_catalog())
        if self.gateway is None:
            return send(req, 503, {"error": "the model gateway is not configured"})
        agent, token = self.gateway.vm_agent(vm)
        target = req.path
        for prefix, provider in self.LLM_ROUTES:
            if path == prefix or path.startswith(prefix + "/"):
                target = provider + req.path
                break
        return self.forward(req, self.gateway.url, "/agent/%s%s" % (agent, target), {"x-agentos-token": token})

    def forward(self, req, target, path, extra, limit=4 * 1024 ** 3):
        """Stream a request to target (scheme://host[:port][/base]) + path."""
        u = urllib.parse.urlsplit(target)
        base = u.path.rstrip("/")
        body, size = spool_body(req, limit)
        try:
            if u.scheme == "https":
                conn = http.client.HTTPSConnection(u.hostname, u.port or 443, timeout=600,
                                                   context=ssl.create_default_context())
            else:
                conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=600)
            headers = {k: v for k, v in req.headers.items() if k.lower() not in HOP and not k.lower().startswith("x-agentos")
                       and not k.lower().startswith("x-exedev")}
            for k in list(headers):
                if k.lower() in {e.lower() for e in extra}:
                    del headers[k]
            headers.update(extra)
            headers["Host"] = u.netloc
            headers["Content-Length"] = str(size)
            conn.request(req.command, base + path, body=body if size else None, headers=headers)
            resp = conn.getresponse()
            req.send_response(resp.status, resp.reason)
            chunked = resp.getheader("Content-Length") is None
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    req.send_header(k, v)
            if chunked:
                req.send_header("Transfer-Encoding", "chunked")
            else:
                req.send_header("Content-Length", resp.getheader("Content-Length"))
            req.end_headers()
            while True:
                chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
                if not chunk:
                    break
                if chunked:
                    req.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                else:
                    req.wfile.write(chunk)
                req.wfile.flush()
            if chunked:
                req.wfile.write(b"0\r\n\r\n")
            conn.close()
        except (OSError, http.client.HTTPException) as exc:
            log.warning("integration upstream %s failed: %s", u.netloc, exc)
            try:
                send(req, 502, {"error": "the integration target did not answer"})
            except OSError:
                pass
        finally:
            body.close()

    # ── metrics and the background loop ───────────────────────────────
    def metrics(self):
        vms = self.st.vms()
        lines = ["# TYPE agentos_cloud_vms gauge"]
        by = {}
        for v in vms:
            by[v.get("status") or "unknown"] = by.get(v.get("status") or "unknown", 0) + 1
        for status, n in sorted(by.items()):
            lines.append('agentos_cloud_vms{status="%s"} %d' % (status, n))
        lines += ["# TYPE agentos_cloud_users gauge", "agentos_cloud_users %d" % len(self.st.users())]
        lines.append("# TYPE agentos_cloud_vcpus_allocated gauge")
        lines.append("agentos_cloud_vcpus_allocated %d" % sum(v["cpu"] for v in vms if v.get("desired") == "running"))
        with self.lock:
            counters = dict(self.counters)
        for name, value in sorted(counters.items()):
            lines += ["# TYPE agentos_cloud_%s_total counter" % name, "agentos_cloud_%s_total %d" % (name, value)]
        return "\n".join(lines) + "\n"

    def tick(self, interval):
        """Restart VMs that should run, and meter usage."""
        day = time.strftime("%Y-%m-%d", time.gmtime(self.clock()))
        for vm in self.st.vms():
            if vm.get("status") == "creating":
                continue
            try:
                live = self.cloud.vmd.stat(vm["id"]) or {}
            except B.BackendError as exc:
                log.warning("stat %s: %s", vm["name"], exc)
                continue
            status = live.get("status")
            if vm.get("desired") == "running" and status == "stopped":
                try:
                    self.cloud.vmd.start(self.cloud.spec_for(vm))
                    status = "running"
                    self.bump("vm_restarts")
                except B.BackendError as exc:
                    log.warning("start %s: %s", vm["name"], exc)
                    status = "failed"
            if status and status != vm.get("status"):
                vm["status"] = status
                self.st.save_vm(vm)
            if status != "running":
                continue
            pool = vm.get("pool") or ("standalone-" + vm["id"])
            owner_pool = vm.get("pool")
            key = "standalone_vcpu_seconds" if vm.get("standalone") else "vcpu_seconds"
            for owner in filter(None, (owner_pool, "vm-" + vm["id"], self.cloud.limits_of(self.st.user(vm["owner"]))[1]
                                       if vm.get("standalone") else None)):
                self.st.add_usage(owner, day, key if owner != "vm-" + vm["id"] else "vcpu_seconds", vm["cpu"] * interval)
            last = vm.get("meter") or {}
            meter = {}
            for field in ("rx_bytes", "tx_bytes", "cpu_seconds"):
                if field in live:
                    meter[field] = live[field]
                    delta = live[field] - last.get(field, 0) if live[field] >= last.get(field, 0) else live[field]
                    if delta > 0:
                        self.st.add_usage("vm-" + vm["id"], day, field, delta)
                        if field != "cpu_seconds" and owner_pool:
                            self.st.add_usage(owner_pool, day, field, delta)
            if meter:
                vm["meter"] = meter
                self.st.save_vm(vm)
            del pool


class GatewayLink:
    """Per-VM agent identities on the AgentOS model gateway (the llm integration)."""

    def __init__(self, url, admin_socket, state):
        self.url = url.rstrip("/")
        self.admin = admin_socket
        self.st = state

    def vm_agent(self, vm):
        agent = "vm-" + vm["id"]
        doc = self.st._get("gwtoken", agent)
        if doc:
            return agent, doc["token"]
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        body = json.dumps({"token_sha256": digest})
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(10)
        s.connect(self.admin)
        s.sendall(("PUT /agents/%s HTTP/1.1\r\nHost: gateway\r\nContent-Type: application/json\r\n"
                   "Content-Length: %d\r\nConnection: close\r\n\r\n%s" % (agent, len(body), body)).encode())
        reply = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            reply += chunk
        s.close()
        if b" 200 " not in reply.split(b"\r\n", 1)[0]:
            raise OSError("the gateway refused the VM identity")
        self.st._put("gwtoken", agent, {"token": token})
        return agent, token


# ── HTTP servers ───────────────────────────────────────────────────────

class ThreadingHTTP(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_web_handler(svc):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "agentos-cloud"

        def log_message(self, fmt, *args):
            log.debug("%s %s", self.address_string(), fmt % args)

        def handle_one(self):
            self.close_connection = True
            url = urllib.parse.urlsplit(self.path)
            path, query = url.path, urllib.parse.parse_qs(url.query)
            host = (self.headers.get("Host") or "").lower()
            try:
                if path == "/__auth":
                    return svc.handle_auth(self)
                if path == "/__agentos/tls-ask":
                    return svc.tls_ask(self, query)
                if host.split(":")[0] == svc.domain:
                    return svc.handle_lobby(self, path, query)
                return svc.handle_vm_host(self, host, path, query)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:
                log.exception("error on %s %s", self.command, self.path)
                try:
                    send(self, 500, {"error": "internal error"})
                except OSError:
                    pass

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = handle_one
    return H


def make_integrations_handler(svc):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "agentos-cloud-integrations"

        def log_message(self, fmt, *args):
            log.debug("integration %s %s", self.address_string(), fmt % args)

        def handle_one(self):
            self.close_connection = True
            try:
                svc.handle_integration(self)
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception:
                log.exception("integration error on %s", self.path)
                try:
                    send(self, 500, {"error": "internal error"})
                except OSError:
                    pass

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = handle_one
    return H


# ── the lobby socket ───────────────────────────────────────────────────

class Lobby:
    """Requests from the lobby SSH entry point (agentos-cloud-lobby)."""

    def __init__(self, svc):
        self.svc = svc

    def handle(self, req, fds):
        op = req.get("op")
        svc, cloud = self.svc, self.svc.cloud
        if op == "authorized-keys":
            return self.authorized_keys(req)
        if op == "redeem":
            try:
                kind, blob, _ = TK.parse_public_key(req.get("public") or "")
            except ValueError as exc:
                raise C.CommandError(str(exc), 400)
            user = cloud.redeem(req.get("code") or "", TK.fingerprint(blob), "%s %s" % (kind, req["public"].split()[1]))
            return {"message": "Welcome, %s. Your key is registered; try `ssh %s@%s help`." % (
                user["email"], svc.cfg["lobby_user"], svc.ssh_host())}
        user = svc.user_by_key(req.get("key") or "")
        if user is None:
            raise C.CommandError("this SSH key is not registered", 401)
        if op == "run":
            ctx = C.Ctx(user, via="ssh", key=req["key"], stdin=req.get("stdin"))
            name, obj = cloud.run(ctx, req.get("argv") or [])
            return {"name": name, "result": obj, "text": C.render(name, obj)}
        if op in ("attach", "tunnel"):
            vm = cloud.find_vm(C.Ctx(user), req.get("vm") or "", "root")
            if vm.get("desired") != "running":
                raise C.CommandError("%s is not running (`start %s`)" % (vm["name"], vm["name"]), 409)
            cloud.emit("cloud.vm.%s" % op, C.Ctx(user), vm=vm["name"], port=req.get("port"))
            if op == "tunnel":
                return {"ip": vm["ip"], "port": int(req.get("port") or 22)}
            return cloud.vmd.attach(vm["id"], req.get("argv") or [], fds, tty=bool(req.get("tty")), term=req.get("term"))
        raise C.CommandError("unknown lobby operation", 400)

    def authorized_keys(self, req):
        """Lines for sshd's AuthorizedKeysCommand: the key, if registered, with its forced command."""
        try:
            kind, blob, _ = TK.parse_public_key("%s %s" % (req.get("type"), req.get("key")))
        except ValueError:
            return {"lines": []}
        fp = TK.fingerprint(blob)
        entry = "%s %s" % (kind, req["key"])
        cmd = self.svc.cfg.get("lobby_command", "/run/current-system/sw/bin/agentos-cloud-lobby")
        if self.svc.user_by_key(fp):
            return {"lines": ['command="%s --key %s",restrict,pty %s' % (cmd, fp, entry)]}
        # Unknown keys may only redeem an invite (or, with open sign-up, register)
        return {"lines": ['command="%s --unregistered %s",restrict,pty %s' % (cmd, entry, entry)]}


def serve_lobby(svc, path, allowed_uids):
    lobby = Lobby(svc)

    class H(socketserver.BaseRequestHandler):
        def handle(self):
            sock = self.request
            fds = []
            try:
                if B.peer_uid(sock) not in allowed_uids:
                    raise C.CommandError("not allowed", 403)
                req, fds = B.recv_request(sock)
                # the VM helper got its own copies of any fds; ours are closed
                # below, or sshd would wait for them before ending the session
                result = lobby.handle(req, fds)
                reply = {"result": result}
            except C.CommandError as exc:
                reply = {"error": exc.message, "status": exc.status}
            except (B.BackendError, StateError) as exc:
                reply = {"error": getattr(exc, "message", str(exc)), "status": getattr(exc, "status", 500)}
            except Exception:
                log.exception("lobby request failed")
                reply = {"error": "internal error", "status": 500}
            finally:
                for fd in fds:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            try:
                sock.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass

    class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
        daemon_threads = True

    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = S(path, H)
    os.chmod(path, 0o660)
    return srv


def main(argv=None):
    ap = argparse.ArgumentParser(description="AgentOS Cloud control plane")
    ap.add_argument("--config", default=None)
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    opts = options(cfg)
    state = State(connect(cfg["redis"]["url"]))
    box = secret_box(opts["secret_key_file"])
    vmd = B.VmdClient((opts.get("vmd") or {}).get("socket", B.VMD_SOCKET))
    audit = auditmod.client_from_config(cfg, "cloud")
    gateway = GatewayLink(opts["gateway_url"], opts["gateway_admin_socket"], state) \
        if opts.get("gateway_url") and opts.get("gateway_admin_socket") else None
    cloud = C.Cloud(opts, state, vmd, audit=audit, box=box)
    svc = CloudService(opts, state, cloud, gateway=gateway)
    svc.apply_declarative()

    import pwd
    allowed = {0}
    try:
        allowed.add(pwd.getpwnam(opts["lobby_user"]).pw_uid)
    except KeyError:
        log.warning("lobby user %s does not exist", opts["lobby_user"])

    servers = [ThreadingHTTP((opts["web_listen"], int(opts["web_port"])), make_web_handler(svc))]
    # VMs reach it on port 80 of the bridge address and of 169.254.169.254:
    # the host redirects both to this port (modules/cloud)
    servers.append(ThreadingHTTP((opts["gateway_ip"], int(opts["integrations_port"])), make_integrations_handler(svc)))

    class M(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            send(self, 200, svc.metrics(), "text/plain; version=0.0.4")

        def log_message(self, *a):
            pass
    servers.append(ThreadingHTTP((opts["metrics_listen"], int(opts["metrics_port"])), M))
    servers.append(serve_lobby(svc, opts["lobby_socket"], allowed))
    for s in servers:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    healthmod.sd_notify("READY=1")
    log.info("serving %s (web %s:%s, integrations %s:%s)", opts["domain"], opts["web_listen"], opts["web_port"],
             opts["gateway_ip"], opts["integrations_port"])
    interval = int(opts.get("tick_sec", 60))
    while True:
        try:
            svc.tick(interval)
        except Exception:
            log.exception("tick failed")
        healthmod.sd_notify("WATCHDOG=1")
        time.sleep(interval)


if __name__ == "__main__":
    main()
