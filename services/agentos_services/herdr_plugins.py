"""agentos-herdr-plugins: manage herdr plugins, declaratively and from the marketplace.

herdr (https://herdr.dev) runs plugins: unsandboxed code that executes as the
user and can call the whole herdr CLI. The marketplace is "every public
GitHub repository with the topic `herdr-plugin` that has a herdr-plugin.toml"
and is not reviewed. This tool never installs anything it has not first
shown (what the plugin runs) and always pins an install to a commit:

  catalog [--refresh]          the marketplace: stars, licence, description, head commit
  show <owner/repo[/subdir]>   every manifest and the commands it will run
  install <src> [--ref REF]    pin to REF, or to the current head commit
  install-all                  every compatible marketplace plugin, pinned to its head
  update [plugin]              move to the new head commit, showing the manifest diff
  list / remove <src|id>
  sync --config FILE           declarative: the NixOS module's per-user oneshot

State (what this tool installed, so it never touches plugins you installed
by hand) is ~/.local/state/agentos-herdr/plugins.json, the marketplace cache
~/.cache/agentos-herdr/. Environment: AGENTOS_HERDR_BIN (herdr binary),
GITHUB_TOKEN (search and tree API limits), AGENTOS_HERDR_GITHUB_API,
AGENTOS_HERDR_GITHUB_RAW, AGENTOS_HERDR_GIT_BASE (tests).
"""

import argparse
import concurrent.futures
import contextlib
import difflib
import fcntl
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

TOPIC = "herdr-plugin"
MANIFEST = "herdr-plugin.toml"
SOURCE_RE = re.compile(r"^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)((?:/[A-Za-z0-9_.@+-]+)*)$")
REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@+-]{0,127}$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
CATALOG_TTL = 6 * 3600
MAX_PAGES = 10  # the GitHub search API serves at most 1000 results


class PluginError(Exception):
    """A failure to report to the user (exit status 1)."""


class Refused(PluginError):
    """The user (or a non-interactive run) declined."""


# ── helpers ─────────────────────────────────────────────────────────────

def log(msg):
    print(msg, file=sys.stderr, flush=True)


