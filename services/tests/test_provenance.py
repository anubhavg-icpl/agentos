import base64
import copy
import json
import os
import shutil
import subprocess

import pytest

from nestlo_services import config as configmod
from nestlo_services import provenance as PV
from nestlo_services import publish as P
from nestlo_services import tasks as T
from nestlo_services.taskrunner import TaskRunner
from orchfix import cfg, clock, orch, runtime, submit, systemctl, taskstore  # noqa: F401
from test_publish import REPO, FakeGitHub, FakeResp, env, sh  # noqa: F401

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")

SHA = "a" * 40


def make_signer(tmp_path, name="k.pem"):
    path = str(tmp_path / name)
    pub, created = PV.generate_key(path, str(tmp_path / (name + ".pub")))
    assert created
    return PV.Signer.load({"key_file": path}, environ={}), pub


def statement(**kw):
    args = dict(commit=SHA, tree="b" * 40, branch="agent/t1", agent="claude", agent_binary="/nix/store/x-claude/bin/claude",
                agent_store_path="/nix/store/x-claude", system_closure="/nix/store/y-system",
                task={"id": "t1", "origin": "gh:acme/widgets#7", "attempt": 2}, prompt="secret prompt",
                usage={"usd": 0.5, "tokens": {"input": 10}, "models": {"claude-test": 0.5}},
                verify={"status": "passed", "exit_code": 0},
                approval={"decision": "approved", "by": "alice", "uid": 1000, "at": 1_800_000_000.0, "note": "ok"},
                started_at=1_800_000_000.0, finished_at=1_800_000_100.0, exit_code=0)
    args.update(kw)
    return PV.build_statement(**args)


# ── sign / verify ────────────────────────────────────────────────────────
def test_sign_and_verify_round_trip(tmp_path):
    signer, pub = make_signer(tmp_path)
    env_ = signer.sign(statement())
    trusted = PV.parse_public_keys("# the host\nhost %s\n" % pub)
    res = PV.verify_envelope(env_, trusted, SHA)
    assert res["ok"], res["checks"]
    st = res["statement"]
    p = st["predicate"]
    assert st["predicateType"] == PV.PREDICATE_TYPE and st["subject"][0]["digest"] == {"gitCommit": SHA}
    assert p["task"] == {"id": "t1", "origin": "gh:acme/widgets#7", "attempt": 2, "exitCode": 0}
    assert p["approvals"][0]["approver"] == "alice" and p["approvals"][0]["uid"] == 1000
    assert p["models"] == ["claude-test"] and p["usage"]["usd"] == 0.5
    assert p["builder"]["systemClosure"] == "/nix/store/y-system"
    # the prompt is hashed, never included by default
    assert p["prompt"] == {"sha256": PV.sha256_hex("secret prompt")}
    assert "secret prompt" not in json.dumps(st)
    assert statement(include_prompt=True)["predicate"]["prompt"]["text"] == "secret prompt"
    assert PV.envelope_digest(env_) == PV.sha256_hex(PV.envelope_json(env_))


def test_pr_becomes_a_second_subject(tmp_path):
    st = statement(pr_url="https://github.com/acme/widgets/pull/5")
    assert [s["name"] for s in st["subject"]][1] == "https://github.com/acme/widgets/pull/5"
    assert all(s["digest"]["gitCommit"] == SHA for s in st["subject"])


def test_tampered_predicate_is_detected(tmp_path):
    signer, pub = make_signer(tmp_path)
    env_ = signer.sign(statement())
    trusted = PV.parse_public_keys(pub)
    st = PV.decode_payload(env_)
    st["predicate"]["agent"]["name"] = "evil"
    env_["payload"] = base64.b64encode(PV.canonical(st)).decode()
    res = PV.verify_envelope(env_, trusted, SHA)
    assert not res["ok"] and not next(c for c in res["checks"] if c["name"] == "signature")["ok"]


