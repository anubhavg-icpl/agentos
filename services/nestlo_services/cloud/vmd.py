"""nestlo-cloud-vmd: the root helper that runs Nestlo Cloud VMs.

It listens on a unix socket that only nestlo-cloudd can open (the socket's
group, plus an SO_PEERCRED check against the allowed UIDs), takes one JSON
request per connection and answers one JSON line. It never decides who may
do what: nestlo-cloudd checks access before it calls. `attach` receives the
caller's stdin, stdout and stderr with SCM_RIGHTS and runs a process in the
VM on them (the shell of `ssh lobby@host ssh <vm>`).
"""

import argparse
import fcntl
import grp
import json
import logging
import os
import pwd
import signal
import socket
import socketserver
import subprocess
import sys
import termios
import threading

from .. import config as configmod
from .. import health as healthmod
from . import backend as B

log = logging.getLogger("nestlo.cloud.vmd")
MAX_REQUEST = 1024 * 1024
MAX_FDS = 3


class Helper:
    def __init__(self, driver, allowed_uids):
        self.driver = driver
        self.allowed = set(allowed_uids)
        self.locks = {}
        self.guard = threading.Lock()

    def lock(self, vid):
        with self.guard:
            return self.locks.setdefault(vid or "", threading.Lock())

    def handle(self, req, fds):
        op = req.get("op")
        spec = req.get("spec") or {}
        vid = spec.get("id") or req.get("id")
        if op == "attach":
            return self.attach(req, fds)
        with self.lock(vid):
            d = self.driver
            if op == "create":
                return d.create(spec, req.get("setup"), req.get("prompt"), req.get("registry_auth"))
            if op == "start":
                return d.start(spec)
            if op == "stop":
                return d.stop(vid)
            if op == "destroy":
                return d.destroy(vid)
            if op == "resize":
                return d.resize(spec)
            if op == "copy":
                with self.lock(req.get("src")):
                    return d.copy(req["src"], spec)
            if op == "stat":
                return d.stat(vid)
            if op == "status":
                return d.status(vid)
            if op == "sync":
                return d.sync(spec)
        raise B.BackendError("unknown operation %r" % op)

    def attach(self, req, fds):
        if len(fds) != 3:
            raise B.BackendError("attach needs stdin, stdout and stderr")
        argv, env = self.driver.attach_argv(req["id"], req.get("argv") or [], (req.get("env") or {}).get("TERM"))
        tty = bool(req.get("tty")) and os.isatty(fds[0])

        def setup():
            os.setsid()
            if tty:
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)

        p = subprocess.Popen(argv, stdin=fds[0], stdout=fds[1], stderr=fds[2], env=env, close_fds=True,
                             preexec_fn=setup)
        for fd in fds:
            os.close(fd)
        return {"exit": p.wait()}


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def make_handler(helper):
    class H(socketserver.BaseRequestHandler):
        def handle(self):
            sock = self.request
            uid = B.peer_uid(sock)
            fds = []
            try:
                if uid not in helper.allowed:
                    raise B.BackendError("not allowed")
                req, fds = B.recv_request(sock, MAX_REQUEST, MAX_FDS)
                result = helper.handle(req, fds)
                fds = []
                reply = {"result": result}
            except (B.BackendError, ValueError, KeyError, OSError) as exc:
                log.warning("request failed: %s", exc)
                reply = {"error": str(exc)}
            except Exception:
                log.exception("request failed")
                reply = {"error": "internal error in the VM helper"}
            finally:
                for fd in fds:
                    try:
                        os.close(fd)
                    except OSError:
                        pass
            try:
                sock.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass
    return H


def main(argv=None):
    ap = argparse.ArgumentParser(description="Nestlo Cloud VM helper (root)")
    ap.add_argument("--config", default=None)
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    cfg = configmod.load(args.config)
    ccfg = cfg.get("cloud") or {}
    vcfg = ccfg.get("vmd") or {}
    allowed = {0}
    for user in vcfg.get("allowed_users", ["nestlo-cloud"]):
        try:
            allowed.add(pwd.getpwnam(user).pw_uid)
        except KeyError:
            log.warning("allowed user %s does not exist", user)
    driver = B.Nspawn(vcfg)
    helper = Helper(driver, allowed)
    path = vcfg.get("socket", B.VMD_SOCKET)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = Server(path, make_handler(helper))
    try:
        gid = grp.getgrnam(vcfg.get("socket_group", "nestlo-cloud")).gr_gid
    except KeyError:
        gid = 0
    os.chown(path, 0, gid)
    os.chmod(path, 0o660)
    # systemd creates the runtime directory as root:root; open it to the group too
    os.chown(os.path.dirname(path), 0, gid)
    os.chmod(os.path.dirname(path), 0o750)
    healthmod.sd_notify("READY=1")
    log.info("listening on %s", path)
    try:
        srv.serve_forever()
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
