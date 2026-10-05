"""The A2A server against the real orchestrator (fakeredis, fake systemctl)."""

import http.client
import json
import threading
import time

import pytest

from nestlo_services import a2a
from nestlo_services import tasks as T
from nestlo_services.unixapi import ApiError
from orchfix import (cfg, clock, complete, orch, runtime, systemctl, taskstore)  # noqa: F401

TOKEN = "tok-alpha-0123456789abcdef"
OTHER = "tok-bravo-0123456789abcdef"
RESTRICTED = "tok-carol-0123456789abcdef"


class OrchBackend:
    """The orchestrator's socket API, in process."""

    def __init__(self, orch):
        self.orch = orch

    def _app(self, method, parts, body=None):
        try:
            return self.orch.app(method, parts, {}, body)
        except ApiError as exc:
            return exc.status, {"error": exc.message}

    def submit(self, body):
        return self._app("POST", ["tasks"], body)

    def get(self, task_id):
        return self._app("GET", ["tasks", task_id])

    def cancel(self, task_id):
        return self._app("POST", ["tasks", task_id, "cancel"], {})

    def list(self, limit):
        return self._app("GET", ["tasks"])


@pytest.fixture
def token_file(tmp_path):
    path = tmp_path / "tokens"
    path.write_text("# a2a clients\nalpha:%s\nbravo:%s\ncarol:%s:other-agent\n" % (TOKEN, OTHER, RESTRICTED))
    return str(path)


def make_opts(**over):
    opts = a2a.settings({"a2a": {"poll_sec": 0.02, "block_timeout_sec": 0.3, "agents": {
        "coder": {"agent": "fake", "workspace": "demo", "description": "Fixes things",
                  "skills": [{"id": "fix", "name": "Fix", "tags": ["code"]}], "budget_usd": 2, "timeout_sec": 600},
        "other-agent": {"agent": "claude", "workspace": "other"},
    }, "default_agent": "coder"}})
    opts.update(over)
    return opts


@pytest.fixture
def service(orch, token_file):
    return a2a.A2AService(make_opts(), OrchBackend(orch), a2a.Clients(token_file))


