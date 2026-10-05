import io
import json
import os
import shutil
import subprocess
import urllib.error

import pytest

from nestlo_services import publish as P
from nestlo_services import tasks as T
from nestlo_services.taskrunner import TaskRunner
from orchfix import cfg, clock, orch, runtime, submit, systemctl, taskstore  # noqa: F401

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")

TOKEN = "ghp_supersecrettoken123"
REPO = "acme/widgets"
IDENT = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}


def sh(*args, cwd=None):
    env = dict(os.environ, **IDENT)
    return subprocess.run(args, cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout.strip()


class FakeResp:
    def __init__(self, status, data):
        self.status, self._raw = status, json.dumps(data).encode()

    def read(self, n=-1):
        return self._raw

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


class FakeGitHub:
    """An injectable opener standing in for the GitHub REST API."""

    def __init__(self):
        self.requests = []
        self.pr_status = 201
        self.existing = []

    def open(self, req, timeout=None):
        body = json.loads(req.data) if req.data else None
        self.requests.append({"method": req.get_method(), "url": req.full_url, "body": body,
                              "headers": {k.lower(): v for k, v in req.header_items()}})
        if req.get_method() == "POST" and req.full_url.endswith("/pulls"):
            if self.pr_status == 201:
                return FakeResp(201, {"html_url": "https://github.com/%s/pull/5" % REPO, "number": 5})
            raise urllib.error.HTTPError(req.full_url, self.pr_status, "x", {}, io.BytesIO(
                json.dumps({"message": "Validation Failed " + TOKEN}).encode()))
        if req.get_method() == "GET":
            return FakeResp(200, self.existing)
        raise AssertionError(req.full_url)


@pytest.fixture
def env(tmp_path):
    remote = tmp_path / "remote.git"
    sh("git", "init", "--bare", "-q", "-b", "main", str(remote))
    ws = tmp_path / "ws"
    sh("git", "init", "-q", "-b", "main", str(ws))
    (ws / "README").write_text("hello\n")
    sh("git", "add", "-A", cwd=ws)
    sh("git", "commit", "-q", "-m", "init", cwd=ws)
    base = sh("git", "rev-parse", "HEAD", cwd=ws)
    sh("git", "push", "-q", str(remote), "main", cwd=ws)
    sh("git", "checkout", "-q", "-b", "agent/task-1", cwd=ws)

    class E:
        pass
    e = E()
    e.remote, e.ws, e.base, e.gh, e.tmp = remote, ws, base, FakeGitHub(), tmp_path
    e.opts = P.settings({"publish": {"repos": {REPO: {"url": str(remote), "base": "main", "workspaces": ["ws"]}},
                                     "api_url": "https://api.github.com"}})
    e.pub = P.Publisher(e.opts, TOKEN, git=P.make_git(None, dict(os.environ, **IDENT)), opener=e.gh, home=str(tmp_path))
    e.spec = {"repo": REPO, "title": "Fix it", "body": "details", "issue": 7, "explicit": True, "draft": False}
    return e


def remote_branches(e):
    return sh("git", "-C", str(e.remote), "branch", "--format=%(refname:short)").split()


def test_publish_commits_pushes_and_opens_a_pr(env):
    (env.ws / "new.txt").write_text("agent work\n")  # left uncommitted by the agent
    res = env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert res["pr_url"] == "https://github.com/acme/widgets/pull/5" and res["base"] == "main"
    assert "agent/task-1" in remote_branches(env)
    assert sh("git", "-C", str(env.remote), "show", "agent/task-1:new.txt") == "agent work"
    assert res["pushed_sha"] == sh("git", "-C", str(env.remote), "rev-parse", "agent/task-1")
    req, = env.gh.requests
    assert req["url"] == "https://api.github.com/repos/acme/widgets/pulls"
    assert req["headers"]["authorization"] == "Bearer " + TOKEN
    assert req["body"]["head"] == "agent/task-1" and req["body"]["base"] == "main" and req["body"]["title"] == "Fix it"
    assert "Refs #7" in req["body"]["body"] and "task-1" in req["body"]["body"]
    # the workspace was not left dirty and no stray temp dirs remain
    assert sh("git", "status", "--porcelain", cwd=env.ws) == ""
    assert not [n for n in os.listdir(env.tmp) if n.startswith("nestlo-publish.")]


def test_committed_work_is_published_without_extra_commit(env):
    (env.ws / "a.txt").write_text("a\n")
    sh("git", "add", "-A", cwd=env.ws)
    sh("git", "commit", "-q", "-m", "agent commit", cwd=env.ws)
    head = sh("git", "rev-parse", "HEAD", cwd=env.ws)
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert sh("git", "-C", str(env.remote), "rev-parse", "agent/task-1") == head


def test_empty_diff_is_refused(env):
    with pytest.raises(P.PublishError) as exc:
        env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert exc.value.code == "empty" and env.gh.requests == []
    assert remote_branches(env) == ["main"]


@pytest.mark.parametrize("branch", ["main", "master", "release/1.0", "agent/../main", "refs/heads/main", "feature/x", ""])
def test_only_agent_branches_are_pushed(env, branch):
    (env.ws / "x").write_text("x")
    with pytest.raises(P.PublishError) as exc:
        env.pub.publish(env.spec, "task-1", str(env.ws), branch, env.base)
    assert exc.value.code == "protected" and env.gh.requests == [] and remote_branches(env) == ["main"]


def test_protected_patterns_and_base_branch_are_refused(env):
    env.opts["protected_branches"].append("agent/hotfix*")
    (env.ws / "x").write_text("x")
    with pytest.raises(P.PublishError):
        env.pub.publish(env.spec, "t", str(env.ws), "agent/hotfix-1", env.base)
    env.opts["repos"][REPO]["base"] = "agent/task-1"  # a base can never be pushed to either
    with pytest.raises(P.PublishError):
        env.pub.publish(env.spec, "t", str(env.ws), "agent/task-1", env.base)
    assert remote_branches(env) == ["main"]


def test_the_workspace_must_be_on_the_branch(env):
    sh("git", "checkout", "-q", "main", cwd=env.ws)
    (env.ws / "x").write_text("x")
    with pytest.raises(P.PublishError) as exc:
        env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert exc.value.code == "branch" and remote_branches(env) == ["main"]


def test_unconfigured_repo_and_unsafe_url_are_refused(env):
    (env.ws / "x").write_text("x")
    with pytest.raises(P.PublishError):
        env.pub.publish(dict(env.spec, repo="evil/other"), "t", str(env.ws), "agent/task-1", env.base)
    for url in ("ext::sh -c id", "ssh://x/y", "-oProxyCommand=x", "git://example.com/x", "http://example.com/x"):
        env.opts["repos"][REPO]["url"] = url
        with pytest.raises(P.PublishError) as exc:
            env.pub.publish(env.spec, "t", str(env.ws), "agent/task-1", env.base)
        assert exc.value.code == "config"


def test_non_fast_forward_push_is_never_forced(env):
    (env.ws / "x").write_text("1")
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    sh("git", "reset", "-q", "--hard", env.base, cwd=env.ws)
    (env.ws / "y").write_text("2")
    before = sh("git", "-C", str(env.remote), "rev-parse", "agent/task-1")
    with pytest.raises(P.PublishError):
        env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert sh("git", "-C", str(env.remote), "rev-parse", "agent/task-1") == before


def test_hostile_repo_config_does_not_run_or_redirect(env):
    marker = env.tmp / "pwned"
    cfgfile = env.ws / ".git" / "config"
    cfgfile.write_text(cfgfile.read_text() + "\n[core]\n\tfsmonitor = touch %s\n\tsshCommand = touch %s\n"
                       "[url \"https://evil.example/\"]\n\tinsteadOf = %s\n" % (marker, marker, env.remote))
    hook = env.ws / ".git" / "hooks" / "pre-push"
    hook.write_text("#!/bin/sh\ntouch %s\n" % marker)
    hook.chmod(0o755)
    (env.ws / "x").write_text("x")
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert not marker.exists()
    assert "agent/task-1" in remote_branches(env)


def test_existing_pr_is_reused_on_422(env):
    (env.ws / "x").write_text("x")
    env.gh.pr_status = 422
    env.gh.existing = [{"html_url": "https://github.com/acme/widgets/pull/3", "number": 3}]
    res = env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert res["pr_url"].endswith("/pull/3")
    assert "head=acme%3Aagent%2Ftask-1" in env.gh.requests[1]["url"]


def test_api_errors_never_leak_the_token(env):
    (env.ws / "x").write_text("x")
    env.gh.pr_status = 403
    with pytest.raises(P.PublishError) as exc:
        env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert TOKEN not in str(exc.value)


def test_api_url_must_be_https_unless_loopback(env):
    env.opts["api_url"] = "http://api.example.com"
    with pytest.raises(P.PublishError):
        env.pub.api("GET", "/x")
    env.opts["api_url"] = "http://127.0.0.1:9"
    env.pub.api("GET", "/repos/x/pulls")  # allowed for local mocks


def test_redirects_are_not_followed():
    handler = P._NoRedirect()
    assert handler.redirect_request(None, None, 302, "x", {}, "http://evil/") is None


def test_http_push_sends_the_token_in_the_environment_not_argv(env):
    seen = []
    real = env.pub.git

    def spy(args, cwd=None, env=None, as_agent=False):
        seen.append((list(args), dict(env or {})))
        return real(args, cwd=cwd, env=env, as_agent=as_agent)
    env.pub.git = spy
    env.opts["repos"][REPO]["url"] = "https://127.0.0.1:1/acme/widgets.git"
    (env.ws / "x").write_text("x")
    with pytest.raises(P.PublishError) as exc:
        env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)  # nothing listens there
    assert TOKEN not in str(exc.value)
    assert not any(TOKEN in a for args, _ in seen for a in args)
    pushes = [e for args, e in seen if "push" in args]
    import base64
    assert base64.b64encode(("x-access-token:" + TOKEN).encode()).decode() in pushes[0]["GIT_CONFIG_VALUE_0"]