def paths():
    home = os.path.expanduser("~")
    cache = os.environ.get("AGENTOS_HERDR_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.join(home, ".cache"), "agentos-herdr")
    state = os.environ.get("AGENTOS_HERDR_STATE") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"), "agentos-herdr")
    return cache, state


def parse_source(text):
    """'owner/repo[/subdir]' -> (owner, repo, subdir or '')."""
    m = SOURCE_RE.match(text or "")
    if not m:
        raise PluginError(f"not a plugin source (expected owner/repo[/subdir]): {text!r}")
    subdir = m.group(3).lstrip("/")
    if any(part in (".", "..") for part in subdir.split("/") if part):
        raise PluginError(f"invalid subdirectory in {text!r}")
    return m.group(1), m.group(2), subdir


def source_name(owner, repo, subdir=""):
    return f"{owner}/{repo}" + (f"/{subdir}" if subdir else "")


def check_ref(ref):
    if not REF_RE.match(ref) or ".." in ref:
        raise PluginError(f"invalid ref: {ref!r}")
    return ref


def version_tuple(text):
    nums = re.findall(r"\d+", str(text or "0").split("-")[0].split("+")[0])
    return tuple(int(n) for n in nums[:4]) or (0,)


def confirm(prompt, yes):
    if yes:
        return True
    if not sys.stdin.isatty():
        raise Refused("not interactive: review the plugins above and pass --yes to install them")
    return input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def table(rows):
    if not rows:
        return
    widths = [max(len(str(r[i])) for r in rows) for i in range(len(rows[0]))]
    for r in rows:
        print("  ".join(str(c).ljust(w) for c, w in zip(r, widths)).rstrip())


def trunc(text, n):
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


# ── herdr ───────────────────────────────────────────────────────────────

class Herdr:
    """The herdr CLI. Plugin install, link, list and uninstall work without a
    running server; enable, disable and unlink need one."""

    def __init__(self, binary=None):
        self.binary = binary or os.environ.get("AGENTOS_HERDR_BIN") or "herdr"

    def run(self, *args, timeout=900):
        try:
            p = subprocess.run([self.binary, *args], capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            raise PluginError(f"herdr not found ({self.binary}); install it or set AGENTOS_HERDR_BIN")
        except subprocess.TimeoutExpired:
            raise PluginError(f"herdr {' '.join(args[:2])} timed out")
        return p

    @staticmethod
    def _fail(p, what):
        out = (p.stderr.strip() or p.stdout.strip() or f"exit status {p.returncode}")
        raise PluginError(f"{what} failed: {trunc(out, 400)}")

    def version(self):
        p = self.run("--version", timeout=30)
        m = re.search(r"\d+\.\d+(?:\.\d+)?", p.stdout or "")
        if p.returncode != 0 or not m:
            self._fail(p, "herdr --version")
        return m.group(0)

    def server_running(self):
        p = self.run("status", "server", timeout=30)
        return re.search(r"^status:\s*running", p.stdout or "", re.M) is not None

    @staticmethod
    def _result(p, what):
        """The `result` object of herdr's JSON reply; PluginError on an error reply."""
        for line in reversed((p.stdout or "").strip().splitlines()):
            try:
                data = json.loads(line)
            except ValueError:
                continue
            if isinstance(data, dict):
                if "error" in data:
                    err = data["error"]
                    raise PluginError(f"{what} failed: {err.get('message', err) if isinstance(err, dict) else err}")
                if "result" in data:
                    return data["result"]
        if p.returncode != 0:
            Herdr._fail(p, what)
        return {}

    def plugins(self):
        p = self.run("plugin", "list", "--json", timeout=60)
        return self._result(p, "herdr plugin list").get("plugins", [])

    def install(self, source, ref):
        p = self.run("plugin", "install", source, "--ref", ref, "--yes")
        if p.returncode != 0:
            self._fail(p, f"herdr plugin install {source}")

    def uninstall(self, ident):
        p = self.run("plugin", "uninstall", ident, timeout=120)
        if p.returncode != 0:
            self._fail(p, f"herdr plugin uninstall {ident}")

    def link(self, path):
        p = self.run("plugin", "link", path, timeout=120)
        res = self._result(p, f"herdr plugin link {path}")
        return (res.get("plugin") or {}).get("plugin_id")

    def unlink(self, ident):
        p = self.run("plugin", "unlink", ident, timeout=120)
        self._result(p, f"herdr plugin unlink {ident}")

    def set_enabled(self, ident, enabled):
        p = self.run("plugin", "enable" if enabled else "disable", ident, timeout=120)
        if p.returncode != 0:
            self._fail(p, f"herdr plugin {'enable' if enabled else 'disable'} {ident}")


def find_installed(plugins, owner, repo, subdir):
    """The herdr plugin record installed from this GitHub source, or None."""
    for p in plugins:
        s = p.get("source") or {}
        if s.get("kind") != "github":
            continue
        if (str(s.get("owner", "")).lower(), str(s.get("repo", "")).lower(), s.get("subdir") or "") == \
                (owner.lower(), repo.lower(), subdir):
            return p
    return None


class ServerGuard:
    """Make sure a herdr server answers while enable/disable/unlink run.

    managed: a systemd unit owns the server, so only wait for it. Otherwise a
    transient `herdr server` is started and stopped again afterwards (unless
    the user's own server was already running)."""

    def __init__(self, herdr, managed=False, wait=45):
        self.herdr, self.managed, self.wait = herdr, managed, wait
        self.proc = None

    def _wait(self):
        end = time.time() + self.wait
        while time.time() < end:
            if self.herdr.server_running():
                return True
            time.sleep(0.5)
        return False

    def __enter__(self):
        if self.herdr.server_running():
            return self
        if not self.managed:
            self.proc = subprocess.Popen([self.herdr.binary, "server"], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, start_new_session=True)
        if not self._wait():
            self.__exit__()
            raise PluginError("the herdr server did not start")
        return self

    def __exit__(self, *exc):
        if self.proc is not None:
            self.herdr.run("server", "stop", timeout=30)
            with contextlib.suppress(Exception):
                self.proc.wait(timeout=10)
            self.proc = None
        return False


# ── GitHub ──────────────────────────────────────────────────────────────

class RateLimited(PluginError):
    pass


class GitHub:
    def __init__(self, api=None, raw=None, git_base=None, token=None, cache_dir=None):
        self.api = (api or os.environ.get("AGENTOS_HERDR_GITHUB_API") or "https://api.github.com").rstrip("/")
        self.raw = (raw or os.environ.get("AGENTOS_HERDR_GITHUB_RAW") or "https://raw.githubusercontent.com").rstrip("/")
        self.git_base = (git_base or os.environ.get("AGENTOS_HERDR_GIT_BASE") or "https://github.com").rstrip("/")
        self.token = token if token is not None else os.environ.get("GITHUB_TOKEN", "")
        self.cache_dir = cache_dir

    def _open(self, url, accept, auth):
        headers = {"User-Agent": "agentos-herdr-plugins", "Accept": accept}
        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 429) and e.headers.get("X-RateLimit-Remaining") == "0":
                reset = e.headers.get("X-RateLimit-Reset", "")
                when = time.strftime("%H:%M:%S", time.localtime(int(reset))) if reset.isdigit() else "later"
                raise RateLimited("GitHub API rate limit reached (resets at "
                                  f"{when}); set GITHUB_TOKEN for a higher limit") from None
            if e.code == 404:
                raise PluginError(f"not found: {url.split('?')[0]}") from None
            raise PluginError(f"GitHub returned HTTP {e.code} for {url.split('?')[0]}") from None
        except (urllib.error.URLError, OSError) as e:
            raise PluginError(f"cannot reach {url.split('?')[0]}: {getattr(e, 'reason', e)}") from None

    def get(self, path, **params):
        q = ("?" + urllib.parse.urlencode(params)) if params else ""
        data = self._open(f"{self.api}{path}{q}", "application/vnd.github+json", True)
        try:
            return json.loads(data)
        except ValueError:
            raise PluginError(f"GitHub sent invalid JSON for {path}") from None

    def search(self, min_stars=0):
        """Every public, non-fork, non-archived repository with the herdr-plugin topic."""
        repos = []
        for page in range(1, MAX_PAGES + 1):
            res = self.get("/search/repositories", q=f"topic:{TOPIC} fork:false archived:false",
                           sort="stars", order="desc", per_page=100, page=page)
            items = res.get("items") or []
            repos.extend(items)
            if len(items) < 100:
                break
        out = []
        for r in repos:
            if r.get("fork") or r.get("archived") or r.get("private"):
                continue
            if int(r.get("stargazers_count") or 0) < min_stars:
                continue
            out.append({
                "full_name": r["full_name"],
                "stars": int(r.get("stargazers_count") or 0),
                "license": ((r.get("license") or {}).get("spdx_id") or "none"),
                "description": r.get("description") or "",
                "default_branch": r.get("default_branch") or "main",
                "pushed_at": r.get("pushed_at") or "",
            })
        return out

    def head_sha(self, full_name, branch):
        """Current commit of a branch. git ls-remote has no API rate limit."""
        url = f"{self.git_base}/{full_name}.git"
        try:
            p = subprocess.run(["git", "ls-remote", url, f"refs/heads/{branch}"], capture_output=True, text=True,
                               timeout=60, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
            for line in p.stdout.splitlines():
                sha, _, ref = line.partition("\t")
                if ref.strip() == f"refs/heads/{branch}" and SHA_RE.match(sha):
                    return sha
        except (OSError, subprocess.TimeoutExpired):
            pass
        res = self.get(f"/repos/{full_name}/commits/{urllib.parse.quote(branch, safe='')}")
        sha = res.get("sha", "")
        if not SHA_RE.match(sha):
            raise PluginError(f"cannot resolve {full_name}@{branch}")
        return sha

    def default_branch(self, full_name):
        return self.get(f"/repos/{full_name}").get("default_branch") or "main"

    def manifest_paths(self, full_name, ref):
        key = f"tree-{ref}" if SHA_RE.match(ref) else None
        cached = self._cache_read(full_name, key) if key else None
        if cached is None:
            res = self.get(f"/repos/{full_name}/git/trees/{urllib.parse.quote(ref, safe='')}", recursive="1")
            cached = [t["path"] for t in res.get("tree", []) if t.get("type") == "blob"
                      and (t["path"] == MANIFEST or t["path"].endswith("/" + MANIFEST))]
            if key:
                self._cache_write(full_name, key, cached)
        return sorted(cached)

    def manifest_text(self, full_name, ref, path):
        key = f"file-{ref}-{path.replace('/', '__')}" if SHA_RE.match(ref) else None
        cached = self._cache_read(full_name, key) if key else None
        if cached is None:
            url = f"{self.raw}/{full_name}/{urllib.parse.quote(ref, safe='')}/{urllib.parse.quote(path)}"
            cached = self._open(url, "text/plain", False).decode("utf-8", "replace")
            if key:
                self._cache_write(full_name, key, cached)
        return cached

    def _cache_file(self, full_name, key):
        return os.path.join(self.cache_dir, "repos", full_name.replace("/", "__"), key + ".json")

    def _cache_read(self, full_name, key):
        if not self.cache_dir:
            return None
        return read_json(self._cache_file(full_name, key), None)

    def _cache_write(self, full_name, key, value):
        if self.cache_dir:
            with contextlib.suppress(OSError):
                write_json(self._cache_file(full_name, key), value)


# ── manifests ───────────────────────────────────────────────────────────

def summarize_manifest(text, path):
    """Parse a herdr-plugin.toml into what matters for review; None if unusable."""
    try:
        m = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return None
    if not all(isinstance(m.get(k), str) and m.get(k) for k in ("id", "name", "version", "min_herdr_version")):
        return None
    subdir = path.rsplit("/", 1)[0] if "/" in path else ""
    commands = []

    def add(kind, label, item):
        cmd = item.get("command")
        if isinstance(cmd, list):
            commands.append({"kind": kind, "label": label, "argv": [str(a) for a in cmd],
                             "platforms": item.get("platforms")})

    for b in m.get("build") or []:
        add("build", "", b)
    for s in m.get("startup") or []:
        add("startup", "", s)
    for a in m.get("actions") or []:
        add("action", a.get("id", ""), a)
    for e in m.get("events") or []:
        add("event", e.get("on", ""), e)
    for p in m.get("panes") or []:
        add("pane", p.get("id", ""), p)
    return {
        "subdir": subdir, "path": path, "id": m["id"], "name": m["name"], "version": m["version"],
        "min_herdr_version": m["min_herdr_version"], "description": m.get("description", ""),
        "platforms": m.get("platforms"), "commands": commands,
    }


def incompatibility(man, herdr_version):
    plats = man.get("platforms")
    if isinstance(plats, list) and "linux" not in plats:
        return f"platforms {plats} exclude linux"
    if version_tuple(man["min_herdr_version"]) > version_tuple(herdr_version):
        return f"needs herdr >= {man['min_herdr_version']} (have {herdr_version})"
    return None


def print_manifest(src, ref, man, stars=None):
    print(f"{src}  ({man['name']} {man['version']}, id {man['id']}, at {ref[:12]})")
    if man["description"]:
        print(f"  {trunc(man['description'], 100)}")
    print(f"  platforms: {man['platforms'] or 'not declared'}   needs herdr >= {man['min_herdr_version']}")
    if not man["commands"]:
        print("  runs: nothing (the manifest declares no commands)")
    for c in man["commands"]:
        label = f"{c['label']}: " if c["label"] else ""
        print(f"  {c['kind']:<8}{label}{' '.join(c['argv'])}")


def discover(gh, full_name, ref):
    """All plugin manifests of a repository at a ref."""
    out = []
    for path in gh.manifest_paths(full_name, ref):
        man = summarize_manifest(gh.manifest_text(full_name, ref, path), path)
        if man:
            out.append(man)
        else:
            log(f"  skipping {full_name}/{path}: unparseable or incomplete manifest")
    return out


# ── commands ────────────────────────────────────────────────────────────

class Tool:
    def __init__(self, herdr=None, gh=None):
        self.cache, self.state_dir = paths()
        self.herdr = herdr or Herdr()
        self.gh = gh or GitHub(cache_dir=self.cache)
        self.state_file = os.path.join(self.state_dir, "plugins.json")

    # state
    @contextlib.contextmanager
    def locked(self):
        os.makedirs(self.state_dir, exist_ok=True)
        with open(os.path.join(self.state_dir, "lock"), "w") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            yield

    def load(self):
        st = read_json(self.state_file, {})
        st.setdefault("plugins", {})
        st.setdefault("links", {})
        return st

    def save(self, st):
        write_json(self.state_file, st)

    # catalog
    def catalog(self, refresh=False, min_stars=0, max_age=CATALOG_TTL):
        f = os.path.join(self.cache, "catalog.json")
        cached = read_json(f, None)
        fresh = cached and time.time() - cached.get("fetched_at", 0) < max_age
        if refresh or not fresh:
            repos = self.gh.search()

            def head(r):
                try:
                    r["head"] = self.gh.head_sha(r["full_name"], r["default_branch"])
                except PluginError as e:
                    r["head"] = ""
                    log(f"  {r['full_name']}: {e}")
                return r

            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                repos = list(ex.map(head, repos))
            cached = {"fetched_at": time.time(), "repos": repos}
            write_json(f, cached)
        return [r for r in cached["repos"] if r["stars"] >= min_stars]

    def candidates(self, src, ref=None):
        """Manifests behind owner/repo[/subdir] at ref (default: the default branch head)."""
        owner, repo, subdir = parse_source(src)
        full = f"{owner}/{repo}"
        if ref:
            check_ref(ref)
        else:
            ref = self.gh.head_sha(full, self.gh.default_branch(full))
        mans = discover(self.gh, full, ref)
        if subdir:
            mans = [m for m in mans if m["subdir"] == subdir]
        if not mans:
            raise PluginError(f"{src}: no {MANIFEST} found at {ref[:12]}")
        return [{"src": source_name(owner, repo, m["subdir"]), "owner": owner, "repo": repo,
                 "subdir": m["subdir"], "ref": ref, "man": m} for m in mans]

    def is_current(self, st, cand, plugins):
        inst = find_installed(plugins, cand["owner"], cand["repo"], cand["subdir"])
        if inst is None:
            return False
        s = inst.get("source") or {}
        if s.get("resolved_commit") == cand["ref"] and SHA_RE.match(cand["ref"]):
            return True
        rec = st["plugins"].get(cand["src"])
        return bool(rec and rec.get("ref") == cand["ref"])

    def install_one(self, st, cand, managed_by, plugins):
        """Install a candidate unless it is already there at that ref. Returns a status word.

        A plugin that is installed but has no state record was installed by
        hand; it is never claimed, reinstalled or (later) uninstalled."""
        if cand["src"] not in st["plugins"] and \
                find_installed(plugins, cand["owner"], cand["repo"], cand["subdir"]) is not None:
            if managed_by == "declarative":
                raise PluginError("installed by hand, not managed by AgentOS; left alone "
                                  "(remove it with `herdr plugin uninstall` to let the declaration manage it)")
            return "installed by hand, left alone"
        if self.is_current(st, cand, plugins):
            rec = st["plugins"].setdefault(cand["src"], {})
            if not rec:
                inst = find_installed(plugins, cand["owner"], cand["repo"], cand["subdir"])
                rec.update({"ref": cand["ref"], "plugin_id": inst.get("plugin_id"),
                            "managed_by": managed_by, "installed_at": int(time.time())})
            return "already installed"
        self.herdr.install(cand["src"], cand["ref"])
        plugins[:] = self.herdr.plugins()
        inst = find_installed(plugins, cand["owner"], cand["repo"], cand["subdir"])
        prev = st["plugins"].get(cand["src"], {})
        st["plugins"][cand["src"]] = {
            "ref": cand["ref"],
            "resolved": ((inst or {}).get("source") or {}).get("resolved_commit", ""),
            "plugin_id": (inst or {}).get("plugin_id") or cand["man"]["id"],
            "managed_by": prev.get("managed_by", managed_by),
            "installed_at": int(time.time()),
        }
        return "installed"

    # ── show / catalog / list
    def cmd_catalog(self, a):
        repos = self.catalog(a.refresh, a.min_stars)
        if a.json:
            print(json.dumps(repos, indent=2))
            return 0
        rows = [("REPOSITORY", "STARS", "LICENSE", "HEAD", "DESCRIPTION")]
        for r in repos:
            rows.append((r["full_name"], r["stars"], r["license"], (r.get("head") or "?")[:12], trunc(r["description"], 60)))
        table(rows)
        print(f"{len(repos)} repositories with the topic {TOPIC} (unreviewed third-party code; see `show`)", file=sys.stderr)
        return 0

    def cmd_show(self, a):
        for c in self.candidates(a.source, a.ref):
            print_manifest(c["src"], c["ref"], c["man"])
            reason = incompatibility(c["man"], self.herdr.version())
            if reason:
                print(f"  NOT INSTALLABLE HERE: {reason}")
            print()
        return 0

    def cmd_list(self, a):
        st = self.load()
        plugins = self.herdr.plugins()
        rows = []
        for p in plugins:
            s = p.get("source") or {}
            if s.get("kind") == "github":
                src = source_name(s.get("owner", ""), s.get("repo", ""), s.get("subdir") or "")
                rec = st["plugins"].get(src)
                managed = rec["managed_by"] if rec else "manual"
                ref = (s.get("resolved_commit") or "")[:12]
            else:
                src = p.get("plugin_root", "")
                rec = next((v for v in st["links"].values() if v.get("plugin_id") == p.get("plugin_id")), None)
                managed = "declarative-link" if rec else "manual-link"
                ref = "local"
            rows.append({"id": p.get("plugin_id"), "version": p.get("version"), "enabled": bool(p.get("enabled")),
                         "source": src, "ref": ref, "managed_by": managed})
        if a.json:
            print(json.dumps(rows, indent=2))
            return 0
        if not rows:
            print("no herdr plugins installed")
            return 0
        table([("ID", "VERSION", "ENABLED", "SOURCE", "REF", "MANAGED BY")]
              + [(r["id"], r["version"], "yes" if r["enabled"] else "no", r["source"], r["ref"], r["managed_by"]) for r in rows])
        return 0

    # ── install
    def cmd_install(self, a):
        herdr_version = self.herdr.version()
        cands = self.candidates(a.source, a.ref)
        bad = []
        for c in cands:
            print_manifest(c["src"], c["ref"], c["man"])
            reason = incompatibility(c["man"], herdr_version)
            if reason:
                print(f"  skipped: {reason}")
                bad.append(c)
            print()
        todo = [c for c in cands if c not in bad]
        if not todo:
            raise PluginError("nothing to install")
        print("herdr does not sandbox plugins: the commands above run as you.")
        if not confirm(f"Install {len(todo)} plugin(s) pinned to these commits?", a.yes):
            raise Refused("not confirmed")
        with self.locked():
            st = self.load()
            plugins = self.herdr.plugins()
            for c in todo:
                print(f"{c['src']}: {self.install_one(st, c, 'cli', plugins)} at {c['ref'][:12]}")
                self.save(st)
        return 0

    def cmd_install_all(self, a):
        herdr_version = self.herdr.version()
        excludes = [e.lower() for e in (a.exclude or [])]

        def excluded(src):
            s = src.lower()
            return any(fnmatch.fnmatch(s, e) or fnmatch.fnmatch(s, e + "/*") for e in excludes)

        repos = [r for r in self.catalog(a.refresh, a.min_stars, max_age=3600) if r.get("head")]
        repos = [r for r in repos if not excluded(r["full_name"])]

        def scan(r):
            try:
                return r, discover(self.gh, r["full_name"], r["head"]), None
            except PluginError as e:
                return r, [], e

        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
            scans = list(ex.map(scan, repos))
        cands, skipped, seen_ids = [], [], {}
        for r, mans, err in scans:
            if err:
                skipped.append((r["full_name"], str(err)))
                if isinstance(err, RateLimited):
                    raise err
                continue
            owner, repo = r["full_name"].split("/", 1)
            for m in mans:
                src = source_name(owner, repo, m["subdir"])
                if excluded(src):
                    continue
                reason = incompatibility(m, herdr_version)
                if reason:
                    skipped.append((src, reason))
                elif m["id"] in seen_ids:
                    skipped.append((src, f"plugin id {m['id']} already provided by {seen_ids[m['id']]}"))
                else:
                    seen_ids[m["id"]] = src
                    cands.append({"src": src, "owner": owner, "repo": repo, "subdir": m["subdir"],
                                  "ref": r["head"], "man": m, "stars": r["stars"]})
        for c in cands:
            print_manifest(c["src"], c["ref"], c["man"])
            print()
        for src, why in skipped:
            print(f"skipped {src}: {why}")
        print(f"\n{len(cands)} plugin(s) would be installed, each pinned to the commit shown. herdr does not "
              "sandbox plugins: their build and runtime commands run as you.")
        if a.dry_run or not cands:
            return 0
        if not confirm(f"Install all {len(cands)} unreviewed plugins?", a.yes):
            raise Refused("not confirmed")
        failed = []
        with self.locked():
            st = self.load()
            plugins = self.herdr.plugins()
            for c in cands:
                try:
                    print(f"{c['src']}: {self.install_one(st, c, 'cli', plugins)} at {c['ref'][:12]}")
                except PluginError as e:
                    failed.append(c["src"])
                    print(f"{c['src']}: FAILED: {e}")
                self.save(st)
        print(f"done: {len(cands) - len(failed)} ok, {len(failed)} failed")
        return 1 if failed else 0

    # ── update / remove
    def cmd_update(self, a):
        with self.locked():
            st = self.load()
            targets = [(s, r) for s, r in sorted(st["plugins"].items())
                       if r.get("managed_by") == "cli"
                       and (not a.plugin or a.plugin in (s, r.get("plugin_id")))]
            if not targets:
                raise PluginError("no matching plugin installed by agentos-herdr-plugins")
            plugins = self.herdr.plugins()
            herdr_version = self.herdr.version()
            rc = 0
            for src, rec in targets:
                try:
                    # a root source lists every manifest in the repository;
                    # take the one this record tracks
                    new = next((c for c in self.candidates(src) if c["src"] == src), None)
                    if new is None:
                        raise PluginError(f"no {MANIFEST} for {src} on the default branch any more")
                except PluginError as e:
                    print(f"{src}: {e}")
                    rc = 1
                    continue
                if new["ref"] == rec.get("ref") or new["ref"] == rec.get("resolved"):
                    print(f"{src}: up to date at {new['ref'][:12]}")
                    continue
                reason = incompatibility(new["man"], herdr_version)
                if reason:
                    print(f"{src}: not updated: {reason}")
                    continue
                self.print_diff(src, rec, new)
                if not confirm(f"Update {src} to {new['ref'][:12]}?", a.yes):
                    print(f"{src}: left at {str(rec.get('ref'))[:12]}")
                    continue
                try:
                    print(f"{src}: {self.install_one(st, {**new, 'ref': new['ref']}, 'cli', plugins)} at {new['ref'][:12]}")
                except PluginError as e:
                    print(f"{src}: FAILED: {e}")
                    rc = 1
                self.save(st)
            return rc

    def print_diff(self, src, rec, new):
        owner, repo, subdir = parse_source(src)
        path = (subdir + "/" if subdir else "") + MANIFEST
        old_text = ""
        for ref in (rec.get("resolved"), rec.get("ref")):
            if ref:
                try:
                    old_text = self.gh.manifest_text(f"{owner}/{repo}", ref, path)
                    break
                except PluginError:
                    continue
        new_text = self.gh.manifest_text(f"{owner}/{repo}", new["ref"], path)
        print(f"{src}: {str(rec.get('ref'))[:12]} -> {new['ref'][:12]}")
        diff = list(difflib.unified_diff(old_text.splitlines(), new_text.splitlines(),
                                         "old " + MANIFEST, "new " + MANIFEST, lineterm=""))
        print("\n".join(diff) if diff else "  (manifest unchanged; the code behind it changed)")
        print_manifest(src, new["ref"], new["man"])

    def cmd_remove(self, a):
        with self.locked():
            st = self.load()
            plugins = self.herdr.plugins()
            hit = None
            for src, rec in st["plugins"].items():
                if a.target in (src, rec.get("plugin_id")):
                    hit = src
            if hit is None:
                for p in plugins:
                    s = p.get("source") or {}
                    if s.get("kind") == "github" and a.target in (
                            p.get("plugin_id"), source_name(s.get("owner", ""), s.get("repo", ""), s.get("subdir") or "")):
                        hit = source_name(s.get("owner", ""), s.get("repo", ""), s.get("subdir") or "")
            if hit is None:
                raise PluginError(f"{a.target}: not a GitHub-installed plugin")
            if st["plugins"].get(hit, {}).get("managed_by") == "declarative":
                log(f"note: {hit} is declared in agentos.herdr.plugins and comes back at the next sync "
                    "unless it is removed from the configuration")
            self.herdr.uninstall(hit)
            st["plugins"].pop(hit, None)
            self.save(st)
            print(f"removed {hit}")
        return 0

    # ── declarative sync
    def cmd_sync(self, a):
        cfg = read_json(a.config, None)
        if not isinstance(cfg, dict):
            raise PluginError(f"cannot read {a.config}")
        desired = {}
        for item in cfg.get("plugins", []):
            owner, repo, subdir = parse_source(item["source"])
            ref = check_ref(item["ref"])
            desired[source_name(owner, repo, subdir)] = (ref, bool(item.get("enable", True)))
        links = [os.path.realpath(p) for p in cfg.get("links", [])]
        managed = bool(cfg.get("server_managed", False))
        errors = []
        toggles = []  # (plugin_id, wanted)

        with self.locked():
            st = self.load()
            plugins = self.herdr.plugins()

            # declared plugins
            for src, (ref, enable) in sorted(desired.items()):
                owner, repo, subdir = parse_source(src)
                cand = {"src": src, "owner": owner, "repo": repo, "subdir": subdir, "ref": ref,
                        "man": {"id": (st["plugins"].get(src) or {}).get("plugin_id", "")}}
                try:
                    status = self.install_one(st, cand, "declarative", plugins)
                    print(f"{src}: {status} at {ref[:12]}")
                    inst = find_installed(plugins, owner, repo, subdir)
                    if inst and bool(inst.get("enabled")) != enable:
                        toggles.append((inst["plugin_id"], enable))
                except PluginError as e:
                    errors.append(f"{src}: {e}")
                self.save(st)

            # declared local links
            for path in links:
                try:
                    pid = self.herdr.link(path)
                    st["links"][path] = {"plugin_id": pid}
                    print(f"linked {path} ({pid})")
                except PluginError as e:
                    errors.append(f"link {path}: {e}")

            # what this tool installed earlier and the configuration no longer lists
            for src, rec in sorted(st["plugins"].items()):
                if rec.get("managed_by") == "declarative" and src not in desired:
                    try:
                        self.herdr.uninstall(src)
                        del st["plugins"][src]
                        print(f"{src}: uninstalled (no longer declared)")
                    except PluginError as e:
                        errors.append(f"{src}: {e}")
            stale_links = [p for p in st["links"] if p not in links]
            stale_ids = [st["links"][p].get("plugin_id") for p in stale_links]
            if toggles or any(stale_ids):
                try:
                    with ServerGuard(self.herdr, managed):
                        for pid, wanted in toggles:
                            self.herdr.set_enabled(pid, wanted)
                            print(f"{pid}: {'enabled' if wanted else 'disabled'}")
                        for path in stale_links:
                            pid = st["links"][path].get("plugin_id")
                            if pid:
                                self.herdr.unlink(pid)
                                print(f"{pid}: unlinked (no longer declared)")
                            del st["links"][path]
                except PluginError as e:
                    errors.append(str(e))
            else:
                for path in stale_links:
                    st["links"].pop(path, None)
            self.save(st)

        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1 if errors else 0


def build_parser():
    p = argparse.ArgumentParser(prog="agentos-herdr-plugins", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    c = sub.add_parser("catalog", help="list marketplace plugins (GitHub topic herdr-plugin)")
    c.add_argument("--refresh", action="store_true", help="ignore the cache")
    c.add_argument("--min-stars", type=int, default=0)
    c.add_argument("--json", action="store_true")

    s = sub.add_parser("show", help="print the manifests of a plugin and the commands they run")
    s.add_argument("source")
    s.add_argument("--ref")

    i = sub.add_parser("install", help="install a plugin pinned to a commit")
    i.add_argument("source")
    i.add_argument("--ref", help="commit, tag or branch (default: the current default-branch head commit)")
    i.add_argument("--yes", "-y", action="store_true", help="do not ask")

    ia = sub.add_parser("install-all", help="install every compatible marketplace plugin (unreviewed code)")
    ia.add_argument("--yes", "-y", action="store_true", help="do not ask")
    ia.add_argument("--exclude", action="append", metavar="GLOB", help="owner/repo[/subdir] glob to skip (repeatable)")
    ia.add_argument("--min-stars", type=int, default=0)
    ia.add_argument("--refresh", action="store_true")
    ia.add_argument("--dry-run", action="store_true", help="print the plan only")

    u = sub.add_parser("update", help="move installed plugins to their new head commit")
    u.add_argument("plugin", nargs="?", help="owner/repo[/subdir] or plugin id (default: all)")
    u.add_argument("--yes", "-y", action="store_true")

    li = sub.add_parser("list", help="installed plugins and who manages them")
    li.add_argument("--json", action="store_true")

    r = sub.add_parser("remove", help="uninstall a GitHub-installed plugin")
    r.add_argument("target", help="owner/repo[/subdir] or plugin id")

    sy = sub.add_parser("sync", help="apply a declarative plugin configuration (used by the NixOS module)")
    sy.add_argument("--config", required=True)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    tool = Tool()
    handler = {"catalog": tool.cmd_catalog, "show": tool.cmd_show, "install": tool.cmd_install,
               "install-all": tool.cmd_install_all, "update": tool.cmd_update, "list": tool.cmd_list,
               "remove": tool.cmd_remove, "sync": tool.cmd_sync}[args.cmd]
    try:
        return handler(args)
    except Refused as e:
        print(f"agentos-herdr-plugins: {e}", file=sys.stderr)
        return 2
    except PluginError as e:
        print(f"agentos-herdr-plugins: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
