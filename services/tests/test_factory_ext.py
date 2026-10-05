"""start_from, kind "publish" and auto-merge (docs/orchestration.md, docs/triggers.md)."""

import io
import json
import os
import shutil
import urllib.error

import pytest

from agentos_services import policy as policymod
from agentos_services import publish as P
from agentos_services import tasks as T
from agentos_services.orchestrator import Orchestrator
from agentos_services.taskrunner import TaskRunner
from orchfix import cfg, clock, complete, orch, runtime, submit, systemctl, taskstore  # noqa: F401
from test_publish import IDENT, REPO, TOKEN, FakeResp, sh
from test_taskrunner import env, queue  # noqa: F401

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")

HEAD = "a" * 40


# ── validation ───────────────────────────────────────────────────────────
def test_start_from_needs_isolate(orch):
    first, = submit(orch, isolate=True)
    with pytest.raises(T.ValidationError, match="isolate"):
        submit(orch, start_from=first["id"])
    with pytest.raises(T.ValidationError, match="start_from must be a task id"):
        submit(orch, isolate=True, start_from="../x")


def test_start_from_unknown_and_other_workspace(orch):
    with pytest.raises(T.ValidationError, match="unknown start_from"):
        submit(orch, isolate=True, start_from="task-nope")
    first, = submit(orch, workspace="other", isolate=True)
    with pytest.raises(T.ValidationError, match="another workspace"):
        submit(orch, isolate=True, start_from=first["id"])


def test_start_from_waits_for_an_unfinished_task_only(orch):
    first, = submit(orch, isolate=True)
    second, = submit(orch, isolate=True, start_from=first["id"])
    assert second["start_from"] == first["id"] and second["depends_on"] == [first["id"]]
    orch.tasks.finish(first["id"], T.FAILED, error="x")
    third, = submit(orch, isolate=True, start_from=first["id"])
    assert third["depends_on"] == []          # finished: any status is a valid start point


def test_defaults_are_unchanged(orch):
    task, = submit(orch)
    assert task["kind"] == "agent" and task["start_from"] is None and task["source_task"] is None


def test_workflow_nodes_refuse_start_from(orch):
    first, = submit(orch, isolate=True)
    with pytest.raises(T.ValidationError, match="start_from not allowed"):
        orch.submit_workflow({"nodes": {"a": {"agent": "fake", "workspace": "demo", "prompt": "x",
                                              "isolate": True, "start_from": first["id"]}}})


def finished(orch, **extra):
    task, = submit(orch, isolate=True)
    orch.tasks.update(task["id"], lambda t: t.update(status="running") or True)
    complete(orch, task["id"], branch="agent/" + task["id"], base_sha=HEAD, **extra)
    return task["id"]


def publish_body(source, **extra):
    return dict({"kind": "publish", "source_task": source, "workspace": "demo",
                 "publish": {"repo": REPO, "title": "T"}}, **extra)


def test_publish_task_validation(orch):
    source = finished(orch)
    task, = orch.submit(publish_body(source))
    assert task["kind"] == "publish" and task["source_task"] == source and task["publish"]["repo"] == REPO
    for bad, msg in (
        ({"source_task": None}, "needs source_task"),
        ({"source_task": "task-nope"}, "unknown source_task"),
        ({"source_task": task["id"]}, "publish task"),
        ({"kind": "deploy"}, "kind must be"),
        ({"isolate": True}, "isolate"),
        ({"swarm": 2}, "swarm"),
        ({"workspace": "other"}, "another workspace"),
        ({"publish": {"repo": REPO, "merge": {"method": "fast-forward"}}}, "merge.method"),
        ({"publish": {"repo": REPO, "merge": {"method": "squash", "require_checks": "yes"}}}, "require_checks"),
    ):
        with pytest.raises(T.ValidationError, match=msg):
            orch.submit(dict(publish_body(source), **bad))
    with pytest.raises(T.ValidationError, match="only for tasks of kind publish"):
        submit(orch, source_task=source)
    with pytest.raises(T.ValidationError, match="only for tasks of kind agent"):
        orch.submit(dict(publish_body(source), start_from=source))


