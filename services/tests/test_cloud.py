"""AgentOS Cloud: tokens, plans, commands, the web/API/proxy service, the lobby and the backend."""

import base64
import http.client
import http.server
import json
import os
import shutil
import subprocess
import threading
import time

import fakeredis
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa

from agentos_services.cloud import backend as B
from agentos_services.cloud import commands as C
from agentos_services.cloud import plans as P
from agentos_services.cloud import server as S
from agentos_services.cloud import tokens as TK
from agentos_services.cloud.state import State, secret_box

DOMAIN = "cloud.test"
NOW = 1_800_000_000


class Clock:
    def __init__(self):
        self.t = NOW

    def __call__(self):
        return self.t


class FakeVmd:
    def __init__(self):
        self.calls = []
        self.running = set()
        self.fail_create = False

    def _rec(self, op, *a):
        self.calls.append((op,) + a)

    def create(self, spec, setup=None, prompt=None, registry_auth=None):
        self._rec("create", spec, setup, prompt)
        if self.fail_create:
            raise B.BackendError("disk full")
        self.running.add(spec["id"])
        return {"status": "running"}

    def start(self, spec):
        self._rec("start", spec)
        self.running.add(spec["id"])

    def stop(self, vid):
        self._rec("stop", vid)
        self.running.discard(vid)

    def destroy(self, vid):
        self._rec("destroy", vid)
        self.running.discard(vid)

    def resize(self, spec):
        self._rec("resize", spec)

    def copy(self, src, spec):
        self._rec("copy", src, spec)
        self.running.add(spec["id"])

    def stat(self, vid):
        return {"status": "running" if vid in self.running else "stopped", "rx_bytes": 1000, "tx_bytes": 500,
                "cpu_seconds": 3.0}

    def status(self, vid):
        return {"status": "running" if vid in self.running else "stopped"}

    def sync(self, spec):
        self._rec("sync", spec)

    def attach(self, vid, argv, fds, tty=False, term=None):
        self._rec("attach", vid, argv)
        return {"exit": 0}


class Audit:
    def __init__(self):
        self.events = []

    def emit(self, etype, actor, **data):
        self.events.append((etype, actor, data))


def cfg(**over):
    c = dict(S.DEFAULTS)
    c.update(domain=DOMAIN, verify_dns=False, images={"agentos": "/nix/store/x-image"}, gateway_url=None)
    c.update(over)
    return c


@pytest.fixture
def env(tmp_path):
    clock = Clock()
    st = State(fakeredis.FakeRedis(server=fakeredis.FakeServer(), decode_responses=True), clock=clock)
    vmd = FakeVmd()
    audit = Audit()
    box = secret_box(str(tmp_path / "secret.key"))
    cloud = C.Cloud(cfg(), st, vmd, audit=audit, box=box, clock=clock)
    svc = S.CloudService(cloud.cfg, st, cloud, clock=clock)

    class E:
        pass
    e = E()
    e.clock, e.st, e.vmd, e.audit, e.cloud, e.svc, e.tmp = clock, st, vmd, audit, cloud, svc, tmp_path
    e.alice = st.create_user("alice@example.com", plan="work")
    e.bob = st.create_user("bob@example.com", plan="work")
    e.alice_key = ed25519.Ed25519PrivateKey.generate()
    line = TK.public_line(e.alice_key)
    e.alice_fp = TK.fingerprint(TK.parse_public_key(line)[1])
    st.add_key(e.alice["id"], e.alice_fp, line, "laptop")
    e.bob_key = ed25519.Ed25519PrivateKey.generate()
    bline = TK.public_line(e.bob_key)
    e.bob_fp = TK.fingerprint(TK.parse_public_key(bline)[1])
    st.add_key(e.bob["id"], e.bob_fp, bline, "bob")

    def run(user, line, via="ssh", perms=None):
        u = st.user(user["id"])
        return cloud.run_line(C.Ctx(u, via=via, key=e.alice_fp, perms=perms), line)[1]
    e.run = run
    return e


# ── tokens ─────────────────────────────────────────────────────────────

def test_token_roundtrip_and_namespaces(env):
    tok = TK.make_token(env.alice_key, {"exp": NOW + 60, "cmds": ["ls"]}, "v0@" + DOMAIN)
    perms, fp = TK.decode(tok, "v0@" + DOMAIN, now=NOW)
    assert fp == env.alice_fp and perms["cmds"] == ["ls"]
    with pytest.raises(TK.TokenError, match="signed for"):
        TK.decode(tok, "v0@web." + DOMAIN, now=NOW)
    with pytest.raises(TK.TokenError, match="expired"):
        TK.decode(tok, "v0@" + DOMAIN, now=NOW + 61)
    exe = "exe0." + tok.split(".", 1)[1]
    assert TK.decode(exe, "v0@" + DOMAIN, now=NOW)[1] == env.alice_fp


def test_token_tamper_and_permission_rules(env):
    tok = TK.make_token(env.alice_key, {"exp": NOW + 60}, "v0@" + DOMAIN)
    head, payload, sig = tok.split(".")
    forged = TK.b64url(b'{"exp":4000000000}')
    with pytest.raises(TK.TokenError, match="verification failed"):
        TK.decode("%s.%s.%s" % (head, forged, sig), "v0@" + DOMAIN, now=NOW)
    for bad in (b' {"exp":1900000000}', b'{"exp":1900000000,"exp":1900000001}', b'{"foo":1}',
                b'{"exp":1.5}', b'{"exp":99}', b'{"cmds":"ls"}', b'{\n}'):
        with pytest.raises(TK.TokenError):
            TK.parse_permissions(bad)
    with pytest.raises(TK.TokenError, match="8 KB"):
        TK.decode("agentos0." + "a" * 9000, "v0@x", now=NOW)
    assert TK.allows({}, "ls") and not TK.allows({}, "rm") and TK.allows({"cmds": ["rm"]}, "rm")
    assert not TK.allows({"cmds": ["ssh-key"]}, "ssh-key list")


