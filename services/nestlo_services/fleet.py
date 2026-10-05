"""nestlo-fleet: drive remote Nestlo hosts over SSH.

Hosts come from two files, merged (the declarative one wins on a name clash):

  /etc/nestlo/fleet.json          nestlo.fleet.hosts in the NixOS config
  ~/.config/nestlo/fleet.json     `nestlo-fleet add` / `remove`

Both look like {"hosts": {"<name>": {"address": "host", "user": "u", "port": 22}}}.

Everything runs through the operator's own `ssh` (their keys, agent and
~/.ssh/config). Host key checking is never relaxed: connect once by hand (or
list the key in programs.ssh.knownHosts) before using a new host.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shlex
import subprocess
import sys

SYSTEM_FILE = "/etc/nestlo/fleet.json"
STATE_DIR = "/var/lib/nestlo/state"
SERVICES = ("nestlo-daemon", "nestlo-model-gateway", "redis-nestlo")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,62}$")
HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,252}$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_.-]{0,31}$")
CONNECT_TIMEOUT = 10


class FleetError(Exception):
    pass


# ── host registry ─────────────────────────────────────────────────────────
def system_file():
    return os.environ.get("NESTLO_FLEET_SYSTEM", SYSTEM_FILE)


def user_file():
    override = os.environ.get("NESTLO_FLEET_USER")
    if override:
        return override
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "nestlo", "fleet.json")


def _read(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise FleetError("cannot read %s: %s" % (path, exc))
    hosts = data.get("hosts") if isinstance(data, dict) else None
    return hosts if isinstance(hosts, dict) else {}


def validate_host(name, entry):
    if not NAME_RE.match(name or ""):
        raise FleetError("invalid host name %r (lower-case letters, digits, . _ -)" % name)
    address = entry.get("address") or ""
    # a leading '-' would be parsed by ssh as an option
    if not HOST_RE.match(address):
        raise FleetError("invalid address %r" % address)
    user = entry.get("user")
    if user is not None and not USER_RE.match(user):
        raise FleetError("invalid user %r" % user)
    port = entry.get("port", 22)
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise FleetError("invalid port %r" % (port,))


def load_hosts():
    """name -> {address, user, port, source}"""
    hosts = {}
    for source, path in (("local", user_file()), ("declarative", system_file())):
        for name, entry in _read(path).items():
            if not isinstance(entry, dict):
                continue
            validate_host(name, entry)
            hosts[name] = {"address": entry["address"], "user": entry.get("user"),
                           "port": entry.get("port", 22), "source": source}
    return hosts


def parse_target(target):
    user, _, address = target.rpartition("@")
    return (user or None), address


def add_host(name, target, port=22):
    user, address = parse_target(target)
    entry = {"address": address, "port": port}
    if user:
        entry["user"] = user
    validate_host(name, entry)
    if load_hosts().get(name, {}).get("source") == "declarative":
        raise FleetError("%s is declared in %s; change nestlo.fleet.hosts instead" % (name, system_file()))
    path = user_file()
    hosts = _read(path)
    hosts[name] = entry
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"hosts": hosts}, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def remove_host(name):
    hosts = load_hosts()
    if name not in hosts:
        raise FleetError("unknown host %r" % name)
    if hosts[name]["source"] == "declarative":
        raise FleetError("%s is declared in %s; change nestlo.fleet.hosts instead" % (name, system_file()))
    path = user_file()
    local = _read(path)
    local.pop(name, None)
    with open(path, "w") as f:
        json.dump({"hosts": local}, f, indent=2, sort_keys=True)
        f.write("\n")


def get_host(name):
    hosts = load_hosts()
    if name not in hosts:
        raise FleetError("unknown host %r (see: nestlo-fleet list)" % name)
    return hosts[name]


# ── ssh ───────────────────────────────────────────────────────────────────
def ssh_argv(host, remote=None, tty=False, batch=False):
    """The ssh command line for `host`. Host key checking stays at its default."""
    argv = shlex.split(os.environ.get("NESTLO_FLEET_SSH", "ssh"))
    argv += ["-p", str(host["port"]), "-o", "ConnectTimeout=%d" % CONNECT_TIMEOUT]
    if batch:
        argv += ["-o", "BatchMode=yes"]
    if tty:
        argv.append("-t")
    argv.append("%s@%s" % (host["user"], host["address"]) if host.get("user") else host["address"])
    if remote is not None:
        argv.append(remote)
    return argv


def remote_command(argv):
    """Wrap a command so it runs under sh with the system profile on PATH,
    whatever the remote login shell is."""
    script = 'PATH="$PATH:/run/current-system/sw/bin"; exec ' + shlex.join(argv)
    return "sh -c " + shlex.quote(script)


STATUS_SCRIPT = """\
PATH="$PATH:/run/current-system/sw/bin"
echo @@services
for s in %s; do echo "$s $(systemctl is-active "$s" 2>/dev/null)"; done
echo @@budget
nestlo-budget status --json 2>/dev/null
echo
echo @@state
cat %s/*.json 2>/dev/null
""" % (" ".join(SERVICES), STATE_DIR)


def _objects(text):
    """Every JSON value in `text`, concatenated back to back."""
    dec = json.JSONDecoder()
    out, i = [], 0
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            return out
        try:
            obj, i = dec.raw_decode(text, i)
        except ValueError:
            return out
        out.append(obj)


def parse_status(text):
    sections, current = {}, None
    for line in text.splitlines():
        if line.startswith("@@") and line[2:] in ("services", "budget", "state"):
            current = line[2:]
            sections[current] = []
        elif current:
            sections[current].append(line)
    services = {}
    for line in sections.get("services", []):
        name, _, state = line.partition(" ")
        if name:
            services[name] = state.strip() or "unknown"
    budget = next((o for o in _objects("\n".join(sections.get("budget", []))) if isinstance(o, dict)), None)
    agents = [o for o in _objects("\n".join(sections.get("state", []))) if isinstance(o, dict)]
    return {"services": services, "budget": budget, "agents": agents}


def host_status(name, host, timeout=45):
    result = {"name": name, "address": host["address"], "port": host["port"], "up": False}
    try:
        proc = subprocess.run(ssh_argv(host, "sh -c " + shlex.quote(STATUS_SCRIPT), batch=True),
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        result["error"] = "timed out"
        return result
    except OSError as exc:
        result["error"] = str(exc)
        return result
    if proc.returncode != 0 and "@@services" not in proc.stdout:
        lines = proc.stderr.strip().splitlines()
        result["error"] = lines[-1] if lines else "ssh exited with %d" % proc.returncode
        return result
    parsed = parse_status(proc.stdout)
    running = [a for a in parsed["agents"] if a.get("status") == "running"]
    budget = parsed["budget"] or {}
    result.update(
        up=True,
        services=parsed["services"],
        services_ok=bool(parsed["services"]) and all(s == "active" for s in parsed["services"].values()),
        agents_running=len(running),
        agents=[{"id": a.get("id"), "agent": a.get("agent"), "status": a.get("status"),
                 "workspace": a.get("workspace"), "branch": a.get("branch")} for a in parsed["agents"]],
        spend_usd=budget.get("global_usd"),
        limit_usd=budget.get("global_limit_usd"),
    )
    return result


def fleet_status(names=None):
    hosts = load_hosts()
    if names:
        for n in names:
            if n not in hosts:
                raise FleetError("unknown host %r (see: nestlo-fleet list)" % n)
        hosts = {n: hosts[n] for n in names}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(16, len(hosts)))) as pool:
        futures = {n: pool.submit(host_status, n, h) for n, h in hosts.items()}
        return [futures[n].result() for n in sorted(futures)]


# ── output ────────────────────────────────────────────────────────────────
def table(rows, header):
    rows = [[str(c) for c in r] for r in rows]
    widths = [max(len(header[i]), *(len(r[i]) for r in rows)) if rows else len(header[i]) for i in range(len(header))]
    lines = ["  ".join(h.ljust(w) for h, w in zip(header, widths)).rstrip()]
    lines += ["  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows]
    return "\n".join(lines)


def status_table(results):
    rows = []
    for r in results:
        if not r["up"]:
            rows.append([r["name"], r["address"], "DOWN", "-", "-", "-", r.get("error", "")])
            continue
        bad = [n for n, s in r["services"].items() if s != "active"]
        spend = "-"
        if r["spend_usd"] is not None:
            spend = "$%.2f / $%.0f" % (r["spend_usd"], r["limit_usd"] or 0)
        rows.append([r["name"], r["address"], "up", "ok" if r["services_ok"] else "down: " + ",".join(bad) if bad else "n/a",
                     r["agents_running"], spend, ""])
    out = table(rows, ["HOST", "ADDRESS", "STATE", "SERVICES", "AGENTS", "SPEND TODAY", "NOTE"])
    agents = [[r["name"], a["id"], a["agent"], a["status"], a["workspace"], a["branch"]]
              for r in results if r["up"] for a in r["agents"]]
    if agents:
        out += "\n\n" + table(agents, ["HOST", "AGENT ID", "AGENT", "STATUS", "WORKSPACE", "BRANCH"])
    return out


# ── commands ──────────────────────────────────────────────────────────────
def cmd_add(args):
    add_host(args.name, args.target, args.port)
    print("added %s (%s)" % (args.name, args.target))


def cmd_list(args):
    hosts = load_hosts()
    if args.json:
        print(json.dumps(hosts, indent=2, sort_keys=True))
        return 0
    rows = [[n, ("%s@%s" % (h["user"], h["address"])) if h["user"] else h["address"], h["port"], h["source"]]
            for n, h in sorted(hosts.items())]
    print(table(rows, ["NAME", "TARGET", "PORT", "SOURCE"]) if rows else "no hosts; add one with: nestlo-fleet add <name> <user@host>")
    return 0


def cmd_remove(args):
    remove_host(args.name)
    print("removed %s" % args.name)


def cmd_status(args):
    results = fleet_status(args.hosts)
    if args.json:
        print(json.dumps(results, indent=2))
    elif results:
        print(status_table(results))
    else:
        print("no hosts; add one with: nestlo-fleet add <name> <user@host>")
    return 0 if all(r["up"] for r in results) else 1


def cmd_spawn(args):
    host = get_host(args.host)
    remote = remote_command(["nestlo", "spawn", args.agent] + args.spawn_args)
    return subprocess.call(ssh_argv(host, remote, tty=True))


def cmd_run(args):
    if not args.cmd:
        raise FleetError("usage: nestlo-fleet run <host> -- <command...>")
    host = get_host(args.host)
    return subprocess.call(ssh_argv(host, remote_command(args.cmd), tty=sys.stdin.isatty() and sys.stdout.isatty()))


def build_parser():
    p = argparse.ArgumentParser(prog="nestlo-fleet", description="Manage remote Nestlo hosts over SSH")
    sub = p.add_subparsers(dest="command", required=True)
    a = sub.add_parser("add", help="register a host")
    a.add_argument("name")
    a.add_argument("target", help="user@host or host")
    a.add_argument("--port", type=int, default=22)
    a.set_defaults(fn=cmd_add)
    a = sub.add_parser("list", aliases=["ls"], help="list hosts")
    a.add_argument("--json", action="store_true")
    a.set_defaults(fn=cmd_list)
    a = sub.add_parser("remove", aliases=["rm"], help="forget a host")
    a.add_argument("name")
    a.set_defaults(fn=cmd_remove)
    a = sub.add_parser("status", help="services, agents and spend of every host")
    a.add_argument("hosts", nargs="*")
    a.add_argument("--json", action="store_true")
    a.set_defaults(fn=cmd_status)
    a = sub.add_parser("spawn", help="run `nestlo spawn` on a host (ssh -t)")
    a.add_argument("host")
    a.add_argument("agent")
    a.add_argument("spawn_args", nargs=argparse.REMAINDER, help="passed to nestlo spawn")
    a.set_defaults(fn=cmd_spawn)
    a = sub.add_parser("run", help="run a command on a host")
    a.add_argument("host")
    a.add_argument("cmd", nargs=argparse.REMAINDER, help="-- <command...>")
    a.set_defaults(fn=cmd_run)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if getattr(args, "cmd", None) and args.cmd[:1] == ["--"]:
        args.cmd = args.cmd[1:]
    try:
        return args.fn(args) or 0
    except FleetError as exc:
        print("nestlo-fleet: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
