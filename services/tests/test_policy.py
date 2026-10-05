"""Policy resolution and enforcement, RBAC roles per endpoint, four-eyes."""

import copy
import os

import pytest

from agentos_services import policy as P
from agentos_services import rbac as R
from agentos_services import tasks as T
from agentos_services import unixapi
from agentos_services.orchestrator import Orchestrator
from agentos_services.unixapi import ApiError
from orchfix import (cfg, clock, complete, orch, runtime, statuses, submit, systemctl,  # noqa: F401
                     taskstore)

POLICY = {
    "version": "abc123def456",
    "default": {"budget_usd": 10, "allowed_agents": ["fake", "claude"], "max_retries": 2},
    "repos": {
        "acme/widgets": {"budget_usd": 2, "daily_budget_usd": 5, "require_approval": {"mode": "publish"},
                         "allowed_models": ["claude-sonnet-5-5"], "routing": {"claude-opus-5-5": "claude-sonnet-5-5"},
                         "max_parallel": 1, "publish_enable": True},
        "demo": {"allowed_agents": ["claude"], "require_approval": {"mode": "always"}},
        "other": {"require_approval": {"mode": "costAbove", "threshold_usd": 3}, "publish_enable": False},
        "locked": {"isolation": "container"},
    },
}


@pytest.fixture
def porch(cfg, taskstore, runtime, clock, systemctl):  # noqa: F811
    cfg = copy.deepcopy(cfg)
    cfg["policy"] = copy.deepcopy(POLICY)
    return Orchestrator(cfg, taskstore, runtime=runtime, clock=clock, runner=systemctl,
                        agents_running=lambda exclude: 0)


def refused(orch_, **fields):
    with pytest.raises(ApiError) as exc:
        submit(orch_, **fields)
    assert exc.value.status == 403
    return exc.value.message


# ── resolution ───────────────────────────────────────────────────────────
def test_resolution_by_origin_publish_then_workspace(runtime):
    pol = P.Policy(POLICY)
    root = runtime["workspace_root"]
    f = lambda **kw: dict({"workspace": root + "/demo"}, **kw)  # noqa: E731
    assert pol.resolve(P.candidates(f(origin="gh:acme/widgets#4"), root))[0] == "acme/widgets"
    assert pol.resolve(P.candidates(f(publish={"repo": "acme/widgets"}), root))[0] == "acme/widgets"
    assert pol.resolve(P.candidates(f(), root))[0] == "demo"
    assert pol.resolve(P.candidates({"workspace": root + "/nothing"}, root))[0] == "default"
    assert pol.resolve([])[0] == "default"


def test_effective_policy_inherits_default_key_by_key():
    eff = P.Policy(POLICY).effective("acme/widgets")
    assert eff["budget_usd"] == 2 and eff["max_retries"] == 2 and eff["allowed_agents"] == ["fake", "claude"]
    assert P.Policy(POLICY).show("nosuch")["matched"] is False
    assert P.Policy(POLICY).show("demo")["name"] == "demo"


def test_no_policy_section_enforces_nothing(orch):
    t, = submit(orch, budget_usd=1000, max_retries=5)
    assert t["budget_usd"] == 1000 and "policy" not in t and t["status"] == "queued"


def test_version_falls_back_to_a_hash_of_the_policy():
    section = {"default": {"budget_usd": 1}}
    assert P.Policy(section).version == P.Policy(copy.deepcopy(section)).version
    assert P.Policy({"default": {"budget_usd": 2}}).version != P.Policy(section).version
    assert P.Policy(POLICY).version == "abc123def456"


# ── enforcement ──────────────────────────────────────────────────────────
def test_policy_name_and_version_are_recorded(porch):
    t, = submit(porch, agent="claude", workspace="other", budget_usd=1)
    assert t["policy"]["name"] == "other" and t["policy"]["version"] == "abc123def456"
    assert porch.tasks.get(t["id"])["policy"]["version"] == "abc123def456"
    d, = submit(porch, workspace="demo", agent="claude")
    assert d["policy"]["name"] == "demo"


def test_budget_is_capped_or_filled_in(porch):
    a, = submit(porch, agent="claude", workspace="other", budget_usd=99)
    b, = submit(porch, agent="claude", workspace="other")
    c, = submit(porch, agent="claude", workspace="other", budget_usd=1)
    assert (a["budget_usd"], b["budget_usd"], c["budget_usd"]) == (10, 10, 1)
    assert "budget_usd capped at 10" in a["policy"]["applied"]