# ── token file ───────────────────────────────────────────────────────────
def test_token_file_must_be_private(tmp_path):
    f = tmp_path / "tok"
    f.write_text(TOKEN + "\n")
    f.chmod(0o640)
    with pytest.raises(P.PublishError):
        P.load_token({"token_file": str(f), "credential_name": "github-token"}, {})
    f.chmod(0o400)
    assert P.load_token({"token_file": str(f), "credential_name": "github-token"}, {}) == TOKEN
    link = tmp_path / "link"
    link.symlink_to(f)
    with pytest.raises(P.PublishError):
        P.load_token({"token_file": str(link), "credential_name": "github-token"}, {})
    with pytest.raises(P.PublishError):
        P.load_token({"token_file": "", "credential_name": "github-token"}, {})


def test_credential_directory_wins(tmp_path):
    d = tmp_path / "creds"
    d.mkdir()
    (d / "github-token").write_text("from-credential\n")
    (d / "github-token").chmod(0o400)
    assert P.load_token({"token_file": "/nonexistent", "credential_name": "github-token"},
                        {"CREDENTIALS_DIRECTORY": str(d)}) == "from-credential"


# ── what a task asks for ─────────────────────────────────────────────────
def test_resolve_spec():
    opts = P.settings({"publish": {"repos": {REPO: {"workspaces": ["ws"]}}}})
    assert P.resolve_spec({"id": "t", "workspace": "/r/ws"}, opts) is None  # nothing asked, autoPR off
    spec = P.resolve_spec({"id": "t", "workspace": "/r/ws", "origin": "gh:acme/widgets#7",
                           "publish": {"title": "T\n\x00x", "body": "b"}}, opts)
    assert spec["repo"] == REPO and spec["issue"] == 7 and spec["title"] == "Tx" and spec["explicit"]
    with pytest.raises(P.PublishError):  # a record cannot name a repo that is not configured
        P.resolve_spec({"id": "t", "workspace": "/r/ws", "publish": {"repo": "evil/x"}}, opts)
    opts["auto"] = True
    assert P.resolve_spec({"id": "t", "workspace": "/r/ws"}, opts)["explicit"] is False
    assert P.resolve_spec({"id": "t", "workspace": "/r/other"}, opts) is None


