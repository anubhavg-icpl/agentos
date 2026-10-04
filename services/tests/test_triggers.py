import copy
import http.client
import json
import threading

import pytest

from agentos_services import config as configmod
from agentos_services import triggers as TR

SECRET = b"s3cret-for-tests"
REPO = "acme/widgets"


def rule(**over):
    r = {"event": "issues", "action": ["opened", "labeled"], "repo": REPO, "agent": "claude", "workspace": "widgets",
         "prompt": "Fix issue #{issue.number}.\nTitle: {issue.title}\nBody:\n{issue.body}"}
    r.update(over)
    return r


def make_cfg(rules=None, **opts):
    cfg = copy.deepcopy(configmod.DEFAULTS)
    cfg["triggers"] = dict({"rules": rules if rules is not None else {"fix": rule()}}, **opts)
    return cfg


class Orch:
    """Fake orchestrator socket: records bodies, answers per `reject` / `status`."""

    def __init__(self, reject=()):
        self.bodies = []
        self.reject = set(reject)  # top-level keys that make it answer 400, like tasks.py
        self.fail = None
        self.live = set()

    def submit(self, body):
        if self.fail:
            raise OSError("down")
        self.bodies.append(body)
        bad = sorted(self.reject & set(body))
        if bad:
            return 400, {"error": "unknown field(s): %s" % ", ".join(bad)}
        return 201, {"tasks": [{"id": "task-%d" % len(self.bodies)}]}

    def status(self, task_id):
        return "running" if task_id in self.live else "succeeded"


def issue_payload(number=7, title="Crash on start", body="It crashes.", assoc="MEMBER", action="opened", **extra):
    p = {"action": action, "repository": {"full_name": REPO}, "sender": {"login": "bob", "type": "User"},
         "issue": {"number": number, "title": title, "body": body, "author_association": assoc, "labels": []}}
    p.update(extra)
    return p


class Hook:
    def __init__(self, cfg=None, orch=None, secret=SECRET):
        self.orch = orch or Orch()
        self.state = TR.MemoryState()
        self.svc = TR.TriggerService(cfg or make_cfg(), secret, self.state, self.orch.submit, self.orch.status)
        self.n = 0

    def post(self, payload, event="issues", delivery=None, secret=SECRET, signature="auto", raw=None, extra=None):
        body = raw if raw is not None else json.dumps(payload).encode()
        self.n += 1
        headers = {"X-GitHub-Event": event, "X-GitHub-Delivery": delivery or "deliv-%04d" % self.n,
                   "Content-Length": str(len(body))}
        if signature == "auto":
            headers["X-Hub-Signature-256"] = TR.sign(secret, body)
        elif signature is not None:
            headers["X-Hub-Signature-256"] = signature
        headers.update(extra or {})
        return self.svc.handle("POST", "/webhook", headers, lambda n: body[:n])


@pytest.fixture
def hook():
    return Hook()


# ── signatures and replay ────────────────────────────────────────────────
def test_valid_signature_submits_a_task(hook):
    status, out = hook.post(issue_payload())
    assert status == 200 and out["results"][0]["status"] == "submitted"
    body, = hook.orch.bodies
    assert body["origin"] == "gh:acme/widgets#7" and body["dedupe_key"] == "gh:acme/widgets#7:issues"
    assert body["agent"] == "claude" and body["workspace"] == "widgets"
    assert "Title: Crash on start" in body["prompt"]


@pytest.mark.parametrize("signature", [None, "", "sha256=", "sha256=" + "0" * 64, "sha1=abc", "garbage",
                                       "sha256=" + "0" * 63])
def test_bad_or_missing_signature_is_401(hook, signature):
    status, _ = hook.post(issue_payload(), signature=signature)
    assert status == 401 and hook.orch.bodies == []


def test_signature_with_another_secret_or_tampered_body_is_401(hook):
    assert hook.post(issue_payload(), secret=b"other-secret-xx")[0] == 401
    body = json.dumps(issue_payload()).encode()
    sig = TR.sign(SECRET, body)
    assert hook.post(None, raw=body + b" ", signature=sig)[0] == 401
    assert hook.orch.bodies == []


def test_verify_signature_is_constant_time_compare_of_hmac():
    body = b'{"a":1}'
    assert TR.verify_signature(SECRET, body, TR.sign(SECRET, body))
    assert not TR.verify_signature(SECRET, body, TR.sign(SECRET, b"x"))
    assert not TR.verify_signature(b"", body, TR.sign(b"", body))  # no secret, no access
    assert not TR.verify_signature(SECRET, body, None)


