import http.client
import json
import threading
import time

from conftest import request


def post(gw, agent, topic, body, **kw):
    return request(gw, "POST", "/agent/%s/bus/%s" % (agent, topic), body, **kw)


def read(gw, agent, topic, query="", **kw):
    status, _, raw = request(gw, "GET", "/agent/%s/bus/%s%s" % (agent, topic, query), **kw)
    return status, json.loads(raw)


def test_publish_and_read(make_gateway):
    gw = make_gateway()
    status, _, raw = post(gw, "a1", "builds", {"body": "tests are green"})
    published = json.loads(raw)
    assert status == 200 and published["from"] == "a1" and published["topic"] == "builds"
    post(gw, "a2", "builds", {"body": {"job": 7}})           # structured bodies are kept
    post(gw, "a2", "builds", ["not", "a", "dict"])           # any other JSON value is the body
    status, res = read(gw, "a3", "builds")
    assert status == 200
    assert [(m["from"], m["body"]) for m in res["messages"]] == [
        ("a1", "tests are green"), ("a2", {"job": 7}), ("a2", ["not", "a", "dict"])]
    assert res["messages"][0]["id"] == published["id"] and res["cursor"] == res["messages"][-1]["id"]
    assert all(m["topic"] == "builds" and m["ts"] > 0 for m in res["messages"])

    # cursor: only newer messages
    assert read(gw, "a3", "builds", "?after=" + res["cursor"])[1]["messages"] == []
    post(gw, "a1", "builds", {"body": "more"})
    fresh = read(gw, "a3", "builds", "?after=" + res["cursor"])[1]
    assert [m["body"] for m in fresh["messages"]] == ["more"]
    # limit
    assert len(read(gw, "a3", "builds", "?limit=2")[1]["messages"]) == 2
    # "$" starts from now
    assert read(gw, "a3", "builds", "?after=$")[1]["messages"] == []


def test_plain_text_body(make_gateway):
    gw = make_gateway()
    conn = http.client.HTTPConnection("127.0.0.1", gw.port, timeout=5)
    conn.request("POST", "/agent/a1/bus/notes", body=b"hello there", headers={"Content-Type": "text/plain"})
    assert conn.getresponse().status == 200
    assert read(gw, "a1", "notes")[1]["messages"][-1]["body"] == "hello there"


def test_long_poll_returns_when_a_message_arrives(make_gateway):
    gw = make_gateway()
    cursor = read(gw, "a2", "jobs")[1]["cursor"]
    threading.Timer(0.4, lambda: post(gw, "a1", "jobs", {"body": "go"})).start()
    started = time.time()
    status, res = read(gw, "a2", "jobs", "?wait=5&after=" + cursor)
    elapsed = time.time() - started
    assert status == 200 and [m["body"] for m in res["messages"]] == ["go"]
    assert 0.3 < elapsed < 4


def test_long_poll_times_out_empty(make_gateway):
    gw = make_gateway()
    started = time.time()
    status, res = read(gw, "a2", "quiet", "?wait=1")
    assert status == 200 and res["messages"] == [] and time.time() - started >= 0.9


def test_wait_is_capped(make_gateway):
    gw = make_gateway(bus={"max_wait_sec": 1})
    started = time.time()
    read(gw, "a2", "quiet", "?wait=60")
    assert time.time() - started < 5


def test_direct_messages_and_inbox_privacy(make_gateway):
    gw = make_gateway()
    assert post(gw, "a1", "@a2", {"body": "ping"})[0] == 200
    assert read(gw, "a2", "@a2")[1]["messages"][0]["body"] == "ping"
    status, res = read(gw, "a3", "@a2")
    assert status == 403
    # operators read any inbox over the admin socket
    status, _, raw = request(gw, "GET", "/_nestlo/bus/@a2", admin=True)
    assert status == 200 and json.loads(raw)["messages"][0]["from"] == "a1"
    assert request(gw, "GET", "/_nestlo/bus/@a2")[0] == 403


def test_operator_posts_and_topic_listing(make_gateway):
    gw = make_gateway()
    status, _, raw = request(gw, "POST", "/_nestlo/bus/ops?from=alice", {"body": "stand down"}, admin=True)
    assert status == 200 and json.loads(raw)["from"] == "alice"
    assert request(gw, "POST", "/_nestlo/bus/ops", {"body": "x"})[0] == 403
    topics = json.loads(request(gw, "GET", "/_nestlo/bus", admin=True)[2])["topics"]
    assert topics == ["ops"]


def test_topic_and_cursor_validation(make_gateway):
    gw = make_gateway()
    assert post(gw, "a1", "bad%20topic", {"body": "x"})[0] == 400
    assert post(gw, "a1", "..%2Fx", {"body": "x"})[0] == 400
    assert post(gw, "a1", "@", {"body": "x"})[0] == 400
    assert post(gw, "a1", "@@a", {"body": "x"})[0] == 400
    assert post(gw, "..%2Fetc", "t", {"body": "x"})[0] == 400
    assert read(gw, "a1", "t", "?after=garbage")[0] == 400
    assert read(gw, "a1", "t", "?wait=abc")[0] == 400


def test_stream_is_bounded_and_messages_limited(make_gateway):
    gw = make_gateway(bus={"max_len": 3, "max_message_bytes": 100})
    for i in range(6):
        post(gw, "a1", "t", {"body": "m%d" % i})
    assert [m["body"] for m in read(gw, "a1", "t")[1]["messages"]] == ["m3", "m4", "m5"]
    assert post(gw, "a1", "t", {"body": "x" * 500})[0] == 413


def test_bus_does_not_use_the_llm_rate_limit(make_gateway):
    gw = make_gateway(limits={"max_requests_per_minute": 1})
    for _ in range(4):
        assert post(gw, "a1", "t", {"body": "x"})[0] == 200
