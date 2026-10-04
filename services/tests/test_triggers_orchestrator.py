"""The trigger service against the real orchestrator (today's tasks.py rejects unknown fields)."""

import json

from agentos_services import tasks as T
from agentos_services import triggers as TR
from agentos_services.unixapi import ApiError
from orchfix import cfg, clock, orch, runtime, systemctl, taskstore  # noqa: F401
from test_triggers import REPO, SECRET, issue_payload, make_cfg, rule


def test_real_orchestrator_end_to_end(orch, taskstore):
    def submit(body):
        try:
            return orch.app("POST", ["tasks"], {}, body)
        except ApiError as exc:
            return exc.status, {"error": exc.message}

    conf = make_cfg({"fix": rule(agent="fake", workspace="demo", publish=True)})
    state = TR.RedisState(taskstore.r)
    svc = TR.TriggerService(conf, SECRET, state, submit, lambda i: (orch.tasks.get(i) or {}).get("status"))
    body = json.dumps(issue_payload()).encode()
    headers = {"X-GitHub-Event": "issues", "X-GitHub-Delivery": "real-0001", "Content-Length": str(len(body)),
               "X-Hub-Signature-256": TR.sign(SECRET, body)}
    status, out = svc.handle("POST", "/webhook", headers, lambda n: body)
    assert status == 200 and out["results"][0]["style"] == "fields", out
    task = orch.tasks.get(out["results"][0]["tasks"][0])
    assert task["origin"] == "gh:acme/widgets#7" and task["status"] == "queued"
    assert T._KEY.fullmatch(task["dedupe_key"]) and task["publish"]["repo"] == REPO
    # a second event for the same issue while the first task is unfinished is deduplicated
    headers["X-GitHub-Delivery"] = "real-0002"
    out = svc.handle("POST", "/webhook", headers, lambda n: body)[1]
    assert out["results"][0]["status"] == "duplicate"


def test_gated_rule_is_accepted_as_awaiting_approval(orch, taskstore):
    def submit(body):
        try:
            return orch.app("POST", ["tasks"], {}, body)
        except ApiError as exc:
            return exc.status, {"error": exc.message}

    conf = make_cfg({"fix": rule(agent="fake", workspace="demo", gate=True)})
    svc = TR.TriggerService(conf, SECRET, TR.RedisState(taskstore.r), submit,
                            lambda i: (orch.tasks.get(i) or {}).get("status"))
    body = json.dumps(issue_payload()).encode()
    headers = {"X-GitHub-Event": "issues", "X-GitHub-Delivery": "gate-0001", "Content-Length": str(len(body)),
               "X-Hub-Signature-256": TR.sign(SECRET, body)}
    out = svc.handle("POST", "/webhook", headers, lambda n: body)[1]
    assert out["results"][0]["status"] == "submitted" and out["results"][0]["style"] == "fields", out
    assert orch.tasks.get(out["results"][0]["tasks"][0])["status"] == "awaiting_approval"