@pytest.mark.parametrize("keytype", ["ecdsa", "rsa"])
def test_verify_other_key_types_with_ssh_keygen(tmp_path, keytype):
    keygen = shutil.which("ssh-keygen")
    if not keygen:
        pytest.skip("ssh-keygen not available")
    path = str(tmp_path / "k")
    subprocess.run([keygen, "-q", "-t", keytype, "-N", "", "-f", path], check=True)
    perms = b'{"cmds":["ls"],"exp":1900000000}'
    sig = subprocess.run([keygen, "-Y", "sign", "-f", path, "-n", "v0@" + DOMAIN], input=perms,
                         capture_output=True, check=True).stdout.decode()
    blob = "".join(sig.strip().splitlines()[1:-1])
    tok = "agentos0.%s.%s" % (TK.b64url(perms), TK.b64url(base64.b64decode(blob)))
    pub = open(path + ".pub").read()
    perms_out, fp = TK.decode(tok, "v0@" + DOMAIN, now=NOW)
    assert fp == TK.fingerprint(TK.parse_public_key(pub)[1]) and perms_out["cmds"] == ["ls"]


def test_ssh_keygen_verifies_our_signature(tmp_path):
    keygen = shutil.which("ssh-keygen")
    if not keygen:
        pytest.skip("ssh-keygen not available")
    key = ed25519.Ed25519PrivateKey.generate()
    msg = b'{"exp":1900000000}'
    sig = TK.sign_sshsig(key, msg, "v0@" + DOMAIN)
    (tmp_path / "sig").write_text(TK.armor(sig))
    (tmp_path / "allowed").write_text("me " + TK.public_line(key) + "\n")
    p = subprocess.run([keygen, "-Y", "verify", "-f", str(tmp_path / "allowed"), "-I", "me", "-n", "v0@" + DOMAIN,
                        "-s", str(tmp_path / "sig")], input=msg, capture_output=True)
    assert p.returncode == 0, p.stderr


# ── plans ──────────────────────────────────────────────────────────────

def test_plan_limits_and_sizes():
    lim = P.limits("personal")
    assert lim["pool_cpu"] == 2 and lim["disk_gb"] == 100 and not lim["sharing"]
    assert P.limits("work")["bandwidth_gb"] == 200
    with pytest.raises(P.QuotaError, match="at most 16"):
        P.check_pool_size(lim, 32, 8192)
    assert P.parse_size_mb("8GB") == 8192 and P.parse_size_mb("512MB") == 512 and P.parse_size_mb("2") == 2048
    assert P.parse_disk_gb("1500MB") == 2
    with pytest.raises(P.QuotaError):
        P.parse_size_mb("lots")
    vms = [{"id": "a", "disk_gb": 90}]
    with pytest.raises(P.QuotaError, match="disk quota"):
        P.check_new_vm(lim, vms, 1, 1024, 20, False)
    with pytest.raises(P.QuotaError, match="more vCPUs"):
        P.check_new_vm(lim, [], 4, 1024, 10, False)


# ── commands ───────────────────────────────────────────────────────────

def test_new_ls_and_views(env):
    out = env.run(env.alice, "new --name web --cpu 2 --memory 4GB --tag prod --env FOO=bar --comment hi")
    assert out["vm_name"] == "web" and out["https_url"] == "https://web.cloud.test/" and out["tags"] == ["prod"]
    create = env.vmd.calls[0]
    assert create[0] == "create" and create[1]["env"]["FOO"] == "bar" and create[1]["memory_mb"] == 4096
    assert create[1]["ip"] == "10.210.0.2" and create[1]["pool"] == "user-" + env.alice["id"]
    assert "reflection.int.cloud.test" in create[1]["hosts"]
    vm = env.st.vm_by_name("web")
    assert "FOO" not in json.dumps(vm)          # env is sealed at rest
    ls = env.run(env.alice, "ls --json")
    assert [v["vm_name"] for v in ls["vms"]] == ["web"] and ls["vms"][0]["status"] == "running"
    assert env.run(env.bob, "ls")["vms"] == []
    with pytest.raises(C.CommandError, match="exists"):
        env.run(env.alice, "new --name web")
    with pytest.raises(C.CommandError, match="bad VM name"):
        env.run(env.alice, "new --name Web_1")
    desc = env.run(env.alice, "new --help")
    assert desc["command"] == "new" and "--cpu" in desc["flags"]


def test_new_failure_releases_name_and_ip(env):
    env.vmd.fail_create = True
    with pytest.raises(B.BackendError):
        env.run(env.alice, "new --name web")
    assert env.st.vm_by_name("web") is None
    env.vmd.fail_create = False
    assert env.run(env.alice, "new --name web")["ip"] == "10.210.0.2"


def test_quota_enforced_on_new_and_resize(env):
    with pytest.raises(C.CommandError, match="more vCPUs"):
        env.run(env.alice, "new --name big --cpu 8")
    env.run(env.alice, "billing capacity --cpu 8 --memory 16GB")
    env.run(env.alice, "new --name big --cpu 8")
    with pytest.raises(C.CommandError, match="only grow"):
        env.run(env.alice, "resize big --disk 1GB")
    out = env.run(env.alice, "resize big --disk 40GB --memory 8GB")
    assert out["disk"] == "40 GB" and env.vmd.calls[-1][0] == "resize"
    sa = env.run(env.alice, "new --name sand --standalone --cpu 16")
    assert sa["standalone"] and env.vmd.calls[-1][1]["pool"] is None


def test_lifecycle_rename_tag_comment_cp_rm(env):
    env.run(env.alice, "new --name web")
    env.run(env.alice, "stop web")
    assert env.st.vm_by_name("web")["desired"] == "stopped"
    env.run(env.alice, "start web")
    env.run(env.alice, "restart web")
    env.run(env.alice, "rename web site")
    assert env.st.vm_by_name("site") and env.st.vm_by_name("web") is None
    assert env.run(env.alice, "tag site a b")["tags"] == ["a", "b"]
    assert env.run(env.alice, "tag -d site a")["tags"] == ["b"]
    assert env.run(env.alice, "comment site staging copy")["comment"] == "staging copy"
    cp = env.run(env.alice, "cp site site2 --disk 30GB")
    assert cp["vm_name"] == "site2" and env.vmd.calls[-1][0] == "copy" and env.st.vm_by_name("site2")["tags"] == ["b"]
    with pytest.raises(C.CommandError, match="no VM"):
        env.run(env.bob, "rm site")
    env.run(env.alice, "rm site site2")
    assert env.st.vms() == [] and env.st.vm_by_ip("10.210.0.2") is None
    assert ("cloud.vm.delete", "alice@example.com", {"vm": "site"}) in env.audit.events