def test_tampered_subject_is_detected(tmp_path):
    signer, pub = make_signer(tmp_path)
    env_ = signer.sign(statement())
    trusted = PV.parse_public_keys(pub)
    st = PV.decode_payload(env_)
    st["subject"][0]["digest"]["gitCommit"] = "c" * 40
    env_["payload"] = base64.b64encode(PV.canonical(st)).decode()
    assert not PV.verify_envelope(env_, trusted, "c" * 40)["ok"]  # the signature no longer matches
    # an intact envelope for another commit is refused as well
    good = signer.sign(statement())
    res = PV.verify_envelope(good, trusted, "d" * 40)
    assert not res["ok"] and not next(c for c in res["checks"] if c["name"] == "subject")["ok"]


def test_untrusted_or_no_keys_do_not_verify(tmp_path):
    signer, _ = make_signer(tmp_path)
    other, other_pub = make_signer(tmp_path, "other.pem")
    env_ = signer.sign(statement())
    assert not PV.verify_envelope(env_, PV.parse_public_keys(other_pub), SHA)["ok"]
    assert not PV.verify_envelope(env_, {}, SHA)["ok"]
    assert not PV.verify_envelope({"payloadType": "x"}, {}, SHA)["ok"]


def test_missing_and_unsafe_keys(tmp_path):
    with pytest.raises(PV.ProvenanceError):
        PV.Signer.load({"key_file": ""}, environ={})
    with pytest.raises(PV.ProvenanceError):
        PV.Signer.load({"key_file": str(tmp_path / "nope.pem")}, environ={})
    path = str(tmp_path / "k.pem")
    PV.generate_key(path)
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"
    os.chmod(path, 0o644)
    with pytest.raises(PV.ProvenanceError, match="readable only"):
        PV.Signer.load({"key_file": path}, environ={})
    os.chmod(path, 0o600)
    # the systemd credential wins over the configured path
    cred = tmp_path / "cred"
    cred.mkdir()
    shutil.copy(path, cred / "provenance-key")
    os.chmod(cred / "provenance-key", 0o600)
    assert PV.key_path({"key_file": "/x", "credential_name": "provenance-key"}, {"CREDENTIALS_DIRECTORY": str(cred)}) \
        == str(cred / "provenance-key")
    # keygen never overwrites
    _, created = PV.generate_key(path)
    assert not created


# ── git notes ────────────────────────────────────────────────────────────
def test_note_is_written_and_read_back(tmp_path):
    repo = tmp_path / "r"
    sh("git", "init", "-q", "-b", "main", str(repo))
    (repo / "f").write_text("x")
    sh("git", "add", "-A", cwd=repo)
    sh("git", "commit", "-q", "-m", "c", cwd=repo)
    sha = sh("git", "rev-parse", "HEAD", cwd=repo)
    signer, pub = make_signer(tmp_path)
    envelope = signer.sign(statement(commit=sha))

    def git(args, cwd):
        return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                              env=dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null"))
    PV.add_note(git, str(repo), sha, envelope)
    assert sh("git", "notes", "--ref=nestlo-provenance", "list", cwd=repo)
    assert PV.read_note(str(repo), sha) == envelope
    assert PV.verify_envelope(PV.read_note(str(repo), sha), PV.parse_public_keys(pub), PV.resolve_commit(str(repo), "HEAD"))["ok"]
    # the CLI resolves a commit-ish to its note
    assert PV.main(["verify", "HEAD", "--repo", str(repo), "--key", pub]) == 0
    other = tmp_path / "o.pub"
    other.write_text(make_signer(tmp_path, "z.pem")[1])
    assert PV.main(["verify", "HEAD", "--repo", str(repo), "--keys", str(other)]) == 1
    assert PV.main(["show", "HEAD", "--repo", str(repo)]) == 0


# ── publish: note push, PR body, commit status ───────────────────────────
class StatusGitHub(FakeGitHub):
    def open(self, req, timeout=None):
        if req.get_method() == "POST" and "/statuses/" in req.full_url:
            self.requests.append({"method": "POST", "url": req.full_url, "body": json.loads(req.data),
                                  "headers": {k.lower(): v for k, v in req.header_items()}})
            return FakeResp(201, {})
        return super().open(req, timeout)


