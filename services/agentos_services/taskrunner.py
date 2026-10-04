"""Root helper that runs one orchestrator task: agentos-task-runner <task-id>.

Started as agentos-task-runner@<task-id>.service. The orchestrator (user
agentos) may start that unit and nothing else as root, so this program is
the only thing an orchestrator compromise can reach. It therefore trusts
nothing in the task record:

  * the record is re-validated (agent known to /etc/agentos/runtime.json,
    workspace below the workspace root, prompt one argv element);
  * the command comes from the root-owned services.toml (task_commands),
    never from the record;
  * git runs as the agent user, not as root (repositories are writable by
    the agent, so their hooks and config must not run with root's rights);
  * the log file is created O_EXCL|O_NOFOLLOW in a directory the
    orchestrator can write to.

It then starts the agent in the same sandbox as `agentos spawn` (a
transient agentos-agent-<id>.service, see cli.nix cmd_spawn: read-only
system, hidden homes, workspace-only writes, resource limits), registers it
with the daemon so budgets, `agentos list` and auto-shutdown cover it,
captures its output in tasks_dir/<id>.log, and records the result.
"""

import argparse
import grp
import hashlib
import json
import logging
import os
import pwd
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

from . import config as configmod
from . import provenance as PV
from . import publish as P
from . import tasks as T
from .recorder import transcript_digest
from .store import Store, connect, utc_date
from .unixapi import call

log = logging.getLogger("agentos.taskrunner")

KILL_LOOKUP_SEC = 3


# Keep in step with HARDEN_PROPS in nixos/packages/cli.nix (see the comment there
# for what is left out on purpose: MemoryDenyWriteExecute, ProcSubset=pid).
HARDEN_PROPS = (
    "SystemCallFilter=@system-service",
    "SystemCallFilter=~@privileged @mount @module @raw-io @reboot @swap @obsolete @cpu-emulation @debug",
    "SystemCallErrorNumber=EPERM",
    "SystemCallArchitectures=native",
    "RestrictNamespaces=yes",
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
    "ProtectProc=invisible",
    "LockPersonality=yes",
    "RestrictRealtime=yes",
    "RestrictSUIDSGID=yes",
    "ProtectClock=yes",
    "ProtectControlGroups=yes",
    "ProtectKernelLogs=yes",
    "ProtectHostname=yes",
    "CapabilityBoundingSet=",
    "AmbientCapabilities=",
    "MemorySwapMax=0",
)


class RunnerError(Exception):
    pass