def test_publish_source_must_have_succeeded_with_a_branch(orch):
    queued, = submit(orch, isolate=True)
    with pytest.raises(T.ValidationError, match="has not succeeded"):
        orch.submit(publish_body(queued["id"]))
    plain, = submit(orch)
    orch.tasks.update(plain["id"], lambda t: t.update(status="running") or True)
    complete(orch, plain["id"])
    with pytest.raises(T.ValidationError, match="produced no branch"):
        orch.submit(publish_body(plain["id"]))


def test_merge_block_is_normalized(orch):
    source = finished(orch)
    task, = orch.submit(publish_body(source, publish={"repo": REPO, "merge": {"method": "squash"}}))
    assert task["publish"]["merge"] == {"method": "squash", "require_checks": True}


def test_publish_task_does_not_hold_the_workspace(orch, systemctl):
    source = finished(orch)
    pub, = orch.submit(publish_body(source))
    other, = submit(orch)                       # a plain task in the same workspace
    orch.tick()
    assert set(systemctl.started()) == {orch.unit(pub["id"]), orch.unit(other["id"])}


def test_policy_treats_publish_tasks_as_publishing(orch, cfg):
    source = finished(orch)
    orch.policy = policymod.Policy({"default": {"require_approval": {"mode": "publish"}}})
    task, = orch.submit(publish_body(source))
    assert task["status"] == T.AWAITING and task["gate"]
    orch.policy = policymod.Policy({"default": {"publish_enable": False}})
    with pytest.raises(Exception, match="publish.enable"):
        orch.submit(publish_body(source))
    plain, = submit(orch)                       # no publish: untouched
    assert plain["status"] == T.QUEUED


def test_publish_nodes_in_a_workflow_use_depends_on(orch):
    group, created = orch.submit_workflow({"nodes": {
        "run": {"agent": "fake", "workspace": "demo", "prompt": "x"},
        "pub": {"kind": "publish", "workspace": "demo", "depends_on": ["run"], "publish": {"repo": REPO}}}})
    assert created["pub"]["kind"] == "publish" and created["pub"]["depends_on"] == [created["run"]["id"]]


# ── runner: start_from ───────────────────────────────────────────────────
def git(env, *args, cwd=None):
    return sh("git", *args, cwd=cwd or env.ws)


def test_start_from_continues_the_previous_branch(env, orch):
    first = queue(orch, isolate=True)
    assert env.runner.run(first) == 0
    r1 = orch.tasks.get(first)["result"]
    # the agent left work behind, uncommitted
    with open(os.path.join(r1["worktree"], "round1.txt"), "w") as f:
        f.write("one\n")

    second = queue(orch, isolate=True, start_from=first)
    assert env.runner.run(second) == 0
    r2 = orch.tasks.get(second)["result"]
    tip1 = git(env, "rev-parse", "agent/" + first)
    assert r2["base_sha"] == tip1 != r1["base_sha"]          # the uncommitted work was committed first
    assert r2["start_from"] == first and r2["chain_base_sha"] == r1["base_sha"]
    assert open(os.path.join(r2["worktree"], "round1.txt")).read() == "one\n"
    assert git(env, "rev-parse", "agent/" + second + "~0") == git(env, "rev-parse", "HEAD", cwd=r2["worktree"])

    # a third round chains on: the diff base stays the root's
    third = queue(orch, isolate=True, start_from=second)
    assert env.runner.run(third) == 0
    r3 = orch.tasks.get(third)["result"]
    assert r3["chain_base_sha"] == r1["base_sha"] and r3["base_sha"] == git(env, "rev-parse", "agent/" + second)