def test_sharing_roles_and_links(env):
    env.run(env.alice, "new --name web")
    vm = env.st.vm_by_name("web")
    assert env.cloud.access(env.bob, vm) is None
    env.run(env.alice, "share add web bob@example.com")
    vm = env.st.vm_by_name("web")
    assert env.cloud.access(env.bob, vm) == "web"
    with pytest.raises(C.CommandError, match="web access"):
        env.run(env.bob, "restart web")
    env.run(env.alice, "share add web bob@example.com --role root")
    assert env.vmd.calls[-1][0] == "sync" and len(env.vmd.calls[-1][1]["authorized_keys"]) == 2
    env.run(env.bob, "restart web")
    with pytest.raises(C.CommandError, match="owner"):
        env.run(env.bob, "share set-public web")
    link = env.run(env.alice, "share add-link web")
    assert link["url"].startswith("https://web.cloud.test/__agentos/share/")
    show = env.run(env.alice, "share show web")
    assert show["visibility"] == "private" and show["users"] == [{"email": "bob@example.com", "role": "root"}]
    env.run(env.alice, "share remove-link web " + link["token"])
    env.run(env.alice, "share remove web bob@example.com")
    assert env.cloud.access(env.bob, env.st.vm_by_name("web")) is None
    assert env.run(env.alice, "share port web 8000")["port"] == 8000
    env.run(env.alice, "share set-public web")
    assert env.st.vm_by_name("web")["public"]


def test_personal_plan_cannot_share_but_can_publish(env):
    carol = env.st.create_user("carol@example.com", plan="personal")
    env.run(carol, "new --name pers")
    with pytest.raises(C.CommandError, match="not part of the personal plan"):
        env.run(carol, "share add pers bob@example.com")
    env.run(carol, "share set-public pers")


def test_domains(env):
    env.run(env.alice, "new --name web")
    env.run(env.alice, "domain add web app.example.org")
    assert env.st.vm_by_domain("app.example.org")["name"] == "web"
    with pytest.raises(C.CommandError, match="already registered"):
        env.run(env.bob, "new --name other") and env.run(env.bob, "domain add other app.example.org")
    with pytest.raises(C.CommandError, match="bad domain"):
        env.run(env.alice, "domain add web foo.cloud.test")
    assert env.run(env.alice, "domain ls -a")["domains"] == [{"vm_name": "web", "domain": "app.example.org"}]
    env.run(env.alice, "domain rm web app.example.org")
    assert env.st.vm_by_domain("app.example.org") is None


def test_dns_check(env, monkeypatch):
    env.cloud.cfg["verify_dns"] = True
    env.cloud.cfg["public_addresses"] = ["203.0.113.7"]
    env.run(env.alice, "new --name web")
    monkeypatch.setattr(C.socket, "getaddrinfo", lambda host, *a, **k: [(0, 0, 0, "", ("198.51.100.1", 443))])
    with pytest.raises(C.CommandError, match="not to this host"):
        env.run(env.alice, "domain add web app.example.org")
    monkeypatch.setattr(C.socket, "getaddrinfo", lambda host, *a, **k: [(0, 0, 0, "", ("203.0.113.7", 443))])
    env.run(env.alice, "domain add web app.example.org")


def test_ssh_keys_and_api_tokens(env):
    other = ed25519.Ed25519PrivateKey.generate()
    out = env.run(env.alice, "ssh-key add '%s' --name desk" % TK.public_line(other, "x@y"))
    assert out["name"] == "desk"
    assert len(env.run(env.alice, "ssh-key list")["keys"]) == 2
    with pytest.raises(C.CommandError, match="already registered"):
        env.run(env.alice, "ssh-key add '%s'" % TK.public_line(other))
    with pytest.raises(C.CommandError, match="connected with this key"):
        env.run(env.alice, "ssh-key remove laptop")
    env.run(env.alice, "ssh-key rename desk desk2")
    env.run(env.alice, "ssh-key remove desk2")
    tok = env.run(env.alice, "ssh-key generate-api-key --cmds=ls,new --exp=1d --label ci")
    perms, fp = TK.decode(tok["token"], "v0@" + DOMAIN, now=NOW)
    assert perms["cmds"] == ["ls", "new"] and perms["exp"] == NOW + 86400
    assert env.st.key(fp)["name"] == "api:ci" and env.st.key(fp)["api"]
    with pytest.raises(C.CommandError, match="unknown command"):
        env.run(env.alice, "ssh-key generate-api-key --cmds=launch")
    short = env.run(env.alice, "token-exchange " + tok["token"])["token"]
    assert short.startswith("agentos1.") and env.st.short_token(short)["token"] == tok["token"]


def test_token_scoped_commands(env):
    perms = {"cmds": ["ls"]}
    env.run(env.alice, "ls", via="http", perms=perms)
    with pytest.raises(C.CommandError) as exc:
        env.run(env.alice, "new", via="http", perms=perms)
    assert exc.value.status == 403
    with pytest.raises(C.CommandError, match="terminal"):
        env.run(env.alice, "ssh web", via="http", perms={"cmds": ["ssh"]})
    with pytest.raises(C.CommandError) as exc:
        env.run(env.alice, "launch")
    assert exc.value.status == 404


def test_integrations_attach_and_shadowing(env):
    env.run(env.alice, "new --name web --tag app")
    out = env.run(env.alice, "integrations add http-proxy --name stripe --target https://api.stripe.com "
                             "--bearer sk_live_1 --header 'X-A: 1' --attach tag:app")
    assert out["url"] == "http://stripe.int.cloud.test/" and out["has_bearer"]
    raw = env.st.integration(env.alice["id"], "stripe")
    assert "sk_live_1" not in json.dumps(raw)
    vm = env.st.vm_by_name("web")
    assert env.cloud.integration_for(vm, "stripe")["target"] == "https://api.stripe.com"
    assert "stripe.int.cloud.test" in env.cloud.spec_for(vm)["hosts"]
    env.run(env.alice, "integrations detach stripe tag:app")
    assert env.cloud.integration_for(vm, "stripe") is None
    env.run(env.alice, "integrations attach stripe vm:web")
    assert env.cloud.integration_for(vm, "stripe")
    with pytest.raises(C.CommandError, match="needs at least one"):
        env.run(env.alice, "integrations add github --name gh --bearer x")
    env.run(env.alice, "integrations add github --name gh --repository acme/web --bearer ghp_x --read-only --attach auto:all")
    env.run(env.alice, "integrations rename gh code")
    assert env.st.integration(env.alice["id"], "code")["read_only"]
    env.run(env.alice, "integrations add peer --name db --vm web --port 5432")
    assert env.st.integration(env.alice["id"], "db")["peer"]["port"] == 5432
    with pytest.raises(C.CommandError, match="gateway is not enabled"):
        env.run(env.alice, "integrations add llm --name llm")
    env.run(env.alice, "integrations remove code")
    assert [i["name"] for i in env.run(env.alice, "integrations list")["integrations"]] == ["db", "stripe"]