def test_a_bad_signature_does_not_burn_the_delivery_id(hook):
    assert hook.post(issue_payload(), delivery="same-delivery-1", signature="sha256=" + "1" * 64)[0] == 401
    assert hook.post(issue_payload(), delivery="same-delivery-1")[1]["results"][0]["status"] == "submitted"


def test_replayed_delivery_is_acknowledged_once(hook):
    first = hook.post(issue_payload(), delivery="replay-0001")
    again = hook.post(issue_payload(), delivery="replay-0001")
    assert first[1]["results"][0]["status"] == "submitted"
    assert again == (200, {"status": "duplicate", "delivery": "replay-0001"})
    assert len(hook.orch.bodies) == 1


def test_delivery_header_is_required_and_validated(hook):
    assert hook.post(issue_payload(), delivery="x")[0] == 400
    assert hook.post(issue_payload(), delivery="a b c d e f g h")[0] == 400


def test_body_size_is_capped_before_reading():
    hook = Hook(make_cfg(max_body_bytes=100))
    called = []
    status, _ = hook.svc.handle("POST", "/webhook", {"Content-Length": "101", "X-Hub-Signature-256": "x"},
                                lambda n: called.append(n) or b"")
    assert status == 413 and called == []
    assert hook.svc.handle("POST", "/webhook", {}, lambda n: b"")[0] == 411
    assert hook.svc.handle("POST", "/webhook", {"Content-Length": "abc"}, lambda n: b"")[0] == 411


def test_routes_and_ping(hook):
    assert hook.svc.handle("GET", "/health", {}, None)[0] == 200
    assert hook.svc.handle("GET", "/webhook", {}, None)[0] == 405
    assert hook.svc.handle("POST", "/other", {}, None)[0] == 404
    assert hook.post({"zen": "x"}, event="ping")[1] == {"status": "pong"}
    assert hook.post(issue_payload(), event="push")[1]["status"] == "ignored"
    assert hook.post(None, raw=b"not json")[0] == 400


def test_dedupe_store_is_bounded_and_expires():
    now = [1000.0]
    state = TR.MemoryState(ttl=10, max_entries=3, clock=lambda: now[0])
    assert state.set_nx("a") and not state.set_nx("a")
    for k in "bcd":
        state.set_nx(k)
    assert len(state.items) <= 3 and state.set_nx("a")  # "a" was evicted
    now[0] += 11
    assert state.set_nx("d")  # expired


# ── rule matching ────────────────────────────────────────────────────────
def test_repo_event_and_action_must_match():
    h = Hook()
    assert h.post(issue_payload(action="closed"))[1]["status"] == "ignored"
    other = issue_payload()
    other["repository"]["full_name"] = "evil/widgets"
    assert h.post(other)[1]["status"] == "ignored"
    assert h.post(issue_payload(), event="issue_comment")[1]["status"] == "ignored"
    assert h.orch.bodies == []
    upper = issue_payload()
    upper["repository"]["full_name"] = "Acme/Widgets"
    assert h.post(upper)[1]["status"] == "ok"  # GitHub names are case-insensitive


def test_label_rule_matches_the_applied_label_only():
    h = Hook(make_cfg({"fix": rule(action=["labeled"], label="agentos")}))
    wrong = issue_payload(action="labeled", label={"name": "bug"}, sender={"login": "m", "type": "User"})
    assert h.post(wrong)[1]["status"] == "ignored"
    right = issue_payload(action="labeled", label={"name": "agentos"})
    assert h.post(right)[1]["status"] == "ok"


def test_label_on_comment_rule_checks_issue_labels():
    cfg = make_cfg({"c": rule(event="issue_comment", action=["created"], label="agentos")})
    h = Hook(cfg)
    payload = {"action": "created", "repository": {"full_name": REPO}, "sender": {"type": "User"},
               "issue": {"number": 3, "title": "t", "body": "b", "labels": [{"name": "other"}]},
               "comment": {"body": "go", "author_association": "OWNER", "user": {"login": "o"}}}
    assert h.post(payload, event="issue_comment")[1]["status"] == "ignored"
    payload["issue"]["labels"].append({"name": "agentos"})
    assert h.post(payload, event="issue_comment")[1]["status"] == "ok"