@pytest.fixture
def server(service):
    srv = a2a.make_server(service, "127.0.0.1", 0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()
    srv.server_close()


def http_call(server, method, path, body=None, token=TOKEN, headers=None, raw=None):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
    hdrs = dict(headers or {})
    if token:
        hdrs["Authorization"] = "Bearer " + token
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    conn.request(method, path, body=data, headers=hdrs)
    resp = conn.getresponse()
    payload = resp.read()
    conn.close()
    return resp, payload


def rpc(server, method, params=None, path="/agents/coder", token=TOKEN, req_id=1, headers=None):
    resp, payload = http_call(server, "POST", path, {"jsonrpc": "2.0", "id": req_id, "method": method,
                                                      "params": params or {}}, token=token, headers=headers)
    assert resp.status == 200, payload
    return json.loads(payload)


def user_message(text="fix the flaky test", **extra):
    return dict({"messageId": "m-1", "role": "ROLE_USER", "parts": [{"text": text}]}, **extra)


def legacy_message(text="fix the flaky test", **extra):
    return dict({"messageId": "m-1", "role": "user", "kind": "message", "parts": [{"kind": "text", "text": text}]}, **extra)


NOW = {"returnImmediately": True}


# ── Agent Card ───────────────────────────────────────────────────────────
def test_agent_card_is_served_without_a_token(server):
    resp, payload = http_call(server, "GET", "/.well-known/agent-card.json", token=None)
    assert resp.status == 200 and resp.getheader("Content-Type") == "application/json"
    card = json.loads(payload)
    port = 9966       # the configured port: the card names the public URL, not the test socket
    assert card["name"] == "Nestlo coder" and card["description"] == "Fixes things"
    assert card["supportedInterfaces"] == [{"url": "http://127.0.0.1:%d/agents/coder" % port,
                                            "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}]
    assert card["skills"][0]["id"] == "fix" and card["capabilities"]["streaming"] is True
    assert card["securitySchemes"]["bearer"]["httpAuthSecurityScheme"]["scheme"] == "Bearer"
    assert card["defaultInputModes"] and card["defaultOutputModes"]
    # the same card at the per-agent path
    resp, payload = http_call(server, "GET", "/agents/coder/.well-known/agent-card.json", token=None)
    assert resp.status == 200 and json.loads(payload) == card
    # nothing about Nestlo internals in a public document
    assert "demo" not in json.dumps(card) and "fake" not in json.dumps(card)


def test_legacy_card_dialect(orch, token_file):
    svc = a2a.A2AService(make_opts(protocol_version="0.3"), OrchBackend(orch), a2a.Clients(token_file))
    card = svc.card("coder")
    assert card["protocolVersion"] == "0.3.0" and card["preferredTransport"] == "JSONRPC"
    assert card["url"].endswith("/agents/coder") and card["security"] == [{"bearer": []}]
    assert card["securitySchemes"]["bearer"] == {"type": "http", "scheme": "bearer"}
    assert "supportedInterfaces" not in card


def test_unknown_agent_card_and_private_card(orch, token_file):
    svc = a2a.A2AService(make_opts(public_card=False), OrchBackend(orch), a2a.Clients(token_file))
    assert svc.handle("GET", "/agents/coder/.well-known/agent-card.json", {}, None)[0] == 401
    assert svc.handle("GET", "/agents/coder/.well-known/agent-card.json", {"Authorization": "Bearer " + TOKEN}, None)[0] == 200
    assert svc.handle("GET", "/agents/nope/.well-known/agent-card.json", {"Authorization": "Bearer " + TOKEN}, None)[0] == 404


# ── authentication ───────────────────────────────────────────────────────
@pytest.mark.parametrize("token", [None, "", "wrong-token-0123456789abcdef", TOKEN[:-1], TOKEN + "x"])
def test_rpc_is_refused_without_a_valid_token(server, orch, token):
    resp, payload = http_call(server, "POST", "/agents/coder",
                              {"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "params": {"message": user_message()}},
                              token=token)
    assert resp.status == 401 and resp.getheader("WWW-Authenticate").startswith("Bearer")
    assert orch.tasks.active_ids() == []


def test_non_bearer_schemes_are_refused(server):
    resp, _ = http_call(server, "POST", "/agents/coder", {"jsonrpc": "2.0", "id": 1, "method": "GetTask"},
                        token=None, headers={"Authorization": "Basic " + TOKEN})
    assert resp.status == 401


def test_client_restricted_to_agents(server):
    # carol may only use other-agent: coder looks like it does not exist
    resp, _ = http_call(server, "POST", "/agents/coder", {"jsonrpc": "2.0", "id": 1, "method": "ListTasks"},
                        token=RESTRICTED)
    assert resp.status == 404
    out = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW}, path="/agents/other-agent",
              token=RESTRICTED)
    assert out["result"]["task"]["id"]


def test_token_file_parsing():
    assert a2a.parse_tokens("a:%s\n#c\n\nb:%s:x,y\n" % (TOKEN, OTHER)) == {"a": (TOKEN, None), "b": (OTHER, {"x", "y"})}
    for bad in ("a:short", "a b:%s" % TOKEN, ":%s" % TOKEN, "a:%s\na:%s" % (TOKEN, OTHER), "a:%s:Bad_Agent" % TOKEN):
        with pytest.raises(a2a.ConfigError):
            a2a.parse_tokens(bad)


def test_token_file_is_reloaded(tmp_path):
    path = tmp_path / "t"
    path.write_text("a:%s\n" % TOKEN)
    clients = a2a.Clients(str(path))
    assert clients.authenticate("Bearer " + TOKEN) == ("a", None)
    assert clients.authenticate("Bearer " + OTHER) is None
    time.sleep(0.01)
    path.write_text("b:%s\n" % OTHER)
    assert clients.authenticate("Bearer " + TOKEN) is None
    assert clients.authenticate("Bearer " + OTHER) == ("b", None)


# ── SendMessage ──────────────────────────────────────────────────────────
def test_send_message_creates_a_nestlo_task(server, orch):
    out = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})
    task = out["result"]["task"]
    assert task["status"]["state"] == "TASK_STATE_SUBMITTED" and "kind" not in task
    # the task is in the orchestrator, with the agent's configuration and not the client's
    status, rec = orch.app("GET", ["tasks", task["id"]], {}, None)
    assert status == 200
    assert rec["agent"] == "fake" and rec["prompt"] == "fix the flaky test" and rec["origin"] == "a2a:alpha/coder"
    assert rec["workspace"].endswith("/demo") and rec["budget_usd"] == 2 and rec["timeout_sec"] == 600
    assert rec["status"] == T.QUEUED and task["metadata"]["nestlo"]["agent"] == "fake"
    # and it is visible through the orchestrator API list
    status, listing = orch.app("GET", ["tasks"], {}, None)
    assert [t["id"] for t in listing["tasks"]] == [task["id"]]