def test_llm_env_when_attached(env):
    env.cloud.cfg["gateway_url"] = "http://127.0.0.1:8080"
    env.run(env.alice, "integrations add llm --name llm --attach auto:all")
    env.run(env.alice, "new --name web")
    spec = env.vmd.calls[-1][1]
    assert spec["env"]["ANTHROPIC_BASE_URL"] == "http://llm.int.cloud.test/anthropic"
    assert spec["env"]["OPENAI_BASE_URL"] == "http://llm.int.cloud.test/openai/v1"


def test_teams_roles_and_team_vms(env):
    t = env.run(env.alice, "team create Acme")
    assert t["members"] == [{"email": "alice@example.com", "role": "billing_owner"}]
    env.run(env.alice, "team add bob@example.com")
    env.run(env.bob, "new --name bobvm")
    vm = env.st.vm_by_name("bobvm")
    assert vm["team"] and vm["pool"].startswith("team-")
    assert env.cloud.access(env.st.user(env.alice["id"]), vm) == "root"   # billing owner sees team VMs
    assert [v["vm_name"] for v in env.run(env.alice, "team vm ls")["vms"]] == ["bobvm"]
    with pytest.raises(C.CommandError, match="team admins"):
        env.run(env.bob, "team role alice@example.com user")
    env.run(env.alice, "team settings vm-sharing admins-only")
    with pytest.raises(C.CommandError, match="only team admins may share"):
        env.run(env.bob, "share add bobvm carol@example.com")
    env.run(env.alice, "team transfer bobvm alice@example.com") if False else None
    env.run(env.bob, "team transfer bobvm alice@example.com")
    assert env.st.vm_by_name("bobvm")["owner"] == env.alice["id"]
    with pytest.raises(C.CommandError, match="last billing owner"):
        env.run(env.alice, "team remove alice@example.com")
    invite = env.run(env.alice, "team add dave@example.com --role admin")
    assert invite["code"] and "redeem" in invite["message"]
    with pytest.raises(C.CommandError, match="--yes"):
        env.run(env.alice, "team disable")
    env.run(env.alice, "team disable --yes")
    assert env.st.vm_by_name("bobvm")["team"] is None and env.st.user(env.bob["id"])["team"] is None


def test_invites_and_redeem(env):
    inv = env.run(env.alice, "invite create --email new@example.com --days 3")
    newkey = ed25519.Ed25519PrivateKey.generate()
    line = TK.public_line(newkey)
    _, blob, _ = TK.parse_public_key(line)
    user = env.cloud.redeem(inv["code"], TK.fingerprint(blob), line)
    assert user["email"] == "new@example.com" and user["plan"] == "work"
    with pytest.raises(C.CommandError, match="not valid"):
        env.cloud.redeem(inv["code"], TK.fingerprint(blob), line)
    with pytest.raises(C.CommandError, match="administrators"):
        env.run(env.alice, "invite create --email x@example.com --plan enterprise")


def test_billing_usage_and_admin(env):
    env.run(env.alice, "new --name web")
    env.svc.tick(60)
    use = env.run(env.alice, "billing usage --range 24h")
    assert use["vcpu_hours"] == round(2 * 60 / 3600, 2) and use["running"] == 1
    stat = env.run(env.alice, "stat web")
    assert stat["live"]["rx_bytes"] == 1000
    with pytest.raises(C.CommandError, match="administrators"):
        env.run(env.alice, "admin users")
    admin = env.st.create_user("root@example.com", admin=True)
    env.run(admin, "admin user plan bob@example.com personal")
    assert env.st.user(env.bob["id"])["plan"] == "personal"
    env.run(admin, "admin user disable bob@example.com")
    assert env.svc.user_by_key(env.bob_fp) is None


def test_tick_restarts_vms_that_should_run(env):
    env.run(env.alice, "new --name web")
    vm = env.st.vm_by_name("web")
    env.vmd.running.discard(vm["id"])
    env.svc.tick(60)
    assert env.vmd.calls[-1][0] == "start" and vm["id"] in env.vmd.running


def test_render_text(env):
    env.run(env.alice, "new --name web")
    text = C.render("ls", env.run(env.alice, "ls"))
    assert "VM_NAME" in text and "web" in text
    assert "new" in C.render("help", env.run(env.alice, "help"))


# ── web service ────────────────────────────────────────────────────────

@pytest.fixture
def web(env):
    srv = S.ThreadingHTTP(("127.0.0.1", 0), S.make_web_handler(env.svc))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env.cloud.cfg["tls"] = "off"
    yield srv.server_address[1]
    srv.shutdown()