def comment_payload(body, assoc="COLLABORATOR", number=9):
    return {"action": "created", "repository": {"full_name": REPO}, "sender": {"login": "c", "type": "User"},
            "issue": {"number": number, "title": "T", "body": "B", "author_association": "NONE", "labels": []},
            "comment": {"body": body, "author_association": assoc, "user": {"login": "c"}}}


def test_command_prefix_and_argument_extraction():
    cfg = make_cfg({"cmd": rule(event="issue_comment", action=["created"], command_prefix="/agentos",
                                prompt="Do: {comment.body} (issue {issue.number})")})
    h = Hook(cfg)
    assert h.post(comment_payload("please fix"), event="issue_comment")[1]["status"] == "ignored"
    assert h.post(comment_payload("/agentosfix"), event="issue_comment")[1]["status"] == "ignored"
    assert h.post(comment_payload("/agentos fix the tests"), event="issue_comment")[1]["status"] == "ok"
    assert h.orch.bodies[-1]["prompt"] == "Do: fix the tests (issue 9)"
    assert h.orch.bodies[-1]["dedupe_key"] == "gh:acme/widgets#9:issue_comment"


def test_check_run_needs_a_same_repo_pull_request():
    cfg = make_cfg({"ci": rule(event="check_run", action=["completed"], conclusion=["failure"],
                               prompt="CI failed: {check.name}\n{check.output}")})
    h = Hook(cfg)

    def payload(conclusion="failure", head=1, base=1):
        return {"action": "completed", "repository": {"full_name": REPO}, "sender": {"type": "Bot"},
                "check_run": {"name": "unit", "conclusion": conclusion,
                              "output": {"title": "3 failed", "summary": "s", "text": "trace"},
                              "pull_requests": [{"number": 12, "head": {"repo": {"id": head}}, "base": {"repo": {"id": base}}}]}}
    assert h.post(payload("success"), event="check_run")[1]["status"] == "ignored"
    assert h.post(payload(head=2), event="check_run")[1]["status"] == "ignored"  # from a fork
    assert h.post(payload(), event="check_run")[1]["status"] == "ok"
    body = h.orch.bodies[-1]
    assert body["origin"] == "gh:acme/widgets#12" and "3 failed" in body["prompt"] and "trace" in body["prompt"]


def test_review_comment_event():
    cfg = make_cfg({"rv": rule(event="pull_request_review_comment", action=["created"], prompt="{comment.body} on {issue.title}")})
    h = Hook(cfg)
    payload = {"action": "created", "repository": {"full_name": REPO}, "sender": {"type": "User"},
               "pull_request": {"number": 4, "title": "PR title", "body": "x"},
               "comment": {"body": "rename this", "author_association": "OWNER", "user": {"login": "o"}}}
    assert h.post(payload, event="pull_request_review_comment")[1]["status"] == "ok"
    assert h.orch.bodies[-1]["prompt"] == "rename this on PR title"
    assert h.orch.bodies[-1]["origin"] == "gh:acme/widgets#4"


# ── who may trigger ──────────────────────────────────────────────────────
@pytest.mark.parametrize("assoc,ok", [("OWNER", True), ("MEMBER", True), ("COLLABORATOR", True),
                                      ("CONTRIBUTOR", False), ("FIRST_TIME_CONTRIBUTOR", False),
                                      ("FIRST_TIMER", False), ("NONE", False), (None, False)])
def test_author_association_filter(assoc, ok):
    h = Hook()
    status, out = h.post(issue_payload(assoc=assoc))
    assert status == 200 and (out["status"] == "ok") == ok
    assert len(h.orch.bodies) == int(ok)


def test_trusted_associations_are_configurable():
    h = Hook(make_cfg(trusted_associations=["OWNER"]))
    assert h.post(issue_payload(assoc="MEMBER"))[1]["status"] == "ignored"
    assert h.post(issue_payload(assoc="OWNER"))[1]["status"] == "ok"


def test_comment_trust_uses_the_commenter_not_the_issue_author():
    cfg = make_cfg({"cmd": rule(event="issue_comment", action=["created"], command_prefix="/agentos")})
    h = Hook(cfg)
    assert h.post(comment_payload("/agentos go", assoc="NONE"), event="issue_comment")[1]["status"] == "ignored"
    assert h.post(comment_payload("/agentos go", assoc="MEMBER"), event="issue_comment")[1]["status"] == "ok"