def test_client_cannot_choose_agent_workspace_or_budget(server, orch):
    msg = user_message(metadata={"agent": "claude", "workspace": "other", "budget_usd": 999})
    out = rpc(server, "SendMessage", {"message": msg, "configuration": NOW,
                                      "metadata": {"agent": "claude", "workspace": "/etc"}, "agent": "claude"})
    rec = orch.tasks.get(out["result"]["task"]["id"])
    assert (rec["agent"], rec["budget_usd"]) == ("fake", 2) and rec["workspace"].endswith("/demo")


def test_legacy_dialect_follows_the_method_name(server):
    out = rpc(server, "message/send", {"message": legacy_message(), "configuration": {"blocking": False}})
    task = out["result"]
    assert task["kind"] == "task" and task["status"]["state"] == "submitted"
    got = rpc(server, "tasks/get", {"id": task["id"]})["result"]
    assert got["kind"] == "task" and got["status"]["state"] == "submitted"


def test_blocking_send_waits_for_the_task(server, orch):
    result = {}

    def call():
        result["out"] = rpc(server, "SendMessage", {"message": user_message()})

    # a second connection finishes the task while the first one waits
    thread = threading.Thread(target=call)
    thread.start()
    for _ in range(100):
        ids = orch.tasks.active_ids()
        if ids:
            break
        time.sleep(0.01)
    complete(orch, ids[0], output="all green\n")
    thread.join(10)
    task = result["out"]["result"]["task"]
    assert task["status"]["state"] == "TASK_STATE_COMPLETED"
    assert task["artifacts"][0]["parts"][0]["text"] == "all green\n"


def test_blocking_send_gives_up_after_the_timeout(server):
    out = rpc(server, "SendMessage", {"message": user_message()})
    assert out["result"]["task"]["status"]["state"] == "TASK_STATE_SUBMITTED"


def test_message_id_makes_a_retry_return_the_live_task(server, orch):
    a = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    b = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    assert a == b and len(orch.tasks.active_ids()) == 1


def test_data_parts_become_json_in_the_prompt(server, orch):
    msg = {"messageId": "m-2", "role": "ROLE_USER", "parts": [{"text": "use this"}, {"data": {"issue": 7}}]}
    task = rpc(server, "SendMessage", {"message": msg, "configuration": NOW})["result"]["task"]
    prompt = orch.tasks.get(task["id"])["prompt"]
    assert prompt.startswith("use this") and '"issue": 7' in prompt


# ── errors ───────────────────────────────────────────────────────────────
def test_bad_requests(server, orch):
    resp, payload = http_call(server, "POST", "/agents/coder", raw=b"{not json")
    assert json.loads(payload)["error"]["code"] == a2a.PARSE_ERROR
    resp, payload = http_call(server, "POST", "/agents/coder", {"id": 1, "method": "SendMessage"})
    assert json.loads(payload)["error"]["code"] == a2a.INVALID_REQUEST
    assert rpc(server, "NoSuchMethod")["error"]["code"] == a2a.METHOD_NOT_FOUND
    assert rpc(server, "SendMessage", {"message": {"role": "ROLE_USER", "parts": []}})["error"]["code"] == a2a.INVALID_PARAMS
    assert rpc(server, "SendMessage", {})["error"]["code"] == a2a.INVALID_PARAMS
    file_part = {"role": "ROLE_USER", "parts": [{"url": "https://example.com/a.pdf", "mediaType": "application/pdf"}]}
    assert rpc(server, "SendMessage", {"message": file_part})["error"]["code"] == a2a.CONTENT_TYPE
    # an option-looking prompt is refused by the orchestrator, and says so
    err = rpc(server, "SendMessage", {"message": user_message("--dangerously-skip-permissions")})["error"]
    assert err["code"] == a2a.INVALID_PARAMS and "must not start with '-'" in err["message"]
    # continuing a task is not supported
    err = rpc(server, "SendMessage", {"message": user_message(taskId="task-1")})["error"]
    assert err["code"] == a2a.UNSUPPORTED_OP
    assert rpc(server, "SendMessage", {"message": user_message()}, headers={"A2A-Version": "9.0"})["error"]["code"] == a2a.VERSION_UNSUPPORTED
    assert orch.tasks.active_ids() == []