def test_start_from_retry_recreates_from_the_same_start(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    with open(os.path.join(orch.tasks.get(first)["result"]["worktree"], "a.txt"), "w") as f:
        f.write("a\n")
    second = queue(orch, isolate=True, start_from=first, max_retries=1)
    env.runner.run(second)
    wt = orch.tasks.get(second)["result"]["worktree"]
    with open(os.path.join(wt, "junk.txt"), "w") as f:
        f.write("failed attempt\n")
    orch.tasks.update(second, lambda t: t.update(status="running", attempt=2) or True)
    env.runner.run(second)
    wt = orch.tasks.get(second)["result"]["worktree"]
    assert os.path.exists(os.path.join(wt, "a.txt")) and not os.path.exists(os.path.join(wt, "junk.txt"))


def test_start_from_missing_branch_fails_clearly(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    git(env, "worktree", "remove", "--force", orch.tasks.get(first)["result"]["worktree"])
    git(env, "branch", "-D", "agent/" + first)
    second = queue(orch, isolate=True, start_from=first)
    assert env.runner.run(second) == 1
    task = orch.tasks.get(second)
    assert task["status"] == "failed" and "branch agent/%s does not exist" % first in task["result"]["error"]


def test_start_from_other_workspace_is_refused_by_the_runner(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    second = queue(orch, isolate=True, start_from=first)
    orch.tasks.update(first, lambda t: t.update(workspace=t["workspace"].replace("demo", "other")) or True)
    assert env.runner.run(second) == 1
    assert "another workspace" in orch.tasks.get(second)["result"]["error"]


# ── runner: kind publish with a local bare remote ────────────────────────
class FakeGitHub:
    """The GitHub REST API: pull requests, check runs, combined status, merge."""

    def __init__(self, head=None):
        self.requests = []
        self.head = head              # sha the PR head reports (None: whatever was pushed)
        self.pushed = None
        self.base = "main"
        self.draft = False
        self.mergeable = True
        self.state = "open"
        self.runs = []                # [{name, status, conclusion}]
        self.combined = {"state": "pending", "total_count": 0}
        self.put_status = 200
        self.merge_sha = "m" * 40
        self.script = []              # callables run before each GET of the PR (simulate progress)

    def open(self, req, timeout=None):
        body = json.loads(req.data) if req.data else None
        method, url = req.get_method(), req.full_url
        self.requests.append((method, url.split("api.github.com")[1], body))
        path = url.split("api.github.com")[1]
        if method == "POST" and path.endswith("/pulls"):
            self.pushed = self.pushed or body["head"]
            return FakeResp(201, {"html_url": "https://github.com/%s/pull/5" % REPO, "number": 5})
        if method == "GET" and "/pulls/5" in path:
            for fn in self.script[:1]:
                self.script.pop(0)()
            return FakeResp(200, {"state": self.state, "draft": self.draft, "mergeable": self.mergeable,
                                  "base": {"ref": self.base}, "head": {"sha": self.head or self.pushed_sha}})
        if method == "GET" and "/check-runs" in path:
            return FakeResp(200, {"total_count": len(self.runs), "check_runs": self.runs})
        if method == "GET" and path.endswith("/status"):
            return FakeResp(200, self.combined)
        if method == "PUT" and path.endswith("/pulls/5/merge"):
            if self.put_status != 200:
                raise urllib.error.HTTPError(url, self.put_status, "x", {}, io.BytesIO(
                    json.dumps({"message": "Head branch was modified"}).encode()))
            return FakeResp(200, {"merged": True, "sha": self.merge_sha})
        if method == "POST" and "/statuses/" in path:
            return FakeResp(201, {})
        raise AssertionError((method, path))

    pushed_sha = HEAD

    def puts(self):
        return [r for r in self.requests if r[0] == "PUT"]


def make_pub(gh, repo_conf=None, wait=100, tmp=None, remote=None, clock=None):
    conf = {"url": str(remote) if remote else "https://github.com/acme/widgets.git", "base": "main", "workspaces": ["demo"],
            "allow_auto_merge": True}
    conf.update(repo_conf or {})
    opts = P.settings({"publish": {"repos": {REPO: conf}, "merge_wait_sec": wait, "merge_poll_sec": 10}})
    ticks = clock or [0.0]
    pub = P.Publisher(opts, TOKEN, git=P.make_git(None, dict(os.environ, **IDENT)), opener=gh, home=str(tmp) if tmp else None,
                      sleep=lambda s: ticks.__setitem__(0, ticks[0] + s), monotonic=lambda: ticks[0])
    return pub


def run_publish(env, orch, tmp_gh, source, **extra):
    """Submit a publish task for `source` and run it with a real Publisher against a bare remote."""
    remote = env.tmp / "remote.git"
    if not remote.exists():
        sh("git", "init", "--bare", "-q", "-b", "main", str(remote))
    env.runner.cfg["publish"] = {"repos": {REPO: {"url": str(remote), "base": "main", "workspaces": ["demo"],
                                                  "allow_auto_merge": extra.pop("allow", False)}},
                                 "merge_wait_sec": 60, "merge_poll_sec": 5}
    env.runner.publisher = lambda opts: P.Publisher(opts, TOKEN, git=P.make_git(None, dict(os.environ, **IDENT)),
                                                    opener=tmp_gh, home=str(env.tmp),
                                                    sleep=lambda s: None)
    body = {"kind": "publish", "source_task": source, "workspace": "demo",
            "publish": dict({"repo": REPO, "title": "Round"}, **extra)}
    task, = orch.submit(body)
    orch.tasks.update(task["id"], lambda t: t.update(status="running") or True)
    code = env.runner.run(task["id"])
    return code, orch.tasks.get(task["id"]), remote


def remote_branches(remote):
    return sh("git", "-C", str(remote), "branch", "--format=%(refname:short)").split()


def test_publish_task_pushes_the_source_branch(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    with open(os.path.join(orch.tasks.get(first)["result"]["worktree"], "r1.txt"), "w") as f:
        f.write("one\n")
    second = queue(orch, isolate=True, start_from=first)       # a fix round that changes nothing itself
    env.runner.run(second)
    gh = FakeGitHub()
    code, done, remote = run_publish(env, orch, gh, second)
    assert code == 0 and done["status"] == "succeeded", done["result"]
    res = done["result"]
    assert res["pr_url"].endswith("/pull/5") and res["pr_number"] == 5 and res["source_task"] == second
    assert res["publish"]["status"] == "published" and res["publish"]["branch"] == "agent/" + second
    assert "agent/" + second in remote_branches(remote)
    # the chain's first round is part of what was pushed
    assert sh("git", "-C", str(remote), "show", "agent/%s:r1.txt" % second) == "one"
    assert "merge" not in res["publish"]
    assert [r for r in gh.requests if r[0] == "PUT"] == []


def test_publish_task_refuses_an_empty_diff(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    second = queue(orch, isolate=True, start_from=first)
    env.runner.run(second)
    gh = FakeGitHub()
    code, done, remote = run_publish(env, orch, gh, second)
    assert code == 1 and done["status"] == "failed" and "no changes" in done["result"]["error"]
    assert remote_branches(remote) == [] and gh.requests == []


def test_publish_task_only_publishes_agent_branches(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    orch.tasks.update(first, lambda t: t["result"].update(branch="main") or True)
    gh = FakeGitHub()
    code, done, remote = run_publish(env, orch, gh, first)
    assert code == 1 and "agent/<task-id>" in done["result"]["error"] and gh.requests == []


def test_publish_task_merges_when_the_repo_allows_it(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    with open(os.path.join(orch.tasks.get(first)["result"]["worktree"], "r1.txt"), "w") as f:
        f.write("one\n")
    gh = FakeGitHub()
    gh.runs = [{"name": "ci", "status": "completed", "conclusion": "success"}]
    gh.combined = {"state": "success", "total_count": 1}
    sha_of = lambda: gh.head  # noqa: E731
    # the PR head is what the publisher pushed; learn it from the first API read
    real_open = gh.open

    def open_(req, timeout=None):
        if req.get_method() == "GET" and "/pulls/5" in req.full_url and gh.head is None:
            gh.head = sh("git", "-C", str(env.tmp / "remote.git"), "rev-parse", "agent/" + first)
        return real_open(req, timeout)
    gh.open = open_
    code, done, remote = run_publish(env, orch, gh, first, allow=True, merge={"method": "squash"})
    assert code == 0, done["result"]
    merge = done["result"]["publish"]["merge"]
    assert merge["status"] == "merged" and merge["sha"] == "m" * 40
    (_, path, body), = gh.puts()
    assert path == "/repos/acme/widgets/pulls/5/merge" and body == {"merge_method": "squash", "sha": gh.head}
    assert sha_of() == done["result"]["publish"]["pushed_sha"]


def test_publish_task_leaves_the_pr_open_when_merge_is_not_allowed(env, orch):
    first = queue(orch, isolate=True)
    env.runner.run(first)
    with open(os.path.join(orch.tasks.get(first)["result"]["worktree"], "r1.txt"), "w") as f:
        f.write("one\n")
    gh = FakeGitHub()
    code, done, remote = run_publish(env, orch, gh, first, allow=False, merge={"method": "squash"})
    assert code == 0 and done["status"] == "succeeded"
    merge = done["result"]["publish"]["merge"]
    assert merge["status"] == "skipped" and "allow_auto_merge" in merge["reason"]
    assert gh.puts() == [] and [r for r in gh.requests if "check-runs" in r[1]] == []


def test_agent_task_publish_block_can_merge_too(cfg, runtime, taskstore):
    class Merger:
        def __init__(self):
            self.merged = []

        def __call__(self, opts):
            return self

        def publish(self, spec, task_id, workdir, branch, base_sha=None):
            return {"pr_url": "u/pull/9", "pr_number": 9, "branch": branch, "base": "main", "repo": REPO, "pushed_sha": HEAD}

        def merge_pr(self, spec, info, task_id=None):
            self.merged.append(spec["merge"])
            return {"status": "merged", "reason": "", "sha": "s"}
    cfg["publish"] = {"repos": {REPO: {"workspaces": ["demo"]}}}
    fake = Merger()
    runner = TaskRunner(cfg, runtime, taskstore, drop_privileges=False, publisher=fake)
    task = {"id": "t", "workspace": "/w/demo", "publish": {"repo": REPO, "merge": {"method": "rebase", "require_checks": False}}}
    fields, error = runner.try_publish(task, "/w/demo", "agent/t", None)
    assert error is None and fields["publish"]["merge"]["status"] == "merged"
    assert fake.merged == [{"method": "rebase", "require_checks": False}]


# ── merge logic ──────────────────────────────────────────────────────────
INFO = {"repo": REPO, "pr_number": 5, "base": "main", "pushed_sha": HEAD, "branch": "agent/t"}


def spec(**merge):
    return {"repo": REPO, "merge": dict({"method": "squash", "require_checks": True}, **merge)}


def green():
    gh = FakeGitHub(head=HEAD)
    gh.runs = [{"name": "build", "status": "completed", "conclusion": "success"},
               {"name": "lint", "status": "completed", "conclusion": "neutral"},
               {"name": "docs", "status": "completed", "conclusion": "skipped"}]
    gh.combined = {"state": "success", "total_count": 2}
    return gh


def test_green_checks_merge_with_the_expected_head(tmp_path):
    gh = green()
    out = make_pub(gh).merge_pr(spec(), INFO, "t")
    assert out["status"] == "merged" and out["sha"] == "m" * 40 and out["method"] == "squash"
    (_, path, body), = gh.puts()
    assert path == "/repos/acme/widgets/pulls/5/merge" and body == {"merge_method": "squash", "sha": HEAD}


def test_a_failing_check_is_skipped(tmp_path):
    gh = green()
    gh.runs.append({"name": "tests", "status": "completed", "conclusion": "failure"})
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "tests" in out["reason"] and gh.puts() == []


@pytest.mark.parametrize("conclusion", ["cancelled", "timed_out", "action_required", "stale"])
def test_only_success_neutral_skipped_count(conclusion):
    gh = green()
    gh.runs[0]["conclusion"] = conclusion
    assert make_pub(gh).merge_pr(spec(), INFO)["status"] == "skipped" and gh.puts() == []


def test_a_failing_combined_status_is_skipped():
    gh = green()
    gh.combined = {"state": "failure", "total_count": 2}
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "commit status" in out["reason"] and gh.puts() == []


def test_pending_checks_are_waited_for_then_merged():
    gh = green()
    gh.runs[0].update(status="in_progress", conclusion=None)
    gh.script = [lambda: None, lambda: gh.runs[0].update(status="completed", conclusion="success")]
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "merged"
    assert len([r for r in gh.requests if r[1].startswith("/repos/acme/widgets/pulls/5") and r[0] == "GET"]) == 2


def test_checks_that_never_finish_time_out_without_merging():
    gh = green()
    gh.runs[0].update(status="queued", conclusion=None)
    out = make_pub(gh, wait=60).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "timed out after 60s" in out["reason"] and gh.puts() == []


def test_no_checks_at_all_depends_on_require_checks():
    gh = FakeGitHub(head=HEAD)
    out = make_pub(gh, wait=30).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "no checks" in out["reason"] and gh.puts() == []
    gh = FakeGitHub(head=HEAD)
    assert make_pub(gh).merge_pr(spec(require_checks=False), INFO)["status"] == "merged"


def test_check_runs_alone_are_enough_when_no_statuses_exist():
    gh = green()
    gh.combined = {"state": "pending", "total_count": 0}      # what GitHub reports with only check runs
    assert make_pub(gh).merge_pr(spec(), INFO)["status"] == "merged"


def test_a_moved_head_is_never_merged():
    gh = green()
    gh.head = "b" * 40
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "moved" in out["reason"] and gh.puts() == []


def test_head_moving_between_the_check_and_the_merge_is_refused_by_the_api():
    gh = green()
    gh.put_status = 409
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "HTTP 409" in out["reason"]
    assert gh.puts()[0][2]["sha"] == HEAD               # the sha was sent, so GitHub is what said no


def test_repo_not_allowed_is_skipped_without_any_api_call():
    gh = green()
    out = make_pub(gh, {"allow_auto_merge": False}).merge_pr(spec(), INFO)
    assert out["status"] == "skipped" and "allow_auto_merge" in out["reason"] and gh.requests == []
    assert P.settings({"publish": {"repos": {REPO: {}}}})["repos"][REPO].get("allow_auto_merge") is None   # default: off


def test_never_merges_into_another_base_a_draft_or_a_conflict():
    for change, text in (({"base": "release"}, "does not target main"), ({"draft": True}, "draft"),
                         ({"mergeable": False}, "not mergeable"), ({"state": "closed"}, "not open")):
        gh = green()
        for k, v in change.items():
            setattr(gh, k, v)
        out = make_pub(gh).merge_pr(spec(), INFO)
        assert out["status"] == "skipped" and text in out["reason"] and gh.puts() == []
    gh = green()
    out = make_pub(gh, {"base": "develop"}).merge_pr(spec(), dict(INFO, base="main"))
    assert out["status"] == "skipped" and gh.requests == []


def test_a_server_error_is_recorded_as_error_and_never_raises():
    gh = green()
    gh.put_status = 500
    out = make_pub(gh).merge_pr(spec(), INFO)
    assert out["status"] == "error" and "500" in out["reason"]


def test_no_merge_request_does_nothing():
    gh = green()
    assert make_pub(gh).merge_pr({"repo": REPO, "merge": None}, INFO) is None and gh.requests == []


def test_merge_is_audited():
    class Rec:
        enabled = True

        def __init__(self):
            self.events = []

        def emit(self, etype, actor=None, **data):
            self.events.append((etype, data))
    pub = make_pub(green())
    pub.audit = Rec()
    pub.merge_pr(spec(), INFO, "task-9")
    (etype, data), = pub.audit.events
    assert etype == "publish.merge" and data["task"] == "task-9" and data["status"] == "merged" and data["sha"] == "m" * 40
    assert TOKEN not in repr(pub.audit.events)


def test_resolve_spec_carries_the_merge_request():
    opts = P.settings({"publish": {"repos": {REPO: {}}}})
    got = P.resolve_spec({"id": "t", "workspace": "/r/ws", "publish": {"repo": REPO, "merge": {"method": "merge"}}}, opts)
    assert got["merge"] == {"method": "merge", "require_checks": True}
    assert P.resolve_spec({"id": "t", "workspace": "/r/ws", "publish": {"repo": REPO}}, opts)["merge"] is None
    with pytest.raises(P.PublishError):
        P.resolve_spec({"id": "t", "workspace": "/r/ws", "publish": {"repo": REPO, "merge": {"method": "x"}}}, opts)
