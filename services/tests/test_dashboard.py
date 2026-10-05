import base64
import copy
import http.client
import json
import os
import time

import pytest

from nestlo_services import config as configmod
from nestlo_services.dashboard import Dashboard, serve, tail_log

TOKEN = "s3cret-token-value"


@pytest.fixture
def env(tmp_path, store):
    cfg = copy.deepcopy(configmod.DEFAULTS)
    state = tmp_path / "state"
    (state / "history").mkdir(parents=True)
    logs = tmp_path / "logs"
    logs.mkdir()
    cfg["daemon"]["state_dir"] = str(state)
    cfg["gateway"]["log_dir"] = str(logs)
    # nothing listens on these: health probes must report "down", not crash
    cfg["gateway"]["port"] = 1
    cfg["daemon"]["metrics_port"] = 1
    token = tmp_path / "token"
    token.write_text(TOKEN + "\n")
    dash = Dashboard(cfg, store, str(token))
    return dash, state, logs, token


def basic(password, user="admin"):
    return "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()


def call(dash, path):
    status, ctype, body = dash.handle(path, "Bearer " + TOKEN)
    return status, json.loads(body) if ctype == "application/json" else body.decode()


def test_auth_required_everywhere(env):
    dash = env[0]
    for path in ("/", "/api/agents", "/api/spend", "/api/health", "/api/links", "/nope"):
        for header in (None, "", "Bearer wrong", basic("wrong"), "Token " + TOKEN, "Basic !!!"):
            assert dash.handle(path, header)[0] == 401, (path, header)


def test_links_only_pass_http_urls(env):
    dash = env[0]
    assert call(dash, "/api/links") == (200, {"links": []})
    dash.cfg["dashboard"]["links"] = [
        {"name": "Chat", "url": "http://127.0.0.1:8484/chat/"},
        {"name": "Bad", "url": "javascript:alert(1)"},
        {"name": "", "url": "http://x"},
    ]
    assert call(dash, "/api/links")[1] == {"links": [{"name": "Chat", "url": "http://127.0.0.1:8484/chat/"}]}


def test_auth_accepts_bearer_and_basic(env):
    dash = env[0]
    assert dash.handle("/api/spend", "Bearer " + TOKEN)[0] == 200
    assert dash.handle("/api/spend", basic(TOKEN))[0] == 200
    assert dash.handle("/api/spend", basic(TOKEN, user=""))[0] == 200


def test_empty_or_missing_token_file_denies_everything(env):
    dash, _, _, token = env
    token.write_text("\n")
    assert dash.handle("/api/spend", "Bearer ")[0] == 401
    assert dash.handle("/api/spend", basic(""))[0] == 401
    token.unlink()
    assert dash.handle("/api/spend", "Bearer " + TOKEN)[0] == 401


def test_token_rotation_takes_effect_without_restart(env):
    dash, _, _, token = env
    token.write_text("another-token-1234")
    assert dash.handle("/api/spend", "Bearer " + TOKEN)[0] == 401
    assert dash.handle("/api/spend", "Bearer another-token-1234")[0] == 200


def test_page_is_self_contained(env):
    status, page = call(env[0], "/")
    assert status == 200 and "<title>Nestlo dashboard</title>" in page
    assert "prefers-color-scheme: dark" in page
    for external in ("http://", "https://", "//cdn"):
        assert external not in page


def test_agents_running_and_history_with_spend(env, store):
    dash, state, _, _ = env
    now = time.time()
    (state / "a1.json").write_text(json.dumps({
        "id": "a1", "agent": "claude", "status": "running", "workspace": "/w/demo",
        "branch": "agent/a1", "started_at": now - 30}))
    (state / "history" / "a0.json").write_text(json.dumps({
        "id": "a0", "agent": "codex", "status": "killed", "reason": "daily budget exceeded"}))
    (state / "junk.json").write_text("not json")
    (state / "badid.json").write_text(json.dumps({"id": "../x", "status": "running"}))
    store.record("a1", "claude-test", 2.5, {"input_tokens": 10})
    store.set_limit("a1", 10)
    status, out = call(dash, "/api/agents")
    assert status == 200
    assert [a["id"] for a in out["running"]] == ["a1"]
    a1 = out["running"][0]
    assert a1["usd_today"] == 2.5 and a1["limit_usd"] == 10.0 and a1["budget_pct"] == 25.0
    assert a1["workspace"] == "/w/demo" and a1["branch"] == "agent/a1"
    assert [a["id"] for a in out["history"]] == ["a0"]
    assert out["history"][0]["limit_usd"] == 50.0
    assert "_mtime" not in a1


