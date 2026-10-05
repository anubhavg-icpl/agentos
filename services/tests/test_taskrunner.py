import json
import os
import shutil
import stat
import subprocess
import sys
import time

import pytest

from nestlo_services import tasks as T
from nestlo_services.taskrunner import TaskRunner
from orchfix import cfg, clock, orch, runtime, submit, systemctl, taskstore  # noqa: F401

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="git is not installed")

FAKE_SYSTEMD_RUN = """#!%(python)s
# Stands in for systemd-run: applies --setenv / --working-directory, records
# the properties it was given, then runs the command after "--".
import json, os, sys
args = sys.argv[1:]
env, cwd, props, i = dict(os.environ), None, [], 0
while args[i] != "--":
    a = args[i]
    if a.startswith("--setenv="):
        k, v = a[len("--setenv="):].split("=", 1)
        env[k] = v
    elif a.startswith("--working-directory="):
        cwd = a.split("=", 1)[1]
    elif a == "-p":
        i += 1
        props.append(args[i])
    i += 1
with open(os.environ["FAKE_SYSTEMD_LOG"], "w") as f:
    json.dump({"props": props, "opts": [a for a in args[:i] if a.startswith("--") and "=" not in a],
               "unit": [a for a in args[:i] if a.startswith("--unit=")], "argv": args[i + 1:]}, f)
os.chdir(cwd)
os.execvpe(args[i + 1], args[i + 1:], env)
"""

FAKE_AGENT = """#!%(python)s
import os, sys, time
mode = sys.argv[1] if len(sys.argv) > 1 else ""
print("agent:", sys.argv[1:], "branch", os.environ["NESTLO_BRANCH"], "cwd", os.getcwd(), flush=True)
if mode == "fail":
    print("boom", file=sys.stderr, flush=True)
    sys.exit(3)
if mode == "sleep":
    time.sleep(60)
if mode == "flood":
    sys.stdout.write("x" * 5000 + "END\\n")
"""


@pytest.fixture
def env(tmp_path, cfg, runtime, taskstore, clock, monkeypatch):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in (("systemd-run", FAKE_SYSTEMD_RUN), ("fake-agent", FAKE_AGENT)):
        path = bin_dir / name
        path.write_text(body % {"python": sys.executable})
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("FAKE_SYSTEMD_LOG", str(tmp_path / "systemd.json"))
    monkeypatch.setenv("GIT_AUTHOR_NAME", "t")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "t@t")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "t")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "t@t")
    cfg["orchestrator"].update(agent_path=str(bin_dir), result_tail_kb=1, task_commands={"fake": ["fake-agent", "{prompt}"]})
    (tmp_path / "home").mkdir()
    ws = os.path.join(runtime["workspace_root"], "demo")
    subprocess.run(["git", "init", "-q", ws], check=True)
    subprocess.run(["git", "-C", ws, "commit", "-q", "--allow-empty", "-m", "init"], check=True)

    class E:
        pass
    e = E()
    e.tmp, e.ws, e.log = tmp_path, ws, tmp_path / "systemd.json"
    e.runner = TaskRunner(cfg, runtime, taskstore, systemd_run=str(bin_dir / "systemd-run"),
                          systemctl=str(bin_dir / "systemd-run"), drop_privileges=False)
    e.runner.stop_unit = lambda unit: e.runner.proc.terminate()
    return e


def queue(orch, **fields):
    """Submit a task and mark it running, as the orchestrator does at dispatch."""
    task, = submit(orch, **fields)
    orch.tasks.update(task["id"], lambda t: t.update(status="running", started_at=time.time()) or True)
    return task["id"]