def test_error_data_follows_the_dialect(server):
    err = rpc(server, "GetTask", {"id": "task-nope"})["error"]
    assert err["code"] == a2a.TASK_NOT_FOUND and err["data"][0]["reason"] == "TASK_NOT_FOUND"
    err = rpc(server, "tasks/get", {"id": "task-nope"})["error"]
    assert err["code"] == a2a.TASK_NOT_FOUND and "data" not in err


def test_oversized_and_malformed_http(server):
    resp, _ = http_call(server, "POST", "/agents/coder", raw=b"x" * (2 * 1024 * 1024))
    assert resp.status == 413
    resp, _ = http_call(server, "GET", "/agents/coder")
    assert resp.status == 405
    for path in ("/agents/..%2f..%2fetc/", "/agents/Coder", "/nothing", "/agents/coder/../x"):
        resp, _ = http_call(server, "POST", path, {"jsonrpc": "2.0", "id": 1, "method": "GetTask"})
        assert resp.status == 404, path
    resp, _ = http_call(server, "GET", "/health", token=None)
    assert resp.status == 200


def test_orchestrator_policy_and_outage(orch, token_file):
    class Down(OrchBackend):
        def submit(self, body):
            raise a2a.RpcError(a2a.INTERNAL, "Nestlo orchestrator is unreachable: down")

    class Denied(OrchBackend):
        def submit(self, body):
            return 403, {"error": "rbac: role required: operator"}

    for backend, code in ((Down(orch), a2a.INTERNAL), (Denied(orch), a2a.POLICY_DENIED)):
        svc = a2a.A2AService(make_opts(), backend, a2a.Clients(token_file))
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "params": {"message": user_message()}}).encode()
        status, _, out = svc.handle("POST", "/agents/coder", {"Authorization": "Bearer " + TOKEN, "Content-Length": str(len(body))},
                                    lambda n: body)
        assert json.loads(out)["error"]["code"] == code


# ── GetTask / CancelTask / ListTasks ─────────────────────────────────────
@pytest.mark.parametrize("status,state,error", [
    (T.SUCCEEDED, "TASK_STATE_COMPLETED", None),
    (T.FAILED, "TASK_STATE_FAILED", "exit status 1"),
    (T.TIMEOUT, "TASK_STATE_FAILED", "timed out after 600s"),
])
def test_get_task_maps_states(server, orch, status, state, error):
    tid = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    orch.tasks.update(tid, lambda t: t.update(status=T.RUNNING, started_at=1.0) or True)
    assert rpc(server, "GetTask", {"id": tid})["result"]["status"]["state"] == "TASK_STATE_WORKING"
    kw = {"error": error} if error else {}
    complete(orch, tid, status, output="done\n", branch="nestlo/x", **kw)
    task = rpc(server, "GetTask", {"id": tid})["result"]
    assert task["status"]["state"] == state and task["artifacts"][0]["name"] == "output"
    if error:
        assert error in task["status"]["message"]["parts"][0]["text"]
    assert task["metadata"]["nestlo"]["branch"] == "nestlo/x"


def test_gated_task_is_input_required(server, orch):
    tid = orch.submit({"agent": "fake", "workspace": "demo", "prompt": "x", "gate": True, "origin": "a2a:alpha/coder"})[0]["id"]
    task = rpc(server, "GetTask", {"id": tid})["result"]
    assert task["status"]["state"] == "TASK_STATE_INPUT_REQUIRED"
    assert "nestlo task approve" in task["status"]["message"]["parts"][0]["text"]


