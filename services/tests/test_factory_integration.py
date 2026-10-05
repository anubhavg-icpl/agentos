"""The factory against the real orchestrator (in process, no sockets).

test_factory.py drives the factory with a fake orchestrator; this checks that
every task body the factory sends is accepted by the real Orchestrator
(validation, start_from, kind publish, dedupe keys) and that an item goes from
backlog to ready when the tasks finish the way the task runner finishes them.
"""
import copy
import urllib.parse

from nestlo_services import config as configmod
from nestlo_services import factory as F
from nestlo_services import tasks as T
from orchfix import (cfg, clock, complete, orch, runtime, systemctl, taskstore)  # noqa: F401

PLAN = "Step 1, step 2.\nSIZE: medium\nPLAN-READY\n"
REVIEW = "Looks fine.\nMINOR: naming nit\nVERDICT: approve"
QA = "CRITERION 1: pass - works\nVERDICT: pass"


class InProcessOrch(F.OrchClient):
    """OrchClient whose HTTP calls go straight to Orchestrator.app."""

    def __init__(self, orchestrator):
        super().__init__("/nonexistent")
        self.o = orchestrator

    def _call(self, method, url, body=None):
        parsed = urllib.parse.urlsplit(url)
        parts = [p for p in parsed.path.split("/") if p]
        status, obj = self.o.app(method, parts, urllib.parse.parse_qs(parsed.query), body)
        if status >= 500 or status == 429:
            raise F.Transient("orchestrator returned %d" % status)
        return status, obj


def role(agent="fake"):
    return {"agent": agent, "budget_usd": 2.0, "timeout_sec": 600}


def make_factory(store, orchestrator, **line):
    c = copy.deepcopy(configmod.DEFAULTS)
    lines = {"main": dict({
        "repo": "acme/widgets", "workspace": "demo", "mode": "supervised", "max_in_flight": 2, "max_open_prs": 5,
        "max_fix_rounds": 2, "budget_usd_per_item": 20.0, "verify": ["make", "test"], "plan_approval": "never",
        "roles": {"planner": role(), "builder": role(), "reviewer": role(), "qa": role()}}, **line)}
    c["factory"] = {"lines": lines, "lease_sec": 60}
    return F.Factory(c, store, InProcessOrch(orchestrator), spend=lambda tid, since: 0.0, owner="t:1")


def finish_running(orch_, output_for):
    """Start what the orchestrator would start, then finish each started task."""
    orch_.tick()
    for t in orch_.tasks.list(limit=100):
        if t["status"] == T.RUNNING:
            out, extra = output_for(t)
            complete(orch_, t["id"], output=out, branch="agent/" + t["id"], **extra)


def outputs(t):
    stage = (t.get("dedupe_key") or "::?:").split(":")[2]
    if t.get("kind") == "publish":
        return "", {"pr_url": "https://github.com/acme/widgets/pull/7", "pr_number": 7,
                    "publish": {"status": "published", "repo": "acme/widgets",
                                "pr_url": "https://github.com/acme/widgets/pull/7", "pr_number": 7}}
    if stage == "plan":
        return PLAN, {}
    if stage == "review":
        return REVIEW, {}
    if stage == "qa":
        return QA, {}
    return "built", {"verify": {"status": "passed", "exit_code": 0, "output_tail": "ok"}}


def test_item_reaches_ready_through_the_real_orchestrator(store, orch):
    fac = make_factory(store, orch)
    status, obj = fac.app("POST", ["items"], {}, {"line": "main", "title": "Add hello", "acceptance": ["it works"]})
    assert status == 201, obj
    iid = obj["item"]["id"]
    for _ in range(40):
        fac.tick()
        if fac.get(iid)["state"] in ("ready", "failed", "blocked"):
            break
        finish_running(orch, outputs)
    item = fac.get(iid)
    assert item["state"] == "ready", (item["state"], item.get("error"), item.get("history"))
    assert item["pr_url"] == "https://github.com/acme/widgets/pull/7"
    submitted = orch.tasks.list(limit=100)
    kinds = {t.get("kind", "agent") for t in submitted}
    assert "publish" in kinds
    build = [t for t in submitted if ":build:" in (t.get("dedupe_key") or "")]
    review = [t for t in submitted if ":review:" in (t.get("dedupe_key") or "")]
    assert build and review and review[0]["start_from"] == build[-1]["id"]
    pub = [t for t in submitted if t.get("kind") == "publish"][0]
    assert pub["source_task"] == build[-1]["id"] and "it works" in pub["publish"]["body"]


def test_fix_round_continues_the_branch_in_the_real_orchestrator(store, orch):
    fac = make_factory(store, orch)
    iid = fac.app("POST", ["items"], {}, {"line": "main", "title": "Fix it", "acceptance": ["it works"]})[1]["item"]["id"]
    failed_once = {"done": False}

    def out(t):
        if ":build:" in (t.get("dedupe_key") or "") and not failed_once["done"]:
            failed_once["done"] = True
            return "built", {"verify": {"status": "failed", "exit_code": 1, "output_tail": "1 test failed"}}
        return outputs(t)

    for _ in range(60):
        fac.tick()
        if fac.get(iid)["state"] in ("ready", "failed", "blocked"):
            break
        finish_running(orch, out)
    item = fac.get(iid)
    assert item["state"] == "ready", (item["state"], item.get("error"))
    builds = sorted((t for t in orch.tasks.list(limit=100) if ":build:" in (t.get("dedupe_key") or "")),
                    key=lambda t: t["created_at"])
    assert len(builds) == 2, [t["dedupe_key"] for t in builds]
    assert "start_from" not in builds[0] or not builds[0]["start_from"]
    assert builds[1]["start_from"] == builds[0]["id"]          # the fix round continues the first round's branch
    assert "1 test failed" in builds[1]["prompt"]               # with the verify output as evidence
