"""Redis model of Nestlo Cloud.

Documents are JSON strings under nestlo:cloud:<kind>:<id>, with indices for
the lookups the control plane needs. Names that must be unique (VM names,
emails, key fingerprints, custom domains) are claimed with SET NX so two
concurrent requests cannot both get one.
"""

import json
import os
import re
import secrets
import time

import redis

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,40}[a-z0-9]$|^[a-z]$")
EMAIL_RE = re.compile(r"^[^@\s]{1,64}@[A-Za-z0-9.-]{1,190}\.[A-Za-z]{2,}$")
DOMAIN_RE = re.compile(r"^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")
TAG_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,31}$")
ROLES = ("user", "admin", "billing_owner")
SHARE_ROLES = ("web", "root")
RESERVED_NAMES = {"www", "api", "int", "lobby", "login", "admin", "mail", "ssh", "exec", "static"}


class StateError(Exception):
    """A refusal the caller reports to the user (status for the HTTP API)."""

    def __init__(self, message, status=422):
        super().__init__(message)
        self.status = status
        self.message = message


def url_token(nbytes=18):
    """A URL-safe random token that cannot be mistaken for a command-line flag."""
    while True:
        tok = secrets.token_urlsafe(nbytes)
        if tok[0].isalnum():
            return tok


def new_id(nbytes=4):
    return secrets.token_hex(nbytes)


def valid_vm_name(name):
    return bool(NAME_RE.match(name or "")) and name not in RESERVED_NAMES and "--" not in name


def norm_email(email):
    email = (email or "").strip()
    if not EMAIL_RE.match(email):
        raise StateError("invalid email address %r" % email, 400)
    local, _, host = email.rpartition("@")
    return local + "@" + host.lower()


