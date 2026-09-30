"""Inter-agent message bus on Redis streams.

Agents publish and read through the gateway:

  POST /agent/<id>/bus/<topic>                      publish
  GET  /agent/<id>/bus/<topic>?after=<cursor>&wait=<sec>&limit=<n>   read

A message is {"id", "from", "topic", "body", "ts"}; `id` is the stream id and
doubles as the cursor: pass the last id you saw as `after` to get only newer
messages ("$" means "from now on"). With `wait`, a read blocks up to that many
seconds for a message (long poll). Each topic keeps at most bus.max_len
messages. Topic "@<agent-id>" is that agent's inbox; only that agent (or an
operator on the admin socket) may read it.
"""

import json
import re

from . import config as configmod

CURSOR = re.compile(r"^(\$|\d+(-\d+)?)$")


class BusError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Bus:
    def __init__(self, cfg, store, clock):
        self.cfg = cfg["bus"]
        self.store = store
        self.clock = clock

    def _check_topic(self, topic):
        if not configmod.valid_topic(topic):
            raise BusError(400, "invalid topic (letters, digits, . _ -; '@<agent>' for an inbox)")

    def publish(self, sender, topic, raw):
        self._check_topic(topic)
        raw = raw or b""
        if len(raw) > int(self.cfg["max_message_bytes"]):
            raise BusError(413, "message too large")
        try:
            payload = json.loads(raw)
            # {"body": ...} or any other JSON value
            body = payload["body"] if isinstance(payload, dict) and "body" in payload else payload
        except ValueError:
            body = raw.decode("utf-8", "replace")
        ts = self.clock()
        msg_id = self.store.bus_publish(topic, {
            "from": sender, "ts": repr(ts), "body": json.dumps(body),
        }, self.cfg["max_len"])
        return {"id": msg_id, "topic": topic, "from": sender, "ts": ts}

    def read(self, reader, topic, after="0", wait=0.0, limit=100, admin=False):
        self._check_topic(topic)
        if topic.startswith("@") and topic[1:] != reader and not admin:
            raise BusError(403, "only %s can read this inbox" % topic[1:])
        after = after or "0"
        if not CURSOR.match(after):
            raise BusError(400, "invalid cursor")
        if after == "$":
            after = self.store.bus_last_id(topic)
        wait = max(0.0, min(float(wait), float(self.cfg["max_wait_sec"])))
        limit = max(1, min(int(limit), 500))
        entries = self.store.bus_read(topic, after, limit, int(wait * 1000))
        messages = []
        for msg_id, fields in entries:
            try:
                body = json.loads(fields.get("body", "null"))
            except ValueError:
                body = fields.get("body")
            messages.append({"id": msg_id, "from": fields.get("from"), "topic": topic,
                             "body": body, "ts": float(fields.get("ts", 0))})
        cursor = messages[-1]["id"] if messages else after
        return {"topic": topic, "messages": messages, "cursor": cursor}