class TaskRunner:
    def __init__(self, cfg, runtime, tasks, clock=time.time, systemd_run="systemd-run",
                 systemctl="systemctl", drop_privileges=True, publisher=None, signer=None,
                 closure_path="/run/current-system"):
        self.cfg = cfg
        self.opts = T.settings(cfg, "orchestrator")
        self.runtime = runtime
        self.tasks = tasks
        self.clock = clock
        self.systemd_run = systemd_run
        self.systemctl = systemctl
        self.drop = drop_privileges
        self.state_dir = runtime.get("state_dir") or cfg["daemon"]["state_dir"]
        self.cancel = threading.Event()
        self.proc = None
        self.base_sha = None
        # publisher(publish_opts) -> P.Publisher; replaced in tests
        self.publisher = publisher or self._make_publisher
        self.prov_opts = PV.settings(cfg)
        self._signer = signer
        self.closure_path = closure_path
        self.envelope = None      # the provenance envelope of the task being run
        self.agent_exe = None
        self.pending_result = {}
        self.pushed_digest = None

    # ── helpers ────────────────────────────────────────────────────────
    def stop_unit(self, unit):
        subprocess.run([self.systemctl, "stop", unit], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=False, timeout=60)

    def _agent_ids(self):
        if not self.drop:
            return {}
        pw = pwd.getpwnam(self.runtime["agent_user"])
        return {"user": pw.pw_uid, "group": pw.pw_gid, "extra_groups": [pw.pw_gid]}

    def git(self, args, cwd, check=True):
        env = {"PATH": os.environ.get("PATH", ""), "HOME": self.runtime["agent_home"], "GIT_TERMINAL_PROMPT": "0", "LANG": "C.UTF-8"}
        res = subprocess.run(["git", *args], cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False,
                             **self._agent_ids())
        if check and res.returncode != 0:
            raise RunnerError("git %s failed: %s" % (" ".join(args[:2]), (res.stderr or "").strip()[:300]))
        return res

    def prepare_workspace(self, task):
        """Create the agent's branch. Returns (working dir, branch, writable paths)."""
        ws, branch = task["workspace"], "agent/" + task["id"]
        if self.git(["rev-parse", "--git-dir"], ws, check=False).returncode != 0:
            self.git(["init", "--quiet"], ws)
        head = self.git(["rev-parse", "--verify", "--quiet", "HEAD"], ws, check=False)
        self.base_sha = head.stdout.strip() if head.returncode == 0 else None
        if task.get("isolate"):
            # Concurrent agents cannot share one working tree: give this one
            # its own worktree (next to the workspace, so still under the root)
            if self.git(["rev-parse", "--verify", "--quiet", "HEAD"], ws, check=False).returncode != 0:
                self.git(["-c", "user.name=AgentOS", "-c", "user.email=agentos@localhost",
                          "commit", "--quiet", "--allow-empty", "-m", "Initialize workspace"], ws)
            self.base_sha = self.git(["rev-parse", "HEAD"], ws).stdout.strip()
            wt = os.path.join(os.path.dirname(ws), "%s.%s" % (os.path.basename(ws), task["id"]))
            if int(task.get("attempt") or 1) > 1:
                # A retry (orchestrator `max_retries`): start clean, drop the failed attempt's worktree and branch
                self.git(["worktree", "remove", "--force", wt], ws, check=False)
                self.git(["branch", "-D", branch], ws, check=False)
            self.git(["worktree", "add", "--quiet", "-b", branch, wt], ws)
            return wt, branch, [wt, os.path.join(ws, ".git")]
        exists = self.git(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], ws, check=False).returncode == 0
        args = ["checkout", "--quiet", branch] if exists else ["checkout", "--quiet", "-b", branch]
        if self.git(args, ws, check=False).returncode != 0:
            current = self.git(["branch", "--show-current"], ws, check=False).stdout.strip()
            log.warning("could not create %s; staying on %r", branch, current)
            branch = current
        return ws, branch, [ws]

    def register(self, task, unit, command, branch, workdir):
        """Write the daemon's registry entry (same shape as `agentos spawn`)."""
        state = {
            "id": task["id"], "agent": task["agent"], "command": command, "workspace": workdir,
            "branch": branch, "user": self.runtime["agent_user"], "operator": "agentos-orchestrator",
            "pid": os.getpid(), "sandboxed": True, "started_at": int(self.clock()), "status": "running",
            "unit": unit, "task": task["id"],
        }
        os.makedirs(self.state_dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.state_dir, prefix=".%s." % task["id"])
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2, sort_keys=True)
        os.chmod(tmp, 0o664)
        os.replace(tmp, os.path.join(self.state_dir, task["id"] + ".json"))

    def open_log(self, task_id):
        directory = self.opts["tasks_dir"]
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, task_id + ".log")
        try:
            os.unlink(path)  # a stale file or a planted symlink; never follow it
        except FileNotFoundError:
            pass
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
        try:
            os.fchown(fd, -1, grp.getgrnam("agentos").gr_gid)
        except (KeyError, PermissionError):
            pass
        return fd, path

    def agent_env(self, task, workdir, branch):
        env = {
            "AGENTOS_AGENT_ID": task["id"],
            "AGENTOS_TASK_ID": task["id"],
            "AGENTOS_WORKSPACE": workdir,
            "AGENTOS_BRANCH": branch,
        }
        if not self.runtime.get("gateway_enabled"):
            if task.get("budget_usd"):
                raise RunnerError("a task budget needs the model gateway (agentos.networking.enable)")
            return env
        base = self.runtime["gateway_url"]
        try:
            with urllib.request.urlopen(base + "/_agentos/health", timeout=5) as resp:
                health = json.load(resp)
        except (OSError, ValueError) as exc:
            raise RunnerError("model gateway is not responding at %s: %s" % (base, exc))
        # The gateway only answers agents presenting their registered token
        token = secrets.token_hex(32)
        status, body = call(self.runtime["admin_socket"], "PUT", "/_agentos/agents/" + task["id"],
                            {"token_sha256": hashlib.sha256(token.encode()).hexdigest()})
        if status != 200:
            raise RunnerError("could not register the task with the gateway: %s" % body)
        prefix = "%s/agent/%s:%s" % (base, task["id"], token)
        env["ANTHROPIC_BASE_URL"] = prefix + "/anthropic"
        env["OPENAI_BASE_URL"] = prefix + "/openai/v1"
        for provider in ("anthropic", "openai"):
            if health.get("providers", {}).get(provider, {}).get("managed_key"):
                env[provider.upper() + "_API_KEY"] = configmod.MANAGED_KEY
        if task.get("budget_usd"):
            status, body = call(self.runtime["admin_socket"], "PUT", "/_agentos/budget/" + task["id"],
                                {"daily_usd": task["budget_usd"]})
            if status != 200:
                raise RunnerError("could not set the task budget: %s" % body)
        return env

    def sandbox_args(self, unit, workdir, writable, env, timeout):
        """systemd-run options; keep in step with cmd_spawn in cli.nix."""
        limits = self.runtime.get("limits") or {}
        ncpu = os.cpu_count() or 1
        user = self.runtime["agent_user"]
        home = self.runtime["agent_home"]
        args = [
            "--quiet", "--collect", "--wait", "--pipe",
            "--unit=" + unit[:-len(".service")],
            "--uid=" + user, "--gid=" + user,
            "--working-directory=" + workdir,
            "-p", "MemoryMax=%dM" % limits.get("memory_mb", 4096),
            "-p", "CPUQuota=%d%%" % (limits.get("cpu_percent", 100) * ncpu),
            "-p", "TasksMax=%d" % limits.get("tasks_max", 1024),
            "-p", "NoNewPrivileges=yes",
            "-p", "PrivateTmp=yes",
            "-p", "ProtectSystem=strict",
            "-p", "ProtectHome=yes",
            "-p", "ReadWritePaths=%s %s" % (" ".join(writable), home),
            "-p", "ProtectKernelTunables=yes",
            "-p", "ProtectKernelModules=yes",
            "-p", "UMask=0002",
            # Backstop in case this helper dies before enforcing the timeout
            "-p", "RuntimeMaxSec=%d" % (timeout + 60),
            "--setenv=HOME=" + home,
            "--setenv=USER=" + user,
            "--setenv=PATH=" + self.opts["agent_path"],
            "--setenv=TERM=dumb",
            "--setenv=LANG=C.UTF-8",
        ]
        for prop in HARDEN_PROPS:
            args += ["-p", prop]
        args += ["--setenv=%s=%s" % kv for kv in env.items()]
        return args

    def killed_reason(self, task_id):
        """Why the daemon stopped this agent (budget), if it did."""
        deadline = time.time() + KILL_LOOKUP_SEC
        while True:
            for path in (os.path.join(self.state_dir, task_id + ".json"),
                         os.path.join(self.state_dir, "history", task_id + ".json")):
                try:
                    with open(path) as f:
                        state = json.load(f)
                except (OSError, ValueError):
                    continue
                if state.get("status") == "killed":
                    return state.get("reason") or "stopped"
            if time.time() >= deadline:
                return None
            time.sleep(0.25)

    # ── provenance (provenance.py) ─────────────────────────────────────
    def signer(self):
        if self._signer is None:
            self._signer = PV.Signer.load(self.prov_opts)
        return self._signer

    @staticmethod
    def _store_path(path):
        parts = (path or "").split("/")
        return "/".join(parts[:4]) if path and path.startswith("/nix/store/") and len(parts) >= 4 else path

    def build_envelope(self, task, result, sha, workdir, repo=None, pr_url=None, started=None):
        """Sign a statement about `sha`. Raises ProvenanceError."""
        signer = self.signer()
        tree = self.git(["rev-parse", sha + "^{tree}"], workdir, check=False).stdout.strip() or None
        dirty = bool(self.git(["status", "--porcelain"], workdir, check=False).stdout.strip())
        now = self.clock()
        started = started or task.get("started_at") or now
        dates = sorted({utc_date(t) for t in (started, now)})
        try:
            usage = self.tasks.store.agent_usage(task["id"], dates)
        except Exception as exc:  # no gateway/Redis books: the statement says so by being empty
            log.warning("task %s: no usage for provenance: %s", task["id"], exc)
            usage = {}
        recording = None
        digest, count = transcript_digest(self.cfg["recording"]["dir"], task["id"])
        if digest:
            recording = {"id": task["id"], "requests": count, "transcriptSha256": digest}
        judge = None
        if task.get("group"):
            meta = self.tasks.group_meta(task["group"]) or {}
            judge = {"group": task["group"], "role": task.get("role"), "winner": meta.get("winner"),
                     "judgeTask": meta.get("judge_task")}
        exe = self.agent_exe
        real = os.path.realpath(exe) if exe else None
        statement = PV.build_statement(
            commit=sha, tree=tree, pr_url=pr_url, repo=repo, branch="agent/" + task["id"], agent=task["agent"],
            agent_binary=real, agent_store_path=self._store_path(real),
            system_closure=os.path.realpath(self.closure_path) if os.path.exists(self.closure_path) else None,
            task=task, prompt=task.get("resolved_prompt") or task.get("prompt"),
            include_prompt=bool(self.prov_opts["include_prompt"]), usage=usage, verify=result.get("verify"),
            judge=judge, approval=task.get("approval"), recording=recording, started_at=started, finished_at=now,
            exit_code=result.get("exit_code"), dirty=dirty)
        return signer.sign(statement)

    def attest_callback(self, task, result, workdir, repo=None):
        """The `attest(commit)` hook for the publisher, or None when provenance is off.
        It returns an envelope; without a key it returns None, or refuses the publish
        when `require_for_publish` is set."""
        if not self.prov_opts["enable"]:
            return None

        def attest(sha):
            try:
                envelope = self.build_envelope(task, result, sha, workdir, repo=repo)
            except PV.ProvenanceError as exc:
                log.warning("task %s: no provenance: %s", task["id"], exc)
                if self.prov_opts["require_for_publish"]:
                    raise P.PublishError("provenance is required and could not be produced: %s" % exc, "provenance")
                return None
            self.envelope = envelope
            return envelope
        return attest

    def reuse_callback(self, envelope):
        """For a task of kind "publish": the dependency's envelope, if it still attests the commit."""
        if not self.prov_opts["enable"]:
            return None

        def attest(sha):
            problem = None
            try:
                signer = self.signer()
                res = PV.verify_envelope(envelope, {signer.keyid: signer.pub}, sha, check_paths=False) if envelope else None
                if res is None:
                    problem = "the task that produced the branch has no provenance"
                elif not res["ok"]:
                    problem = "its provenance does not match the commit being published"
            except PV.ProvenanceError as exc:
                problem = str(exc)
            if problem and self.prov_opts["require_for_publish"]:
                raise P.PublishError("provenance is required: %s" % problem, "provenance")
            return None if problem else envelope
        return attest

    def attest_unpublished(self, task, result, workdir, branch):
        """Provenance for a task that was not (or could not be) published: sign the
        branch tip and attach the note locally."""
        if not self.prov_opts["enable"] or self.envelope is not None or branch != "agent/" + task["id"]:
            return
        try:
            sha = self.git(["rev-parse", "--verify", "refs/heads/" + branch], workdir).stdout.strip()
            envelope = self.build_envelope(task, result, sha, workdir)
            PV.add_note(self.git, workdir, sha, envelope)
        except (PV.ProvenanceError, RunnerError) as exc:
            log.warning("task %s: no provenance: %s", task["id"], exc)
            return
        self.envelope = envelope

    def bind_pr(self, task, result, workdir):
        """Once a PR exists, re-sign with the PR as a second subject. The pushed note
        (and the PR body digest) keep the first envelope; this one is for the task result."""
        info = result.get("publish") or {}
        if self.envelope is None or info.get("status") != "published":
            return
        self.pushed_digest = info.get("provenance_digest")
        try:
            sha = PV.decode_payload(self.envelope)["subject"][0]["digest"]["gitCommit"]
            bound = self.build_envelope(task, result, sha, workdir, repo=info.get("repo"), pr_url=info.get("pr_url"))
            PV.add_note(self.git, workdir, sha, bound)
        except (PV.ProvenanceError, RunnerError) as exc:
            log.warning("task %s: could not bind the PR to the provenance: %s", task["id"], exc)
            return
        self.envelope = bound

    def provenance_fields(self):
        if self.envelope is None:
            return {}
        out = {"envelope": self.envelope, "sha256": PV.envelope_digest(self.envelope), "predicateType": PV.PREDICATE_TYPE}
        if self.pushed_digest:
            out["pushed_sha256"] = self.pushed_digest
        return {"provenance": out}

    # ── publishing (publish.py) ────────────────────────────────────────
    def _make_publisher(self, popts):
        return P.Publisher(popts, P.load_token(popts),
                           git=P.make_git(self._agent_ids(), {k: v for k, v in os.environ.items()
                                                    if k in ("PATH", "SSL_CERT_FILE", "GIT_SSL_CAINFO")}))

    def publish_marker(self, task_id):
        """A publish request recorded by the trigger service (see triggers.py)."""
        try:
            raw = self.tasks.r.get(self.tasks._k("publish", task_id))
            marker = json.loads(raw) if raw else None
        except Exception:
            return None
        return marker if isinstance(marker, dict) else None

    def try_publish(self, task, workdir, branch, base_sha, skip_reason=None):
        """Returns (result fields, error). The error is set only when the publish
        was asked for explicitly: such a task then fails, with the agent's output kept.
        With skip_reason (a failed verification) a requested publish is not attempted
        and the task keeps the agent's status."""
        popts = P.settings(self.cfg)
        try:
            spec = P.resolve_spec(task, popts, self.publish_marker(task["id"]))
        except P.PublishError as exc:
            return {"publish": {"status": "error", "error": str(exc)}}, str(exc)
        if spec is None:
            return {}, None
        if skip_reason:
            return {"publish": {"status": "skipped", "error": skip_reason}}, None
        if branch != "agent/" + task["id"]:
            msg = "task is not on its own branch"
            return {"publish": {"status": "skipped", "error": msg}}, (msg if spec["explicit"] else None)
        try:
            attest = self.attest_callback(task, self.pending_result, workdir, repo=spec["repo"])
            extra = {"attest": attest} if attest else {}
            info = self.publisher(popts).publish(spec, task["id"], workdir, branch, base_sha, **extra)
        except P.PublishError as exc:
            log.warning("task %s: publish %s: %s", task["id"], exc.code, exc)
            status = "skipped" if exc.code == "empty" and not spec["explicit"] else "error"
            fields = {"publish": {"status": status, "error": str(exc), "code": exc.code}}
            return fields, (str(exc) if spec["explicit"] else None)
        except Exception:  # never let a publish bug lose the agent's result
            log.exception("task %s: publish crashed", task["id"])
            return {"publish": {"status": "error", "error": "internal error"}}, "internal error"
        return {"pr_url": info["pr_url"], "publish": dict(info, status="published")}, None

    def run_publish_task(self, task):
        """A task of kind "publish": publish the branch a dependency produced."""
        task_id = task["id"]
        try:
            if not configmod.valid_agent_id(task_id):
                raise P.PublishError("malformed task record")
            workspace = T.resolve_workspace(task.get("workspace"), self.runtime["workspace_root"])
            source = {}
            for dep_id in task.get("depends_on") or task.get("after") or []:
                dep = self.tasks.get(dep_id) or {}
                if dep.get("status") == T.SUCCEEDED and (dep.get("result") or {}).get("branch"):
                    source = dep
                    break
            res = source.get("result") or {}
            if not res.get("branch"):
                raise P.PublishError("no successful dependency produced a branch to publish")
            popts = P.settings(self.cfg)
            spec = P.resolve_spec(dict(task, kind="publish", workspace=workspace,
                                       origin=task.get("origin") or source.get("origin")),
                                  popts, self.publish_marker(task_id))
            attest = self.reuse_callback(((res.get("provenance") or {}).get("envelope")))
            extra = {"attest": attest} if attest else {}
            info = self.publisher(popts).publish(spec, task_id, res.get("worktree") or workspace, res["branch"],
                                                 res.get("base_sha"), **extra)
        except (P.PublishError, T.ValidationError) as exc:
            self.tasks.finish(task_id, T.FAILED, error="publish refused: %s" % exc)
            log.error("task %s: %s", task_id, exc)
            return 1
        self.tasks.finish(task_id, T.SUCCEEDED, pr_url=info["pr_url"], branch=info["branch"],
                          publish=dict(info, status="published"), exit_code=0)
        return 0

    # ── verify contract (docs/orchestration.md) ────────────────────────
    GATEWAY_ENV = ("ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "OPENAI_API_KEY")

    def run_verify(self, task, workdir, writable, env):
        """Run task["verify"]["cmd"] as an argv (never a shell) in the agent's sandbox
        and user, in workdir, without the gateway credentials. Never raises."""
        verify = task["verify"]
        cmd0, timeout = verify["cmd"][0], verify["timeout_sec"]
        started = self.clock()

        def outcome(status, code, tail=""):
            return {"status": status, "exit_code": code, "output_tail": tail,
                    "duration_sec": round(self.clock() - started, 1)}

        if "/" in cmd0:
            exe = cmd0 if os.path.isabs(cmd0) else os.path.join(workdir, cmd0)
            exe = exe if os.path.isfile(exe) and os.access(exe, os.X_OK) else None
        else:
            exe = shutil.which(cmd0, path=self.opts["agent_path"])
        if not exe:
            return outcome("error", None, "%s is not installed" % cmd0)
        venv = {k: v for k, v in env.items() if k not in self.GATEWAY_ENV}
        unit = "agentos-verify-%s.service" % task["id"]
        cmd = [self.systemd_run] + self.sandbox_args(unit, workdir, writable, venv, timeout) + ["--", exe] + verify["cmd"][1:]
        tail_max = int(self.opts["result_tail_kb"]) * 1024
        tail = bytearray()
        try:
            self.proc = proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except OSError as exc:
            return outcome("error", None, "could not start the sandbox: %s" % exc)

        def pump():
            while True:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    break
                tail.extend(chunk)
                if len(tail) > tail_max:
                    del tail[:len(tail) - tail_max]

        pumper = threading.Thread(target=pump, daemon=True)
        pumper.start()
        reason = None
        while True:
            try:
                rc = proc.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                if self.cancel.is_set():
                    reason = "cancelled"
                elif self.clock() - started > timeout:
                    reason = "timed out after %ds" % timeout
                if reason:
                    self.stop_unit(unit)
                    try:
                        rc = proc.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        rc = proc.wait()
                    break
        pumper.join(timeout=10)
        text = tail.decode(errors="replace")
        if reason:
            return outcome("error", None, (text + "\n[agentos: verify %s]" % reason).strip()[-tail_max:])
        return outcome("passed" if rc == 0 else "failed", rc, text)

    # ── the run ────────────────────────────────────────────────────────
    def run(self, task_id):
        """Run one task to completion. Returns a process exit code."""
        task = self.tasks.get(task_id)
        if task is None:
            log.error("no such task: %s", task_id)
            return 2
        if task["status"] != T.RUNNING:
            log.error("task %s is %s, not running; refusing to start it", task_id, task["status"])
            return 3
        if task.get("kind") == "publish":
            return self.run_publish_task(task)
        try:
            task = T.validate_record(task, self.runtime, self.opts)
            template = T.task_command(self.opts, self.runtime, task["agent"])
            argv = T.render_argv(template, task["resolved_prompt"], task["workspace"], task["id"])
            exe = shutil.which(argv[0], path=self.opts["agent_path"])
            if not exe:
                raise RunnerError("%s is not installed" % argv[0])
            argv[0] = exe
            self.agent_exe, self.envelope, self.pushed_digest = exe, None, None
        except (T.ValidationError, RunnerError) as exc:
            self.tasks.finish(task_id, T.FAILED, error="rejected: %s" % exc)
            log.error("task %s rejected: %s", task_id, exc)
            return 1

        unit = "agentos-agent-%s.service" % task_id
        started = self.clock()
        log_fd = None
        try:
            workdir, branch, writable = self.prepare_workspace(task)
            env = self.agent_env(task, workdir, branch)
            self.register(task, unit, os.path.basename(exe), branch, workdir)
            log_fd, log_path = self.open_log(task_id)
        except (RunnerError, OSError) as exc:
            self.tasks.finish(task_id, T.FAILED, error="setup failed: %s" % exc)
            log.error("task %s: setup failed: %s", task_id, exc)
            return 1

        cmd = [self.systemd_run] + self.sandbox_args(unit, workdir, writable, env, task["timeout_sec"]) + ["--"] + argv
        tail = bytearray()
        tail_max = int(self.opts["result_tail_kb"]) * 1024
        cap = int(self.opts["log_cap_mb"]) * 1024 * 1024

        try:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        except OSError as exc:
            os.close(log_fd)
            self.tasks.finish(task_id, T.FAILED, error="could not start the sandbox: %s" % exc, branch=branch, log=log_path)
            return 1

        logf = os.fdopen(log_fd, "wb")

        def pump():
            written = 0
            while True:
                chunk = os.read(self.proc.stdout.fileno(), 65536)
                if not chunk:
                    break
                tail.extend(chunk)
                if len(tail) > tail_max:
                    del tail[:len(tail) - tail_max]
                if written < cap:
                    part = chunk[:cap - written]
                    logf.write(part)
                    logf.flush()
                    written += len(part)
                    if written >= cap:
                        logf.write(b"\n[agentos: log truncated at %d MB]\n" % (cap // (1024 * 1024)))
                        logf.flush()

        pumper = threading.Thread(target=pump, daemon=True)
        pumper.start()

        outcome = None
        while True:
            try:
                rc = self.proc.wait(timeout=0.5)
                break
            except subprocess.TimeoutExpired:
                if self.cancel.is_set():
                    outcome = T.CANCELLED
                elif self.clock() - started > task["timeout_sec"]:
                    outcome = T.TIMEOUT
                if outcome:
                    self.stop_unit(unit)
                    try:
                        rc = self.proc.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        self.proc.kill()
                        rc = self.proc.wait()
                    break
        pumper.join(timeout=10)
        logf.close()
        if outcome is None and self.cancel.is_set():
            outcome = T.CANCELLED  # the unit was stopped as part of a cancel

        error = None
        if outcome is None:
            if rc == 0:
                outcome = T.SUCCEEDED
            else:
                outcome = T.FAILED
                reason = self.killed_reason(task_id)
                error = "stopped: %s" % reason if reason else "exit code %d" % rc
        elif outcome == T.TIMEOUT:
            error = "timed out after %ds" % task["timeout_sec"]
        else:
            error = "cancelled by operator"
        result = {
            "exit_code": rc, "output_tail": tail.decode(errors="replace"), "branch": branch, "log": log_path,
            "duration_sec": round(self.clock() - started, 1),
            "worktree": workdir if workdir != task["workspace"] else None,
            "base_sha": self.base_sha,
        }
        if error:
            result["error"] = error
        skip = None
        if outcome == T.SUCCEEDED and task.get("verify"):
            result["verify"] = self.run_verify(task, workdir, writable, env)
            if result["verify"]["status"] != "passed":
                skip = "verify failed"
        if outcome == T.SUCCEEDED:
            self.pending_result = result
            fields, publish_error = self.try_publish(task, workdir, branch, self.base_sha, skip_reason=skip)
            result.update(fields)
            if publish_error:
                outcome, result["error"] = T.FAILED, "publish failed: %s" % publish_error
            else:
                self.attest_unpublished(task, result, workdir, branch)
            self.bind_pr(task, result, workdir)
            result.update(self.provenance_fields())
        self.tasks.finish(task_id, outcome, **result)
        try:
            self.tasks.store.publish({"type": "task_finished", "task": task_id, "agent": task_id,
                                      "status": outcome, "exit_code": rc})
        except Exception as exc:  # Redis down must not lose the result on disk
            log.warning("could not publish task_finished: %s", exc)
        log.info("task %s %s (exit %s)", task_id, outcome, rc)
        return 0 if outcome == T.SUCCEEDED else 1


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run one AgentOS orchestrator task (root helper)")
    parser.add_argument("task_id")
    parser.add_argument("--config", default=None, help="services.toml path")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s", stream=sys.stderr)
    if not configmod.valid_agent_id(args.task_id):
        print("invalid task id", file=sys.stderr)
        return 2
    cfg = configmod.load(args.config)
    opts = T.settings(cfg, "orchestrator")
    runtime = T.load_runtime(opts["runtime_file"])
    runner = TaskRunner(cfg, runtime, T.TaskStore(Store(connect(cfg["redis"]["url"]))))
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: runner.cancel.set())
    return runner.run(args.task_id)


if __name__ == "__main__":
    sys.exit(main())
