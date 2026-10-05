"""Minimal static file server for the agent-fleet chat and hub.

Serves a read-only directory tree with the right content types for
.wasm, .mjs and .webmanifest. Everything under /chat/ also gets the
cross-origin isolation headers (COOP same-origin, COEP require-corp) that
wllama needs for SharedArrayBuffer, i.e. multi-threaded inference, and a
Content-Security-Policy that confines the page to its own scripts.

Only GET and HEAD, no directory listings, no symlink escapes. The default
listen address is loopback.
"""

import argparse
import http.server
import os
import posixpath
import urllib.parse

TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json",
    ".webmanifest": "application/manifest+json",
    ".wasm": "application/wasm",
    ".svg": "image/svg+xml",
    ".webp": "image/webp",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".txt": "text/plain; charset=utf-8",
}

# connect-src allows https: because Hugging Face redirects model downloads to
# changing CDN hosts.
CHAT_CSP = (
    "default-src 'self'; "
    "script-src 'self' 'wasm-unsafe-eval' blob:; "
    "worker-src 'self' blob:; "
    "connect-src 'self' https: blob: data:; "
    "img-src 'self' data: blob:; "
    "style-src 'self' 'unsafe-inline'; "
    "font-src 'self' data:; "
    "object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
)
HUB_CSP = (
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; "
    "script-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
)


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "agent-fleet-web"
    sys_version = ""
    root = "."

    def _resolve(self, raw):
        path = posixpath.normpath(urllib.parse.unquote(urllib.parse.urlsplit(raw).path))
        if "\0" in path or not path.startswith("/"):
            return None
        full = os.path.realpath(os.path.join(self.root, path.lstrip("/")))
        if full != self.root and not full.startswith(self.root + os.sep):
            return None
        if os.path.isdir(full):
            full = os.path.join(full, "index.html")
        return full if os.path.isfile(full) else None

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=(), head=False):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-cache")
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _serve(self, head):
        split = urllib.parse.urlsplit(self.path)
        if split.path == "/":
            return self._send(302, b"", extra=[("Location", "/hub/")], head=head)
        # a directory without the trailing slash: relative URLs need it
        if split.path in ("/chat", "/hub"):
            return self._send(301, b"", extra=[("Location", split.path + "/")], head=head)
        full = self._resolve(self.path)
        if full is None:
            return self._send(404, b"not found\n", head=head)
        with open(full, "rb") as f:
            body = f.read()
        ctype = TYPES.get(os.path.splitext(full)[1].lower(), "application/octet-stream")
        extra = []
        rel = os.path.relpath(full, self.root)
        if rel.startswith("chat" + os.sep):
            extra = [
                ("Cross-Origin-Opener-Policy", "same-origin"),
                ("Cross-Origin-Embedder-Policy", "require-corp"),
                ("Cross-Origin-Resource-Policy", "same-origin"),
                ("Content-Security-Policy", CHAT_CSP),
            ]
        elif rel.startswith("hub" + os.sep):
            extra = [("Content-Security-Policy", HUB_CSP)]
        self._send(200, body, ctype, extra, head)

    def do_GET(self):
        self._serve(False)

    def do_HEAD(self):
        self._serve(True)

    def _no(self):
        self._send(405, b"method not allowed\n", extra=[("Allow", "GET, HEAD")])

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _no

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--root", required=True, help="directory holding chat/ and hub/")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8484)
    args = ap.parse_args()
    Handler.root = os.path.realpath(args.root)
    srv = http.server.ThreadingHTTPServer((args.listen, args.port), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()
