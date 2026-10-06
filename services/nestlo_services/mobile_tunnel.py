"""Tunnel providers for the phone app (docs/mobile-protocol.md, "Tunnel providers").

A tunnel makes the machine reachable from outside its network. Each provider is
a small adapter: how to start its command (`argv`), how to find the public
endpoint in the output (`parse`), and how the app should trust it. The
`nestlo-mobile-tunnel` systemd unit runs `nestlo-mobile tunnel-run`, which runs
the chosen provider and publishes the endpoint in tunnel.json:

    {"provider", "url" | ("host", "port"), "trust": "webpki" | "pin",
     "landing_only"?: true, "expires_at"?: ISO time}

Secrets are files read from the unit's credentials directory; they reach the
tool through its environment or a 0600 file, never through a QR code or the Nix
store. If no endpoint shows up within 60 s the unit fails and tunnel-error holds
the last lines of output.
"""

import collections
import contextlib
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
ENDPOINT_TIMEOUT = 60
OUTPUT_TAIL = 20


def write_text_atomic(path, text, mode=0o600):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=directory)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def clean(line):
    return ANSI_RE.sub("", line or "")


def parse_tunnel_url(text):
    """The quick-tunnel URL in cloudflared's output (a log line or the boxed banner), or None."""
    m = re.search(r"https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com\b", clean(text))
    return m.group(0) if m else None


class Ctx:
    """What an adapter needs: the settings of its provider and the machine."""

    def __init__(self, name, cfg, bins, port=7443, onboarding_port=7080, creds="", state=""):
        self.name, self.cfg, self.bins = name, cfg or {}, bins or {}
        self.port, self.onboarding_port = port, onboarding_port
        self.creds, self.state = creds, state

    def bin(self, tool):
        return self.bins.get(tool) or tool

    def secret(self, key):
        """Contents of the credential file the provider setting `key` names."""
        name = self.cfg.get(key)
        if not name:
            return None
        path = os.path.join(self.creds, name) if self.creds else name
        with open(path) as f:
            return f.read().strip()


def _url_ep(provider, url, trust="webpki", **extra):
    return dict({"provider": provider, "url": url.rstrip("/"), "trust": trust}, **extra)


def _tcp_ep(provider, host, port, trust="pin", **extra):
    return dict({"provider": provider, "host": host, "port": int(port), "trust": trust}, **extra)


class Provider:
    name = ""
    account = "none"             # none | token | account | server
    trust = "webpki"
    needs = ()                   # provider settings that must be set (module marks "configured")
    note = ""
    detach = False               # the command exits after setting things up (tailscale funnel --bg)
    pre = None                   # optional setup command, run first

    def argv(self, ctx):
        raise NotImplementedError

    def env(self, ctx):
        return {}

    def parse(self, line, ctx):
        """The endpoint dict when this output line announces it, else None."""
        raise NotImplementedError

    def static(self, ctx):
        """An endpoint known before the command prints anything, else None."""
        return None

    def stop_argv(self, ctx):
        return None


class Cloudflare(Provider):
    name, account, trust = "cloudflare", "none", "webpki"
    note = "quick tunnel, temporary trycloudflare.com URL"

    def argv(self, ctx):
        return [ctx.bin("cloudflared"), "tunnel", "--no-autoupdate", "--url", "https://127.0.0.1:%d" % ctx.port,
                "--no-tls-verify"]

    def parse(self, line, ctx):
        url = parse_tunnel_url(line)
        return _url_ep(self.name, url) if url else None


class CloudflareNamed(Provider):
    name, account, trust = "cloudflare-named", "account", "webpki"
    needs = ("tokenCredential", "url")
    note = "named tunnel; the public hostname is routed in the Cloudflare dashboard to https://127.0.0.1:7443"

    def argv(self, ctx):
        return [ctx.bin("cloudflared"), "tunnel", "--no-autoupdate", "run", "--token-file",
                os.path.join(ctx.creds, ctx.cfg["tokenCredential"])]

    def static(self, ctx):
        return _url_ep(self.name, ctx.cfg["url"]) if ctx.cfg.get("url") else None

    def parse(self, line, ctx):
        return None