def test_retries_are_capped(porch):
    t, = submit(porch, agent="claude", workspace="other", max_retries=5)
    assert t["max_retries"] == 2


def test_disallowed_agent_names_the_rule(porch):
    msg = refused(porch, agent="fake", workspace="demo")
    assert "demo.allowed_agents" in msg and "'fake'" in msg and msg.startswith("policy violation")
    assert porch.tasks.active_ids() == []


def test_disallowed_model_and_routing_override(porch, runtime):
    msg = refused(porch, agent="fake", origin="gh:acme/widgets#1", model="gpt-test")
    assert "acme/widgets.allowed_models" in msg
    ok, = submit(porch, agent="fake", origin="gh:acme/widgets#1", model="claude-opus-5-5")
    assert ok["model"] == "claude-sonnet-5-5"
    assert any("routing" in a for a in ok["policy"]["applied"])
    # no model named: nothing to check
    submit(porch, agent="fake", origin="gh:acme/widgets#1")


@pytest.mark.parametrize("mode,fields,gated", [
    ("always", {"workspace": "demo", "agent": "claude"}, True),
    ("publish", {"origin": "gh:acme/widgets#1"}, False),
    ("publish", {"origin": "gh:acme/widgets#1", "publish": {"title": "t"}}, True),
    ("costAbove", {"workspace": "other", "budget_usd": 3}, False),
    ("costAbove", {"workspace": "other", "budget_usd": 3.5}, True),
    ("costAbove", {"workspace": "other"}, True),            # capped to $10 by the default: above $3
    ("never", {"workspace": "nothing-special"}, False),
])
def test_require_approval_modes(porch, runtime, tmp_path, mode, fields, gated):
    os.makedirs(os.path.join(runtime["workspace_root"], "nothing-special"), exist_ok=True)
    fields.setdefault("agent", "fake")
    t, = submit(porch, **fields)
    assert bool(t["gate"]) is gated
    assert t["status"] == ("awaiting_approval" if gated else "queued")


def test_policy_never_removes_a_requested_gate(porch):
    t, = submit(porch, workspace="other", gate=True, budget_usd=1)
    assert t["gate"] is True


def test_publish_disabled_is_refused(porch):
    assert "other.publish.enable" in refused(porch, workspace="other", publish={"title": "x"})


def test_isolation_container_needs_container_runtime(porch, runtime):
    os.makedirs(os.path.join(runtime["workspace_root"], "locked"))
    assert "locked.isolation" in refused(porch, workspace="locked")
    runtime["default_isolation"] = "container"
    submit(porch, workspace="locked")


def test_daily_budget_is_committed_per_entry(porch, clock):
    submit(porch, origin="gh:acme/widgets#1", budget_usd=2)
    submit(porch, origin="gh:acme/widgets#2", budget_usd=2)
    msg = refused(porch, origin="gh:acme/widgets#3", budget_usd=2)
    assert "acme/widgets.daily_budget_usd" in msg
    # a swarm counts all of its members
    assert "daily_budget_usd" in refused(porch, origin="gh:acme/widgets#4", budget_usd=0.6, swarm=2)
    clock.advance(86400)                       # next UTC day
    submit(porch, origin="gh:acme/widgets#5", budget_usd=2)


def test_max_parallel_limits_running_tasks(porch, systemctl):
    ids = [submit(porch, origin="gh:acme/widgets#%d" % i, isolate=True)[0]["id"] for i in range(2)]
    other, = submit(porch, workspace="other", agent="fake", isolate=True, budget_usd=1)
    porch.tick()
    # max_workers is 2: the first widgets task and the unrelated one run, the second widgets task waits
    assert statuses(porch, ids) == ["running", "queued"]
    assert porch.tasks.get(other["id"])["status"] == "running"
    complete(porch, ids[0])
    porch.tick()
    assert statuses(porch, ids) == ["succeeded", "running"]


def test_judge_agent_is_checked_and_budget_capped(porch):
    with pytest.raises(ApiError) as exc:
        porch.submit({"agent": "claude", "workspace": "demo", "prompt": "x", "swarm": 2,
                      "judge": {"agent": "fake", "prompt": "pick"}})
    assert exc.value.status == 403 and "demo.allowed_agents" in exc.value.message


