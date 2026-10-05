"""Publish an agent's branch: push it and open a pull request.

Called by the root task runner (taskrunner.py) after a task whose record has
`kind: "publish"` or a `publish` block, when a trigger asked for it, or for
every successful task when `agentos.git-automation.autoPR` is on and the
task's workspace belongs to a configured repository.

Trust model. The task record is written by the orchestrator user, which is
not trusted with the GitHub token, so the record can only *ask* for a
publish ({repo, title, body, draft}). Everything that decides where the
code goes comes from the root-owned services.toml:

  * the repository must be listed under [publish.repos] (push URL, base
    branch);
  * only branches named agent/<task-id> are pushed, never a protected or the
    base branch, never with force;
  * the token is read from a file only root may read (a systemd credential)
    and is used by this process alone: the agent sandbox never sees it.

The agent controls the repository, and a root process must not run its git
hooks or config (core.fsmonitor, core.sshCommand, url.<x>.insteadOf would
leak the token). So the work is split:

  1. as the agent user (no token): commit leftover changes on the branch,
     check the diff is not empty, `git bundle` the branch into a temp dir;
  2. as root: fetch the bundle into a fresh bare repository with an empty
     config, and push *that* with the token as an http.extraHeader.

Git and HTTP are injectable (`git`, `opener`) so the tests use a local bare
repository and a fake GitHub API.
"""

import base64
import fnmatch
import json
import logging
import os
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

from . import audit as auditmod
from . import config as configmod
from . import provenance as prov

log = logging.getLogger("agentos.publish")

DEFAULTS = {
    "publish": {
        # Publish every successful task of a configured workspace (autoPR)
        "auto": False,
        "api_url": "https://api.github.com",
        "token_file": "",
        "credential_name": "github-token",
        "protected_branches": ["main", "master", "develop", "dev", "trunk", "release/*", "production", "prod", "stable"],
        "commit_uncommitted": True,
        "commit_name": "AgentOS",
        "commit_email": "agentos@localhost",
        "draft": False,
        # "owner/name" -> {url, base, workspaces[]}
        "repos": {},
    },
}

_REPO = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}/[A-Za-z0-9._-]{1,100}$")
_BRANCH = re.compile(r"^agent/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_BASE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$")
_ORIGIN = re.compile(r"^gh:([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#(\d+)")
_SAFE_URL = re.compile(r"^(https://|http://(127\.0\.0\.1|localhost|\[::1\])(:\d+)?/|file:///|/)")


class PublishError(Exception):
    def __init__(self, message, code="failed"):
        super().__init__(message)
        self.code = code


def settings(cfg):
    section = json.loads(json.dumps(DEFAULTS["publish"]))
    return configmod._merge(section, cfg.get("publish", {}))


# ── helpers ──────────────────────────────────────────────────────────────
def clean_text(value, limit, multiline=False):
    """Printable text, capped; for titles and bodies that go to the API as data."""
    if not isinstance(value, str):
        return ""
    keep = "\n\t" if multiline else ""
    text = "".join(c for c in value if c.isprintable() or c in keep)
    if not multiline:
        text = " ".join(text.split())
    return text[:limit]


def is_protected(branch, opts, base=None):
    if base and branch == base:
        return True
    return any(fnmatch.fnmatchcase(branch, pat) for pat in opts["protected_branches"])


def load_token(opts, environ=None):
    """Read the token from the systemd credential or token_file; root-only files."""
    environ = os.environ if environ is None else environ
    path = opts.get("token_file") or ""
    cred_dir = environ.get("CREDENTIALS_DIRECTORY")
    if cred_dir and opts.get("credential_name"):
        candidate = os.path.join(cred_dir, opts["credential_name"])
        if os.path.exists(candidate):
            path = candidate
    if not path:
        raise PublishError("no GitHub token is configured (agentos.git-automation.publish.tokenFile)", "config")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        raise PublishError("cannot read the GitHub token file: %s" % exc.strerror, "config")
    with os.fdopen(fd) as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077:
            raise PublishError("the GitHub token file must be a regular file readable only by its owner", "config")
        token = f.read().strip()
    if not token or any(c.isspace() for c in token):
        raise PublishError("the GitHub token file is empty or malformed", "config")
    return token