def test_successful_run_records_result_state_and_sandbox(env, orch):
    tid = queue(orch, prompt="build $(it) 'now'")
    assert env.runner.run(tid) == 0
    task = orch.tasks.get(tid)
    assert task["status"] == "succeeded"
    res = task["result"]
    assert res["exit_code"] == 0 and res["branch"] == "agent/" + tid
    assert repr(["build $(it) 'now'"]) in res["output_tail"]
    assert open(res["log"]).read().startswith("agent:")
    assert stat.S_IMODE(os.stat(res["log"]).st_mode) == 0o640
    # the agent's branch was checked out in the workspace
    head = subprocess.run(["git", "-C", env.ws, "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
    assert head == "agent/" + tid
    # the daemon's registry entry
    with open(os.path.join(env.runner.state_dir, tid + ".json")) as f:
        state = json.load(f)
    assert state["unit"] == "nestlo-agent-%s.service" % tid and state["sandboxed"] and state["task"] == tid
    assert state["status"] == "running" and state["user"] == "nestlo-agent"
    # the sandbox mirrors `nestlo spawn`, and the prompt is one argv element
    seen = json.load(open(env.log))
    assert seen["unit"] == ["--unit=nestlo-agent-" + tid]
    for prop in ("NoNewPrivileges=yes", "ProtectSystem=strict", "ProtectHome=yes", "PrivateTmp=yes"):
        assert prop in seen["props"]
    assert any(p.startswith("ReadWritePaths=%s " % env.ws) for p in seen["props"])
    assert any(p.startswith("RuntimeMaxSec=") for p in seen["props"])
    assert seen["argv"][1:] == ["build $(it) 'now'"]
    assert {"--pipe", "--wait", "--collect"} <= set(seen["opts"])


def test_failure_keeps_exit_code_and_tail(env, orch):
    tid = queue(orch, prompt="fail")
    assert env.runner.run(tid) == 1
    task = orch.tasks.get(tid)
    assert task["status"] == "failed" and task["result"]["exit_code"] == 3
    assert "boom" in task["result"]["output_tail"] and "exit code 3" in task["result"]["error"]


def test_output_tail_is_bounded_but_log_is_complete(env, orch):
    tid = queue(orch, prompt="flood")
    env.runner.run(tid)
    res = orch.tasks.get(tid)["result"]
    assert len(res["output_tail"]) <= 1024 and res["output_tail"].rstrip().endswith("END")
    assert len(open(res["log"]).read()) > 5000


def test_timeout_stops_the_unit(env, orch):
    tid = queue(orch, prompt="sleep", timeout_sec=1)
    started = time.time()
    assert env.runner.run(tid) == 1
    task = orch.tasks.get(tid)
    assert task["status"] == "timeout" and "timed out" in task["result"]["error"]
    assert time.time() - started < 20


def test_cancel_signal_stops_the_unit(env, orch):
    tid = queue(orch, prompt="sleep")
    import threading
    threading.Timer(1.0, env.runner.cancel.set).start()
    env.runner.run(tid)
    assert orch.tasks.get(tid)["status"] == "cancelled"


def test_budget_kill_is_reported(env, orch):
    tid = queue(orch, prompt="fail")
    os.makedirs(env.runner.state_dir, exist_ok=True)
    original = env.runner.register

    def register_then_kill(*a, **kw):
        original(*a, **kw)
        path = os.path.join(env.runner.state_dir, tid + ".json")
        state = json.load(open(path))
        state.update(status="killed", reason="daily budget exceeded ($3.00 of $2.00)")
        json.dump(state, open(path, "w"))
    env.runner.register = register_then_kill
    env.runner.run(tid)
    assert "budget exceeded" in orch.tasks.get(tid)["result"]["error"]


def test_swarm_tasks_get_their_own_worktrees_and_branches(env, orch):
    ids = [queue(orch, swarm=1, isolate=True, prompt="x") for _ in range(2)]
    for tid in ids:
        assert env.runner.run(tid) == 0
    results = [orch.tasks.get(t)["result"] for t in ids]
    assert results[0]["branch"] != results[1]["branch"]
    for tid, res in zip(ids, results):
        assert res["worktree"] == "%s.%s" % (env.ws, tid)
        assert os.path.isdir(res["worktree"]) and ("cwd " + res["worktree"]) in res["output_tail"]
    branches = subprocess.run(["git", "-C", env.ws, "branch", "--list", "agent/*"], capture_output=True, text=True).stdout
    assert all("agent/" + t in branches for t in ids)
    # the main working tree was left alone
    head = subprocess.run(["git", "-C", env.ws, "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
    assert not head.startswith("agent/")
    seen = json.load(open(env.log))
    assert any("ReadWritePaths=%s.%s %s/.git" % (env.ws, ids[1], env.ws) in p for p in seen["props"])


def test_workspace_without_git_or_commits_is_prepared(env, orch, runtime):
    fresh = os.path.join(runtime["workspace_root"], "other")
    tid = queue(orch, workspace="other", isolate=True, prompt="x")
    assert env.runner.run(tid) == 0
    assert os.path.isdir(fresh + "." + tid)


def test_runner_refuses_tasks_that_are_not_running(env, orch):
    task, = submit(orch)
    assert env.runner.run(task["id"]) == 3          # still queued
    assert not os.path.exists(env.log)
    assert env.runner.run("task-nosuch") == 2


def test_runner_rejects_a_tampered_record(env, orch):
    tid = queue(orch)
    orch.tasks.update(tid, lambda t: t.update(workspace="/etc") or True)
    assert env.runner.run(tid) == 1
    task = orch.tasks.get(tid)
    assert task["status"] == "failed" and task["result"]["error"].startswith("rejected")
    assert not os.path.exists(env.log)


def test_command_comes_from_config_not_from_the_record(env, orch):
    tid = queue(orch)
    orch.tasks.update(tid, lambda t: t.update(task_command=["/bin/sh", "-c", "touch /tmp/pwned"]) or True)
    env.runner.run(tid)
    assert json.load(open(env.log))["argv"][0].endswith("fake-agent")


def test_missing_agent_binary_fails_cleanly(env, orch, cfg):
    env.runner.opts["task_commands"] = {"fake": ["not-installed", "{prompt}"]}
    tid = queue(orch)
    assert env.runner.run(tid) == 1
    assert "not installed" in orch.tasks.get(tid)["result"]["error"]


def test_log_symlink_is_not_followed(env, orch):
    tid = queue(orch)
    target = env.tmp / "victim"
    target.write_text("precious")
    os.makedirs(env.runner.opts["tasks_dir"])
    os.symlink(target, os.path.join(env.runner.opts["tasks_dir"], tid + ".log"))
    env.runner.run(tid)
    assert target.read_text() == "precious"
    assert orch.tasks.get(tid)["status"] == "succeeded"


def test_task_budget_needs_the_gateway(env, orch):
    tid = queue(orch, budget_usd=2)
    env.runner.run(tid)
    task = orch.tasks.get(tid)
    assert task["status"] == "failed" and "gateway" in task["result"]["error"]


# ── verify contract ────────────────────────────────────────────────────
def test_verify_passed_runs_in_its_own_sandbox_unit(env, orch):
    tid = queue(orch, prompt="ok", verify={"cmd": ["fake-agent", "check one"]})
    assert env.runner.run(tid) == 0
    task = orch.tasks.get(tid)
    v = task["result"]["verify"]
    assert task["status"] == "succeeded"
    assert v["status"] == "passed" and v["exit_code"] == 0 and "check one" in v["output_tail"]
    assert "cwd " + env.ws in v["output_tail"]
    seen = json.load(open(env.log))  # the last systemd-run call is the verification
    assert seen["unit"] == ["--unit=nestlo-verify-" + tid]
    assert "NoNewPrivileges=yes" in seen["props"] and "ProtectSystem=strict" in seen["props"]
    assert seen["argv"][1:] == ["check one"] and os.path.isabs(seen["argv"][0])


def test_verify_failed_keeps_status_and_skips_publish(env, orch, cfg):
    calls = []

    class Publisher:
        def publish(self, *a):
            calls.append(a)
            return {"pr_url": "u"}

    env.runner.publisher = lambda popts: Publisher()
    env.runner.cfg["publish"] = {"repos": {"acme/widgets": {"workspaces": ["demo"]}}}
    tid = queue(orch, prompt="ok", verify={"cmd": ["fake-agent", "fail"]}, publish={"repo": "acme/widgets"})
    assert env.runner.run(tid) == 0
    task = orch.tasks.get(tid)
    assert task["status"] == "succeeded" and task["result"].get("error") is None
    v = task["result"]["verify"]
    assert v["status"] == "failed" and v["exit_code"] == 3 and "boom" in v["output_tail"]
    assert task["result"]["publish"] == {"status": "skipped", "error": "verify failed"}
    assert calls == []


def test_verify_timeout_is_an_error(env, orch):
    tid = queue(orch, prompt="ok", verify={"cmd": ["fake-agent", "sleep"], "timeout_sec": 1})
    started = time.time()
    env.runner.run(tid)
    assert time.time() - started < 30
    task = orch.tasks.get(tid)
    v = task["result"]["verify"]
    assert task["status"] == "succeeded" and v["status"] == "error" and v["exit_code"] is None
    assert "timed out" in v["output_tail"]


def test_verify_missing_binary_is_an_error(env, orch):
    tid = queue(orch, prompt="ok", verify={"cmd": ["no-such-verifier", "x"]})
    env.runner.run(tid)
    task = orch.tasks.get(tid)
    v = task["result"]["verify"]
    assert task["status"] == "succeeded" and v["status"] == "error" and v["exit_code"] is None
    assert "not installed" in v["output_tail"]


def test_no_verify_for_failed_agent_or_when_unset(env, orch):
    tid = queue(orch, prompt="fail", verify={"cmd": ["fake-agent"]})
    env.runner.run(tid)
    assert "verify" not in orch.tasks.get(tid)["result"]
    tid = queue(orch, prompt="ok")
    env.runner.run(tid)
    assert "verify" not in orch.tasks.get(tid)["result"]


def test_judge_sees_the_runner_verify_status(env, orch):
    tid = queue(orch, prompt="ok", verify={"cmd": ["fake-agent", "fail"]})
    env.runner.run(tid)
    assert "verify: failed" in orch._judge_results([orch.tasks.get(tid)])


def test_retry_of_a_plain_task_reuses_its_existing_branch(env, orch):
    tid = queue(orch, prompt="x")
    subprocess.run(["git", "-C", env.ws, "branch", "agent/" + tid], check=True)
    subprocess.run(["git", "-C", env.ws, "branch", "agent/other"], check=True)
    subprocess.run(["git", "-C", env.ws, "checkout", "-q", "agent/other"], check=True)
    _, branch, _ = env.runner.prepare_workspace(orch.tasks.get(tid))
    assert branch == "agent/" + tid
    current = subprocess.run(["git", "-C", env.ws, "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
    assert current == "agent/" + tid