def test_workflow_nodes_are_governed(porch):
    with pytest.raises(ApiError) as exc:
        porch.submit_workflow({"nodes": {"a": {"agent": "fake", "workspace": "demo", "prompt": "x"}}})
    assert exc.value.status == 403 and exc.value.message.startswith("node a: policy violation")
    group, made = porch.submit_workflow({"nodes": {"a": {"agent": "fake", "workspace": "other", "prompt": "x"},
                                                   "b": {"agent": "fake", "workspace": "other", "prompt": "y", "depends_on": ["a"]}}})
    assert made["a"]["policy"]["name"] == "other" and made["b"]["budget_usd"] == 10


def test_policy_endpoint_and_http_403(porch):
    status, body = porch.app("GET", ["policy"], {"repo": ["acme/widgets"]}, {})
    assert status == 200 and body["name"] == "acme/widgets" and body["policy"]["budget_usd"] == 2
    with pytest.raises(ApiError) as exc:
        porch.app("POST", ["tasks"], {}, {"agent": "fake", "workspace": "demo", "prompt": "x"})
    assert exc.value.status == 403


def test_runner_revalidation_accepts_policy_fields(porch, runtime):
    t, = submit(porch, origin="gh:acme/widgets#1", model="claude-sonnet-5-5")
    T.validate_record(porch.tasks.get(t["id"]), runtime, porch.opts)


# ── RBAC ─────────────────────────────────────────────────────────────────
USERS = {  # name -> (uid, groups)
    "vera": (1001, {"auditors"}), "sam": (1002, {"devs"}), "alice": (1003, {"leads"}),
    "root": (0, set()), "olga": (1004, {"agentos"}), "nobody": (1005, set()),
}


def as_user(name):
    uid, groups = USERS[name]
    unixapi._local.peer = {"uid": uid, "gid": uid, "pid": 1, "name": name, "groups": groups}


@pytest.fixture(autouse=True)
def _clear_peer():
    yield
    unixapi._local.peer = None


@pytest.fixture
def rorch(cfg, taskstore, runtime, clock, systemctl, monkeypatch):  # noqa: F811
    monkeypatch.setattr("agentos_services.orchestrator.peer_identity",
                        lambda peer: (peer["name"], peer["uid"]) if peer else ("unknown", None))
    cfg = copy.deepcopy(cfg)
    cfg["rbac"] = {"enable": True, "separate_approver": False, "roles": {
        "viewer": {"groups": ["auditors"]}, "submitter": {"groups": ["devs"]},
        "approver": {"groups": ["leads"]}, "admin": {"groups": ["agentos"]}}}
    o = Orchestrator(cfg, taskstore, runtime=runtime, clock=clock, runner=systemctl, agents_running=lambda e: 0)
    o.rbac = R.Rbac(cfg, group_lookup=lambda peer: (peer["name"], set(peer["groups"])))
    return o


def call(o, user, method, path, body=None):
    as_user(user)
    parts = [p for p in path.split("?")[0].split("/") if p]
    try:
        return o.app(method, parts, {}, body or {})[0]
    except ApiError as exc:
        return exc.status


TASK = {"agent": "fake", "workspace": "demo", "prompt": "go"}


# who may do what: (method, path, body) -> users that get through
def endpoint_matrix(tid, gid):
    return [
        ("GET", "/tasks", None, {"vera", "sam", "alice", "root", "olga"}),
        ("GET", "/tasks/" + tid, None, {"vera", "sam", "alice", "root", "olga"}),
        ("GET", "/groups/" + gid, None, {"vera", "sam", "alice", "root", "olga"}),
        ("GET", "/workflows/" + gid, None, {"vera", "sam", "alice", "root", "olga"}),
        ("GET", "/policy", None, {"vera", "sam", "alice", "root", "olga"}),
        ("POST", "/tasks", dict(TASK), {"sam", "root", "olga"}),
        ("POST", "/workflows", {"nodes": {"a": dict(TASK)}}, {"sam", "root", "olga"}),
    ]


def test_every_endpoint_per_role(rorch):
    g, = submit(rorch, group="grp", gate=True)
    for method, path, body, allowed in endpoint_matrix(g["id"], "grp"):
        for user in USERS:
            got = call(rorch, user, method, path, body)
            assert (got != 403) == (user in allowed), (user, method, path, got)


