"""Fakes for the herdr tests: a `herdr` binary and a GitHub (search/tree/raw) server."""

import json
import os
import stat
import sys
import textwrap
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

FAKE_HERDR = r'''#!__PY__
import json, os, sys, time, tomllib

path = os.environ["FAKE_HERDR_STATE"]


def load():
    for _ in range(50):
        try:
            with open(path) as f:
                return json.load(f)
        except OSError:
            break
        except ValueError:  # read while another call was replacing the file
            time.sleep(0.02)
    return {"plugins": [], "panes": [], "agents": []}


def save(st):
    tmp = path + "." + str(os.getpid())
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, path)


def reply(result):
    print(json.dumps({"id": "cli:x", "result": result}))


def error(code, msg, rc=1):
    print(json.dumps({"id": "cli:x", "error": {"code": code, "message": msg}}))
    sys.exit(rc)


st = load()
args = sys.argv[1:]
with open(path + ".calls", "a") as f:  # append-only: calls may overlap with the server process
    f.write(json.dumps(args) + "\n")
st["server"] = os.path.exists(path + ".server")
fail = [s for s in os.environ.get("FAKE_HERDR_FAIL", "").split(",") if s]

if args == ["--version"]:
    print("herdr " + os.environ.get("FAKE_HERDR_VERSION", "0.9.1"))
elif args[:2] == ["status", "server"]:
    print("status: running" if st["server"] else "status: not running")
elif args == ["server"]:
    open(path + ".server", "w").close()
    while os.path.exists(path + ".server"):
        time.sleep(0.05)
elif args[:2] == ["server", "stop"]:
    if os.path.exists(path + ".server"):
        os.remove(path + ".server")
elif args[:2] in (["pane", "list"], ["agent", "list"]):
    if not st["server"]:
        error("server_not_running", "no herdr server is running")
    key = args[0] + "s"
    reply({key: st[key], "type": args[0] + "_list"})
elif args[:2] == ["plugin", "list"]:
    reply({"plugins": st["plugins"], "type": "plugin_list"})
elif args[:2] == ["plugin", "install"]:
    src = args[2]
    ref = args[args.index("--ref") + 1] if "--ref" in args else "HEAD"
    if src in fail:
        print("install failed: build error", file=sys.stderr)
        sys.exit(1)
    parts = src.split("/")
    ids = json.loads(os.environ.get("FAKE_HERDR_IDS", "{}"))
    source = {"kind": "github", "owner": parts[0], "repo": parts[1], "requested_ref": ref,
              "resolved_commit": ref if len(ref) == 40 else "c" * 40}
    if len(parts) > 2:
        source["subdir"] = "/".join(parts[2:])
    st["plugins"] = [p for p in st["plugins"] if p["plugin_id"] != ids.get(src, src.replace("/", "."))]
    st["plugins"].append({"plugin_id": ids.get(src, src.replace("/", ".")), "name": src, "version": "1.0.0",
                          "enabled": True, "source": source})
    save(st)
    print("installed " + src)
elif args[:2] == ["plugin", "uninstall"]:
    before = len(st["plugins"])
    def match(p):
        s = p["source"]
        gh = "/".join([s.get("owner", ""), s.get("repo", "")] + ([s["subdir"]] if s.get("subdir") else []))
        return args[2] in (p["plugin_id"], gh)
    st["plugins"] = [p for p in st["plugins"] if not match(p)]
    save(st)
    if len(st["plugins"]) == before:
        print("plugin not installed: " + args[2], file=sys.stderr)
        sys.exit(1)
    print("Uninstalled " + args[2])
elif args[:2] == ["plugin", "link"]:
    root = args[2]
    man = tomllib.load(open(os.path.join(root, "herdr-plugin.toml"), "rb"))
    st["plugins"] = [p for p in st["plugins"] if p["plugin_id"] != man["id"]]
    plugin = {"plugin_id": man["id"], "name": man["name"], "version": man["version"], "enabled": True,
              "plugin_root": root, "source": {"kind": "local"}}
    st["plugins"].append(plugin)
    save(st)
    reply({"plugin": plugin, "type": "plugin_linked"})
elif args[:2] in (["plugin", "enable"], ["plugin", "disable"], ["plugin", "unlink"]):
    if not st["server"]:
        error("server_not_running", "no herdr server is running")
    for p in list(st["plugins"]):
        if p["plugin_id"] == args[2]:
            if args[1] == "unlink":
                st["plugins"].remove(p)
            else:
                p["enabled"] = args[1] == "enable"
    save(st)
    reply({"plugin_id": args[2], "type": "plugin_" + args[1] + "d"})
else:
    print("unsupported: " + " ".join(args), file=sys.stderr)
    sys.exit(2)
'''


