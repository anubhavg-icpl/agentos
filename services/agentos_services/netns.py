"""Per-agent network namespace for container-isolated agents.

Runs as root from the agent's transient systemd unit:

  ExecStartPre=+agentos-netns setup <id>      before the agent starts
  ExecStopPost=+agentos-netns teardown <id>   whenever the unit ends

setup creates a network namespace `agentos-<id>` with a veth pair: one end
(eth0 in the namespace) gets a free address from the agent subnet, the other
is attached to the agentos0 bridge as an isolated port (containers cannot
talk to each other, only to the host side). It also writes the container's
own /etc files (resolv.conf pointing at the bridge address, minimal
passwd/group) under <state_dir>/<id>/, which the unit bind-mounts.

The unit joins the namespace with NetworkNamespacePath=/run/netns/agentos-<id>.
Firewall policy for the subnet lives in the NixOS security/networking modules.
"""

import argparse
import contextlib
import fcntl
import hashlib
import ipaddress
import json
import os
import pwd
import grp
import shutil
import subprocess
import sys

from . import config as configmod

TOOL_DIRS = ("/run/current-system/sw/bin", "/run/wrappers/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin")

NSSWITCH = """passwd: files
group: files
hosts: files dns
"""


def names(agent_id):
    """Namespace and interface names for an agent (interface names are <= 15 chars)."""
    digest = hashlib.sha1(agent_id.encode()).hexdigest()[:8]
    return {"ns": "agentos-" + agent_id, "host_if": "avh" + digest, "peer_if": "avc" + digest}


def allocate_ip(used, network, gateway):
    """First free host address in `network`, skipping the gateway and `used`."""
    taken = {str(gateway)} | {str(u) for u in used}
    for host in network.hosts():
        if str(host) not in taken:
            return host
    raise RuntimeError("no free addresses left in %s" % network)


def _tool(name):
    for d in os.environ.get("PATH", "").split(":") + list(TOOL_DIRS):
        path = os.path.join(d, name)
        if d and os.access(path, os.X_OK):
            return path
    raise FileNotFoundError(name)


def _run(cmd, check=True):
    return subprocess.run([_tool(cmd[0])] + cmd[1:], check=check, stdout=subprocess.DEVNULL,
                          stderr=subprocess.PIPE, text=True)


class Netns:
    def __init__(self, conf, state_dir="/run/agentos/net", runner=_run, netns_dir="/run/netns"):
        self.bridge = conf["bridge"]
        self.gateway = ipaddress.ip_address(conf["bridge_address"])
        self.network = ipaddress.ip_network(conf["network"], strict=False)
        self.agent_user = conf.get("agent_user", "agentos-agent")
        self.agent_home = conf.get("agent_home", "/var/lib/agentos/agent-home")
        self.shell = conf.get("shell", "/run/current-system/sw/bin/bash")
        self.state_dir = state_dir
        self.netns_dir = netns_dir
        self.run = runner

    def dir(self, agent_id):
        return os.path.join(self.state_dir, agent_id)

    def used_addresses(self):
        used = []
        try:
            entries = os.listdir(self.state_dir)
        except OSError:
            return used
        for name in entries:
            try:
                with open(os.path.join(self.state_dir, name, "ip")) as f:
                    used.append(ipaddress.ip_address(f.read().strip()))
            except (OSError, ValueError):
                pass
        return used

    @contextlib.contextmanager
    def _locked(self):
        os.makedirs(self.state_dir, mode=0o755, exist_ok=True)
        with open(os.path.join(self.state_dir, ".lock"), "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            yield

    def setup(self, agent_id):
        """Create the namespace; returns the container's address."""
        n = names(agent_id)
        self.teardown(agent_id)  # leftovers of an earlier run with the same id
        try:
            with self._locked():
                addr = allocate_ip(self.used_addresses(), self.network, self.gateway)
                d = self.dir(agent_id)
                os.makedirs(d, mode=0o755)
                with open(os.path.join(d, "ip"), "w") as f:
                    f.write(str(addr) + "\n")
            self._files(agent_id, d)
            ns = n["ns"]
            r = self.run
            r(["ip", "netns", "add", ns])
            r(["ip", "link", "add", n["host_if"], "type", "veth", "peer", "name", n["peer_if"]])
            r(["ip", "link", "set", n["peer_if"], "netns", ns, "name", "eth0"])
            r(["ip", "-n", ns, "addr", "add", "%s/%d" % (addr, self.network.prefixlen), "dev", "eth0"])
            r(["ip", "-n", ns, "link", "set", "lo", "up"])
            r(["ip", "-n", ns, "link", "set", "eth0", "up"])
            r(["ip", "-n", ns, "route", "add", "default", "via", str(self.gateway)])
            r(["ip", "link", "set", n["host_if"], "master", self.bridge])
            r(["bridge", "link", "set", "dev", n["host_if"], "isolated", "on"])
            r(["ip", "link", "set", n["host_if"], "up"])
            # The egress policy is IPv4 only, so the container gets no IPv6
            with contextlib.suppress(FileNotFoundError):
                r(["ip", "netns", "exec", ns, _tool("sysctl"), "-q", "-w", "net.ipv6.conf.all.disable_ipv6=1"], check=False)
            return addr
        except Exception:
            self.teardown(agent_id)
            raise

    def _files(self, agent_id, d):
        """The container's own /etc/{resolv.conf,passwd,group,hosts,nsswitch.conf}."""
        pw = pwd.getpwnam(self.agent_user)
        gr = grp.getgrgid(pw.pw_gid)
        files = {
            "resolv.conf": "nameserver %s\n" % self.gateway,
            "hosts": "127.0.0.1 localhost\n%s agentos-gateway\n" % self.gateway,
            "nsswitch.conf": NSSWITCH,
            "passwd": "root:x:0:0:root:/root:%s\n%s:x:%d:%d:AgentOS agent:%s:%s\nnobody:x:65534:65534:nobody:/var/empty:%s\n"
                      % (self.shell, self.agent_user, pw.pw_uid, pw.pw_gid, self.agent_home, self.shell, self.shell),
            "group": "root:x:0:\n%s:x:%d:\nnobody:x:65534:\n" % (gr.gr_name, gr.gr_gid),
        }
        for name, text in files.items():
            with open(os.path.join(d, name), "w") as f:
                f.write(text)
            os.chmod(os.path.join(d, name), 0o644)

    def teardown(self, agent_id):
        """Remove everything setup created. Safe to call repeatedly."""
        n = names(agent_id)
        # Deleting one end of a veth pair removes the other
        self.run(["ip", "link", "del", n["host_if"]], check=False)
        self.run(["ip", "netns", "del", n["ns"]], check=False)
        with self._locked():
            shutil.rmtree(self.dir(agent_id), ignore_errors=True)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="agentos-netns", description="Per-agent network namespaces")
    parser.add_argument("action", choices=["setup", "teardown"])
    parser.add_argument("agent")
    args = parser.parse_args(argv)
    if not configmod.valid_agent_id(args.agent):
        print("invalid agent id", file=sys.stderr)
        return 2
    path = os.environ.get("AGENTOS_RUNTIME", "/etc/agentos/runtime.json")
    with open(path) as f:
        runtime = json.load(f)
    conf = dict(runtime["container"], agent_user=runtime["agent_user"], agent_home=runtime["agent_home"])
    ns = Netns(conf)
    try:
        if args.action == "setup":
            ns.setup(args.agent)
        else:
            ns.teardown(args.agent)
    except subprocess.CalledProcessError as exc:
        print("agentos-netns: %s: %s" % (" ".join(exc.cmd), (exc.stderr or "").strip()), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
