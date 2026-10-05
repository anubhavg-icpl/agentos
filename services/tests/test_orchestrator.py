import os

import pytest

from nestlo_services import tasks as T
from nestlo_services.unixapi import call, serve_unix
from orchfix import (cfg, clock, complete, orch, runtime, statuses, submit, systemctl,  # noqa: F401
                     taskstore)


# ── validation and injection ─────────────────────────────────────────────
@pytest.mark.parametrize("field,value", [
    ("agent", "nosuch"),
    ("agent", "fake; rm -rf /"),
    ("agent", "$(id)"),
    ("agent", "../fake"),
    ("agent", ["fake"]),
    ("workspace", "../../etc"),
    ("workspace", "/etc"),
    ("workspace", "/"),
    ("workspace", "demo/../../.."),
    ("workspace", "nosuchdir"),
    ("workspace", ""),
    ("workspace", "demo\0/x"),
    ("prompt", ""),
    ("prompt", "a\0b"),
    ("prompt", "--dangerously-skip-permissions"),
    ("prompt", "x" * (64 * 1024 + 1)),
    ("prompt", 42),
    ("budget_usd", -1),
    ("budget_usd", 0),
    ("budget_usd", True),
    ("budget_usd", "5"),
    ("budget_usd", float("inf")),
    ("timeout_sec", 0),
    ("timeout_sec", 10 ** 9),
    ("timeout_sec", 1.5),
    ("depends_on", "task; ls"),
    ("depends_on", [1]),
    ("depends_on", ["nosuch-task"]),
    ("swarm", 0),
    ("swarm", 1000),
    ("group", "a b"),
    ("isolate", "yes"),
    ("origin", "x" * 200),
    ("command", ["sh", "-c", "id"]),   # unknown field: commands come from the config only
])
def test_submit_rejects_malicious_or_bad_fields(orch, field, value):
    with pytest.raises(T.ValidationError):
        submit(orch, **{field: value})
    assert orch.tasks.active_ids() == []


def test_workspace_symlink_escape_is_refused(orch, runtime, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, os.path.join(runtime["workspace_root"], "sneaky"))
    with pytest.raises(T.ValidationError):
        submit(orch, workspace="sneaky")


def test_workspace_may_be_a_bare_name_or_absolute_path(orch, runtime):
    a, = submit(orch, workspace="demo")
    b, = submit(orch, workspace=os.path.join(runtime["workspace_root"], "other"))
    assert a["workspace"] == os.path.join(runtime["workspace_root"], "demo")
    assert b["workspace"] == os.path.join(runtime["workspace_root"], "other")


def test_agent_without_task_command_is_refused(orch):
    with pytest.raises(T.ValidationError, match="no task command"):
        submit(orch, agent="noplan")


def test_alias_agent_uses_the_command_template(orch):
    task, = submit(orch, agent="claude-code")
    assert T.task_command(orch.opts, orch.runtime(), task["agent"]) == ["claude", "-p", "{prompt}"]


def test_prompt_is_one_argv_element_and_never_reexpanded(orch):
    nasty = "$(touch /tmp/pwned); `id` \"'; {workspace} {task_id} {prompt}\n&& rm -rf /"
    task, = submit(orch, prompt=nasty)
    argv = T.render_argv(["claude", "-p", "{prompt}"], task["prompt"], task["workspace"], task["id"])
    assert argv == ["claude", "-p", nasty]
    # placeholders in the template are filled, those inside the prompt are not
    argv = T.render_argv(["x", "--dir={workspace}", "--id={task_id}", "{prompt}"], nasty, "/w", "t1")
    assert argv == ["x", "--dir=/w", "--id=t1", nasty]


def test_prev_result_needs_a_dependency(orch):
    with pytest.raises(T.ValidationError, match="prev_result"):
        submit(orch, prompt="continue from {prev_result}")


def test_runner_revalidates_a_tampered_record(orch, runtime):
    task, = submit(orch)
    record = dict(orch.tasks.get(task["id"]))
    for field, value in (("workspace", "/etc"), ("agent", "root"), ("resolved_prompt", "--evil"),
                         ("prompt", "a\0b"), ("id", "../x")):
        bad = dict(record, **{field: value})
        with pytest.raises(T.ValidationError):
            T.validate_record(bad, runtime, orch.opts)
    assert T.validate_record(record, runtime, orch.opts)["resolved_prompt"] == "do it"


