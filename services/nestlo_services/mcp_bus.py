"""MCP server (stdio) that gives an agent access to the Nestlo message bus.

Tools:
  send_message(topic, text)       publish to a topic; "@<agent-id>" messages an agent
  read_messages(topic?, after?, wait?)   read a topic (default: this agent's inbox "@<id>")

Configuration comes from the environment `nestlo spawn` sets for the agent:
NESTLO_AGENT_ID, and the gateway base URL, from NESTLO_GATEWAY_URL or
derived from ANTHROPIC_BASE_URL / OPENAI_BASE_URL
(http://127.0.0.1:8080/agent/<id>/anthropic -> http://127.0.0.1:8080/agent/<id>).

Speaks newline-delimited JSON-RPC 2.0 on stdin/stdout, as MCP stdio servers do.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PROTOCOL_VERSION = "2024-11-05"
SERVER_INFO = {"name": "nestlo-bus", "version": "0.1.0"}

TOOLS = [
    {
        "name": "send_message",
        "description": "Send a message to other agents on the Nestlo bus. Use a topic name for a "
                       "shared channel, or '@<agent-id>' for a direct message to one agent.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "topic": {"type": "string", "description": "Topic name, or @<agent-id> for a direct message"},
                "text": {"type": "string", "description": "Message text"},
            },
            "required": ["topic", "text"],
        },
    },
    {
        "name": "read_messages",
        "description": "Read messages from a topic on the Nestlo bus. Defaults to this agent's own inbox. "
                       "Pass the returned cursor as 'after' to get only newer messages.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "topic": {"type": "string", "description": "Topic to read (default: this agent's inbox)"},
                "after": {"type": "string", "description": "Cursor from a previous read; omit for all retained messages"},
                "wait": {"type": "number", "description": "Seconds to wait for a message (long poll, max 30)"},
            },
        },
    },
]


def derive_base(env):
    """Return (gateway base URL for this agent, agent id) or raise ValueError."""
    agent = env.get("NESTLO_AGENT_ID", "")
    base = env.get("NESTLO_GATEWAY_URL", "").rstrip("/")
    if not base:
        for var in ("ANTHROPIC_BASE_URL", "OPENAI_BASE_URL"):
            m = re.match(r"^(https?://[^/]+/agent/([^/]+))/", env.get(var, "").rstrip("/") + "/")
            if m:
                base, agent = m.group(1), agent or m.group(2).partition(":")[0]
                break
    if not base or not agent:
        raise ValueError("set NESTLO_AGENT_ID and NESTLO_GATEWAY_URL (or ANTHROPIC_BASE_URL)")
    if "/agent/" not in base:
        base = "%s/agent/%s" % (base, urllib.parse.quote(agent, safe=""))
    return base, agent


def http_json(method, url, body=None, timeout=60):
    data = json.dumps({"body": body}).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        try:
            msg = json.loads(exc.read())["error"]["message"]
        except (ValueError, KeyError, TypeError):
            msg = exc.reason
        raise RuntimeError("gateway returned %d: %s" % (exc.code, msg))
    except (urllib.error.URLError, OSError) as exc:
        raise RuntimeError("cannot reach the Nestlo gateway: %s" % exc)


class BusServer:
    def __init__(self, base, agent, fetch=http_json):
        self.base = base
        self.agent = agent
        self.fetch = fetch

    def _topic_url(self, topic):
        return "%s/bus/%s" % (self.base, urllib.parse.quote(topic, safe="@"))

    # ── tools ──────────────────────────────────────────────────────────
    def send_message(self, args):
        topic, text = args.get("topic"), args.get("text")
        if not isinstance(topic, str) or not isinstance(text, str):
            raise ValueError("topic and text are required strings")
        res = self.fetch("POST", self._topic_url(topic), text)
        return "sent to %s (id %s)" % (topic, res["id"])

    def read_messages(self, args):
        topic = args.get("topic") or "@" + self.agent
        query = {"after": args.get("after") or "0"}
        wait = float(args.get("wait") or 0)
        if wait > 0:
            query["wait"] = str(min(wait, 30))
        res = self.fetch("GET", self._topic_url(topic) + "?" + urllib.parse.urlencode(query), None,
                         timeout=max(60, wait + 10))
        lines = ["[%s] %s: %s" % (m["id"], m["from"], m["body"] if isinstance(m["body"], str) else json.dumps(m["body"]))
                 for m in res["messages"]]
        lines.append("cursor: %s" % res["cursor"])
        return "\n".join(lines) if res["messages"] else "no new messages\ncursor: %s" % res["cursor"]

    # ── JSON-RPC ───────────────────────────────────────────────────────
    def handle(self, msg):
        """Handle one JSON-RPC message; returns the response or None."""
        if not isinstance(msg, dict) or "method" not in msg:
            return None
        mid, method, params = msg.get("id"), msg["method"], msg.get("params") or {}
        if "id" not in msg:
            return None                                   # notification (e.g. notifications/initialized)
        if method == "initialize":
            return self._ok(mid, {"protocolVersion": params.get("protocolVersion") or PROTOCOL_VERSION,
                                  "capabilities": {"tools": {}}, "serverInfo": SERVER_INFO})
        if method == "ping":
            return self._ok(mid, {})
        if method == "tools/list":
            return self._ok(mid, {"tools": TOOLS})
        if method == "tools/call":
            name, args = params.get("name"), params.get("arguments") or {}
            tool = {"send_message": self.send_message, "read_messages": self.read_messages}.get(name)
            if tool is None:
                return self._err(mid, -32602, "unknown tool %r" % name)
            try:
                text, is_error = tool(args), False
            except (RuntimeError, ValueError) as exc:
                text, is_error = str(exc), True
            return self._ok(mid, {"content": [{"type": "text", "text": text}], "isError": is_error})
        return self._err(mid, -32601, "method not found: %s" % method)

    @staticmethod
    def _ok(mid, result):
        return {"jsonrpc": "2.0", "id": mid, "result": result}

    @staticmethod
    def _err(mid, code, message):
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}

    def serve(self, stdin=sys.stdin, stdout=sys.stdout):
        for line in stdin:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                resp = self._err(None, -32700, "parse error")
            else:
                resp = self.handle(msg)
            if resp is not None:
                stdout.write(json.dumps(resp) + "\n")
                stdout.flush()


def main(argv=None):
    try:
        base, agent = derive_base(os.environ)
    except ValueError as exc:
        print("nestlo-mcp-bus: %s" % exc, file=sys.stderr)
        return 1
    BusServer(base, agent).serve()
    return 0


if __name__ == "__main__":
    sys.exit(main())
