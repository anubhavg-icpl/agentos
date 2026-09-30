"""Session recording and deterministic replay storage.

A recording is a directory <dir>/<agent-id>/ with one file per proxied
request, <seq>.json (seq is zero padded, starting at 1):

  {"seq": 1, "ts": ..., "agent": "...", "provider": "anthropic",
   "request":  {"method": "POST", "path": "/v1/messages", "query": "",
                "body_sha256": "...", "body": "<text>"},
   "response": {"status": 200, "headers": {"content-type": "..."},
                "body": "<text>", "streamed": false}}

Bodies are stored as text; a body that is not valid UTF-8 is stored as
base64 with "body_encoding": "base64". Streamed (SSE) responses are stored
raw. The request hash is computed over the client's body as sent (JSON is
canonicalised first), before any gateway routing, so a replay is matched
against what the agent itself sent.
"""

import base64
import hashlib
import json
import logging
import os
import threading

from . import config as configmod

log = logging.getLogger("agentos.recorder")

KEEP_HEADERS = ("content-type", "request-id", "x-request-id")


def body_hash(body):
    """sha256 over the canonical form of a request body."""
    body = body or b""
    try:
        canon = json.dumps(json.loads(body), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    except ValueError:
        canon = body
    return hashlib.sha256(canon).hexdigest()


def encode_body(data):
    data = data or b""
    try:
        return data.decode(), None
    except UnicodeDecodeError:
        return base64.b64encode(data).decode(), "base64"


def decode_body(text, encoding):
    return base64.b64decode(text) if encoding == "base64" else (text or "").encode()


class Recorder:
    def __init__(self, directory, max_body_bytes=64 * 1024 * 1024):
        self.dir = directory
        self.max_body_bytes = int(max_body_bytes)
        self._lock = threading.Lock()
        self._seq = {}

    def _agent_dir(self, agent):
        return os.path.join(self.dir, agent)

    def _path(self, agent, seq):
        return os.path.join(self._agent_dir(agent), "%06d.json" % seq)

    def count(self, recording):
        if not configmod.valid_agent_id(recording):
            return 0
        try:
            return len([n for n in os.listdir(self._agent_dir(recording)) if n.endswith(".json")])
        except OSError:
            return 0

    def next_seq(self, agent):
        """Reserve the next sequence number for an agent's recording."""
        with self._lock:
            if agent not in self._seq:
                self._seq[agent] = self.count(agent)
            self._seq[agent] += 1
            return self._seq[agent]

    def write(self, agent, seq, entry):
        directory = self._agent_dir(agent)
        try:
            os.makedirs(directory, mode=0o750, exist_ok=True)
            path = self._path(agent, seq)
            tmp = path + ".tmp"
            with open(tmp, "w") as f:
                json.dump(entry, f, sort_keys=True)
            os.replace(tmp, path)
            return True
        except OSError as exc:
            log.warning("cannot write recording %s/%d: %s", agent, seq, exc)
            return False

    def load(self, recording, seq):
        try:
            with open(self._path(recording, seq)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def list(self):
        out = []
        try:
            names = sorted(os.listdir(self.dir))
        except OSError:
            return out
        for name in names:
            if configmod.valid_agent_id(name) and self.count(name):
                first = self.load(name, 1) or {}
                out.append({"id": name, "requests": self.count(name), "started": first.get("ts")})
        return out

    def summary(self, recording):
        """One line per recorded request (no bodies)."""
        out = []
        for seq in range(1, self.count(recording) + 1):
            entry = self.load(recording, seq)
            if entry:
                req, resp = entry["request"], entry["response"]
                out.append({"seq": seq, "method": req["method"], "path": req["path"],
                            "status": resp["status"], "streamed": resp.get("streamed", False),
                            "model": entry.get("model"), "ts": entry.get("ts")})
        return out

    def build(self, agent, seq, ts, provider, method, path, query, req_body, status, headers, resp_body, model,
              streamed, truncated=False):
        rbody, renc = encode_body(req_body)
        sbody, senc = encode_body(resp_body)
        request = {"method": method, "path": path, "query": query, "body_sha256": body_hash(req_body), "body": rbody}
        response = {"status": status, "headers": {k: v for k, v in headers.items() if k.lower() in KEEP_HEADERS},
                    "body": sbody, "streamed": streamed}
        if renc:
            request["body_encoding"] = renc
        if senc:
            response["body_encoding"] = senc
        if truncated:
            response["truncated"] = True
        return {"seq": seq, "ts": ts, "agent": agent, "provider": provider, "model": model,
                "request": request, "response": response}
