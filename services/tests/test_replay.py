import json
import os

import pytest

from conftest import request

REC = "/agent/rec1/anthropic/v1/messages"
PLAY = "/agent/play1/anthropic/v1/messages"


def turn(text, **extra):
    return dict({"model": "claude-test", "messages": [{"role": "user", "content": text}]}, **extra)


@pytest.fixture
def recorded(make_gateway, tmp_path):
    """A gateway with recording on and a two-request session by agent rec1."""
    gw = make_gateway(recording={"enabled": True, "dir": str(tmp_path / "rec")})
    assert request(gw, "POST", REC, turn("one"))[0] == 200
    assert request(gw, "POST", REC, turn("two", stream=True))[0] == 200
    return gw


def test_records_request_response_pairs(recorded, tmp_path):
    files = sorted(os.listdir(tmp_path / "rec" / "rec1"))
    assert files == ["000001.json", "000002.json"]
    first = json.loads((tmp_path / "rec" / "rec1" / files[0]).read_text())
    assert first["request"]["method"] == "POST" and first["request"]["path"] == "/v1/messages"
    assert json.loads(first["request"]["body"])["messages"][0]["content"] == "one"
    assert len(first["request"]["body_sha256"]) == 64
    assert first["response"]["status"] == 200
    assert first["response"]["headers"]["Content-Type"] == "application/json"
    assert json.loads(first["response"]["body"])["content"][0]["text"] == "hi"
    second = json.loads((tmp_path / "rec" / "rec1" / files[1]).read_text())
    assert second["response"]["streamed"] is True
    assert second["response"]["body"].count("data: ") == 4               # raw SSE
    # the recording does not contain credentials
    assert "sk-real-anthropic" not in json.dumps(first)
    # listing over the admin socket
    listing = json.loads(request(recorded, "GET", "/_nestlo/recordings", admin=True)[2])
    assert listing["recordings"][0]["id"] == "rec1" and listing["recordings"][0]["requests"] == 2
    detail = json.loads(request(recorded, "GET", "/_nestlo/recordings/rec1", admin=True)[2])
    assert [r["status"] for r in detail["requests"]] == [200, 200]
    assert request(recorded, "GET", "/_nestlo/recordings")[0] == 403


def test_replay_serves_from_recording_at_zero_cost(recorded, upstream, store, tmp_path):
    before = len(upstream.requests)
    spent = store.spend("rec1")
    status, _, body = request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"}, admin=True)
    assert status == 200 and json.loads(body)["replay"] == {"recording": "rec1", "pos": 0, "total": 2}

    status, headers, body = request(recorded, "POST", PLAY, turn("one"))
    assert status == 200 and json.loads(body)["content"][0]["text"] == "hi"
    assert headers["X-Nestlo-Replay"] == "rec1/1"
    status, headers, body = request(recorded, "POST", PLAY, turn("two", stream=True))
    assert status == 200 and headers["Content-Type"] == "text/event-stream"
    assert body.decode().count("data: ") == 4

    assert len(upstream.requests) == before                       # upstream never contacted
    assert store.spend("play1") == 0 and store.spend("rec1") == spent
    entry = json.loads((tmp_path / "logs" / "play1.log").read_text().splitlines()[-1])
    assert entry["replayed"] == "rec1/2" and entry["cost_usd"] == 0.0

    # the recording is exhausted
    status, _, body = request(recorded, "POST", PLAY, turn("three"))
    assert status == 409 and json.loads(body)["error"]["type"] == "replay_exhausted"


def test_replay_diverged_reports_details_and_does_not_advance(recorded, upstream):
    request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"}, admin=True)
    before = len(upstream.requests)
    status, _, body = request(recorded, "POST", PLAY, turn("something else"))
    err = json.loads(body)["error"]
    assert status == 409 and err["type"] == "replay_diverged"
    assert err["details"]["seq"] == 1
    assert err["details"]["expected"]["body_sha256"] != err["details"]["got"]["body_sha256"]
    assert err["details"]["expected"]["path"] == "/v1/messages"
    # a different path also diverges; the correct request still succeeds afterwards
    assert request(recorded, "POST", "/agent/play1/anthropic/v1/other", turn("one"))[0] == 409
    assert request(recorded, "POST", PLAY, turn("one"))[0] == 200
    assert len(upstream.requests) == before


def test_key_order_does_not_matter_for_the_hash(recorded):
    request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"}, admin=True)
    reordered = {"messages": [{"content": "one", "role": "user"}], "model": "claude-test"}
    assert request(recorded, "POST", PLAY, reordered)[0] == 200


def test_replay_registration_rules(recorded, store):
    assert request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "nope"}, admin=True)[0] == 404
    assert request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "../x"}, admin=True)[0] == 400
    assert request(recorded, "PUT", "/_nestlo/replay/rec1", {"recording": "rec1"}, admin=True)[0] == 400
    assert request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"})[0] == 403   # admin only
    assert request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"}, admin=True)[0] == 200
    assert json.loads(request(recorded, "GET", "/_nestlo/replay/play1", admin=True)[2])["replay"]["pos"] == 0
    assert request(recorded, "DELETE", "/_nestlo/replay/play1", admin=True)[0] == 200
    assert store.replay_state("play1") is None
    # replay agents are not blocked by budgets, and normal traffic resumes after DELETE
    assert request(recorded, "POST", PLAY, turn("live"))[0] == 200


def test_replay_ignores_budgets(recorded):
    request(recorded, "PUT", "/_nestlo/budget/play1", {"daily_usd": 0}, admin=True)
    request(recorded, "PUT", "/_nestlo/replay/play1", {"recording": "rec1"}, admin=True)
    assert request(recorded, "POST", PLAY, turn("one"))[0] == 200


def test_per_agent_recording_flag(make_gateway, tmp_path):
    gw = make_gateway(recording={"enabled": False, "dir": str(tmp_path / "rec")})
    assert request(gw, "POST", REC, turn("a"))[0] == 200
    assert not (tmp_path / "rec").exists()
    assert request(gw, "PUT", "/_nestlo/record/rec1", {"enabled": True}, admin=True)[0] == 200
    assert request(gw, "POST", REC, turn("b"))[0] == 200
    assert os.listdir(tmp_path / "rec" / "rec1") == ["000001.json"]
    assert request(gw, "DELETE", "/_nestlo/record/rec1", admin=True)[0] == 200
    request(gw, "POST", REC, turn("c"))
    assert os.listdir(tmp_path / "rec" / "rec1") == ["000001.json"]


def test_recording_stores_original_body_when_routed(make_gateway, tmp_path):
    gw = make_gateway(recording={"enabled": True, "dir": str(tmp_path / "rec")},
                      routing={"rewrites": {"claude-pricey": "claude-cheap"}})
    request(gw, "POST", REC, turn("x", model="claude-pricey"))
    rec = json.loads((tmp_path / "rec" / "rec1" / "000001.json").read_text())
    assert json.loads(rec["request"]["body"])["model"] == "claude-pricey"
    assert rec["model"] == "claude-cheap"


def test_sequence_continues_after_restart(make_gateway, tmp_path):
    cfg = {"recording": {"enabled": True, "dir": str(tmp_path / "rec")}}
    gw = make_gateway(**cfg)
    request(gw, "POST", REC, turn("a"))
    gw2 = make_gateway(**cfg)
    request(gw2, "POST", REC, turn("b"))
    assert sorted(os.listdir(tmp_path / "rec" / "rec1")) == ["000001.json", "000002.json"]
