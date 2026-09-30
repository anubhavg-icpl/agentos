import ipaddress
import os
import pwd
import subprocess

import pytest

from agentos_services import netns
from agentos_services.netns import Netns, allocate_ip, names

NET = ipaddress.ip_network("10.200.0.0/24")
GW = ipaddress.ip_address("10.200.0.1")


class Recorder:
    def __init__(self, fail_on=None):
        self.calls = []
        self.fail_on = fail_on

    def __call__(self, cmd, check=True):
        self.calls.append(cmd)
        if check and self.fail_on and cmd[:len(self.fail_on)] == self.fail_on:
            raise subprocess.CalledProcessError(1, cmd, stderr="boom")


def make(tmp_path, runner=None):
    conf = {"bridge": "agentos0", "bridge_address": "10.200.0.1", "network": "10.200.0.0/24",
            "agent_user": pwd.getpwuid(os.getuid()).pw_name, "agent_home": "/home/agent"}
    return Netns(conf, state_dir=str(tmp_path / "net"), runner=runner or Recorder())


def test_names_fit_interface_limit():
    n = names("claude-20260101-120000-abcd")
    assert len(n["host_if"]) <= 15 and len(n["peer_if"]) <= 15
    assert n["ns"] == "agentos-claude-20260101-120000-abcd"
    assert names("a")["host_if"] != names("b")["host_if"]


def test_allocate_ip_skips_gateway_and_used():
    assert str(allocate_ip([], NET, GW)) == "10.200.0.2"
    used = [ipaddress.ip_address("10.200.0.2"), ipaddress.ip_address("10.200.0.4")]
    assert str(allocate_ip(used, NET, GW)) == "10.200.0.3"
    with pytest.raises(RuntimeError):
        allocate_ip(list(NET.hosts()), NET, GW)


def test_setup_and_teardown(tmp_path):
    rec = Recorder()
    ns = make(tmp_path, rec)
    a = ns.setup("agent-a")
    b = ns.setup("agent-b")
    assert (str(a), str(b)) == ("10.200.0.2", "10.200.0.3")
    joined = [" ".join(c) for c in rec.calls]
    assert any(c.startswith("ip netns add agentos-agent-a") for c in joined)
    assert any("route add default via 10.200.0.1" in c for c in joined)
    assert any(c.startswith("bridge link set dev") and c.endswith("isolated on") for c in joined)
    d = tmp_path / "net/agent-a"
    assert (d / "resolv.conf").read_text() == "nameserver 10.200.0.1\n"
    assert (d / "ip").read_text().strip() == "10.200.0.2"
    assert "nobody" in (d / "passwd").read_text()

    rec.calls.clear()
    ns.teardown("agent-a")
    assert not d.exists()
    assert [c[:3] for c in rec.calls] == [["ip", "link", "del"], ["ip", "netns", "del"]]
    # the freed address is reused; tearing down twice is harmless
    ns.teardown("agent-a")
    assert str(ns.setup("agent-c")) == "10.200.0.2"


def test_setup_failure_rolls_back(tmp_path):
    rec = Recorder(fail_on=["bridge", "link", "set"])
    ns = make(tmp_path, rec)
    with pytest.raises(subprocess.CalledProcessError):
        ns.setup("agent-a")
    assert not (tmp_path / "net/agent-a").exists()
    assert ["ip", "netns", "del", "agentos-agent-a"] in rec.calls


def test_main_rejects_bad_id():
    assert netns.main(["setup", "../x"]) == 2