def test_label_by_a_maintainer_approves_an_outsiders_issue():
    cfg = make_cfg({"fix": rule(action=["labeled"], label="agentos")})
    payload = issue_payload(assoc="NONE", action="labeled", label={"name": "agentos"})
    assert Hook(cfg).post(payload)[1]["status"] == "ok"
    strict = make_cfg({"fix": rule(action=["labeled"], label="agentos", trust_labeler=False)})
    assert Hook(strict).post(payload)[1]["status"] == "ignored"


def test_bots_never_trigger():
    h = Hook()
    payload = issue_payload()
    payload["sender"] = {"login": "agentos[bot]", "type": "Bot"}
    assert h.post(payload)[1]["status"] == "ignored" and h.orch.bodies == []


# ── untrusted text ───────────────────────────────────────────────────────
EVIL = "$(rm -rf /); `id`; ${HOME}; '; touch /tmp/x; \x00\x1b[31m {issue.body} {prev_result} {prompt} {workspace}"


def test_untrusted_text_is_data_and_substituted_once():
    h = Hook()
    h.post(issue_payload(title=EVIL, body="B {issue.title}"))
    body = h.orch.bodies[0]
    prompt = body["prompt"]
    assert "$(rm -rf /); `id`; ${HOME}" in prompt  # verbatim, passed as an argv element, never to a shell
    assert "\x00" not in prompt and "\x1b" not in prompt
    assert "{issue.body}" in prompt and "B {issue.title}" in prompt  # not re-expanded
    assert "{prev_result}" not in prompt  # defused: the orchestrator expands that one
    # nothing but the prompt carries event text
    assert body["agent"] == "claude" and body["workspace"] == "widgets" and body["origin"] == "gh:acme/widgets#7"
    assert set(body) <= {"agent", "workspace", "prompt", "origin", "dedupe_key", "budget_usd", "timeout_sec"}


def test_text_is_length_capped():
    h = Hook(make_cfg(max_text_chars=50, max_title_chars=10))
    h.post(issue_payload(title="T" * 1000, body="B" * 100000))
    prompt = h.orch.bodies[0]["prompt"]
    assert "T" * 11 not in prompt and "B" * 51 not in prompt and "[truncated]" in prompt
    assert len(prompt.encode()) < 500


def test_prompt_never_looks_like_an_option_and_is_byte_capped():
    cfg = make_cfg({"fix": rule(prompt="{issue.title}")}, max_prompt_bytes=2000)
    h = Hook(cfg)
    h.post(issue_payload(title="--dangerously-skip-permissions"))
    assert h.orch.bodies[0]["prompt"].startswith(" --")
    h2 = Hook(make_cfg({"fix": rule(prompt="{issue.body}")}, max_prompt_bytes=200, max_text_chars=10000))
    h2.post(issue_payload(body="é" * 1000))
    assert len(h2.orch.bodies[0]["prompt"].encode()) <= 200


def test_rules_are_validated_at_load():
    for bad in (rule(event="push"), rule(repo="nope"), rule(prompt="{issue.title} {nope}"), rule(action=[]),
                rule(command_prefix="/x"), rule(agent="")):
        with pytest.raises(TR.ConfigError):
            TR.compile_rules({"r": bad})
    with pytest.raises(TR.ConfigError):
        TR.compile_rules({"bad name!": rule()})


# ── submission to older and newer orchestrators ──────────────────────────
def test_newer_orchestrator_gets_gate_and_dedupe_key():
    cfg = make_cfg({"fix": rule(gate=True)})
    h = Hook(cfg)
    h.post(issue_payload())
    assert h.orch.bodies[0]["gate"] is True and h.orch.bodies[0]["dedupe_key"]


def test_publish_rule_submits_one_task_with_a_publish_block():
    h = Hook(make_cfg({"fix": rule(publish=True, gate=True)}))
    status, out = h.post(issue_payload())
    body = h.orch.bodies[0]
    assert out["results"][0]["style"] == "fields"
    assert body["gate"] is True and body["publish"]["repo"] == REPO
    assert body["origin"] == "gh:acme/widgets#7" and body["dedupe_key"] == "gh:acme/widgets#7:issues"


