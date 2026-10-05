"""Rules with factory = "<line>": issues go to the factory socket (POST /items), not the orchestrator."""

import os
import tempfile

import pytest

from nestlo_services import triggers as TR
from nestlo_services.unixapi import serve_unix
from test_triggers import REPO, Hook, Orch, issue_payload, make_cfg


class Factory:
    """Fake factory socket: records items; answers 201, or 200 for a source it has seen."""

    def __init__(self):
        self.items = []
        self.status_override = None

    def app(self, method, parts, query, body):
        assert (method, parts) == ("POST", ["items"]), (method, parts)
        if self.status_override:
            return self.status_override, {"error": "boom"}
        key = (body["source"]["repo"], body["source"]["number"])
        seen = any((i["source"]["repo"], i["source"]["number"]) == key for i in self.items)
        self.items.append(body)
        return (200, {"id": "item-1", "duplicate": True}) if seen else (201, {"id": "item-%d" % len(self.items)})


@pytest.fixture
def factory():
    d = tempfile.mkdtemp()
    path = os.path.join(d, "factory.sock")
    f = Factory()
    f.path = path
    server = serve_unix(path, f.app)
    yield f
    server.shutdown()


def frule(**over):
    r = {"event": "issues", "action": ["opened", "labeled"], "repo": REPO, "label": "factory:web", "factory": "web"}
    r.update(over)
    return r


def hook_for(factory, rules=None):
    orch = Orch()
    h = Hook(cfg=make_cfg(rules or {"intake": frule()}), orch=orch)
    h.svc.factory_submit = TR.factory_client(factory.path)
    return h, orch


def labeled(number=7, **kw):
    p = issue_payload(number=number, action="labeled", assoc="NONE", **kw)
    p["label"] = {"name": "factory:web"}
    p["issue"]["labels"] = [{"name": "factory:web"}]
    p["issue"]["html_url"] = "https://github.com/acme/widgets/issues/%d" % number
    return p


def test_labeled_issue_becomes_a_factory_item(factory):
    h, orch = hook_for(factory)
    status, out = h.post(labeled(title="Add search", body="Users want search."))
    assert status == 200, out
    assert out["results"][0]["status"] == "submitted" and out["results"][0]["line"] == "web", out
    assert orch.bodies == []  # nothing went to the orchestrator
    (item,) = factory.items
    assert item == {"line": "web", "title": "Add search", "body": "Users want search.",
                    "source": {"kind": "github", "repo": REPO, "number": 7,
                               "url": "https://github.com/acme/widgets/issues/7"}}


def test_rule_without_agent_workspace_prompt_is_valid():
    rules = TR.compile_rules({"intake": frule()})
    assert rules["intake"]["factory"] == "web"


def test_factory_rule_is_for_issues_only():
    with pytest.raises(TR.ConfigError):
        TR.compile_rules({"x": frule(event="issue_comment", action=["created"])})


def test_same_trust_rules_apply(factory):
    h, _ = hook_for(factory, {"intake": frule(label=None)})
    # opened by a stranger: ignored
    status, out = h.post(issue_payload(assoc="NONE"))
    assert out["status"] == "ignored" and factory.items == []
    # opened by a member: accepted
    status, out = h.post(issue_payload(number=8, assoc="MEMBER"))
    assert out["results"][0]["status"] == "submitted"
    # bots never
    bot = issue_payload(number=9, assoc="MEMBER")
    bot["sender"]["type"] = "Bot"
    assert h.post(bot)[1]["status"] == "ignored"
    assert len(factory.items) == 1


def test_wrong_label_and_wrong_signature_do_nothing(factory):
    h, _ = hook_for(factory)
    p = labeled()
    p["label"] = {"name": "other"}
    assert h.post(p)[1]["status"] == "ignored"
    assert h.post(labeled(), signature="sha256=" + "0" * 64)[0] == 401
    assert factory.items == []


def test_replayed_delivery_and_repeated_issue_are_deduplicated(factory):
    h, _ = hook_for(factory)
    assert h.post(labeled(), delivery="deliv-same-1")[1]["results"][0]["status"] == "submitted"
    assert h.post(labeled(), delivery="deliv-same-1")[1]["status"] == "duplicate"
    # a new delivery for the same issue: the factory answers 200 duplicate
    out = h.post(labeled(), delivery="deliv-same-2")[1]
    assert out["results"][0]["status"] == "duplicate"


def test_text_is_sanitised(factory):
    h, _ = hook_for(factory)
    h.post(labeled(title="T\x00itle\x07", body="b\x1b[31mx {prev_result}"))
    (item,) = factory.items
    assert "\x00" not in item["title"] and "\x1b" not in item["body"] and "{prev_result}" not in item["body"]


def test_unreachable_or_failing_factory_lets_github_retry(factory):
    h, _ = hook_for(factory)
    factory.status_override = 500
    status, out = h.post(labeled(), delivery="deliv-retry-1")
    assert status == 502, out
    factory.status_override = None
    status, out = h.post(labeled(), delivery="deliv-retry-1")  # delivery id was released
    assert status == 200 and out["results"][0]["status"] == "submitted"
    h.svc.factory_submit = TR.factory_client("/nonexistent/factory.sock")
    assert h.post(labeled(number=11), delivery="deliv-retry-2")[0] == 502


def test_rejection_is_reported_not_retried(factory):
    h, _ = hook_for(factory)
    factory.status_override = 400
    status, out = h.post(labeled())
    assert status == 200 and out["results"][0]["status"] == "rejected"