def req(port, method, path, host=DOMAIN, body=None, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    h = {"Host": host}
    h.update(headers or {})
    c.request(method, path, body=body, headers=h)
    r = c.getresponse()
    data = r.read()
    return r.status, dict(r.getheaders()), data


def test_exec_api(env, web):
    tok = TK.make_token(env.alice_key, {"exp": NOW + 600, "cmds": ["ls", "new", "whoami"]}, "v0@" + DOMAIN)
    auth = {"Authorization": "Bearer " + tok}
    s, _, b = req(web, "POST", "/exec", body=b"whoami", headers=auth)
    assert s == 200 and json.loads(b)["email"] == "alice@example.com"
    s, _, b = req(web, "POST", "/exec", body=b"new --name api1", headers=auth)
    assert s == 200 and json.loads(b)["vm_name"] == "api1"
    assert req(web, "POST", "/exec", body=b"rm api1", headers=auth)[0] == 403
    assert req(web, "POST", "/exec", body=b"launch", headers=auth)[0] == 404
    assert req(web, "POST", "/exec", body=b"new --name api1", headers=auth)[0] == 409
    assert req(web, "POST", "/exec", body=b"", headers=auth)[0] == 400
    assert req(web, "POST", "/exec", body=b"ls 'x", headers=auth)[0] == 400
    assert req(web, "GET", "/exec", headers=auth)[0] == 405
    assert req(web, "POST", "/exec", body=b"x" * (64 * 1024 + 1), headers=auth)[0] == 413
    assert req(web, "POST", "/exec", body=b"ls")[0] == 401
    bad = TK.make_token(ed25519.Ed25519PrivateKey.generate(), {}, "v0@" + DOMAIN)
    assert req(web, "POST", "/exec", body=b"ls", headers={"Authorization": "Bearer " + bad})[0] == 401
    short = env.st.put_short_token(tok)
    assert req(web, "POST", "/exec", body=b"ls", headers={"Authorization": "Bearer " + short})[0] == 200
    env.cloud.cfg["exec_rate_per_minute"] = 2
    codes = [req(web, "POST", "/exec", body=b"ls", headers=auth)[0] for _ in range(3)]
    assert 429 in codes


def test_exec_timeout(env, web):
    env.cloud.cfg["exec_timeout_sec"] = 0.2
    orig = env.vmd.create

    def slow(*a, **k):
        time.sleep(0.6)
        return orig(*a, **k)
    env.vmd.create = slow
    tok = TK.make_token(env.alice_key, {"cmds": ["new"]}, "v0@" + DOMAIN)
    assert req(web, "POST", "/exec", body=b"new --name slow", headers={"Authorization": "Bearer " + tok})[0] == 504


def login(env, web, user, host):
    """Magic link on the lobby, then the cross-domain hop to `host`; returns the host cookie."""
    code = env.st.put_once("magic", {"uid": user["id"]}, ttl=600)
    s, h, _ = req(web, "GET", "/__agentos/magic/" + code)
    assert s == 302
    lobby_cookie = h["Set-Cookie"].split(";")[0]
    assert req(web, "GET", "/__agentos/magic/" + code)[0] == 403        # one time only
    s, h, _ = req(web, "GET", "/__agentos/login?next=http://%s/app" % host, headers={"Cookie": lobby_cookie})
    assert s == 302 and h["Location"].startswith("http://%s/__agentos/callback?" % host)
    path = h["Location"].split(host, 1)[1]
    s, h, _ = req(web, "GET", path, host=host)
    assert s == 302 and h["Location"] == "/app"
    return h["Set-Cookie"].split(";")[0], lobby_cookie


def test_forward_auth_private_public_and_identity(env, web):
    env.run(env.alice, "new --name web --port 8000")
    host = "web." + DOMAIN
    fwd = {"X-Forwarded-Host": host, "X-Forwarded-Uri": "/x", "X-Forwarded-Method": "GET"}
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Accept="text/html"))
    assert s == 302 and "/__agentos/login?next=" in h["Location"]
    assert req(web, "GET", "/__auth", host="127.0.0.1", headers=fwd)[0] == 401
    cookie, _ = login(env, web, env.alice, host)
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Cookie=cookie))
    assert s == 200 and h["X-AgentOS-Upstream"] == "10.210.0.2:8000"
    assert h["X-AgentOS-Email"] == "alice@example.com" and h["X-ExeDev-Email"] == "alice@example.com"
    # the cookie of one VM host is not valid on another host
    env.run(env.alice, "new --name other")
    assert req(web, "GET", "/__auth", host="127.0.0.1",
               headers=dict(fwd, Cookie=cookie, **{"X-Forwarded-Host": "other." + DOMAIN}))[0] == 401
    bob_cookie, _ = login(env, web, env.bob, host)
    assert req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Cookie=bob_cookie))[0] == 403
    env.run(env.alice, "share set-public web")
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=fwd)
    assert s == 200 and "X-AgentOS-Email" not in h
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, **{"X-Forwarded-Host": "web-3000." + DOMAIN}))
    assert h["X-AgentOS-Upstream"] == "10.210.0.2:3000"
    env.run(env.alice, "stop web")
    assert req(web, "GET", "/__auth", host="127.0.0.1", headers=fwd)[0] == 503


def test_vm_tokens_basic_and_bearer(env, web):
    env.run(env.alice, "new --name web")
    tok = env.run(env.alice, "ssh-key generate-api-key --vm web --label deploy")["token"]
    assert tok and TK.decode(tok, "v0@web." + DOMAIN, now=NOW)
    fwd = {"X-Forwarded-Host": "web." + DOMAIN, "X-Forwarded-Uri": "/repo.git/info/refs"}
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, **{"X-AgentOS-Authorization": "Bearer " + tok}))
    assert s == 200 and h["X-AgentOS-Email"] == "alice@example.com"
    basic = base64.b64encode(("git:" + tok).encode()).decode()
    assert req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Authorization="Basic " + basic))[0] == 200
    ctx_tok = TK.make_token(env.alice_key, {"ctx": {"role": "deploy"}}, "v0@web." + DOMAIN)
    s, h, _ = req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Authorization="Bearer " + ctx_tok))
    assert s == 200 and json.loads(h["X-AgentOS-Token-Ctx"]) == {"role": "deploy"}
    api_tok = TK.make_token(env.alice_key, {}, "v0@" + DOMAIN)
    assert req(web, "GET", "/__auth", host="127.0.0.1", headers=dict(fwd, Authorization="Bearer " + api_tok))[0] == 401


def test_share_link_flow(env, web):
    env.run(env.alice, "new --name web")
    link = env.run(env.alice, "share add-link web")
    host = "web." + DOMAIN
    path = "/__agentos/share/" + link["token"]
    s, h, _ = req(web, "GET", path, host=host)
    assert s == 302 and "/__agentos/login" in h["Location"]
    cookie, _ = login(env, web, env.bob, host)
    s, h, _ = req(web, "GET", path, host=host, headers={"Cookie": cookie})
    assert s == 302 and env.cloud.access(env.bob, env.st.vm_by_name("web")) == "web"
    env.run(env.alice, "share remove-link web " + link["token"])
    assert req(web, "GET", path, host=host, headers={"Cookie": cookie})[0] == 404


