"""Regression tests for the second round of review findings on PR 5."""
import pytest
from test_herdr_plugins import SHA_A, SHA_B, env, gh, herdr, manifest, run, state, write_cfg  # noqa: F401
from test_policy import TASK, _clear_peer, call, rorch  # noqa: F401
from orchfix import cfg, clock, runtime, systemctl, taskstore  # noqa: F401

from nestlo_services import herdr_bridge as hb
from nestlo_services import policy as P


# ── herdr plugins ──────────────────────────────────────────────────────

HAND = {"plugin_id": "alice.one", "version": "1", "enabled": True,
        "source": {"kind": "github", "owner": "alice", "repo": "one", "resolved_commit": SHA_A}}


def test_sync_never_claims_a_plugin_installed_by_hand(env, herdr, capsys):
    herdr.update(plugins=[dict(HAND)])
    cfg_ = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True}])
    rc, _, err = run(capsys, "sync", "--config", cfg_)
    assert rc == 1 and "alice/one: installed by hand" in err
    assert "alice/one" not in state(env)["plugins"]
    # dropping the declaration leaves the hand-installed plugin alone
    run(capsys, "sync", "--config", write_cfg(env))
    assert [p["plugin_id"] for p in herdr.data()["plugins"]] == ["alice.one"]
    assert herdr.calls("plugin", "uninstall") == [] and herdr.calls("plugin", "install") == []


def test_cli_install_leaves_a_hand_installed_plugin_unrecorded(env, gh, herdr, capsys):
    gh.add("alice/one", sha=SHA_B)
    herdr.update(plugins=[dict(HAND)])
    rc, out, _ = run(capsys, "install", "alice/one", "--yes")
    assert rc == 0 and "installed by hand, left alone" in out
    assert herdr.calls("plugin", "install") == []
    assert "alice/one" not in state(env)["plugins"]


def test_update_of_a_root_source_keeps_the_root_plugin(env, gh, herdr, capsys):
    gh.add("alice/multi", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.root")})
    run(capsys, "install", "alice/multi", "--yes")
    gh.repos["alice/multi"].update(sha=SHA_B, files={"herdr-plugin.toml": manifest("alice.root", version="2.0.0"),
                                                     "a/herdr-plugin.toml": manifest("alice.a")})
    rc, _, _ = run(capsys, "update", "alice/multi", "--yes")
    assert rc == 0
    assert herdr.calls("plugin", "install")[-1] == ["plugin", "install", "alice/multi", "--ref", SHA_B, "--yes"]
    assert state(env)["plugins"]["alice/multi"]["ref"] == SHA_B


# ── herdr bridge ───────────────────────────────────────────────────────

def test_notify_json_keeps_arguments_with_spaces():
    assert hb.notify_argv('["/opt/my tools/notify", "a b"]', None) == ["/opt/my tools/notify", "a b"]
    assert hb.notify_argv(None, "nestlo-notify test") == ["nestlo-notify", "test"]
    assert hb.notify_argv(None, None) is None
    for bad in ("[]", "{}", "[1]", "not json"):
        with pytest.raises(SystemExit):
            hb.notify_argv(bad, None)


# ── policy for publish tasks ───────────────────────────────────────────

def test_publish_tasks_skip_agent_and_budget_rules():
    eff = {"allowed_agents": ["claude"], "budget_usd": 2, "daily_budget_usd": 1,
           "require_approval": {"mode": "costAbove", "threshold_usd": 0}}
    fields = {"kind": "publish", "agent": "fake", "source_task": "t-1"}
    rec = P.enforce(eff, "acme/widgets", "v", fields, {}, spent_today=5.0)
    assert rec["applied"] == [] and "budget_usd" not in fields and not fields.get("gate")
    with pytest.raises(P.PolicyError):
        P.enforce({"publish_enable": False}, "n", "v", {"kind": "publish"}, {})
    fields = {"kind": "publish"}
    P.enforce({"require_approval": {"mode": "publish"}}, "n", "v", fields, {})
    assert fields["gate"] is True


def test_publish_tasks_do_not_count_against_the_daily_budget():
    tasks = [{"policy": {"name": "n"}, "created_at": 10, "status": "succeeded", "budget_usd": 3.0, "kind": "publish"},
             {"policy": {"name": "n"}, "created_at": 10, "status": "succeeded", "budget_usd": 2.0}]
    assert P.day_spent(tasks, "n", 20) == 2.0


# ── publish.merge needs the decide role ────────────────────────────────

MERGE = {"method": "squash", "require_checks": True}


def test_publish_merge_needs_decide(rorch):  # noqa: F811
    body = dict(TASK, publish={"repo": "acme/widgets", "merge": MERGE})
    assert call(rorch, "sam", "POST", "/tasks", body) == 403            # submitter only
    assert call(rorch, "sam", "POST", "/workflows", {"nodes": {"a": body}}) == 403
    assert call(rorch, "olga", "POST", "/tasks", body) != 403           # admin
    assert call(rorch, "sam", "POST", "/tasks", dict(TASK, publish={"repo": "acme/widgets"})) != 403