class TailscaleFunnel(Provider):
    name, account, trust = "tailscale-funnel", "account", "webpki"
    detach = True
    note = "needs a tailnet with Funnel enabled"

    def argv(self, ctx):
        return [ctx.bin("tailscale"), "funnel", "--bg", "https+insecure://127.0.0.1:%d" % ctx.port]

    def stop_argv(self, ctx):
        return [ctx.bin("tailscale"), "funnel", "reset"]

    def parse(self, line, ctx):
        m = re.search(r"https://[A-Za-z0-9][A-Za-z0-9.-]*\.ts\.net", clean(line))
        return _url_ep(self.name, m.group(0)) if m else None


class Ngrok(Provider):
    name, account, trust = "ngrok", "token", "webpki"
    needs = ("authtokenCredential",)
    note = "ngrok authtoken; a reserved domain is optional"

    def argv(self, ctx):
        a = [ctx.bin("ngrok"), "http", "https://127.0.0.1:%d" % ctx.port, "--log", "stdout", "--log-format", "json"]
        if ctx.cfg.get("domain"):
            a += ["--url", "https://" + ctx.cfg["domain"].replace("https://", "")]
        return a

    def env(self, ctx):
        return {"NGROK_AUTHTOKEN": ctx.secret("authtokenCredential") or ""}

    def parse(self, line, ctx):
        line = clean(line)
        if "started tunnel" not in line:
            return None
        try:
            url = json.loads(line).get("url", "")
        except ValueError:
            m = re.search(r'"url":"(https://[^"]+)"', line)
            url = m.group(1) if m else ""
        return _url_ep(self.name, url) if url.startswith("https://") else None


class Zrok(Provider):
    name, account, trust = "zrok", "token", "webpki"
    needs = ("tokenCredential",)
    note = "zrok enable token (zrok.io or a self-hosted instance via `server`)"

    def pre(self, ctx):
        if os.path.exists(os.path.join(ctx.state, ".zrok", "environment.json")):
            return None
        return [ctx.bin("zrok"), "enable", "--headless", ctx.secret("tokenCredential") or ""]

    def argv(self, ctx):
        return [ctx.bin("zrok"), "share", "public", "https://127.0.0.1:%d" % ctx.port, "--insecure", "--headless"]

    def env(self, ctx):
        e = {"HOME": ctx.state}
        if ctx.cfg.get("server"):
            e["ZROK_API_ENDPOINT"] = ctx.cfg["server"]
        return e

    def parse(self, line, ctx):
        m = re.search(r"https://[A-Za-z0-9][A-Za-z0-9.-]*\.[a-z]{2,}", clean(line))
        if not m or any(d in m.group(0) for d in ("github.com", "zrok.io/docs", "openziti.io")):
            return None
        return _url_ep(self.name, m.group(0))


class _Ssh(Provider):
    def ssh(self, ctx, *tail):
        return [ctx.bin("ssh"), "-o", "StrictHostKeyChecking=accept-new",
                "-o", "UserKnownHostsFile=" + os.path.join(ctx.state, "known_hosts"),
                "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes", "-o", "PasswordAuthentication=no", *tail]


class Pinggy(_Ssh):
    name, account, trust = "pinggy", "none", "pin"
    note = "free sessions are time-limited (about 60 minutes); TLS passthrough keeps the certificate end to end"

    def argv(self, ctx):
        return self.ssh(ctx, "-p", "443", "-R0:127.0.0.1:%d" % ctx.port, "tls" + "@" + "a.pinggy.io")

    def parse(self, line, ctx):
        m = re.search(r"([a-z0-9-]+(?:\.[a-z0-9-]+)*\.pinggy\.(?:link|online|io))(?::(\d+))?", clean(line))
        if not m or m.group(1).startswith("a.pinggy"):
            return None
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=60)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
        return _tcp_ep(self.name, m.group(1), m.group(2) or 443, expires_at=expires)