def test_login_rejects_open_redirects_and_tls_ask(env, web):
    _, lobby = login(env, web, env.alice, DOMAIN) if False else (None, None)
    code = env.st.put_once("magic", {"uid": env.alice["id"]}, ttl=600)
    lobby = req(web, "GET", "/__agentos/magic/" + code)[1]["Set-Cookie"].split(";")[0]
    s, h, _ = req(web, "GET", "/__agentos/login?next=http://evil.example/x", headers={"Cookie": lobby})
    assert s == 302 and h["Location"] == "/"
    env.run(env.alice, "new --name web")
    env.run(env.alice, "domain add web app.example.org")
    assert req(web, "GET", "/__agentos/tls-ask?domain=app.example.org")[0] == 200
    assert req(web, "GET", "/__agentos/tls-ask?domain=web.cloud.test")[0] == 200
    assert req(web, "GET", "/__agentos/tls-ask?domain=web-8080.cloud.test")[0] == 200
    assert req(web, "GET", "/__agentos/tls-ask?domain=nope.cloud.test")[0] == 403
    assert req(web, "GET", "/__agentos/tls-ask?domain=evil.example")[0] == 403
    # a login code is bound to its host
    code = env.st.put_once("login", {"uid": env.alice["id"], "host": "web." + DOMAIN}, ttl=60)
    assert req(web, "GET", "/__agentos/callback?code=" + code, host="app.example.org")[0] == 403


def test_home_page_and_key_form(env, web):
    code = env.st.put_once("magic", {"uid": env.alice["id"]}, ttl=600)
    cookie = req(web, "GET", "/__agentos/magic/" + code)[1]["Set-Cookie"].split(";")[0]
    s, _, body = req(web, "GET", "/", headers={"Cookie": cookie})
    assert s == 200 and b"alice@example.com" in body
    csrf = env.svc.csrf(type("R", (), {"headers": {"Cookie": cookie}})())
    key = TK.public_line(ed25519.Ed25519PrivateKey.generate())
    form = "csrf=%s&key=%s" % (csrf, key.replace(" ", "+").replace("/", "%2F").replace("+", "%2B", 0))
    import urllib.parse
    form = urllib.parse.urlencode({"csrf": csrf, "key": key})
    hdr = {"Cookie": cookie, "Content-Type": "application/x-www-form-urlencoded"}
    assert req(web, "POST", "/__agentos/keys", body=form, headers=hdr)[0] == 302
    assert len(env.st.keys_of(env.alice["id"])) == 2
    bad = urllib.parse.urlencode({"csrf": "x", "key": key})
    assert req(web, "POST", "/__agentos/keys", body=bad, headers=hdr)[0] == 403


# ── integrations proxy ─────────────────────────────────────────────────