def attest_with(signer, **kw):
    def attest(sha):
        return signer.sign(statement(commit=sha, **kw))
    return attest


def test_publish_pushes_note_sets_status_and_describes_the_pr(env, tmp_path):
    env.gh = StatusGitHub()
    env.pub.opener = env.gh
    signer, pub = make_signer(tmp_path)
    (env.ws / "new.txt").write_text("agent work\n")  # uncommitted: the attested commit is the one made at publish
    res = env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base, attest=attest_with(signer))
    sha = res["pushed_sha"]
    # the note rides along on the remote and verifies against the pushed commit
    note = json.loads(sh("git", "-C", str(env.remote), "notes", "--ref=nestlo-provenance", "show", sha))
    assert PV.verify_envelope(note, PV.parse_public_keys(pub), sha)["ok"]
    assert res["provenance_digest"] == PV.envelope_digest(note)
    pr, status = env.gh.requests
    assert "nestlo-provenance" in pr["body"]["body"] and res["provenance_digest"] in pr["body"]["body"]
    assert "Nestlo provenance" in pr["body"]["body"] and "Refs #7" in pr["body"]["body"]
    assert status["method"] == "POST" and status["url"] == "https://api.github.com/repos/acme/widgets/statuses/" + sha
    assert status["body"]["state"] == "success" and status["body"]["context"] == "nestlo/provenance"
    assert status["headers"]["authorization"] == "Bearer " + "ghp_supersecrettoken123"


def test_publish_merges_notes_already_on_the_remote(env, tmp_path):
    env.gh = StatusGitHub()
    env.pub.opener = env.gh
    signer, pub = make_signer(tmp_path)
    attest = attest_with(signer)
    (env.ws / "a.txt").write_text("a")
    first = env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base, attest=attest)
    sh("git", "checkout", "-q", "-b", "agent/task-2", env.base, cwd=env.ws)
    (env.ws / "b.txt").write_text("b")
    second = env.pub.publish(env.spec, "task-2", str(env.ws), "agent/task-2", env.base, attest=attest)
    for sha in (first["pushed_sha"], second["pushed_sha"]):
        assert sh("git", "-C", str(env.remote), "notes", "--ref=nestlo-provenance", "show", sha)


def test_publish_without_an_envelope_reports_a_failed_status(env):
    env.gh = StatusGitHub()
    env.pub.opener = env.gh
    (env.ws / "x").write_text("x")
    res = env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base, attest=lambda sha: None)
    assert "provenance_digest" not in res
    assert env.gh.requests[-1]["body"]["state"] == "failure"
    assert "nestlo-provenance" not in env.gh.requests[0]["body"]["body"]
    assert sh("git", "-C", str(env.remote), "for-each-ref", "refs/notes") == ""


def test_publish_without_provenance_sets_no_status(env):
    (env.ws / "x").write_text("x")
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base)
    assert len(env.gh.requests) == 1  # only the PR


def test_status_failure_does_not_fail_the_publish(env, tmp_path):
    (env.ws / "x").write_text("x")
    signer, _ = make_signer(tmp_path)
    # FakeGitHub raises AssertionError for unknown URLs; make the status endpoint answer 404
    import io
    import urllib.error

    class Gh(FakeGitHub):
        def open(self, req, timeout=None):
            if "/statuses/" in req.full_url:
                raise urllib.error.HTTPError(req.full_url, 404, "x", {}, io.BytesIO(b"{}"))
            return super().open(req, timeout)
    env.pub.opener = Gh()
    assert env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base, attest=attest_with(signer))["pr_url"]


# ── the task runner ──────────────────────────────────────────────────────
def prov_runner(cfg, runtime, taskstore, tmp_path, **opts):
    cfg["provenance"] = dict({"enable": True}, **opts)
    cfg["recording"] = dict(cfg.get("recording") or {}, dir=str(tmp_path / "rec"))
    signer, pub = make_signer(tmp_path)
    runner = TaskRunner(cfg, runtime, taskstore, drop_privileges=False, signer=signer,
                        closure_path=str(tmp_path / "system"))
    return runner, pub


