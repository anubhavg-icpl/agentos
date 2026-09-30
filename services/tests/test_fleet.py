import json
import os
import shlex
import sys

import pytest

from agentos_services import fleet

FAKE_SSH = r"""
import json, os, sys
with open(os.environ["FAKE_SSH_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
dest = [a for a in sys.argv[1:] if "@" in a or a.startswith("host")][0]
if "down" in dest:
    sys.stderr.write("ssh: connect to host down port 22: Connection refused\n")
    sys.exit(255)
if os.environ.get("FAKE_SSH_STATUS") and "@@services" in " ".join(sys.argv):
    print(open(os.environ["FAKE_SSH_STATUS"]).read())
"""

STATUS_OUT = """@@services
agentos-daemon active
agentos-model-gateway active
redis-agentos active
@@budget
{"date": "2026-09-30", "global_usd": 1.5, "global_limit_usd": 500.0, "agents": {}}

@@state
{
  "id": "claude-1",
  "agent": "claude",
  "status": "running",
  "workspace": "/var/lib/agentos/workspaces/demo",
  "branch": "agent/claude-1"
}{"id": "codex-1", "agent": "codex", "status": "killed"}
"""


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTOS_FLEET_SYSTEM", str(tmp_path / "system.json"))
    monkeypatch.setenv("AGENTOS_FLEET_USER", str(tmp_path / "config" / "fleet.json"))
    script = tmp_path / "fake_ssh.py"
    script.write_text(FAKE_SSH)
    monkeypatch.setenv("AGENTOS_FLEET_SSH", "%s %s" % (shlex.quote(sys.executable), shlex.quote(str(script))))
    monkeypatch.setenv("FAKE_SSH_LOG", str(tmp_path / "ssh.log"))
    status = tmp_path / "status.txt"
    status.write_text(STATUS_OUT)
    monkeypatch.setenv("FAKE_SSH_STATUS", str(status))
    return tmp_path


def ssh_calls(tmp_path):
    try:
        return [json.loads(l) for l in (tmp_path / "ssh.log").read_text().splitlines()]
    except FileNotFoundError:
        return []


def test_add_list_remove(env, capsys):
    assert fleet.main(["add", "build1", "ops@10.0.0.5", "--port", "2222"]) == 0
    assert fleet.main(["add", "build2", "example.org"]) == 0
    hosts = fleet.load_hosts()
    assert hosts["build1"] == {"address": "10.0.0.5", "user": "ops", "port": 2222, "source": "local"}
    assert hosts["build2"]["user"] is None and hosts["build2"]["port"] == 22
    capsys.readouterr()
    assert fleet.main(["list"]) == 0
    out = capsys.readouterr().out
    assert "build1" in out and "ops@10.0.0.5" in out and "2222" in out
    assert fleet.main(["remove", "build1"]) == 0
    assert "build1" not in fleet.load_hosts()
    assert fleet.main(["remove", "build1"]) == 2


def test_declarative_hosts_win_and_are_read_only(env):
    (env / "system.json").write_text(json.dumps({"hosts": {"prod": {"address": "prod.example", "user": "admin", "port": 22}}}))
    assert fleet.load_hosts()["prod"]["source"] == "declarative"
    assert fleet.main(["add", "prod", "x@y.example"]) == 2
    assert fleet.main(["remove", "prod"]) == 2
    fleet.main(["add", "extra", "z.example"])
    assert set(fleet.load_hosts()) == {"prod", "extra"}


@pytest.mark.parametrize("name,target", [
    ("Bad Name", "a@b.example"),
    ("ok", "-oProxyCommand=evil"),
    ("ok", "a@-bad"),
    ("ok", "a b@host"),
    ("ok", "root@host;rm"),
    ("-x", "host"),
])
def test_rejects_option_injection_and_bad_names(env, name, target):
    try:
        rc = fleet.main(["add", name, target])
    except SystemExit as exc:  # argparse itself refuses arguments that look like options
        rc = exc.code
    assert rc == 2
    assert fleet.load_hosts() == {}


def test_rejects_bad_port(env):
    assert fleet.main(["add", "h", "host.example", "--port", "70000"]) == 2


def test_ssh_argv_keeps_host_key_checking(env):
    host = {"address": "h.example", "user": "ops", "port": 2200}
    argv = fleet.ssh_argv(host, "true", tty=True, batch=True)
    assert argv[-2:] == ["ops@h.example", "true"]
    assert "-t" in argv and "BatchMode=yes" in argv and ["-p", "2200"] == argv[argv.index("-p"):argv.index("-p") + 2]
    assert not any("StrictHostKeyChecking" in a or "UserKnownHostsFile" in a for a in argv)


def test_remote_command_quotes_arguments():
    remote = fleet.remote_command(["agentos", "spawn", "claude", "--workspace", "my ws; rm -rf /"])
    inner = shlex.split(remote)
    assert inner[:2] == ["sh", "-c"]
    assert shlex.split(inner[2].split("exec ", 1)[1]) == ["agentos", "spawn", "claude", "--workspace", "my ws; rm -rf /"]


def test_parse_status():
    parsed = fleet.parse_status(STATUS_OUT)
    assert parsed["services"]["agentos-daemon"] == "active"
    assert parsed["budget"]["global_usd"] == 1.5
    assert [a["id"] for a in parsed["agents"]] == ["claude-1", "codex-1"]


def test_parse_status_tolerates_missing_sections():
    parsed = fleet.parse_status("@@services\nagentos-daemon inactive\n@@budget\n\n@@state\n")
    assert parsed["budget"] is None and parsed["agents"] == []


def test_status_aggregates_hosts(env, capsys):
    fleet.main(["add", "alpha", "ops@host-a"])
    fleet.main(["add", "beta", "ops@down-b"])
    capsys.readouterr()
    assert fleet.main(["status"]) == 1  # one host is down
    out = capsys.readouterr().out
    lines = {l.split()[0]: l for l in out.splitlines() if len(l.split()) > 1 and l.split()[1] in ("host-a", "down-b")}
    lines = {"alpha" if "host-a" in l.split()[1] else "beta": l for l in lines.values()}
    assert "up" in lines["alpha"] and "$1.50 / $500" in lines["alpha"]
    assert "DOWN" in lines["beta"] and "Connection refused" in lines["beta"]
    assert "agent/claude-1" in out

    assert fleet.main(["status", "alpha", "--json"]) == 0
    data = json.loads(capsys.readouterr().out)
    assert data[0]["agents_running"] == 1 and data[0]["services_ok"] is True
    # every status call was non-interactive
    assert all("BatchMode=yes" in c for c in ssh_calls(env))


def test_status_unknown_host(env):
    assert fleet.main(["status", "nope"]) == 2


def test_spawn_uses_tty_and_forwards_args(env):
    fleet.main(["add", "alpha", "ops@host-a", "--port", "2022"])
    assert fleet.main(["spawn", "alpha", "claude", "--budget", "5", "--", "-p", "fix it"]) == 0
    call = ssh_calls(env)[-1]
    assert "-t" in call and "ops@host-a" in call
    inner = shlex.split(shlex.split(call[-1])[2].split("exec ", 1)[1])
    assert inner == ["agentos", "spawn", "claude", "--budget", "5", "--", "-p", "fix it"]


def test_run_passes_command(env):
    fleet.main(["add", "alpha", "ops@host-a"])
    assert fleet.main(["run", "alpha", "--", "agentos", "list"]) == 0
    call = ssh_calls(env)[-1]
    assert shlex.split(call[-1])[2].endswith("exec agentos list")
    assert fleet.main(["run", "alpha"]) == 2