class FakeHerdr:
    def __init__(self, tmp_path):
        self.path = str(tmp_path / "herdr")
        self.state = str(tmp_path / "herdr-state.json")
        with open(self.path, "w") as f:
            f.write(FAKE_HERDR.replace("__PY__", sys.executable))
        os.chmod(self.path, os.stat(self.path).st_mode | stat.S_IEXEC)

    def data(self):
        try:
            with open(self.state) as f:
                d = json.load(f)
        except OSError:
            d = {"plugins": [], "panes": [], "agents": []}
        d["server"] = os.path.exists(self.state + ".server")
        try:
            with open(self.state + ".calls") as f:
                d["calls"] = [json.loads(line) for line in f if line.strip()]
        except OSError:
            d["calls"] = []
        return d

    def update(self, **kw):
        d = self.data()
        d.update(kw)
        if "server" in kw:
            if kw["server"]:
                open(self.state + ".server", "w").close()
            elif os.path.exists(self.state + ".server"):
                os.remove(self.state + ".server")
        d.pop("calls", None)
        d.pop("server", None)
        tmp = self.state + ".t"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, self.state)

    def calls(self, *prefix):
        return [c for c in self.data()["calls"] if c[: len(prefix)] == list(prefix)]


def manifest(id, name=None, version="1.0.0", min="0.7.0", platforms='["linux", "macos"]', body=""):
    return textwrap.dedent(f'''
        id = "{id}"
        name = "{name or id}"
        version = "{version}"
        min_herdr_version = "{min}"
        description = "plugin {id}"
        {"platforms = " + platforms if platforms else ""}
        ''') + body


class FakeGitHub:
    """repos: {"owner/repo": {"stars": n, "license": "MIT", "sha": 40 hex, "files": {path: text}}}"""

    def __init__(self):
        self.repos = {}
        self.requests = []
        self.rate_limited = False
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def send(self, code, body, ctype="application/json", headers=()):
                data = body if isinstance(body, bytes) else (body if isinstance(body, str) else json.dumps(body)).encode()
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                for k, v in headers:
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                u = urlparse(self.path)
                q = parse_qs(u.query)
                outer.requests.append((u.path, self.headers.get("Authorization")))
                if outer.rate_limited:
                    return self.send(403, {"message": "rate limit"}, headers=[("X-RateLimit-Remaining", "0"),
                                                                              ("X-RateLimit-Reset", "1900000000")])
                parts = [p for p in u.path.split("/") if p]
                if u.path == "/search/repositories":
                    page, per = int(q["page"][0]), int(q["per_page"][0])
                    names = sorted(outer.repos, key=lambda n: -outer.repos[n]["stars"])
                    items = []
                    for n in names[(page - 1) * per: page * per]:
                        r = outer.repos[n]
                        items.append({"full_name": n, "stargazers_count": r["stars"], "fork": False, "archived": False,
                                      "license": {"spdx_id": r.get("license", "MIT")} if r.get("license", "MIT") else None,
                                      "description": r.get("description", f"repo {n}"), "default_branch": "main",
                                      "pushed_at": "2026-09-01T00:00:00Z"})
                    return self.send(200, {"total_count": len(names), "items": items})
                if parts[:1] == ["repos"] and len(parts) >= 3:
                    full = "/".join(parts[1:3])
                    r = outer.repos.get(full)
                    if r is None:
                        return self.send(404, {"message": "Not Found"})
                    rest = parts[3:]
                    if not rest:
                        return self.send(200, {"full_name": full, "default_branch": "main"})
                    if rest[0] == "commits":
                        return self.send(200, {"sha": r["sha"]})
                    if rest[0] == "git" and rest[1] == "trees":
                        return self.send(200, {"tree": [{"path": p, "type": "blob"} for p in r["files"]], "truncated": False})
                # raw: /owner/repo/<ref>/<path>
                if len(parts) >= 4:
                    r = outer.repos.get("/".join(parts[:2]))
                    path = "/".join(parts[3:])
                    if r and path in r["files"]:
                        return self.send(200, r["files"][path], "text/plain")
                self.send(404, {"message": "Not Found"})

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def add(self, name, stars=10, sha=None, files=None, **kw):
        self.repos[name] = {"stars": stars, "sha": sha or (format(abs(hash(name)) % 16 ** 8, "08x") * 5),
                            "files": files or {"herdr-plugin.toml": manifest(name.replace("/", "."))}, **kw}
        return self.repos[name]

    def close(self):
        self.httpd.shutdown()