def test_viewer_cannot_change_anything(rorch):
    g, = submit(rorch, gate=True)
    for path in ("/tasks/%s/approve" % g["id"], "/tasks/%s/reject" % g["id"], "/tasks/%s/cancel" % g["id"]):
        assert call(rorch, "vera", "POST", path) == 403
    assert call(rorch, "vera", "POST", "/tasks", dict(TASK)) == 403
    assert rorch.tasks.get(g["id"])["status"] == "awaiting_approval"


def test_submitter_cancels_own_but_not_others(rorch):
    mine = call(rorch, "sam", "POST", "/tasks", dict(TASK, gate=True))
    assert mine == 201
    sam_task = rorch.tasks.list(limit=1)[0]
    assert sam_task["submitted_by"] == "sam"
    USERS["sam2"] = (1006, {"devs"})
    try:
        assert call(rorch, "sam2", "POST", "/tasks/%s/cancel" % sam_task["id"]) == 403
        assert call(rorch, "sam", "POST", "/tasks/%s/cancel" % sam_task["id"]) == 200
        again, = submit(rorch, gate=True)            # submitted_by None (internal)
        assert call(rorch, "sam", "POST", "/tasks/%s/cancel" % again["id"]) == 403
        assert call(rorch, "olga", "POST", "/tasks/%s/cancel" % again["id"]) == 200   # admin cancels any
    finally:
        del USERS["sam2"]


def test_submitter_cannot_cancel_a_group_with_foreign_tasks(rorch):
    submit(rorch, group="mixed", gate=True)          # internal task
    call(rorch, "sam", "POST", "/tasks", dict(TASK, group="mixed", gate=True))
    assert call(rorch, "sam", "POST", "/tasks/mixed/cancel") == 403
    assert call(rorch, "root", "POST", "/tasks/mixed/cancel") == 200


def test_only_approvers_and_admins_approve_or_reject(rorch):
    g1, = submit(rorch, gate=True)
    g2, = submit(rorch, gate=True)
    assert call(rorch, "sam", "POST", "/tasks/%s/approve" % g1["id"]) == 403
    assert call(rorch, "nobody", "POST", "/tasks/%s/approve" % g1["id"]) == 403
    assert call(rorch, "alice", "POST", "/tasks/%s/approve" % g1["id"]) == 200
    assert call(rorch, "olga", "POST", "/tasks/%s/reject" % g2["id"]) == 200
    assert rorch.tasks.get(g1["id"])["approval"]["by"] == "alice"


def test_approver_cannot_submit_or_cancel(rorch):
    assert call(rorch, "alice", "POST", "/tasks", dict(TASK)) == 403
    g, = submit(rorch, gate=True)
    assert call(rorch, "alice", "POST", "/tasks/%s/cancel" % g["id"]) == 403


def test_user_without_a_role_is_refused_everywhere(rorch):
    assert call(rorch, "nobody", "GET", "/tasks") == 403
    assert call(rorch, "nobody", "GET", "/policy") == 403
    assert call(rorch, "nobody", "GET", "/health") == 200
    as_user("nobody")
    assert rorch.app("GET", ["whoami"], {}, {})[1]["roles"] == []


def test_unidentified_caller_is_denied(rorch):
    unixapi._local.peer = None
    with pytest.raises(ApiError) as exc:
        rorch.app("GET", ["tasks"], {}, {})
    assert exc.value.status == 403


def test_error_names_the_missing_role(rorch):
    as_user("vera")
    with pytest.raises(ApiError) as exc:
        rorch.app("POST", ["tasks", "x", "approve"], {}, {})
    assert "approver" in exc.value.message and "admin" in exc.value.message and "viewer" in exc.value.message


def test_whoami_lists_roles(rorch):
    as_user("alice")
    status, body = rorch.app("GET", ["whoami"], {}, {})
    assert body["name"] == "alice" and body["roles"] == ["approver"] and "leads" in body["groups"]
    as_user("root")
    assert rorch.app("GET", ["whoami"], {}, {})[1]["roles"] == ["admin"]


def test_default_roles_keep_operators_working(cfg):
    # Nix emits admin.groups = ["agentos"]; operators in that group can do everything
    cfg = copy.deepcopy(cfg)
    cfg["rbac"] = {"enable": True, "roles": {"admin": {"groups": ["agentos"]}}}
    r = R.Rbac(cfg, group_lookup=lambda peer: ("op", {"agentos"}))
    ident = r.identity({"uid": 1000, "gid": 1, "pid": 1})
    assert ident["roles"] == ["admin"]
    for action in R.ALLOWED:
        r.require({"uid": 1000, "gid": 1, "pid": 1}, action)


