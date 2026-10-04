"""The trigger service against the real orchestrator (today's tasks.py rejects unknown fields)."""

import json

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
    assert task["publish"]["repo"] == REPO


def test_real_orchestrator_gated_webhook_awaits_approval(orch):
    def submit(body):
        try:
            return orch.app("POST", ["tasks"], {}, body)
        except ApiError as exc:
            return exc.status, {"error": exc.message}

    conf = make_cfg({"fix": rule(agent="fake", workspace="demo", gate=True)})
    svc = TR.TriggerService(conf, SECRET, TR.MemoryState(), submit,
                            lambda i: (orch.tasks.get(i) or {}).get("status"))
    body = json.dumps(issue_payload()).encode()
    headers = {"X-GitHub-Event": "issues", "X-GitHub-Delivery": "gated-0001", "Content-Length": str(len(body)),
               "X-Hub-Signature-256": TR.sign(SECRET, body)}
    status, out = svc.handle("POST", "/webhook", headers, lambda n: body)
    assert status == 200 and out["results"][0]["style"] == "fields", out
    task = orch.tasks.get(out["results"][0]["tasks"][0])
    assert task["origin"] == "gh:acme/widgets#7" and task["status"] == "awaiting_approval"