# ── the task runner integration ──────────────────────────────────────────
class FakePublisher:
    def __init__(self, error=None):
        self.calls, self.error = [], error

    def __call__(self, opts):
        return self

    def publish(self, spec, task_id, workdir, branch, base_sha=None):
        self.calls.append((spec, task_id, workdir, branch, base_sha))
        if self.error:
            raise self.error
        return {"pr_url": "https://github.com/acme/widgets/pull/9", "pr_number": 9, "branch": branch, "base": "main",
                "repo": REPO, "pushed_sha": "abc"}


def make_runner(cfg, runtime, taskstore, publisher):
    cfg["publish"] = {"repos": {REPO: {"workspaces": ["demo"]}}}
    return TaskRunner(cfg, runtime, taskstore, drop_privileges=False, publisher=publisher)


def test_runner_try_publish_stores_pr_url(cfg, runtime, taskstore, orch):
    fake = FakePublisher()
    runner = make_runner(cfg, runtime, taskstore, fake)
    task = {"id": "task-1", "workspace": "/w/demo", "origin": "gh:acme/widgets#7", "publish": {"title": "T"}}
    fields, error = runner.try_publish(task, "/w/demo", "agent/task-1", "sha")
    assert error is None and fields["pr_url"].endswith("/pull/9") and fields["publish"]["status"] == "published"
    assert fake.calls[0][3:] == ("agent/task-1", "sha")
    # nothing requested: no call
    assert runner.try_publish({"id": "t2", "workspace": "/w/demo"}, "/w/demo", "agent/t2", None) == ({}, None)
    assert len(fake.calls) == 1


