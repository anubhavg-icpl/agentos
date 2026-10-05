"""The AgentOS herdr plugin (integrations/herdr-plugin): manifest and panel script."""

import os
import pathlib
import stat
import subprocess
import tomllib

import pytest

PLUGIN = pathlib.Path(__file__).resolve().parents[2] / "integrations" / "herdr-plugin"

# The nix build of this package only sees services/; these run in the dev shell
pytestmark = pytest.mark.skipif(not PLUGIN.is_dir(), reason="integrations/herdr-plugin is not in this source tree")


def test_manifest_is_valid_and_points_at_the_script():
    m = tomllib.loads((PLUGIN / "herdr-plugin.toml").read_text())
    assert m["id"] == "agentos.dashboard" and m["platforms"] == ["linux"]
    for key in ("name", "version", "min_herdr_version"):
        assert m[key]
    panes = {p["id"] for p in m["panes"]}
    assert {"tasks", "factory", "budget", "approve", "cancel"} <= panes
    for item in m["panes"] + m["actions"]:
        assert item["command"][0] == "sh" and item["command"][1] == "panel.sh"
        assert (PLUGIN / item["command"][1]).is_file()
    # every action opens a pane that exists
    for a in m["actions"]:
        assert a["command"][2] == "open" and a["command"][3] in panes


@pytest.fixture
def bindir(tmp_path):
    d = tmp_path / "bin"
    d.mkdir()
    (d / "agentos-task").write_text(
        '#!/bin/sh\necho "agentos-task $*" >> "$CALLS"\n'
        'case "$1 $2" in "list --status") echo "t-123 awaiting_approval";; esac\n')
    (d / "agentos-task").chmod((d / "agentos-task").stat().st_mode | stat.S_IEXEC)
    return d


def panel(args, stdin, bindir, tmp_path, with_cli=True):
    env = {"PATH": (f"{bindir}:" if with_cli else "") + os.environ["PATH"], "CALLS": str(tmp_path / "calls"),
           "HERDR_BIN_PATH": "/bin/echo", "HERDR_PLUGIN_ID": "agentos.dashboard"}
    p = subprocess.run(["sh", str(PLUGIN / "panel.sh"), *args], input=stdin, capture_output=True, text=True,
                       env={**os.environ, **env}, timeout=30)
    calls = (tmp_path / "calls").read_text().splitlines() if (tmp_path / "calls").exists() else []
    return p, calls


def test_approve_asks_for_an_id_and_calls_the_cli(bindir, tmp_path):
    p, calls = panel(["approve"], "t-123\n\n", bindir, tmp_path)
    assert p.returncode == 0 and "t-123 awaiting_approval" in p.stdout
    assert calls == ["agentos-task list --status awaiting_approval", "agentos-task approve t-123"]


@pytest.mark.parametrize("bad", ["", "../etc", "a b", "x;rm -rf /", "$(id)", "-rf"])
def test_approve_rejects_anything_but_a_task_id(bindir, tmp_path, bad):
    p, calls = panel(["approve"], bad + "\n\n", bindir, tmp_path)
    assert not any(c.startswith("agentos-task approve") for c in calls)


def test_cancel_needs_confirmation(bindir, tmp_path):
    p, calls = panel(["cancel"], "t-9\nn\n\n", bindir, tmp_path)
    assert "left running" in p.stdout and not any("cancel" in c for c in calls)
    p, calls = panel(["cancel"], "t-9\ny\n\n", bindir, tmp_path)
    assert "agentos-task cancel t-9" in calls


def test_missing_cli_is_reported_not_fatal(bindir, tmp_path):
    p, calls = panel(["approve"], "t-1\n\n", bindir, tmp_path, with_cli=False)
    assert p.returncode == 0 and "agentos-task is not installed" in p.stdout and calls == []


def test_open_runs_herdr_with_the_entrypoint(bindir, tmp_path):
    p, _ = panel(["open", "tasks"], "", bindir, tmp_path)
    assert p.stdout.strip() == "plugin pane open --plugin agentos.dashboard --entrypoint tasks"
    p, _ = panel(["open", "../x"], "", bindir, tmp_path)
    assert p.returncode == 2


def test_unknown_command_fails(bindir, tmp_path):
    p, _ = panel(["frobnicate"], "", bindir, tmp_path)
    assert p.returncode == 2