def test_rbac_off_without_a_section(orch):
    as_user("nobody")
    assert orch.app("GET", ["tasks"], {}, {})[0] == 200


# ── four eyes ────────────────────────────────────────────────────────────
@pytest.fixture
def four_eyes(rorch):
    rorch.rbac.separate_approver = True
    USERS["both"] = (1010, {"devs", "leads"})
    yield rorch
    del USERS["both"]


def test_four_eyes_blocks_self_approval(four_eyes):
    assert call(four_eyes, "both", "POST", "/tasks", dict(TASK, gate=True)) == 201
    t = four_eyes.tasks.list(limit=1)[0]
    assert call(four_eyes, "both", "POST", "/tasks/%s/approve" % t["id"]) == 403
    assert call(four_eyes, "both", "POST", "/tasks/%s/reject" % t["id"]) == 403
    assert four_eyes.tasks.get(t["id"])["status"] == "awaiting_approval"
    assert call(four_eyes, "alice", "POST", "/tasks/%s/approve" % t["id"]) == 200


def test_four_eyes_applies_to_admins_too(four_eyes):
    assert call(four_eyes, "olga", "POST", "/tasks", dict(TASK, gate=True)) == 201
    t = four_eyes.tasks.list(limit=1)[0]
    assert call(four_eyes, "olga", "POST", "/tasks/%s/approve" % t["id"]) == 403
    assert call(four_eyes, "root", "POST", "/tasks/%s/approve" % t["id"]) == 200


def test_self_approval_allowed_when_not_separate(rorch):
    USERS["both"] = (1010, {"devs", "leads"})
    try:
        assert call(rorch, "both", "POST", "/tasks", dict(TASK, gate=True)) == 201
        t = rorch.tasks.list(limit=1)[0]
        assert call(rorch, "both", "POST", "/tasks/%s/approve" % t["id"]) == 200
    finally:
        del USERS["both"]


def test_policy_gate_plus_four_eyes(cfg, taskstore, runtime, clock, systemctl, monkeypatch):  # noqa: F811
    monkeypatch.setattr("agentos_services.orchestrator.peer_identity",
                        lambda peer: (peer["name"], peer["uid"]) if peer else ("unknown", None))
    cfg = copy.deepcopy(cfg)
    cfg["policy"] = {"default": {"require_approval": {"mode": "always"}}}
    cfg["rbac"] = {"enable": True, "separate_approver": True, "roles": {
        "submitter": {"groups": ["devs"]}, "approver": {"groups": ["devs"]}}}
    o = Orchestrator(cfg, taskstore, runtime=runtime, clock=clock, runner=systemctl, agents_running=lambda e: 0)
    o.rbac = R.Rbac(cfg, group_lookup=lambda peer: (peer["name"], set(peer["groups"])))
    assert call(o, "sam", "POST", "/tasks", dict(TASK)) == 201
    t = o.tasks.list(limit=1)[0]
    assert t["status"] == "awaiting_approval" and t["policy"]["name"] == "default"
    assert call(o, "sam", "POST", "/tasks/%s/approve" % t["id"]) == 403


def test_daily_budget_counts_every_task_of_the_day(porch, clock):
    submit(porch, origin="gh:acme/widgets#1", budget_usd=2)
    submit(porch, origin="gh:acme/widgets#2", budget_usd=2)
    now = clock()
    for i in range(1100):  # more than any list window
        porch.tasks.create({"id": "task-filler%04d" % i, "created_at": now + 1 + i * 1e-3, "status": "succeeded"})
    assert "acme/widgets.daily_budget_usd" in refused(porch, origin="gh:acme/widgets#3", budget_usd=2)


def test_entries_inherit_nested_defaults():
    pol = P.Policy({"version": "v",
                            "default": {"require_approval": {"mode": "costAbove", "threshold_usd": 5},
                                        "routing": {"a": "b"}},
                            "repos": {"r": {"require_approval": {"threshold_usd": 1}, "routing": {"c": "d"}}}})
    eff = pol.effective("r")
    assert eff["require_approval"] == {"mode": "costAbove", "threshold_usd": 1}
    assert eff["routing"] == {"a": "b", "c": "d"}