def resolve_spec(task, opts, marker=None):
    """What to publish for a task, or None when no publish was requested.

    `marker` is a request recorded outside the task record (the trigger
    service does that when the orchestrator has no `publish` field).
    Returns {repo, title, body, draft, explicit, issue}."""
    block = task.get("publish") if isinstance(task.get("publish"), dict) else None
    explicit = task.get("kind") == "publish" or block is not None or marker is not None
    if not explicit and not opts.get("auto"):
        return None
    block = block or (marker if isinstance(marker, dict) else {})
    origin = task.get("origin") or ""
    m = _ORIGIN.match(origin)
    repo = block.get("repo") if isinstance(block.get("repo"), str) else None
    issue = None
    if m:
        repo = repo or m.group(1)
        issue = int(m.group(2))
    if repo is None:
        ws = os.path.basename(str(task.get("workspace") or "").rstrip("/"))
        for name, conf in opts["repos"].items():
            if ws and ws in (conf.get("workspaces") or []):
                repo = name
                break
    if repo is None or repo not in opts["repos"]:
        if explicit:
            raise PublishError("repository %r is not configured for publishing" % repo, "config")
        return None
    if not _REPO.match(repo):
        raise PublishError("invalid repository name", "config")
    title = clean_text(block.get("title"), 200) or "AgentOS: %s" % task.get("id", "change")
    body = clean_text(block.get("body"), 4000, multiline=True)
    return {"repo": repo, "title": title, "body": body, "issue": issue, "explicit": explicit,
            "draft": bool(block.get("draft", opts.get("draft")))}