# ── dependency ordering ──────────────────────────────────────────────────
def test_pipeline_runs_in_order_and_passes_results(orch, systemctl):
    a, = submit(orch, prompt="step one")
    b, = submit(orch, prompt="review: {prev_result}", depends_on=[a["id"]])
    c, = submit(orch, prompt="summarize: {prev_result}", after=[b["id"]])
    orch.tick()
    assert systemctl.started() == [orch.unit(a["id"])]
    assert statuses(orch, [a["id"], b["id"], c["id"]]) == ["running", "queued", "queued"]

    complete(orch, a["id"], output="ONE")
    orch.tick()
    assert systemctl.started() == [orch.unit(a["id"]), orch.unit(b["id"])]
    assert orch.tasks.get(b["id"])["resolved_prompt"] == "review: ONE"

    complete(orch, b["id"], output="TWO")
    orch.tick()
    assert orch.tasks.get(c["id"])["resolved_prompt"] == "summarize: TWO"
    assert orch.tasks.get(c["id"])["status"] == "running"


def test_output_is_not_reexpanded_and_cannot_become_an_option(orch):
    a, = submit(orch)
    b, = submit(orch, prompt="{prev_result}", depends_on=[a["id"]])
    orch.tick()
    complete(orch, a["id"], output="--flag {prev_result}")
    orch.tick()
    assert orch.tasks.get(b["id"])["resolved_prompt"] == " --flag {prev_result}"


def test_failed_dependency_skips_the_rest_of_the_chain(orch, systemctl):
    a, = submit(orch)
    b, = submit(orch, depends_on=[a["id"]])
    c, = submit(orch, depends_on=[b["id"]])
    d, = submit(orch, workspace="other")           # independent
    orch.tick()
    complete(orch, a["id"], status=T.FAILED)
    orch.tick()
    assert statuses(orch, [b["id"], c["id"]]) == ["skipped", "skipped"]
    assert "failed" in orch.tasks.get(b["id"])["result"]["error"]
    assert orch.tasks.get(d["id"])["status"] == "running"
    assert orch.unit(b["id"]) not in systemctl.started()


def test_multiple_dependencies_wait_for_all(orch):
    a, = submit(orch, workspace="demo")
    b, = submit(orch, workspace="other")
    c, = submit(orch, prompt="{prev_result}", depends_on=[a["id"], b["id"]])
    orch.tick()
    complete(orch, a["id"], output="A")
    orch.tick()
    assert orch.tasks.get(c["id"])["status"] == "queued"
    complete(orch, b["id"], output="B")
    orch.tick()
    assert orch.tasks.get(c["id"])["resolved_prompt"] == "A\n\n---\n\nB"


# ── swarm and concurrency ────────────────────────────────────────────────
def test_swarm_fans_out_into_isolated_group_tasks(orch, systemctl):
    tasks = submit(orch, swarm=3, prompt="same prompt")
    assert len(tasks) == 3 and len({t["id"] for t in tasks}) == 3
    assert len({t["group"] for t in tasks}) == 1 and tasks[0]["group"].startswith("swarm-")
    assert all(t["isolate"] and t["prompt"] == "same prompt" for t in tasks)
    orch.tick()
    # max_workers is 2: two start, one waits, all in the same workspace
    assert len(systemctl.started()) == 2
    assert statuses(orch, [t["id"] for t in tasks]).count("queued") == 1
    done = systemctl.started()[0].split("@")[1][:-len(".service")]
    complete(orch, done)
    orch.tick()
    assert len(systemctl.started()) == 3


def test_concurrency_limit_and_fifo_order(orch, systemctl):
    ids = [submit(orch, workspace="demo" if i % 2 else "other", isolate=True)[0]["id"] for i in range(5)]
    orch.tick()
    assert systemctl.started() == [orch.unit(i) for i in ids[:2]]
    orch.tick()
    assert len(systemctl.started()) == 2      # still at the limit
    complete(orch, ids[0])
    orch.tick()
    assert systemctl.started()[-1] == orch.unit(ids[2])
    assert statuses(orch, ids) == ["succeeded", "running", "running", "queued", "queued"]


def test_non_isolated_tasks_never_share_a_working_tree(orch, systemctl):
    a, = submit(orch, workspace="demo")
    b, = submit(orch, workspace="demo")
    c, = submit(orch, workspace="other")
    orch.tick()
    assert statuses(orch, [a["id"], b["id"], c["id"]]) == ["running", "queued", "running"]
    complete(orch, a["id"])
    orch.tick()
    assert orch.tasks.get(b["id"])["status"] == "running"