def test_runner_builds_an_envelope_from_the_books(cfg, runtime, taskstore, tmp_path, env):
    (tmp_path / "rec" / "task-1").mkdir(parents=True)
    (tmp_path / "rec" / "task-1" / "000001.json").write_text('{"seq": 1}')
    (tmp_path / "real").mkdir()
    os.symlink(tmp_path / "real", tmp_path / "system")
    runner, pub = prov_runner(cfg, runtime, taskstore, tmp_path)
    taskstore.store.record("task-1", "claude-test", 0.25, {"input": 100, "output": 20})
    runtime["agent_home"] = str(tmp_path)
    task = {"id": "task-1", "agent": "claude", "resolved_prompt": "do it", "origin": "manual", "started_at": runner.clock(),
            "attempt": 1, "approval": {"decision": "approved", "by": "bob", "uid": 7, "at": runner.clock(), "note": ""}}
    runner.agent_exe = shutil.which("git")
    sha = sh("git", "rev-parse", "HEAD", cwd=env.ws)
    envelope = runner.build_envelope(task, {"verify": {"status": "passed", "exit_code": 0}, "exit_code": 0}, sha, str(env.ws))
    res = PV.verify_envelope(envelope, PV.parse_public_keys(pub), sha)
    assert res["ok"], res["checks"]
    p = res["statement"]["predicate"]
    assert p["usage"]["usd"] == 0.25 and p["usage"]["tokens"] == {"input": 100, "output": 20}
    assert p["models"] == ["claude-test"]
    assert p["recording"]["id"] == "task-1" and p["recording"]["requests"] == 1
    assert p["builder"]["systemClosure"] == str(tmp_path / "real")
    assert p["source"]["gitTree"] == sh("git", "rev-parse", sha + "^{tree}", cwd=env.ws)
    assert p["approvals"][0]["approver"] == "bob" and p["verify"]["status"] == "passed"


def test_runner_attest_callback_off_missing_key_and_require(cfg, runtime, taskstore, tmp_path):
    task = {"id": "task-1", "agent": "claude"}
    off = TaskRunner(cfg, runtime, taskstore, drop_privileges=False)
    assert off.attest_callback(task, {}, "/w") is None
    cfg["provenance"] = {"enable": True, "key_file": str(tmp_path / "absent.pem")}
    lax = TaskRunner(cfg, runtime, taskstore, drop_privileges=False)
    assert lax.attest_callback(task, {}, "/w")(SHA) is None  # no key: publish goes on, unsigned
    cfg["provenance"]["require_for_publish"] = True
    strict = TaskRunner(cfg, runtime, taskstore, drop_privileges=False)
    with pytest.raises(P.PublishError) as exc:
        strict.attest_callback(task, {}, "/w")(SHA)
    assert exc.value.code == "provenance"


def test_runner_try_publish_passes_the_hook_only_when_enabled(cfg, runtime, taskstore, tmp_path):
    calls = []

    class Pub:
        def __call__(self, opts):
            return self

        def publish(self, *a, **kw):
            calls.append(kw)
            return {"pr_url": "https://github.com/acme/widgets/pull/9", "pr_number": 9, "branch": "agent/t", "base": "main",
                    "repo": REPO, "pushed_sha": SHA}
    cfg["publish"] = {"repos": {REPO: {"workspaces": ["demo"]}}}
    task = {"id": "t", "workspace": "/w/demo", "publish": {"repo": REPO}, "agent": "claude"}
    TaskRunner(cfg, runtime, taskstore, drop_privileges=False, publisher=Pub()).try_publish(task, "/w/demo", "agent/t", None)
    assert calls == [{}]
    runner, _ = prov_runner(cfg, runtime, taskstore, tmp_path)
    runner.publisher = Pub()
    runner.try_publish(task, "/w/demo", "agent/t", None)
    assert callable(calls[1]["attest"])