# ── git ──────────────────────────────────────────────────────────────────
class _Result:
    def __init__(self, returncode, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def make_git(agent_ids=None, base_env=None):
    """A git runner: git(args, cwd=None, env=None, as_agent=False) -> result.

    `agent_ids` ({user, group, extra_groups}) is applied when as_agent is set,
    so the repository's own config and hooks run without root's rights."""
    def git(args, cwd=None, env=None, as_agent=False):
        full_env = dict(base_env if base_env is not None else {"PATH": os.environ.get("PATH", "")})
        full_env.update({"GIT_TERMINAL_PROMPT": "0", "LANG": "C.UTF-8"})
        full_env.update(env or {})
        extra = agent_ids if (as_agent and agent_ids) else {}
        res = subprocess.run(["git", *args], cwd=cwd, env=full_env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
                             timeout=600, **extra)
        return _Result(res.returncode, res.stdout, res.stderr)
    return git


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects: they would carry the token to another host."""

    def redirect_request(self, *args, **kwargs):
        return None


def default_opener():
    return urllib.request.build_opener(_NoRedirect)


# ── the publisher ────────────────────────────────────────────────────────
class Publisher:
    audit = auditmod.NullClient()       # the task runner sets a real client

    def __init__(self, opts, token, git=None, opener=None, home=None):
        self.opts = opts
        self.token = token
        self.git = git or make_git()
        self.opener = opener or default_opener()
        self.home = home

    # -- error hygiene
    def _redact(self, text):
        text = text or ""
        for secret in (self.token, base64.b64encode(b"x-access-token:" + self.token.encode()).decode()):
            if secret:
                text = text.replace(secret, "***")
        return text.strip()[:400]

    def _git(self, args, cwd=None, env=None, as_agent=False, what="git"):
        res = self.git(args, cwd=cwd, env=env, as_agent=as_agent)
        if res.returncode != 0:
            raise PublishError("%s failed: %s" % (what, self._redact(res.stderr or res.stdout)))
        return res

    # -- stage 1: as the agent user
    def prepare_bundle(self, workdir, branch, base_sha, base, bundle, attest=None):
        """Commit, check, bundle. Returns (branch commit, provenance envelope or None).

        `attest(commit)` -> envelope (or None) runs after the leftover changes
        are committed and before the bundle is made, so the signed commit is
        exactly the one pushed; the envelope goes into a git note that rides
        in the bundle."""
        agent = lambda args, **kw: self.git(["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", *args],  # noqa: E731
                                            cwd=workdir, as_agent=True, **kw)
        if agent(["rev-parse", "--git-dir"]).returncode != 0:
            raise PublishError("%s is not a git repository" % workdir)
        current = agent(["symbolic-ref", "--short", "-q", "HEAD"]).stdout.strip()
        if current != branch:
            raise PublishError("the workspace is on %r, not on %s" % (current, branch), "branch")
        dirty = agent(["status", "--porcelain"]).stdout.strip()
        if dirty and self.opts["commit_uncommitted"]:
            ident = ["-c", "user.name=" + self.opts["commit_name"], "-c", "user.email=" + self.opts["commit_email"],
                     "-c", "commit.gpgsign=false"]
            for args in (["add", "-A"], [*ident, "commit", "--quiet", "--no-verify", "-m", "AgentOS: changes from the agent"]):
                res = agent(args)
                if res.returncode != 0:
                    raise PublishError("could not commit the agent's changes: %s" % self._redact(res.stderr))
        base_ref = None
        for candidate in (base_sha, "refs/heads/" + base, "refs/remotes/origin/" + base):
            if candidate and agent(["rev-parse", "--verify", "--quiet", candidate + "^{commit}"]).returncode == 0:
                base_ref = candidate
                break
        if base_ref is None:
            base_ref = agent(["hash-object", "-t", "tree", "/dev/null"]).stdout.strip()
        if agent(["diff", "--quiet", base_ref, "refs/heads/" + branch]).returncode == 0:
            raise PublishError("the branch has no changes against %s" % base, "empty")
        refs = ["refs/heads/" + branch]
        sha = agent(["rev-parse", "--verify", "refs/heads/" + branch]).stdout.strip()
        envelope = attest(sha) if attest else None
        if envelope:
            try:
                prov.add_note(lambda a, cwd: agent(a), workdir, sha, envelope)
            except prov.ProvenanceError as exc:
                raise PublishError(str(exc), "provenance")
            refs.append(prov.NOTES_REF)
        res = agent(["bundle", "create", "--quiet", bundle, *refs])
        if res.returncode != 0:
            raise PublishError("could not bundle the branch: %s" % self._redact(res.stderr))
        return sha, envelope

    # -- stage 2: as root, in a clean repository
    def push_bundle(self, bundle, branch, url, tmp, notes=False):
        bare = os.path.join(tmp, "clean.git")
        env = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": tmp}
        self._git(["init", "--bare", "--quiet", bare], env=env, what="git init")
        safe = ["-c", "transfer.fsckObjects=true", "-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null"]
        refspecs = ["refs/heads/%s:refs/heads/%s" % (branch, branch)]
        self._git([*safe, "fetch", "--quiet", bundle, refspecs[0]], cwd=bare, env=env, what="git fetch (bundle)")
        if url.startswith(("https://", "http://")):
            cred = base64.b64encode(("x-access-token:" + self.token).encode()).decode()
            # In the environment, not argv: argv is world-readable in /proc
            env.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraHeader",
                        "GIT_CONFIG_VALUE_0": "Authorization: Basic " + cred})
        if notes:
            refspecs.append(prov.NOTES_REF + ":" + prov.NOTES_REF)
            self._git([*safe, "fetch", "--quiet", bundle, prov.NOTES_REF + ":" + prov.NOTES_REF],
                      cwd=bare, env=env, what="git fetch (notes)")
            # Notes others pushed before must survive: merge them in (union; ours are on other commits)
            remote = "refs/notes/remote-agentos-provenance"
            got = self.git([*safe, "fetch", "--quiet", url, "+%s:%s" % (prov.NOTES_REF, remote)], cwd=bare, env=env)
            if got.returncode == 0:
                ident = {"GIT_AUTHOR_NAME": "AgentOS", "GIT_AUTHOR_EMAIL": "agentos@localhost",
                         "GIT_COMMITTER_NAME": "AgentOS", "GIT_COMMITTER_EMAIL": "agentos@localhost"}
                self._git([*safe, "notes", "--ref=" + prov.NOTES_REF, "merge", "-s", "union", remote],
                          cwd=bare, env=dict(env, **ident), what="git notes merge")
        # Atomic: the branch must never land without its provenance note
        atomic = ["--atomic"] if notes else []
        self._git([*safe, "push", "--quiet", *atomic, url, *refspecs], cwd=bare, env=env, what="git push")
        return self._git(["rev-parse", "refs/heads/" + branch], cwd=bare, env=env).stdout.strip()

    # -- GitHub REST
    def api(self, method, path, body=None):
        base = self.opts["api_url"].rstrip("/")
        parsed = urllib.parse.urlsplit(base)
        if parsed.scheme != "https" and parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise PublishError("api_url must be https (the token would travel in clear text)", "config")
        req = urllib.request.Request(base + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("User-Agent", "agentos-publish")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with self.opener.open(req, timeout=30) as resp:
                raw = resp.read(1 << 20)
                return resp.status, json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            try:
                data = json.loads(exc.read(1 << 16) or b"{}")
            except ValueError:
                data = {}
            return exc.code, data
        except (urllib.error.URLError, OSError, ValueError) as exc:
            raise PublishError("GitHub API unreachable: %s" % self._redact(str(exc)))

    def set_status(self, repo, sha, state, description, context=prov.STATUS_CONTEXT, target_url=None):
        """A commit status (the merge gate). Best effort: a failure is logged, never raised."""
        body = {"state": state, "context": context, "description": clean_text(description, 140)}
        if target_url:
            body["target_url"] = target_url
        try:
            status, data = self.api("POST", "/repos/%s/statuses/%s" % (repo, sha), body)
        except PublishError as exc:
            log.warning("could not set the %s status: %s", context, exc)
            return False
        if status != 201:
            log.warning("could not set the %s status (HTTP %s)", context, status)
        return status == 201

    def open_pr(self, repo, branch, base, title, body, draft):
        status, data = self.api("POST", "/repos/%s/pulls" % repo,
                                {"title": title, "head": branch, "base": base, "body": body, "draft": draft})
        if status == 201 and isinstance(data.get("html_url"), str):
            return data["html_url"], data.get("number")
        if status == 422:
            # Most likely "a pull request already exists for this branch"
            owner = repo.split("/")[0]
            query = urllib.parse.urlencode({"head": "%s:%s" % (owner, branch), "state": "open"})
            st2, existing = self.api("GET", "/repos/%s/pulls?%s" % (repo, query))
            if st2 == 200 and isinstance(existing, list) and existing and isinstance(existing[0].get("html_url"), str):
                return existing[0]["html_url"], existing[0].get("number")
        message = data.get("message") if isinstance(data, dict) else None
        raise PublishError("GitHub refused the pull request (HTTP %s): %s" % (status, self._redact(clean_text(message, 200))), "api")

    # -- entry point
    def publish(self, spec, task_id, workdir, branch, base_sha=None, attest=None):
        """Push `branch` from `workdir` and open the PR. Returns the result dict.

        `attest(commit)` (see prepare_bundle) is given when provenance is on: its
        envelope is pushed as a git note, summarised in the PR body, and the
        `agentos/provenance` status is set on the pushed commit."""
        repo = spec["repo"]
        conf = self.opts["repos"].get(repo)
        if conf is None or not _REPO.match(repo):
            raise PublishError("repository %r is not configured for publishing" % repo, "config")
        base = conf.get("base") or "main"
        if not _BASE.match(base):
            raise PublishError("invalid base branch in the configuration", "config")
        url = conf.get("url") or "https://github.com/%s.git" % repo
        if not _SAFE_URL.match(url):
            raise PublishError("the push URL for %s is not allowed" % repo, "config")
        if not _BRANCH.match(branch or ""):
            raise PublishError("refusing to publish %r: only agent/<task-id> branches are pushed" % branch, "protected")
        if is_protected(branch, self.opts, base):
            raise PublishError("refusing to push the protected branch %s" % branch, "protected")
        if not os.path.isdir(workdir):
            raise PublishError("no such working directory: %s" % workdir)
        tmp = tempfile.mkdtemp(prefix="agentos-publish.", dir=self.home)
        try:
            os.chmod(tmp, 0o1777)  # the agent-side git writes the bundle here
            bundle = os.path.join(tmp, "branch.bundle")
            _, envelope = self.prepare_bundle(workdir, branch, base_sha, base, bundle, attest)
            sha = self.push_bundle(bundle, branch, url, tmp, notes=bool(envelope))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        body = spec.get("body") or ""
        if spec.get("issue"):
            body += "\n\nRefs #%d" % spec["issue"]
        body += "\n\n---\nOpened by AgentOS from task `%s` (branch `%s`)." % (task_id, branch)
        if envelope:
            body += "\n\n---\n" + prov.summary(envelope)
        pr_url, number = self.open_pr(repo, branch, base, spec["title"], body.strip(), bool(spec.get("draft")))
        result = {}
        if attest is not None:
            if envelope:
                digest = prov.envelope_digest(envelope)
                self.set_status(repo, sha, "success", "Signed provenance attached (sha256 %s)" % digest[:16], target_url=pr_url)
                result = {"provenance_digest": digest}
            else:
                self.set_status(repo, sha, "failure", "No provenance was attached to this commit", target_url=pr_url)
        log.info("task %s: pushed %s to %s, PR %s", task_id, branch, repo, pr_url)
        self.audit.emit("publish.pr", None, task=task_id, repo=repo, branch=branch, base=base, pr_url=pr_url,
                        pr_number=number, pushed_sha=sha)
        return {"pr_url": pr_url, "pr_number": number, "branch": branch, "base": base, "repo": repo, "pushed_sha": sha, **result}