def test_hand_started_agents_count_against_the_runtime_limit(cfg, taskstore, runtime, clock, systemctl):
    from nestlo_services.orchestrator import Orchestrator
    runtime["max_agents"] = 3
    orch = Orchestrator(cfg, taskstore, runtime=runtime, clock=clock, runner=systemctl,
                        agents_running=lambda exclude: 2)      # two agents started by hand
    submit(orch, workspace="demo")
    submit(orch, workspace="other")
    orch.tick()
    assert len(systemctl.started()) == 1


def test_start_failure_fails_the_task(orch, systemctl):
    systemctl.fail_start = True
    task, = submit(orch)
    orch.tick()
    got = orch.tasks.get(task["id"])
    assert got["status"] == "failed" and "Access denied" in got["result"]["error"]


def test_dead_runner_without_result_fails_the_task(orch, systemctl, clock):
    task, = submit(orch)
    orch.tick()
    systemctl.active.clear()          # runner unit vanished
    clock.advance(1)
    orch.tick()
    got = orch.tasks.get(task["id"])
    assert got["status"] == "failed" and "runner exited" in got["result"]["error"]


def test_finished_result_is_not_overwritten_by_reconcile(orch, systemctl, clock):
    task, = submit(orch)
    orch.tick()
    complete(orch, task["id"], output="fine")
    clock.advance(100)
    orch.tick()
    assert orch.tasks.get(task["id"])["status"] == "succeeded"


# ── cancel ───────────────────────────────────────────────────────────────
def test_cancel_queued_running_and_group(orch, systemctl):
    a, = submit(orch, workspace="demo")
    b, = submit(orch, workspace="demo")
    orch.tick()
    orch.cancel(b["id"])
    assert orch.tasks.get(b["id"])["status"] == "cancelled"
    orch.cancel(a["id"])
    assert ["systemctl", "stop", orch.unit(a["id"])] in systemctl.calls
    assert orch.tasks.get(a["id"])["status"] == "cancelled"
    with pytest.raises(Exception, match="already finished"):
        orch.cancel(a["id"])
    swarm = submit(orch, swarm=3, workspace="other")
    orch.tick()
    orch.cancel(swarm[0]["group"])
    assert set(statuses(orch, [t["id"] for t in swarm])) == {"cancelled"}


def test_cancelled_dependency_skips_dependents(orch):
    a, = submit(orch, workspace="demo")
    b, = submit(orch, depends_on=[a["id"]])
    orch.cancel(a["id"])
    orch.tick()
    assert orch.tasks.get(b["id"])["status"] == "skipped"


# ── HTTP API over the unix socket ────────────────────────────────────────
def test_api_roundtrip(orch, short_dir, systemctl):
    path = os.path.join(short_dir, "orch.sock")
    server = serve_unix(path, orch.app)
    try:
        status, body = call(path, "POST", "/tasks", {"agent": "fake", "workspace": "demo", "prompt": "hi", "swarm": 2})
        assert status == 201 and len(body["tasks"]) == 2
        group = body["group"]
        first = body["tasks"][0]["id"]

        assert call(path, "GET", "/tasks/" + first)[1]["prompt"] == "hi"
        assert len(call(path, "GET", "/tasks?status=queued")[1]["tasks"]) == 2
        status, body = call(path, "GET", "/groups/" + group)
        assert status == 200 and body["counts"] == {"queued": 2}
        assert call(path, "GET", "/health")[1]["queued"] == 2

        status, body = call(path, "POST", "/tasks", {"agent": "fake", "workspace": "/etc", "prompt": "x"})
        assert status == 400 and "not below" in body["error"]
        assert call(path, "GET", "/tasks/nosuch")[0] == 404
        assert call(path, "POST", "/tasks/%s/cancel" % first)[0] == 200
        assert call(path, "POST", "/tasks/%s/cancel" % first)[0] == 409
        assert call(path, "GET", "/nothing")[0] == 404
    finally:
        server.shutdown()
        server.server_close()


def test_publish_block_is_validated():
    from nestlo_services.tasks import validate_publish, ValidationError as VE
    assert validate_publish(None) is None
    assert validate_publish({"repo": "acme/widgets", "title": "t"}) == {"repo": "acme/widgets", "title": "t"}
    for bad in ({"repo": "nope"}, {"url": "x"}, {"title": 1}, {"body": "x" * 60001}, "acme/widgets"):
        with pytest.raises(VE):
            validate_publish(bad)
