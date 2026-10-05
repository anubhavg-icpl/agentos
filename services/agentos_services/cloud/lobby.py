"""The SSH entry points of AgentOS Cloud (`ssh lobby@host <command>`).

sshd runs `agentos-cloud-lobby keys <type> <base64>` as its
AuthorizedKeysCommand for the lobby user. It asks agentos-cloudd whether the
key is registered and prints it with a forced command:

    command="agentos-cloud-lobby --key SHA256:...",restrict,pty ssh-ed25519 AAAA...

so every session of the lobby user runs this program, which knows the key
that authenticated and finds the requested command in SSH_ORIGINAL_COMMAND.
Unregistered keys get `--unregistered`, which only accepts `redeem <code>`.

`ssh <vm> [command]` hands this process's stdin, stdout and stderr (the
session's terminal) to agentos-cloudd, which checks access and passes them on
to the VM helper; `tunnel <vm> [port]` connects stdio to a VM port, for
ProxyCommand (scp, rsync, VS Code Remote-SSH to the VM's own sshd).
"""

import json
import os
import select
import shlex
import socket
import sys

from . import backend as B

SOCKET = os.environ.get("AGENTOS_CLOUD_LOBBY_SOCKET", "/run/agentos-cloud/lobby.sock")


def call(op, fds=None, **args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(SOCKET)
        data = (json.dumps(dict(args, op=op)) + "\n").encode()
        if fds:
            import array
            s.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
        else:
            s.sendall(data)
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except OSError as exc:
        sys.stderr.write("AgentOS Cloud is not available right now (%s)\n" % exc)
        sys.exit(75)
    finally:
        s.close()
    reply = json.loads(buf or b"{}")
    if reply.get("error"):
        sys.stderr.write("error: %s\n" % reply["error"])
        sys.exit(2 if reply.get("status", 500) < 500 else 1)
    return reply.get("result")


def pump(sock):
    """Copy stdin to the socket and the socket to stdout until both ends close."""
    fin, fout = sys.stdin.buffer.raw, sys.stdout.buffer.raw
    open_in = True
    while True:
        rl = [sock] + ([fin] if open_in else [])
        r, _, _ = select.select(rl, [], [])
        if sock in r:
            data = sock.recv(65536)
            if not data:
                return
            fout.write(data)
            fout.flush()
        if open_in and fin in r:
            data = os.read(fin.fileno(), 65536)
            if not data:
                open_in = False
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
            else:
                sock.sendall(data)


def remote_command(line):
    """argv for the command of `ssh <vm> <command>`: like OpenSSH, the command
    text (quoting, redirections, `&`) goes to the VM's shell; [] means a login shell."""
    parts = line.split(None, 2)
    if len(parts) < 3 or not parts[2].strip():
        return []
    return ["/bin/sh", "-c", parts[2]]


def keys_main(argv):
    """AuthorizedKeysCommand: agentos-cloud-lobby keys %t %k"""
    if len(argv) != 2:
        return 0
    result = call("authorized-keys", type=argv[0], key=argv[1])
    for line in result.get("lines", []):
        print(line)
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["keys"]:
        return keys_main(argv[1:])
    line = os.environ.get("SSH_ORIGINAL_COMMAND", "").strip()
    try:
        words = shlex.split(line)
    except ValueError as exc:
        sys.stderr.write("error: cannot parse the command: %s\n" % exc)
        return 2
    if argv[:1] == ["--unregistered"]:
        if words[:1] == ["redeem"] and len(words) == 2 and len(argv) == 3:
            print(call("redeem", code=words[1], public="%s %s" % (argv[1], argv[2]))["message"])
            return 0
        sys.stderr.write("This SSH key is not registered with AgentOS Cloud.\n"
                         "If you have an invite code, run:  ssh %s@<host> redeem <code>\n"
                         "Otherwise ask an administrator to add your key.\n" % os.environ.get("USER", "lobby"))
        return 1
    if argv[:1] != ["--key"] or len(argv) < 2:
        sys.stderr.write("error: the lobby must be started by sshd\n")
        return 1
    key = argv[1]
    if not words:
        words = ["help"]
    if words[0] == "ssh":
        if len(words) < 2:
            sys.stderr.write("usage: ssh <vm> [command]\n")
            return 2
        tty = os.isatty(0)
        res = call("attach", fds=[0, 1, 2], key=key, vm=words[1], argv=remote_command(line), tty=tty,
                   term=os.environ.get("TERM"))
        return int((res or {}).get("exit", 0))
    if words[0] == "tunnel":
        if len(words) < 2:
            sys.stderr.write("usage: tunnel <vm> [port]\n")
            return 2
        vm = words[1].split(".")[0]
        port = words[2] if len(words) > 2 else "22"
        res = call("tunnel", key=key, vm=vm, port=port)
        s = socket.create_connection((res["ip"], res["port"]), timeout=10)
        s.settimeout(None)
        pump(s)
        return 0
    stdin = None
    if "/dev/stdin" in words:
        stdin = sys.stdin.read(60001)
    res = call("run", key=key, argv=words, stdin=stdin)
    if "--json" in words:
        print(json.dumps(res["result"], indent=2))
    else:
        print(res["text"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