def test_runner_marker_from_redis_requests_publish(cfg, runtime, taskstore):
    fake = FakePublisher()
    runner = make_runner(cfg, runtime, taskstore, fake)
    taskstore.r.set(taskstore._k("publish", "task-5"), json.dumps({"repo": REPO, "title": "via marker"}))
    fields, error = runner.try_publish({"id": "task-5", "workspace": "/w/demo"}, "/w/demo", "agent/task-5", None)
    assert error is None and fake.calls[0][0]["title"] == "via marker"


def test_explicit_publish_failure_is_reported_auto_failure_is_not(cfg, runtime, taskstore):
    err = P.PublishError("the branch has no changes against main", "empty")
    runner = make_runner(cfg, runtime, taskstore, FakePublisher(err))
    task = {"id": "t", "workspace": "/w/demo", "publish": {"repo": REPO}}
    fields, error = runner.try_publish(task, "/w/demo", "agent/t", None)
    assert error and fields["publish"]["code"] == "empty"
    cfg["publish"]["auto"] = True
    fields, error = runner.try_publish({"id": "t", "workspace": "/w/demo"}, "/w/demo", "agent/t", None)
    assert error is None and fields["publish"]["status"] == "skipped"


def test_publish_kind_task_publishes_the_dependencys_branch(cfg, runtime, taskstore, orch):
    fake = FakePublisher()
    runner = make_runner(cfg, runtime, taskstore, fake)
    run, = submit(orch)
    orch.tasks.finish(run["id"], T.SUCCEEDED, branch="agent/" + run["id"], base_sha="b" * 40, worktree=None)
    node = dict(id="task-pub", agent="fake", workspace="demo", prompt="publish", kind="publish",
                depends_on=[run["id"]], status="running", origin="gh:acme/widgets#7", created_at=1.0,
                publish={"title": "T"}, result=None)
    taskstore.create(node)
    assert runner.run("task-pub") == 0
    done = taskstore.get("task-pub")
    assert done["status"] == "succeeded" and done["result"]["pr_url"].endswith("/pull/9")
    spec, task_id, workdir, branch, base = fake.calls[0]
    assert branch == "agent/" + run["id"] and base == "b" * 40 and workdir.endswith("/demo")


def test_publish_kind_task_without_a_branch_fails(cfg, runtime, taskstore, orch):
    runner = make_runner(cfg, runtime, taskstore, FakePublisher())
    taskstore.create(dict(id="task-pub", agent="fake", workspace="demo", prompt="p", kind="publish", depends_on=[],
                          status="running", created_at=1.0, result=None))
    assert runner.run("task-pub") == 1
    assert "no successful dependency" in taskstore.get("task-pub")["result"]["error"]


def test_publish_refused_when_not_on_the_tasks_own_branch(cfg, runtime, taskstore):
    fake = FakePublisher()
    runner = make_runner(cfg, runtime, taskstore, fake)
    task = {"id": "t", "workspace": "/w/demo", "publish": {"repo": REPO}}
    fields, error = runner.try_publish(task, "/w/demo", "agent/other", None)
    assert error == "task is not on its own branch" and fields["publish"]["status"] == "skipped"
    cfg["publish"]["auto"] = True
    fields, error = runner.try_publish({"id": "t", "workspace": "/w/demo"}, "/w/demo", "main", None)
    assert error is None and fields["publish"]["status"] == "skipped" and not fake.calls


def test_publish_is_audited(env):
    class Rec:
        enabled = True

        def __init__(self):
            self.events = []

        def emit(self, etype, actor=None, **data):
            self.events.append((etype, actor, data))

    env.pub.audit = Rec()
    (env.ws / "new.txt").write_text("agent work\n")
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    (etype, _, data), = env.pub.audit.events
    assert etype == "publish.pr" and data["task"] == "task-1" and data["repo"] == REPO
    assert data["branch"] == "agent/task-1" and data["pr_url"].endswith("/pull/5")
    assert TOKEN not in repr(env.pub.audit.events)