def test_a_client_sees_only_its_own_tasks(server, orch):
    tid = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    assert rpc(server, "GetTask", {"id": tid}, token=OTHER)["error"]["code"] == a2a.TASK_NOT_FOUND
    assert rpc(server, "CancelTask", {"id": tid}, token=OTHER)["error"]["code"] == a2a.TASK_NOT_FOUND
    # a task submitted by an operator, not through A2A, is invisible too
    mine = orch.submit({"agent": "fake", "workspace": "demo", "prompt": "x"})[0]["id"]
    assert rpc(server, "GetTask", {"id": mine})["error"]["code"] == a2a.TASK_NOT_FOUND
    # and so is a task of the same client reached through another agent
    assert rpc(server, "GetTask", {"id": tid}, path="/agents/other-agent")["error"]["code"] == a2a.TASK_NOT_FOUND
    assert rpc(server, "GetTask", {"id": "../../etc"})["error"]["code"] == a2a.INVALID_PARAMS
    assert rpc(server, "ListTasks", token=OTHER)["result"]["tasks"] == []


def test_cancel_task(server, orch):
    tid = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    task = rpc(server, "CancelTask", {"id": tid})["result"]
    assert task["status"]["state"] == "TASK_STATE_CANCELED" and orch.tasks.get(tid)["status"] == T.CANCELLED
    err = rpc(server, "CancelTask", {"id": tid})["error"]
    assert err["code"] == a2a.TASK_NOT_CANCELABLE
    # legacy name, legacy state spelling
    tid2 = rpc(server, "message/send", {"message": legacy_message("again", messageId="m-9")})["result"]["id"]
    assert rpc(server, "tasks/cancel", {"id": tid2})["result"]["status"]["state"] == "canceled"


def test_list_tasks(server):
    ids = [rpc(server, "SendMessage", {"message": user_message("t%d" % i, messageId="m-%d" % i), "configuration": NOW})
           ["result"]["task"]["id"] for i in range(3)]
    out = rpc(server, "ListTasks", {"pageSize": 2})["result"]
    assert out["totalSize"] == 3 and len(out["tasks"]) == 2 and out["tasks"][0]["id"] in ids
    assert rpc(server, "ListTasks", {"status": "TASK_STATE_WORKING"})["result"]["totalSize"] == 0
    assert rpc(server, "ListTasks", {"pageSize": 0})["error"]["code"] == a2a.INVALID_PARAMS


def test_unsupported_operations(server):
    assert rpc(server, "CreateTaskPushNotificationConfig", {})["error"]["code"] == a2a.PUSH_UNSUPPORTED
    assert rpc(server, "tasks/pushNotificationConfig/set", {})["error"]["code"] == a2a.PUSH_UNSUPPORTED
    assert rpc(server, "GetExtendedAgentCard")["error"]["code"] == a2a.EXT_CARD_UNCONFIGURED


