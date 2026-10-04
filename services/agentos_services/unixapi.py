"""A tiny JSON-over-HTTP API on a unix socket, and a client for it.

The orchestrator and the scheduler are controlled through sockets owned by
the agentos group (like the gateway's admin socket): operators can use
them, the sandboxed agent user cannot. Handlers are plain functions

    app(method, parts, query, body) -> (status, object)

where `parts` is the URL path split on "/".
"""

import http.client
import http.server
import json
import logging
import os
import socket
import socketserver
import struct
import threading
import urllib.parse

log = logging.getLogger("agentos.unixapi")

MAX_BODY = 1024 * 1024

_local = threading.local()


def peer_credentials():
    """{pid, uid, gid} of the client of the request being handled (SO_PEERCRED,
    set by the kernel and not forgeable by the client), or None."""
    return getattr(_local, "peer", None)


def _read_peer(sock):
    try:
        pid, uid, gid = struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        return {"pid": pid, "uid": uid, "gid": gid}
    except (OSError, AttributeError, struct.error):
        return None


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "agentos-api"

    def _serve(self):
        self.close_connection = True
        _local.peer = _read_peer(self.connection)
        url = urllib.parse.urlsplit(self.path)
        parts = [urllib.parse.unquote(p) for p in url.path.split("/") if p]
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise ApiError(413, "request body too large")
            raw = self.rfile.read(length) if length else b""
            try:
                body = json.loads(raw) if raw else {}
            except ValueError:
                raise ApiError(400, "request body is not valid JSON")
            status, obj = self.server.app(self.command, parts, urllib.parse.parse_qs(url.query), body)
        except ApiError as exc:
            status, obj = exc.status, {"error": exc.message}
        except Exception:
            log.exception("error handling %s %s", self.command, self.path)
            status, obj = 500, {"error": "internal error"}
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_DELETE = _serve

    def address_string(self):
        return "unix"

    def log_message(self, fmt, *args):
        log.debug(fmt, *args)


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def serve_unix(path, app):
    """Listen on `path` (mode 0660) and serve in a background thread."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.exists(path):
        os.unlink(path)
    server = UnixServer(path, Handler)
    os.chmod(path, 0o660)
    server.app = app
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class _Conn(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.path)


def call(socket_path, method, url, body=None, timeout=15):
    """Returns (status, decoded JSON body). Raises OSError if unreachable."""
    conn = _Conn(socket_path, timeout)
    try:
        data = json.dumps(body).encode() if body is not None else None
        conn.request(method, url, body=data, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        raw = resp.read()
        try:
            return resp.status, json.loads(raw) if raw else {}
        except ValueError:
            return resp.status, {"error": raw.decode(errors="replace")[:200]}
    finally:
        conn.close()
