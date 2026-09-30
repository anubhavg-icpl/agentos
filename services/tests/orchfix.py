"""Shared fixtures for the orchestrator, task runner and scheduler tests."""

import copy
import os
import subprocess

import pytest

from agentos_services import config as configmod
from agentos_services import tasks as T
from agentos_services.orchestrator import Orchestrator

TEMPLATES = {
    "fake": ["fake-agent", "{prompt}"],
    "claude": ["claude", "-p", "{prompt}"],
}


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class FakeSystemctl:
    """Records systemctl calls; `active` is the set of live runner units."""

    def __init__(self):
        self.calls = []
        self.active = set()
        self.fail_start = False

    def __call__(self, cmd, timeout=60):
        self.calls.append(cmd)
        rc, out, err = 0, "", ""
        if cmd[:3] == ["systemctl", "start", "--no-block"]:
            if self.fail_start:
                rc, err = 1, "Access denied"
            else:
                self.active.add(cmd[-1])
        elif cmd[:2] == ["systemctl", "stop"]:
            self.active.discard(cmd[-1])
        elif cmd[:2] == ["systemctl", "show"]:
            out = "active\n" if cmd[-1] in self.active else "inactive\n"
        return subprocess.CompletedProcess(cmd, rc, out, err)

    def started(self):
        return [c[-1] for c in self.calls if c[:3] == ["systemctl", "start", "--no-block"]]


@pytest.fixture
def runtime(tmp_path):
    root = tmp_path / "workspaces"
    (root / "demo").mkdir(parents=True)
    (root / "other").mkdir()
    return {
        "agents": {"fake": "fake-agent", "claude": "claude", "claude-code": "claude", "noplan": "noplan"},
        "max_agents": 8,
        "workspace_root": str(root),
        "state_dir": str(tmp_path / "state"),
        "agent_user": "agentos-agent",
        "agent_home": str(tmp_path / "home"),
        "gateway_enabled": False,
        "limits": {},
    }


@pytest.fixture
def cfg(tmp_path, runtime):
    c = copy.deepcopy(configmod.DEFAULTS)
    c["daemon"]["state_dir"] = runtime["state_dir"]
    c["orchestrator"] = {
        "max_workers": 2, "start_grace_sec": 0, "tasks_dir": str(tmp_path / "tasks"),
        "task_commands": copy.deepcopy(TEMPLATES),
    }
    return c


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def systemctl():
    return FakeSystemctl()


@pytest.fixture
def taskstore(store):
    return T.TaskStore(store)


@pytest.fixture
def orch(cfg, taskstore, runtime, clock, systemctl):
    return Orchestrator(cfg, taskstore, runtime=runtime, clock=clock, runner=systemctl,
                        agents_running=lambda exclude: 0)


def submit(orch, **fields):
    body = {"agent": "fake", "workspace": "demo", "prompt": "do it"}
    body.update(fields)
    return orch.submit(body)


def complete(orch, task_id, status=T.SUCCEEDED, output="", **result):
    """What the root task runner does when the agent finishes."""
    orch.tasks.finish(task_id, status, output_tail=output, exit_code=0 if status == T.SUCCEEDED else 1, **result)
    orch.run_cmd.active.discard(orch.unit(task_id))


def statuses(orch, ids):
    return [orch.tasks.get(i)["status"] for i in ids]


def is_executable(path):
    return os.path.isfile(path) and os.access(path, os.X_OK)