class LocalhostRun(_Ssh):
    name, account, trust = "localhost-run", "none", "webpki"
    note = "serves only the onboarding page; the API is reached through the LAN hosts"

    def argv(self, ctx):
        return self.ssh(ctx, "-R", "80:127.0.0.1:%d" % ctx.onboarding_port, "nokey" + "@" + "localhost.run")

    def parse(self, line, ctx):
        m = re.search(r"https://[a-z0-9][a-z0-9-]*\.lhr\.life", clean(line))
        return _url_ep(self.name, m.group(0), landing_only=True) if m else None


class Bore(Provider):
    name, account, trust = "bore", "none", "pin"
    note = "raw TCP on bore.pub (or your own server), TLS stays end to end"

    def argv(self, ctx):
        return [ctx.bin("bore"), "local", str(ctx.port), "--local-host", "127.0.0.1", "--to",
                ctx.cfg.get("server") or "bore.pub"]

    def env(self, ctx):
        secret = ctx.secret("secretCredential")
        return {"BORE_SECRET": secret} if secret else {}

    def parse(self, line, ctx):
        m = re.search(r"listening at ([A-Za-z0-9.\-]+):(\d+)", clean(line))
        return _tcp_ep(self.name, m.group(1), m.group(2)) if m else None


class Frp(Provider):
    name, account, trust = "frp", "server", "pin"
    needs = ("server", "remotePort")
    note = "your own frps server; raw TCP, TLS stays end to end"

    def config_text(self, ctx):
        c = ctx.cfg
        lines = ['serverAddr = "%s"' % c["server"], "serverPort = %d" % int(c.get("serverPort") or 7000)]
        token = ctx.secret("tokenCredential")
        if token:
            lines += ['auth.method = "token"', 'auth.token = "%s"' % token.replace("\\", "\\\\").replace('"', '\\"')]
        lines += ["", "[[proxies]]", 'name = "nestlo-mobile"', 'type = "tcp"', 'localIP = "127.0.0.1"',
                  "localPort = %d" % ctx.port, "remotePort = %d" % int(c["remotePort"])]
        return "\n".join(lines) + "\n"

    def argv(self, ctx):
        return [ctx.bin("frpc"), "-c", os.path.join(ctx.state, "frpc.toml")]

    def prepare(self, ctx):
        write_text_atomic(os.path.join(ctx.state, "frpc.toml"), self.config_text(ctx), 0o600)

    def parse(self, line, ctx):
        if "start proxy success" in clean(line):
            return _tcp_ep(self.name, ctx.cfg["server"], ctx.cfg["remotePort"])
        return None


PROVIDERS = {p.name: p for p in (Cloudflare(), CloudflareNamed(), TailscaleFunnel(), Ngrok(), Zrok(), Pinggy(),
                                 LocalhostRun(), Bore(), Frp())}
# `tailscale` (address only) has no process; the server answers it from `tailscale status`
LISTED = ("cloudflare", "cloudflare-named", "tailscale-funnel", "tailscale", "ngrok", "zrok", "pinggy",
          "localhost-run", "bore", "frp")
DEFAULT_PROVIDER = "cloudflare"


def provider_table(config):
    """Rows for the interactive question: name, account, trust, configured, note."""
    rows = []
    prov_cfg = (config or {}).get("providers", {})
    for name in LISTED:
        if name == "tailscale":
            rows.append({"name": name, "account": "account", "trust": "pin", "configured": True,
                         "note": "your tailnet address, port %s (no process)" % (config or {}).get("port", 7443)})
            continue
        p = PROVIDERS[name]
        cfg = prov_cfg.get(name, {})
        rows.append({"name": name, "account": p.account, "trust": p.trust,
                     "configured": bool(cfg.get("enabled", True)) and all(cfg.get(k) for k in p.needs),
                     "note": p.note})
    return rows