# ── streaming ────────────────────────────────────────────────────────────
def sse_events(server, method, params, path="/agents/coder"):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
    conn.request("POST", path, body=json.dumps({"jsonrpc": "2.0", "id": 7, "method": method, "params": params}),
                 headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    resp = conn.getresponse()
    assert resp.status == 200 and resp.getheader("Content-Type") == "text/event-stream"
    events = []
    for line in resp.read().decode().splitlines():
        if line.startswith("data: "):
            events.append(json.loads(line[6:]))
    conn.close()
    return events


def finish_when_started(orch, status=T.SUCCEEDED, output="built\n"):
    def run():
        for _ in range(500):
            ids = orch.tasks.active_ids()
            if ids:
                time.sleep(0.1)
                orch.tasks.update(ids[0], lambda t: t.update(status=T.RUNNING, started_at=1.0) or True)
                time.sleep(0.1)
                complete(orch, ids[0], status, output=output)
                return
            time.sleep(0.01)
    thread = threading.Thread(target=run)
    thread.start()
    return thread


def test_streaming_message(server, orch):
    thread = finish_when_started(orch)
    events = sse_events(server, "SendStreamingMessage", {"message": user_message()})
    thread.join(10)
    assert all(e["id"] == 7 for e in events)
    results = [e["result"] for e in events]
    assert results[0]["task"]["status"]["state"] == "TASK_STATE_SUBMITTED"
    states = [r["statusUpdate"]["status"]["state"] for r in results if "statusUpdate" in r]
    assert states == ["TASK_STATE_WORKING", "TASK_STATE_COMPLETED"]
    art = [r for r in results if "artifactUpdate" in r]
    assert art and art[0]["artifactUpdate"]["artifact"]["parts"][0]["text"] == "built\n"
    assert "final" not in json.dumps(results)       # removed in v1.0


def test_streaming_legacy_dialect_marks_the_final_event(server, orch):
    thread = finish_when_started(orch, T.FAILED, "")
    events = sse_events(server, "message/stream", {"message": legacy_message()})
    thread.join(10)
    results = [e["result"] for e in events]
    assert results[0]["kind"] == "task"
    updates = [r for r in results if r.get("kind") == "status-update"]
    assert [u["final"] for u in updates] == [False, True] and updates[-1]["status"]["state"] == "failed"


def test_resubscribe(server, orch):
    tid = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    thread = finish_when_started(orch)
    events = sse_events(server, "SubscribeToTask", {"id": tid})
    thread.join(10)
    assert events[0]["result"]["task"]["id"] == tid
    assert events[-1]["result"]["statusUpdate"]["status"]["state"] == "TASK_STATE_COMPLETED"
    # a finished task cannot be subscribed to
    assert rpc(server, "SubscribeToTask", {"id": tid})["error"]["code"] == a2a.UNSUPPORTED_OP


# ── configuration ────────────────────────────────────────────────────────
def test_configuration_is_validated(orch, token_file):
    def build(**agents):
        return a2a.A2AService(a2a.settings({"a2a": {"agents": agents}}), OrchBackend(orch), a2a.Clients(token_file))

    with pytest.raises(a2a.ConfigError):
        build(**{"Bad Name": {"agent": "fake", "workspace": "demo"}})
    with pytest.raises(a2a.ConfigError):
        build(x={"agent": "fake"})
    with pytest.raises(a2a.ConfigError):
        build(x={"agent": "fake", "workspace": "demo", "command": ["sh"]})
    with pytest.raises(a2a.ConfigError):
        a2a.A2AService(a2a.settings({"a2a": {"default_agent": "nope", "agents": {"x": {"agent": "f", "workspace": "d"}}}}),
                       OrchBackend(orch), a2a.Clients(token_file))
    with pytest.raises(a2a.ConfigError):
        a2a.A2AService(a2a.settings({"a2a": {"protocol_version": "2.0"}}), OrchBackend(orch), a2a.Clients(token_file))
    # a single agent is the default one
    assert build(only={"agent": "fake", "workspace": "demo"}).default == "only"


def test_main_refuses_non_loopback_and_missing_tokens(tmp_path, capsys):
    conf = tmp_path / "services.toml"
    conf.write_text('[a2a]\nlisten = "0.0.0.0"\n[a2a.agents.x]\nagent = "fake"\nworkspace = "demo"\n')
    tokens = tmp_path / "tokens"
    tokens.write_text("a:%s\n" % TOKEN)
    assert a2a.main(["--config", str(conf), "--token-file", str(tokens)]) == 2
    assert "loopback" in capsys.readouterr().err
    assert a2a.main(["--config", str(conf)]) == 2
    assert "no client tokens" in capsys.readouterr().err
    tokens.write_text("")
    conf.write_text('[a2a]\n[a2a.agents.x]\nagent = "fake"\nworkspace = "demo"\n')
    assert a2a.main(["--config", str(conf), "--token-file", str(tokens)]) == 2
    assert "no clients" in capsys.readouterr().err


# ── hardening ────────────────────────────────────────────────────────────
def test_default_card_and_health_do_not_leak_config(orch, token_file):
    opts = a2a.settings({"a2a": {"agents": {"bare": {"agent": "claude", "workspace": "secretws"}}}})
    svc = a2a.A2AService(opts, OrchBackend(orch), a2a.Clients(token_file))
    assert "secretws" not in json.dumps(svc.card("bare")) and "claude" not in json.dumps(svc.card("bare"))
    status, _, body = svc.handle("GET", "/health", {}, None)
    assert status == 200 and json.loads(body) == {"status": "ok"}


def test_unicode_digit_content_length_is_refused(server):
    resp, _ = http_call(server, "POST", "/agents/coder", raw=b"{}", headers={"Content-Length": "²"})
    assert resp.status in (400, 411)
    resp, payload = http_call(server, "POST", "/agents/coder", raw=b"{}", headers={"Content-Length": "9" * 40})
    assert resp.status in (400, 411, 413)


def test_task_id_with_trailing_newline_is_rejected(server):
    out = rpc(server, "GetTask", {"id": "task-1\n"})
    assert out["error"]["code"] == a2a.INVALID_PARAMS


def test_dedupe_key_is_per_agent(server, orch):
    a = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW})["result"]["task"]["id"]
    # the same client and messageId to another agent must not return the first agent's task
    out = rpc(server, "SendMessage", {"message": user_message(), "configuration": NOW}, path="/agents/other-agent")
    assert out["result"]["task"]["id"] != a