def test_workflow_style_submits_a_two_node_workflow():
    cfg = make_cfg({"fix": rule(publish=True, gate=True)})
    cfg["triggers"]["submit_style"] = "workflow"
    h = Hook(cfg)
    status, out = h.post(issue_payload())
    body = h.orch.bodies[0]
    run, pub = body["workflow"]
    assert out["results"][0]["style"] == "workflow"
    assert run["id"] == "run" and run["gate"] is True and "origin" not in run
    assert pub["kind"] == "publish" and pub["depends_on"] == ["run"] and pub["publish"]["repo"] == REPO
    assert body["origin"] == "gh:acme/widgets#7" and body["dedupe_key"] == "gh:acme/widgets#7:issues"


def test_todays_orchestrator_rejects_unknown_fields_so_we_fall_back():
    orch = Orch(reject={"dedupe_key", "workflow", "publish", "gate"})
    h = Hook(make_cfg({"fix": rule(publish=True)}), orch)
    out = h.post(issue_payload())[1]
    assert out["results"][0]["style"] == "compat"
    assert [sorted(set(b) & {"workflow", "dedupe_key", "publish"}) for b in orch.bodies] == [["dedupe_key", "publish"], []]
    assert set(orch.bodies[-1]) == {"agent", "workspace", "prompt", "origin"}
    # publish is requested out of band for the root task runner
    marker = json.loads(h.state.get("publish:task-2"))
    assert marker["repo"] == REPO and marker["title"].startswith("AgentOS: ")


def test_gate_fails_closed_on_an_orchestrator_without_gates():
    orch = Orch(reject={"dedupe_key", "gate", "workflow"})
    h = Hook(make_cfg({"fix": rule(gate=True)}), orch)
    out = h.post(issue_payload())[1]
    assert out["results"][0]["status"] == "rejected"
    assert all("gate" in b or "dedupe_key" not in b for b in orch.bodies)
    assert not any(set(b) == {"agent", "workspace", "prompt", "origin"} for b in orch.bodies)


def test_compat_emulates_dedupe_key_while_a_task_is_live():
    orch = Orch(reject={"dedupe_key"})
    h = Hook(orch=orch)
    h.post(issue_payload(), delivery="delivery-aaa1")
    orch.live.add("task-2")  # the compat attempt was the 2nd submit
    out = h.post(issue_payload(), delivery="delivery-aaa2")[1]
    assert out["results"][0]["status"] == "duplicate"
    orch.live.clear()
    assert h.post(issue_payload(), delivery="delivery-aaa3")[1]["results"][0]["status"] == "submitted"


def test_pinned_style_does_not_fall_back():
    orch = Orch(reject={"dedupe_key"})
    h = Hook(make_cfg(submit_style="fields"), orch)
    assert h.post(issue_payload())[1]["results"][0]["status"] == "rejected"
    assert len(orch.bodies) == 1


def test_orchestrator_down_returns_502_and_allows_redelivery():
    orch = Orch()
    h = Hook(orch=orch)
    orch.fail = True
    assert h.post(issue_payload(), delivery="retry-me-01")[0] == 502
    orch.fail = False
    status, out = h.post(issue_payload(), delivery="retry-me-01")
    assert status == 200 and out["results"][0]["status"] == "submitted"


def test_budget_and_timeout_come_from_the_rule():
    h = Hook(make_cfg({"fix": rule(budget_usd=2.5, timeout_sec=600)}))
    h.post(issue_payload())
    assert h.orch.bodies[0]["budget_usd"] == 2.5 and h.orch.bodies[0]["timeout_sec"] == 600


# ── over real HTTP ───────────────────────────────────────────────────────
def test_http_server_end_to_end():
    h = Hook()
    server = TR.make_server(h.svc, "127.0.0.1", 0)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        port = server.server_address[1]
        body = json.dumps(issue_payload()).encode()

        def send(headers):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request("POST", "/webhook", body=body, headers=dict({"X-GitHub-Event": "issues"}, **headers))
            resp = conn.getresponse()
            resp.read()
            conn.close()
            return resp.status
        assert send({"X-GitHub-Delivery": "http-test-1", "X-Hub-Signature-256": "sha256=" + "0" * 64}) == 401
        assert send({"X-GitHub-Delivery": "http-test-2"}) == 401
        assert send({"X-GitHub-Delivery": "http-test-3", "X-Hub-Signature-256": TR.sign(SECRET, body)}) == 200
        assert len(h.orch.bodies) == 1
    finally:
        server.shutdown()
        server.server_close()