class State:
    def __init__(self, client, prefix="nestlo:cloud", clock=time.time):
        self.r = client
        self.prefix = prefix
        self.clock = clock

    def _k(self, *parts):
        return ":".join((self.prefix,) + tuple(str(p) for p in parts))

    # ── generic documents ──────────────────────────────────────────────
    def _get(self, kind, key):
        raw = self.r.get(self._k(kind, key))
        return json.loads(raw) if raw else None

    def _put(self, kind, key, doc, ttl=None):
        self.r.set(self._k(kind, key), json.dumps(doc, sort_keys=True), ex=ttl)

    def _claim(self, index, name, value):
        """Claim a unique name; False if it is taken."""
        return bool(self.r.hsetnx(self._k("idx", index), name, value))

    def _release(self, index, name, value=None):
        key = self._k("idx", index)
        if value is None or self.r.hget(key, name) == value:
            self.r.hdel(key, name)

    def _lookup(self, index, name):
        return self.r.hget(self._k("idx", index), name)

    # ── users ──────────────────────────────────────────────────────────
    def create_user(self, email, plan="personal", admin=False, name=None):
        email = norm_email(email)
        uid = "u" + new_id(5)
        if not self._claim("email", email.lower(), uid):
            raise StateError("a user with email %s exists" % email, 409)
        user = {"id": uid, "email": email, "name": name or email.split("@")[0], "plan": plan,
                "admin": bool(admin), "team": None, "created": int(self.clock()), "disabled": False,
                "pool_cpu": None, "pool_memory_mb": None, "region": None}
        self._put("user", uid, user)
        self.r.sadd(self._k("users"), uid)
        return user

    def user(self, uid):
        return self._get("user", uid) if uid else None

    def user_by_email(self, email):
        uid = self._lookup("email", (email or "").strip().lower())
        return self.user(uid)

    def users(self):
        return sorted((u for u in (self.user(i) for i in self.r.smembers(self._k("users"))) if u),
                      key=lambda u: u["email"])

    def save_user(self, user):
        self._put("user", user["id"], user)

    def ensure_user(self, email, **kw):
        return self.user_by_email(email) or self.create_user(email, **kw)

    # ── SSH keys ───────────────────────────────────────────────────────
    def add_key(self, uid, fp, public, name, tag=None, api=False):
        if not self._claim("key", fp, uid):
            if self._lookup("key", fp) == uid:
                raise StateError("this key is already registered to you", 409)
            raise StateError("this key is registered to another user", 409)
        doc = {"fp": fp, "uid": uid, "public": public, "name": name, "tag": tag, "api": api,
               "created": int(self.clock())}
        self._put("key", fp, doc)
        self.r.sadd(self._k("user-keys", uid), fp)
        return doc

    def key(self, fp):
        return self._get("key", fp)

    def keys_of(self, uid):
        return sorted((k for k in (self.key(fp) for fp in self.r.smembers(self._k("user-keys", uid))) if k),
                      key=lambda k: k["created"])

    def all_keys(self):
        out = []
        for uid in self.r.smembers(self._k("users")):
            out.extend(self.keys_of(uid))
        return out

    def remove_key(self, uid, fp):
        if self._lookup("key", fp) != uid:
            raise StateError("no such key", 404)
        self._release("key", fp, uid)
        self.r.delete(self._k("key", fp))
        self.r.srem(self._k("user-keys", uid), fp)

    def save_key(self, doc):
        self._put("key", doc["fp"], doc)

    # ── teams ──────────────────────────────────────────────────────────
    def create_team(self, name, owner_uid, plan="work"):
        tid = "t" + new_id(5)
        team = {"id": tid, "name": name, "plan": plan, "members": {owner_uid: "billing_owner"},
                "settings": {"vm_sharing": "all-members"}, "created": int(self.clock()),
                "pool_cpu": None, "pool_memory_mb": None, "billing": {}}
        self._put("team", tid, team)
        self.r.sadd(self._k("teams"), tid)
        owner = self.user(owner_uid)
        owner["team"] = tid
        self.save_user(owner)
        return team

    def team(self, tid):
        return self._get("team", tid) if tid else None

    def save_team(self, team):
        self._put("team", team["id"], team)

    def delete_team(self, tid):
        team = self.team(tid)
        for uid in (team or {}).get("members", {}):
            u = self.user(uid)
            if u and u.get("team") == tid:
                u["team"] = None
                self.save_user(u)
        self.r.delete(self._k("team", tid))
        self.r.srem(self._k("teams"), tid)

    # ── VMs ────────────────────────────────────────────────────────────
    def create_vm(self, vm):
        if not self._claim("vm", vm["name"], vm["id"]):
            raise StateError("a VM named %s exists" % vm["name"], 409)
        self._put("vm", vm["id"], vm)
        self.r.sadd(self._k("vms"), vm["id"])
        self.r.sadd(self._k("owner-vms", vm["owner"]), vm["id"])
        return vm

    def vm(self, vid):
        return self._get("vm", vid) if vid else None

    def vm_by_name(self, name):
        return self.vm(self._lookup("vm", name or ""))

    def vms(self):
        return [v for v in (self.vm(i) for i in sorted(self.r.smembers(self._k("vms")))) if v]

    def vms_of(self, uid):
        return sorted((v for v in (self.vm(i) for i in self.r.smembers(self._k("owner-vms", uid))) if v),
                      key=lambda v: v["name"])

    def save_vm(self, vm):
        self._put("vm", vm["id"], vm)

    def rename_vm(self, vm, new):
        if not self._claim("vm", new, vm["id"]):
            raise StateError("a VM named %s exists" % new, 409)
        self._release("vm", vm["name"], vm["id"])
        vm["name"] = new
        self.save_vm(vm)

    def transfer_vm(self, vm, new_owner):
        self.r.srem(self._k("owner-vms", vm["owner"]), vm["id"])
        vm["owner"] = new_owner
        self.r.sadd(self._k("owner-vms", new_owner), vm["id"])
        self.save_vm(vm)

    def delete_vm(self, vm):
        self._release("vm", vm["name"], vm["id"])
        for d in vm.get("domains", []):
            self._release("domain", d, vm["id"])
        for tok in vm.get("links", {}):
            self.r.delete(self._k("link", tok))
        self.r.delete(self._k("vm", vm["id"]))
        self.r.srem(self._k("vms"), vm["id"])
        self.r.srem(self._k("owner-vms", vm["owner"]), vm["id"])

    def allocate_ip(self, vid, network):
        """Lowest free address of the VM network (host is .1)."""
        base, bits = network.split("/")
        a, b, c, d = (int(x) for x in base.split("."))
        start = (a << 24) | (b << 16) | (c << 8) | d
        size = 1 << (32 - int(bits))
        for n in range(2, size - 1):
            ip = start + n
            addr = "%d.%d.%d.%d" % (ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255)
            if self._claim("ip", addr, vid):
                return addr
        raise StateError("the VM network %s is full" % network, 507)

    def release_ip(self, addr, vid):
        if addr:
            self._release("ip", addr, vid)

    def vm_by_ip(self, addr):
        return self.vm(self._lookup("ip", addr or ""))

    # ── custom domains ─────────────────────────────────────────────────
    def claim_domain(self, domain, vid):
        if not self._claim("domain", domain, vid):
            raise StateError("%s is already registered" % domain, 409)

    def release_domain(self, domain, vid):
        self._release("domain", domain, vid)

    def vm_by_domain(self, domain):
        return self.vm(self._lookup("domain", (domain or "").lower()))

    # ── share links ────────────────────────────────────────────────────
    def add_link(self, vm, role="web"):
        tok = url_token(18)
        vm.setdefault("links", {})[tok] = {"created": int(self.clock()), "role": role}
        self.save_vm(vm)
        self.r.set(self._k("link", tok), vm["id"])
        return tok

    def link_vm(self, tok):
        return self.vm(self.r.get(self._k("link", tok)))

    def remove_link(self, vm, tok):
        if tok not in vm.get("links", {}):
            raise StateError("no such share link", 404)
        del vm["links"][tok]
        self.save_vm(vm)
        self.r.delete(self._k("link", tok))

    # ── integrations ───────────────────────────────────────────────────
    def integration_key(self, scope, name):
        return "%s/%s" % (scope, name)

    def put_integration(self, integ, new=False):
        key = self.integration_key(integ["scope"], integ["name"])
        if new and not self._claim("integration", key, key):
            raise StateError("an integration named %s exists" % integ["name"], 409)
        self._put("integration", key, integ)
        self.r.sadd(self._k("integrations"), key)

    def integration(self, scope, name):
        return self._get("integration", self.integration_key(scope, name))

    def integrations(self):
        return [i for i in (self._get("integration", k) for k in sorted(self.r.smembers(self._k("integrations")))) if i]

    def delete_integration(self, integ):
        key = self.integration_key(integ["scope"], integ["name"])
        self._release("integration", key)
        self.r.delete(self._k("integration", key))
        self.r.srem(self._k("integrations"), key)

    # ── invites ────────────────────────────────────────────────────────
    def create_invite(self, by_uid, email=None, team=None, role="user", days=7, plan=None):
        code = url_token(12)
        doc = {"code": code, "by": by_uid, "email": email, "team": team, "role": role, "plan": plan,
               "created": int(self.clock()), "exp": int(self.clock()) + days * 86400, "used_by": None}
        self._put("invite", code, doc, ttl=days * 86400)
        self.r.sadd(self._k("invites", by_uid), code)
        return doc

    def invite(self, code):
        return self._get("invite", code)

    def save_invite(self, doc):
        ttl = max(1, doc["exp"] - int(self.clock()))
        self._put("invite", doc["code"], doc, ttl=ttl)

    def invites_of(self, uid):
        out = []
        for code in sorted(self.r.smembers(self._k("invites", uid))):
            doc = self.invite(code)
            if doc:
                out.append(doc)
            else:
                self.r.srem(self._k("invites", uid), code)
        return out

    # ── short tokens, sessions, login codes ────────────────────────────
    def put_short_token(self, token0, vm=None, ttl=None):
        handle = "nestlo1." + secrets.token_urlsafe(24)
        self._put("short", handle, {"token": token0, "vm": vm}, ttl=ttl)
        return handle

    def short_token(self, handle):
        return self._get("short", handle)

    def put_session(self, uid, host, ttl):
        sid = secrets.token_urlsafe(32)
        self._put("session", sid, {"uid": uid, "host": host, "created": int(self.clock())}, ttl=ttl)
        return sid

    def session(self, sid, host):
        doc = self._get("session", sid) if sid else None
        if not doc or doc.get("host") != host:
            return None
        user = self.user(doc["uid"])
        return user if user and not user.get("disabled") else None

    def delete_session(self, sid):
        self.r.delete(self._k("session", sid))

    def put_once(self, kind, doc, ttl):
        code = secrets.token_urlsafe(24)
        self._put("once-" + kind, code, doc, ttl=ttl)
        return code

    def take_once(self, kind, code):
        """Read and delete a one-time document (GETDEL), or None."""
        if not code or len(code) > 200:
            return None
        raw = self.r.getdel(self._k("once-" + kind, code))
        return json.loads(raw) if raw else None

    # ── usage metering ─────────────────────────────────────────────────
    def add_usage(self, owner, day, field, amount):
        key = self._k("usage", owner, day)
        self.r.hincrbyfloat(key, field, amount)
        self.r.expire(key, 400 * 86400)

    def usage(self, owner, days):
        out = {}
        for day in days:
            for field, value in (self.r.hgetall(self._k("usage", owner, day)) or {}).items():
                out[field] = out.get(field, 0.0) + float(value)
        return out

    def rate_limited(self, key, limit, window=60):
        """Count one event for `key`; True once more than `limit` happened in the window."""
        if limit <= 0:
            return False
        k = self._k("rate", key, int(self.clock()) // window)
        n = self.r.incr(k)
        if n == 1:
            self.r.expire(k, window * 2)
        return n > limit


def connect(url):
    return redis.Redis.from_url(url, decode_responses=True)


def secret_box(path):
    """A Fernet box for integration secrets, keyed from a file (created on first use)."""
    from cryptography.fernet import Fernet
    if not os.path.exists(path):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(Fernet.generate_key())
    with open(path, "rb") as f:
        return Fernet(f.read().strip())