class Echo(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []

    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        Echo.seen.append({"path": self.path, "method": self.command, "headers": dict(self.headers), "body": body})
        data = json.dumps({"ok": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = _do

    def log_message(self, *a):
        pass


@pytest.fixture
def proxy(env):
    Echo.seen = []
    upstream = S.ThreadingHTTP(("127.0.0.1", 0), Echo)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    srv = S.ThreadingHTTP(("127.0.0.1", 0), S.make_integrations_handler(env.svc))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    # the test client connects from 127.0.0.1: make that the VM's address
    env.run(env.alice, "new --name web --tag app")
    vm = env.st.vm_by_name("web")
    env.st.release_ip(vm["ip"], vm["id"])
    vm["ip"] = "127.0.0.1"
    env.st.save_vm(vm)
    env.st._claim("ip", "127.0.0.1", vm["id"])
    yield srv.server_address[1], upstream.server_address[1]
    srv.shutdown()
    upstream.shutdown()


def test_http_proxy_injects_secrets(env, proxy):
    port, up = proxy
    env.run(env.alice, "integrations add http-proxy --name api --target http://127.0.0.1:%d/v1 --bearer s3cret "
                       "--header 'X-Key: k' --attach tag:app --act-as-user" % up)
    s, _, b = req(port, "POST", "/charges?x=1", host="api.int." + DOMAIN, body=b"amount=5",
                  headers={"Authorization": "Bearer fake", "X-AgentOS-Email": "forged@x"})
    assert s == 200 and json.loads(b) == {"ok": True}
    got = Echo.seen[-1]
    assert got["path"] == "/v1/charges?x=1" and got["body"] == b"amount=5"
    assert got["headers"]["Authorization"] == "Bearer s3cret" and got["headers"]["X-Key"] == "k"
    assert got["headers"]["X-AgentOS-Email"] == "alice@example.com"
    assert req(port, "GET", "/", host="nope.int." + DOMAIN)[0] == 404
    env.run(env.alice, "integrations detach api tag:app")
    assert req(port, "GET", "/", host="api.int." + DOMAIN)[0] == 404


def test_reflection_and_unknown_clients(env, proxy):
    port, _ = proxy
    s, _, b = req(port, "GET", "/", host="reflection.int." + DOMAIN)
    meta = json.loads(b)
    assert s == 200 and meta["vm"]["vm_name"] == "web" and meta["owner"] == "alice@example.com"
    vm = env.st.vm_by_name("web")
    env.st.release_ip("127.0.0.1", vm["id"])
    assert req(port, "GET", "/", host="reflection.int." + DOMAIN)[0] == 403


def test_github_integration_rules(env, proxy):
    port, up = proxy
    env.run(env.alice, "integrations add github --name gh --repository acme/* --bearer ghp_t --read-only --attach vm:web")
    integ = env.st.integration(env.alice["id"], "gh")
    integ["target"] = "http://127.0.0.1:%d" % up
    env.st.put_integration(integ)
    host = "gh.int." + DOMAIN
    s, _, _ = req(port, "GET", "/acme/web.git/info/refs?service=git-upload-pack", host=host)
    assert s == 200
    got = Echo.seen[-1]
    assert got["path"] == "/acme/web.git/info/refs?service=git-upload-pack"
    assert base64.b64decode(got["headers"]["Authorization"][6:]) == b"x-access-token:ghp_t"
    assert req(port, "GET", "/other/web.git/info/refs?service=git-upload-pack", host=host)[0] == 403
    assert req(port, "POST", "/acme/web.git/git-receive-pack", host=host, body=b"x")[0] == 403
    assert req(port, "GET", "/acme/web.git/objects/xx", host=host)[0] == 404


def test_peer_integration(env, proxy):
    port, up = proxy
    env.run(env.alice, "new --name db")
    db = env.st.vm_by_name("db")
    env.st.release_ip(db["ip"], db["id"])
    db["ip"] = "127.0.0.1"   # the upstream echo server plays the peer
    env.st.save_vm(db)
    env.run(env.alice, "integrations add peer --name db --vm db --port %d --attach vm:web" % up)
    s, _, _ = req(port, "GET", "/health", host="db.int." + DOMAIN)
    assert s == 200 and Echo.seen[-1]["headers"]["X-AgentOS-Peer"] == "web"


# ── lobby ──────────────────────────────────────────────────────────────

def test_lobby_operations(env):
    lobby = S.Lobby(env.svc)
    pub = TK.public_line(env.alice_key).split()
    lines = lobby.handle({"op": "authorized-keys", "type": pub[0], "key": pub[1]}, [])["lines"]
    assert lines[0].startswith('command="/run/current-system/sw/bin/agentos-cloud-lobby --key %s",restrict,pty' % env.alice_fp)
    stranger = TK.public_line(ed25519.Ed25519PrivateKey.generate()).split()
    lines = lobby.handle({"op": "authorized-keys", "type": stranger[0], "key": stranger[1]}, [])["lines"]
    assert "--unregistered %s %s" % (stranger[0], stranger[1]) in lines[0]
    out = lobby.handle({"op": "run", "key": env.alice_fp, "argv": ["new", "--name", "web"]}, [])
    assert out["result"]["vm_name"] == "web" and "Created web" in out["text"]
    with pytest.raises(C.CommandError, match="not registered"):
        lobby.handle({"op": "run", "key": "SHA256:nope", "argv": ["ls"]}, [])
    assert lobby.handle({"op": "attach", "key": env.alice_fp, "vm": "web", "argv": ["id"]}, [0, 1, 2]) == {"exit": 0}
    assert lobby.handle({"op": "tunnel", "key": env.alice_fp, "vm": "web", "port": "22"}, []) == {"ip": "10.210.0.2", "port": 22}
    with pytest.raises(C.CommandError, match="no VM"):
        lobby.handle({"op": "attach", "key": env.bob_fp, "vm": "web"}, [0, 1, 2])
    inv = env.run(env.alice, "invite create --email eve@example.com")
    msg = lobby.handle({"op": "redeem", "code": inv["code"], "public": " ".join(stranger)}, [])["message"]
    assert "eve@example.com" in msg


def test_declarative_users_and_system_integrations(env, tmp_path):
    secret = tmp_path / "gh"
    secret.write_text("ghp_file\n")
    key = TK.public_line(ed25519.Ed25519PrivateKey.generate(), "ops")
    env.svc.cfg.update(users=[{"email": "ops@example.com", "admin": True, "plan": "enterprise", "keys": [key]}],
                       integrations=[{"name": "github", "type": "github", "repositories": ["acme/*"],
                                      "bearer_file": str(secret), "attach": ["auto:all"]}])
    env.svc.apply_declarative()
    ops = env.st.user_by_email("ops@example.com")
    assert ops["admin"] and ops["plan"] == "enterprise" and len(env.st.keys_of(ops["id"])) == 1
    env.run(env.alice, "new --name web")
    integ = env.cloud.integration_for(env.st.vm_by_name("web"), "github")
    assert integ["scope"] == "system" and env.svc._secret(integ, "bearer", None) == "ghp_file"
    env.svc.cfg["integrations"] = []
    env.svc.apply_declarative()
    assert env.st.integration("system", "github") is None


# ── backend ────────────────────────────────────────────────────────────

class Recorder:
    def __init__(self):
        self.argvs = []

    def __call__(self, argv, check=True, input=None, timeout=900):
        self.argvs.append(argv)
        out = ""
        if argv[:2] == ["machinectl", "show"]:
            out = "4242\n"
        rc = 1 if argv[:2] == ["mountpoint", "-q"] or argv[:3] == ["systemctl", "is-active", "--quiet"] else 0
        return subprocess.CompletedProcess(argv, rc, out, "")


def test_nspawn_create_composes_commands(tmp_path):
    init = tmp_path / "init"
    init.write_text("#!/bin/sh\n")
    image = tmp_path / "image"
    (image / "etc").mkdir(parents=True)
    rec = Recorder()
    d = B.Nspawn({"state_dir": str(tmp_path / "state"), "bridge": "agentoscl0", "gateway_ip": "10.210.0.1",
                  "images": {"agentos": str(image)}, "init": str(init)}, runner=rec)
    spec = {"id": "0a1b2c3d", "name": "web", "image": "agentos", "cpu": 2, "memory_mb": 4096, "disk_gb": 20,
            "ip": "10.210.0.2", "env": {"FOO": "bar baz"}, "pool": "user-u1", "pool_cpu": 4, "pool_memory_mb": 8192,
            "authorized_keys": ["ssh-ed25519 AAAA x"], "hosts": ["llm.int.cloud.test"]}
    d.create(spec, setup="apt-get install -y git")
    flat = [" ".join(a) for a in rec.argvs]
    assert any(a.startswith("truncate -s 20G") for a in flat) and any(a.startswith("mkfs.ext4") for a in flat)
    run = next(a for a in rec.argvs if a[0] == "systemd-run")
    assert "--slice=agentos-cloud-user_u1.slice" in run and "--property=CPUQuota=200%" in run
    assert "--property=MemoryMax=4096M" in run and "--private-users=pick" in run and "--as-pid2" in run
    assert "--network-bridge=agentoscl0" in run and "--bind-ro=/nix/store" in run
    assert any("set-property --runtime agentos-cloud-user_u1.slice CPUQuota=400% MemoryMax=8192M" in a for a in flat)
    assert any(a.startswith("nsenter -t 4242 -n ip addr replace 10.210.0.2/16 dev host0") for a in flat)
    assert any("ip saddr != 10.210.0.2 drop" in a for a in flat)
    root = d.root("0a1b2c3d")
    assert "export FOO='bar baz'" in open(os.path.join(root, ".agentos/env")).read()
    assert open(os.path.join(root, ".agentos/setup")).read().startswith("#!/bin/sh\napt-get")
    assert "10.210.0.1 llm.int.cloud.test" in open(os.path.join(root, "etc/hosts")).read()
    assert open(os.path.join(root, "root/.ssh/authorized_keys")).read() == "ssh-ed25519 AAAA x\n"
    with pytest.raises(B.BackendError):
        d.dir("../etc")
    argv, env = d.attach_argv("0a1b2c3d", ["id"], "xterm")
    assert os.path.basename(argv[0]) == "nsenter" and argv[1:5] == ["-t", "4242", "-a", "--"]
    assert argv[-1] == "id" and env["TERM"] == "xterm"


def test_nspawn_refuses_writes_outside_the_vm(tmp_path):
    d = B.Nspawn({"state_dir": str(tmp_path), "bridge": "b", "gateway_ip": "10.0.0.1"}, runner=Recorder())
    root = d.root("0a1b2c3d")
    os.makedirs(os.path.join(root, "etc"))
    os.symlink("/tmp", os.path.join(root, "evil"))
    with pytest.raises(B.BackendError, match="outside"):
        d._write("0a1b2c3d", "/evil/x", "boom")


# ── exe.dev compatibility inside VMs (metadata, reflection, team hosts, llm) ──

def test_metadata_and_reflection_integrations(env, proxy):
    port, _ = proxy
    s, _, b = req(port, "GET", "/", host="169.254.169.254")
    meta = json.loads(b)
    assert s == 200 and meta["reflection_url"] == "http://reflection.int." + DOMAIN and meta["vm_name"] == "web"
    env.run(env.alice, "integrations add github --name gh --repository acme/web --bearer t --attach vm:web")
    s, _, b = req(port, "GET", "/integrations", host="reflection.int." + DOMAIN)
    integ = json.loads(b)["integrations"]
    assert integ[0]["name"] == "gh" and integ[0]["type"] == "github" and not integ[0]["team"]
    assert integ[0]["details"]["repositories"][0]["clone_command"] == "git clone http://gh.int.%s/acme/web.git" % DOMAIN


def test_team_integration_host(env, proxy):
    port, up = proxy
    env.run(env.alice, "team create Acme")
    env.run(env.alice, "integrations add http-proxy --name api --team --target http://127.0.0.1:%d --attach auto:all" % up)
    # the VM was created before the team: give it to the team
    vm = env.st.vm_by_name("web")
    vm["team"] = env.st.user(env.alice["id"])["team"]
    env.st.save_vm(vm)
    assert req(port, "GET", "/x", host="api.team." + DOMAIN)[0] == 200
    assert "api.team." + DOMAIN in env.cloud.spec_for(vm)["hosts"]
    env.run(env.alice, "integrations add http-proxy --name api --target http://127.0.0.1:1 --attach auto:all")
    # the personal one shadows on int., the team one stays on team.
    assert req(port, "GET", "/x", host="api.team." + DOMAIN)[0] == 200


def test_llm_integration_catalog_and_routes(env, proxy, tmp_path):
    port, up = proxy
    pricing = tmp_path / "pricing.json"
    pricing.write_text(json.dumps({"models": {"claude-sonnet-5-5": {"provider": "anthropic"},
                                              "gpt-6": {"provider": "openai"}, "llama": {"provider": "local"}}}))
    env.svc.cfg["pricing_file"] = str(pricing)
    env.cloud.cfg["gateway_url"] = "http://127.0.0.1:%d" % up

    class GW:
        url = "http://127.0.0.1:%d" % up

        def vm_agent(self, vm):
            return "vm-" + vm["id"], "tok"
    env.svc.gateway = GW()
    env.run(env.alice, "integrations add llm --name llm --attach auto:all")
    s, _, b = req(port, "GET", "/models.json", host="llm.int." + DOMAIN)
    cat = json.loads(b)
    assert cat["schema_version"] == 1 and [m["id"] for m in cat["models"]] == ["claude-sonnet-5-5", "gpt-6"]
    assert cat["models"][0]["apis"] == ["anthropic_messages"]
    vid = env.st.vm_by_name("web")["id"]
    req(port, "POST", "/v1/messages", host="llm.int." + DOMAIN, body=b"{}")
    assert Echo.seen[-1]["path"] == "/agent/vm-%s/anthropic/v1/messages" % vid
    assert Echo.seen[-1]["headers"]["x-agentos-token"] == "tok"
    req(port, "POST", "/v1/responses", host="llm.int." + DOMAIN, body=b"{}")
    assert Echo.seen[-1]["path"] == "/agent/vm-%s/openai/v1/responses" % vid
    req(port, "POST", "/anthropic/v1/messages", host="llm.int." + DOMAIN, body=b"{}")
    assert Echo.seen[-1]["path"] == "/agent/vm-%s/anthropic/v1/messages" % vid


def test_every_cloud_audit_event_is_a_known_type():
    import re
    from agentos_services import audit as A
    src = ""
    for name in ("commands.py", "server.py"):
        src += open(os.path.join(os.path.dirname(C.__file__), name)).read()
    emitted = set(re.findall(r'emit\("(cloud\.[a-z.]+)"', src))
    emitted |= {"cloud.vm.attach", "cloud.vm.tunnel"}          # emit("cloud.vm.%s" % op)
    assert emitted and emitted <= A.EVENT_TYPES, emitted - A.EVENT_TYPES


def test_lobby_socket_closes_forwarded_fds(env, tmp_path):
    """sshd ends a session only when every copy of its pipes is closed."""
    import socket as so
    path = str(tmp_path / "l.sock")
    srv = S.serve_lobby(env.svc, path, {os.getuid()})
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    env.run(env.alice, "new --name web")
    r, w = os.pipe()
    s = so.socket(so.AF_UNIX, so.SOCK_STREAM)
    s.connect(path)
    import array
    msg = json.dumps({"op": "attach", "key": env.alice_fp, "vm": "web", "argv": ["true"]}).encode() + b"\n"
    s.sendmsg([msg], [(so.SOL_SOCKET, so.SCM_RIGHTS, array.array("i", [w, w, w]))])
    assert json.loads(s.makefile().readline())["result"] == {"exit": 0}
    s.close()
    os.close(w)
    os.set_blocking(r, False)
    time.sleep(0.2)
    assert os.read(r, 10) == b""      # EOF: the service kept no copy of the write end
    srv.shutdown()