# ── replay-check ─────────────────────────────────────────────────────────
def test_replay_check_compares_transcript_and_tree(tmp_path, capsys):
    from nestlo_services.recorder import transcript_digest
    rec = tmp_path / "rec" / "t1"
    rec.mkdir(parents=True)
    (rec / "000001.json").write_text('{"seq": 1}')
    digest, count = transcript_digest(str(tmp_path / "rec"), "t1")
    repo = tmp_path / "r"
    sh("git", "init", "-q", "-b", "agent/t1", str(repo))
    (repo / "f").write_text("x")
    sh("git", "add", "-A", cwd=repo)
    sh("git", "commit", "-q", "-m", "c", cwd=repo)
    sha = sh("git", "rev-parse", "HEAD", cwd=repo)
    signer, pub = make_signer(tmp_path)
    st = statement(commit=sha, tree=PV.tree_of(str(repo), sha), system_closure=os.path.realpath("/run/current-system"),
                   recording={"id": "t1", "requests": count, "transcriptSha256": digest})
    path = tmp_path / "e.json"
    path.write_text(PV.envelope_json(signer.sign(st)))
    base = ["replay-check", "t1", "--envelope", str(path), "--repo", str(repo), "--key", pub, "--recordings", str(tmp_path / "rec")]
    assert PV.main(base + ["--replayed", str(repo)]) == 0
    assert PV.main(base) == 0
    out = capsys.readouterr().out
    assert "ok   transcript" in out and "ok   tree" in out
    (rec / "000001.json").write_text('{"seq": 1, "tampered": true}')
    assert PV.main(base) == 1
    assert "FAIL transcript" in capsys.readouterr().out


def test_branch_and_note_are_pushed_atomically(env, tmp_path):
    env.gh = StatusGitHub()
    env.pub.opener = env.gh
    signer, _ = make_signer(tmp_path)
    seen, real = [], env.pub.git

    def spy(args, cwd=None, env=None, as_agent=False):
        seen.append(list(args))
        return real(args, cwd=cwd, env=env, as_agent=as_agent)
    env.pub.git = spy
    (env.ws / "n.txt").write_text("n")
    env.pub.publish(env.spec, "task-1", str(env.ws), "agent/task-1", env.base, attest=attest_with(signer))
    push, = [a for a in seen if "push" in a]
    assert "--atomic" in push and PV.NOTES_REF + ":" + PV.NOTES_REF in push


def test_failed_run_signs_only_commits_the_agent_made(cfg, runtime, taskstore, tmp_path, env):
    (tmp_path / "real").mkdir()
    os.symlink(tmp_path / "real", tmp_path / "system")
    runner, pub = prov_runner(cfg, runtime, taskstore, tmp_path)
    runtime["agent_home"] = str(tmp_path)
    runner.agent_exe = shutil.which("git")
    runner.base_sha = sh("git", "rev-parse", "HEAD", cwd=env.ws)
    sh("git", "checkout", "-q", "-b", "agent/task-9", cwd=env.ws)
    task = {"id": "task-9", "agent": "claude", "resolved_prompt": "x", "origin": "manual",
            "started_at": runner.clock(), "attempt": 1}
    runner.attest_unpublished(task, {"exit_code": 1}, str(env.ws), "agent/task-9", new_only=True)
    assert runner.envelope is None              # nothing new on the branch: nothing to sign
    (env.ws / "w.txt").write_text("work")
    sh("git", "add", "w.txt", cwd=env.ws)
    sh("git", "commit", "-q", "-m", "partial", cwd=env.ws)
    runner.attest_unpublished(task, {"exit_code": 1}, str(env.ws), "agent/task-9", new_only=True)
    sha = sh("git", "rev-parse", "HEAD", cwd=env.ws)
    res = PV.verify_envelope(runner.envelope, PV.parse_public_keys(pub), sha)
    assert res["ok"], res["checks"]
    assert runner.provenance_fields()["provenance"]["sha256"]