def test_orchestrator_errors_do_not_leak_internals(orch, token_file):
    class Down(OrchBackend):
        def submit(self, body):
            return 500, {"error": "Traceback /nix/store/secret"}

    svc = a2a.A2AService(make_opts(), Down(orch), a2a.Clients(token_file))
    srv = a2a.make_server(svc, "127.0.0.1", 0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        out = rpc(srv, "SendMessage", {"message": user_message()})
        assert out["error"]["code"] == a2a.INTERNAL and "secret" not in json.dumps(out)
    finally:
        srv.shutdown()
        srv.server_close()
    sock = a2a.SocketBackend("/nonexistent/orch.sock")
    with pytest.raises(a2a.RpcError) as exc:
        sock.get("task-1")
    assert "/nonexistent" not in exc.value.message


def test_stream_slots_are_limited_and_released(orch, token_file):
    svc = a2a.A2AService(make_opts(max_streams_per_client=1), OrchBackend(orch), a2a.Clients(token_file))
    hdrs = {"Authorization": "Bearer " + TOKEN}
    req = lambda: svc.handle("POST", "/agents/coder", hdrs | {"Content-Length": str(len(raw))}, lambda n: raw)  # noqa: E731
    raw = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "SendStreamingMessage",
                      "params": {"message": user_message()}}).encode()
    status, _, body = req()
    assert status == 200 and not isinstance(body, bytes)
    status, _, second = req()
    assert json.loads(second)["error"]["code"] == a2a.UNSUPPORTED_OP
    body.close()
    status, _, third = req()
    assert not isinstance(third, bytes)
    third.close()


def test_stream_sends_keepalives(orch, token_file):
    now = [0.0]
    svc = a2a.A2AService(make_opts(keepalive_sec=5, poll_sec=2), OrchBackend(orch), a2a.Clients(token_file),
                         clock=lambda: now[0], sleep=lambda s: now.__setitem__(0, now[0] + s))
    task = svc._submit("alpha", "coder", {"message": user_message()})
    gen = svc._stream("alpha", "coder", task, False)
    first = next(gen)
    assert "task" in first
    assert next(gen) is None            # nothing changed, a keep-alive is due
    assert b": keepalive" in next(svc._sse(iter([None]), 1, False))


def test_connection_limit_drops_excess_connections(service):
    import socket
    service.opts["max_connections"] = 1
    srv = a2a.make_server(service, "127.0.0.1", 0)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        port = srv.server_address[1]
        hold = socket.create_connection(("127.0.0.1", port))      # occupies the only slot (sends nothing)
        time.sleep(0.2)
        extra = socket.create_connection(("127.0.0.1", port))
        extra.settimeout(3)
        extra.sendall(b"GET /health HTTP/1.1\r\nHost: x\r\n\r\n")
        assert extra.recv(100) == b""                              # closed without an answer
        hold.close()
        extra.close()
    finally:
        srv.shutdown()
        srv.server_close()