def test_agents_empty_state_dir(env):
    dash, state, _, _ = env
    os.rmdir(state / "history")
    assert call(dash, "/api/agents")[1]["running"] == []


def test_spend_per_agent_and_model(env, store):
    dash = env[0]
    store.record("a1", "claude-test", 1.0, {"input_tokens": 100, "output_tokens": 5})
    store.record("a2", "gpt-test", 0.5, {})
    store.count_request("a1", 200)
    status, snap = call(dash, "/api/spend")
    assert status == 200
    assert snap["global_usd"] == 1.5
    assert snap["agents"]["a1"]["usd"] == 1.0
    assert snap["agents"]["a1"]["tokens"]["output_tokens"] == 5
    assert snap["models"] == {"claude-test": 1.0, "gpt-test": 0.5}
    assert snap["global_limit_usd"] == 500.0


def test_history_seven_days(env, store):
    dash = env[0]
    store.record("a1", "m", 1.0, {})
    status, out = call(dash, "/api/history")
    assert status == 200 and len(out["days"]) == 7
    assert out["days"][0]["global_usd"] == 1.0 and out["days"][0]["agents"] == {"a1": 1.0}
    assert all(d["global_usd"] == 0 for d in out["days"][1:])
    assert len(call(dash, "/api/history?days=3")[1]["days"]) == 3
    assert len(call(dash, "/api/history?days=999")[1]["days"]) == 35
    assert len(call(dash, "/api/history?days=x")[1]["days"]) == 7


def test_requests_tail_newest_first(env):
    dash, _, logs, _ = env
    lines = [json.dumps({"ts": i, "path": "/v1/messages", "status": 200}) for i in range(10)]
    (logs / "a1.log").write_text("\n".join(lines) + "\ngarbage\n")
    status, out = call(dash, "/api/requests?agent=a1&limit=3")
    assert status == 200
    assert [e["ts"] for e in out["requests"]] == [9, 8, 7]
    assert call(dash, "/api/requests?agent=nope")[1]["requests"] == []


def test_requests_rejects_bad_agent_ids(env):
    dash = env[0]
    for agent in ("", "..%2Fstate%2Fa1", "a%2Fb", ".hidden"):
        assert call(dash, "/api/requests?agent=" + agent)[0] == 400


def test_tail_log_handles_large_files(tmp_path):
    with open(tmp_path / "big.log", "w") as f:
        for i in range(20000):
            f.write(json.dumps({"ts": i, "pad": "x" * 40}) + "\n")
    out = tail_log(str(tmp_path), "big", 2)
    assert [e["ts"] for e in out] == [19999, 19998]


def test_health_reports_down_services(env):
    status, out = call(env[0], "/api/health")
    assert status == 200 and out["ok"] is False
    assert out["services"]["redis"]["ok"] is True
    assert out["services"]["gateway"]["ok"] is False
    assert out["services"]["daemon"]["ok"] is False


def test_unknown_route_404(env):
    assert call(env[0], "/api/nothing")[0] == 404


def test_http_server_end_to_end(env, store):
    dash = env[0]
    srv = serve(dash.cfg, dash.token_file, "127.0.0.1", 0, store=store)
    try:
        port = srv.server_address[1]

        def http_call(method, path, headers=None):
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            conn.request(method, path, headers=headers or {})
            resp = conn.getresponse()
            body = resp.read()
            conn.close()
            return resp.status, dict(resp.getheaders()), body

        status, headers, _ = http_call("GET", "/api/spend")
        assert status == 401 and "Basic" in headers["WWW-Authenticate"]
        status, headers, body = http_call("GET", "/api/spend", {"Authorization": basic(TOKEN)})
        assert status == 200 and json.loads(body)["date"]
        assert "default-src 'none'" in headers["Content-Security-Policy"]
        # read-only: write methods are refused even with a valid token
        for method in ("POST", "PUT", "DELETE"):
            assert http_call(method, "/api/spend", {"Authorization": basic(TOKEN)})[0] == 405
    finally:
        srv.shutdown()
        srv.server_close()