def endpoint_json(ep):
    return json.dumps(ep, sort_keys=True)


def run_provider(name, config, run_dir, state_dir, creds_dir="", popen=subprocess.Popen, run=subprocess.run,
                 out=sys.stdout, timeout=ENDPOINT_TIMEOUT, clock=time.monotonic, stop_event=None):
    """Run provider `name` until it ends or SIGTERM. Returns the exit status."""
    if name not in PROVIDERS:
        print("unknown tunnel provider %r" % name, file=sys.stderr)
        return 2
    p = PROVIDERS[name]
    ctx = Ctx(name, (config.get("providers") or {}).get(name, {}), config.get("bins"), config.get("port", 7443),
              config.get("onboarding_port", 7080), creds_dir, state_dir)
    json_path = os.path.join(run_dir, "tunnel.json")
    err_path = os.path.join(run_dir, "tunnel-error")
    for path in (json_path, err_path):
        with contextlib.suppress(OSError):
            os.unlink(path)
    tail = collections.deque(maxlen=OUTPUT_TAIL)
    state = {"done": False}
    lock = threading.Lock()

    def publish(ep):
        with lock:
            if state["done"]:
                return
            state["done"] = True
        write_text_atomic(json_path, endpoint_json(ep) + "\n", 0o644)

    def fail(reason):
        write_text_atomic(err_path, "%s\n%s\n" % (reason, "\n".join(tail)), 0o644)

    stop = stop_event or threading.Event()
    child = {"proc": None}

    def killer():
        stop.wait()
        proc = child["proc"]
        if proc is not None:
            with contextlib.suppress(OSError):
                os.killpg(proc.pid, signal.SIGTERM)

    old_term = None
    if stop_event is None:
        old_term = signal.signal(signal.SIGTERM, lambda *_: stop.set())
    threading.Thread(target=killer, daemon=True).start()
    try:
        if hasattr(p, "prepare"):
            p.prepare(ctx)
        pre = p.pre(ctx) if callable(p.pre) else None
        if pre:
            res = run(pre, capture_output=True, text=True, timeout=120, env=dict(os.environ, **p.env(ctx)))
            tail.extend((res.stdout + res.stderr).splitlines()[-OUTPUT_TAIL:])
            if res.returncode != 0:
                fail("%s setup failed" % name)
                return res.returncode
        static = p.static(ctx)
        if static:
            publish(static)
        env = dict(os.environ, **p.env(ctx))
        proc = popen(p.argv(ctx), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env,
                     start_new_session=True)
        child["proc"] = proc
        if stop.is_set():
            os.killpg(proc.pid, signal.SIGTERM)
        deadline = clock() + timeout

        def watchdog():
            while not stop.wait(1.0):
                if not state["done"] and clock() > deadline:
                    fail("no endpoint from %s within %d seconds" % (name, timeout))
                    stop.set()
                    return
                if state["done"]:
                    return
        threading.Thread(target=watchdog, daemon=True).start()
        for line in proc.stdout:
            out.write(line)
            out.flush()
            tail.append(clean(line).rstrip())
            if not state["done"]:
                ep = p.parse(line, ctx)
                if ep:
                    publish(ep)
        rc = proc.wait()
        if p.detach and rc == 0:
            stop.wait()                      # e.g. tailscale funnel --bg: the setting lives on, we wait for the stop
            return 0
        if not state["done"] and not stop.is_set():
            fail("%s exited with status %d before an endpoint was found" % (name, rc))
        return rc
    finally:
        stop.set()
        if old_term is not None:
            signal.signal(signal.SIGTERM, old_term)
        stop_cmd = p.stop_argv(ctx)
        if stop_cmd:
            with contextlib.suppress(Exception):
                run(stop_cmd, capture_output=True, timeout=30)
        with contextlib.suppress(OSError):
            os.unlink(json_path)
