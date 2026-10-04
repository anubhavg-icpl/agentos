import ipaddress
import os
import pwd
import subprocess
import threading

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


def test_sweep_removes_only_stale(tmp_path):
    rec = Recorder()
    ns = make(tmp_path, rec)
    ns.netns_dir = str(tmp_path / "netns")
    os.makedirs(ns.netns_dir)
    for i in ("live", "dead", "mine"):
        (tmp_path / "netns" / ("agentos-" + i)).write_text("")
        os.makedirs(tmp_path / "net" / i)
    os.makedirs(tmp_path / "net" / "orphan")
    ns.is_live = lambda i: i == "live"
    ns.list_veths = lambda: [names("live")["host_if"], names("dead")["host_if"], "avhdeadbeef"]
    removed = ns.sweep(keep=("mine",))
    assert "live" not in removed and "mine" not in removed
    assert {"dead", "orphan", "avhdeadbeef"} <= set(removed)
    assert not (tmp_path / "net" / "dead").exists()
    assert (tmp_path / "net" / "live").exists() and (tmp_path / "net" / "mine").exists()
    assert ["ip", "link", "del", "avhdeadbeef"] in rec.calls
    assert ["ip", "netns", "del", "agentos-dead"] in rec.calls


def test_sweep_cannot_delete_a_veth_created_during_discovery(tmp_path):
    discovered = threading.Event()
    resume_sweep = threading.Event()
    veth_added = threading.Event()
    interfaces = set()
    deleted_active_veth = threading.Event()
    active_if = names("active")["host_if"]

    class CoordinatedRunner(Recorder):
        def __call__(self, cmd, check=True):
            super().__call__(cmd, check)
            if cmd[:3] == ["ip", "link", "add"]:
                interfaces.add(cmd[3])
                veth_added.set()
            elif cmd[:3] == ["ip", "link", "del"]:
                if cmd[3] == active_if and active_if in interfaces:
                    deleted_active_veth.set()
                interfaces.discard(cmd[3])

    ns = make(tmp_path, CoordinatedRunner())
    (tmp_path / "net/stale").mkdir(parents=True)

    def is_live(agent_id):
        if agent_id == "stale":
            discovered.set()
            resume_sweep.wait(2)
        return False

    ns.is_live = is_live
    ns.list_veths = lambda: list(interfaces)
    sweep_result = []
    sweep_thread = threading.Thread(target=lambda: sweep_result.extend(ns.sweep()))
    sweep_thread.start()
    assert discovered.wait(2)

    setup_thread = threading.Thread(target=lambda: ns.setup("active"))
    setup_thread.start()
    veth_added.wait(0.2)
    resume_sweep.set()
    setup_thread.join(2)
    sweep_thread.join(2)

    assert not setup_thread.is_alive() and not sweep_thread.is_alive()
    assert active_if in interfaces
    assert not deleted_active_veth.is_set()


def test_sweep_waits_for_a_setup_in_progress(tmp_path):
    import threading
    order = []
    started = threading.Event()
    other = {}

    def runner(cmd, check=True):
        if cmd[:3] == ["ip", "link", "add"]:
            started.set()
            t = threading.Thread(target=lambda: (other["ns"].sweep(), order.append("sweep")))
            other["t"] = t
            t.start()
            t.join(0.5)                     # the sweep must still be blocked on the lock
            order.append("setup-step")

    ns = make(tmp_path, runner)
    other["ns"] = make(tmp_path, lambda cmd, check=True: None)
    other["ns"].list_veths = lambda: [names("agent-a")["host_if"]]
    other["ns"].is_live = lambda i: False
    ns.setup("agent-a")
    other["t"].join(5)
    assert order == ["setup-step", "sweep"]


def test_setup_with_sweep_does_not_deadlock(tmp_path):
    ns = make(tmp_path)
    ns.list_veths = lambda: []
    assert str(ns.setup("agent-a", sweep=True)) == "10.200.0.2"
