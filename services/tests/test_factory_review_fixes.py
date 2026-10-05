"""Regression tests for review findings on the software factory and its neighbours."""
import threading

from agentos_services import audit as A
from agentos_services import tasks as T
from test_factory import PLAN, Env, line_cfg

PLAN_NO_SCOPE = "Step 1.\nSIZE: medium\nPLAN-READY\n"
GH = {"kind": "github", "repo": "acme/widgets", "number": 7}


def test_concurrent_github_deliveries_create_one_item(store):
    e = Env(store, {"main": line_cfg()})
    results, barrier = [], threading.Barrier(8)

    def deliver():
        barrier.wait()
        results.append(e.post(title="Crash", source=dict(GH)))

    threads = [threading.Thread(target=deliver) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    ids = {obj["item"]["id"] for _, obj in results}
    assert len(ids) == 1, results
    assert sorted(status for status, _ in results) == [200] * 7 + [201]


def test_a_finished_item_frees_its_github_source(store):
    e = Env(store, {"main": line_cfg()})
    first = e.create(title="Crash", source=dict(GH))
    assert e.act(first, "cancel")[0] == 200
    second = e.create(title="Crash again", source=dict(GH))
    assert second != first


def test_enforce_scope_without_scope_lines_fails_closed(store):
    e = Env(store, {"main": line_cfg(enforce_scope=True)})
    iid = e.create(acceptance=["a"])
    e.tick()
    e.stage(PLAN_NO_SCOPE)
    build = e.orch.live()[-1]
    cmd = build["verify"]["cmd"]
    assert cmd[0].endswith("agentos-factory-scope") and "--allow" not in cmd   # no globs: every file is outside
    e.stage("built", changed_files=["src/a.py"], verify={"status": "passed", "output_tail": ""})
    item = e.item(iid)
    assert item["state"] == "blocked" and item["error_kind"] == "scope"
    assert "(none declared)" in item["error"]


def test_cost_counter_is_monotonic_per_line(store):
    e = Env(store, {"main": line_cfg()})
    e.create(acceptance=["a"])
    e.tick()
    e.costs[e.orch.bodies[0]["id"]] = 1.5
    e.stage(PLAN)
    e.costs[e.orch.live()[-1]["id"]] = 0.5
    e.stage("built", verify={"status": "passed", "output_tail": ""})
    e.tick()
    text = e.fac.metrics()
    line = [ln for ln in text.splitlines() if ln.startswith("agentos_factory_cost_usd_total{")]
    assert line == ['agentos_factory_cost_usd_total{line="main"} 2.000000'], line


def test_publish_merge_is_an_audit_event_type():
    assert "publish.merge" in A.EVENT_TYPES


def test_long_evidence_bodies_pass_task_validation():
    body = "x" * 59000
    T.validate_publish({"repo": "acme/widgets", "title": "t", "body": body})
