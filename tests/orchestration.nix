# VM test of the orchestrator and the scheduler.
#
#   nix build .#checks.x86_64-linux.orchestration
#
# Boots a VM with the runtime, gateway, orchestrator and scheduler. A fake
# headless agent calls the (mock) model API through the gateway, and tasks
# are submitted as an operator who has no sudo:
#
#   single task -> 2-step pipeline ({prev_result}) -> a gated task that
#   only runs once approved from the CLI -> a 3-node DAG with fan-in
#   ({nodes.<name>.result}) -> swarm of 2 (own worktree and branch each) ->
#   timeout / cancel / failed dependency -> a schedule firing -> what the
#   orchestrator user may and may not do
{ pkgs, nestloModules }:

let
  # Mock of the Anthropic Messages API: $2 per request at claude-sonnet-5-5 prices
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            data = json.dumps({
                "id": "msg_test", "type": "message",
                "model": body.get("model", "claude-sonnet-5-5"),
                "content": [{"type": "text", "text": "ok"}],
                "usage": {"input_tokens": 1000000, "output_tokens": 0},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
  '';

  # A headless "coding agent": one model call through the gateway, a file in
  # its workspace, and behaviour selected by the prompt.
  fakeTaskAgent = pkgs.writeShellApplication {
    name = "fake-task-agent";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      prompt="$1"
      echo "user=$(id -un) task=$NESTLO_TASK_ID cwd=$PWD branch=$NESTLO_BRANCH"
      echo "prompt=[$prompt]"
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "x-api-key: $ANTHROPIC_API_KEY" -H 'content-type: application/json' \
        -d '{"model": "claude-sonnet-5-5", "max_tokens": 16, "messages": []}' \
        "$ANTHROPIC_BASE_URL/v1/messages")
      echo "gateway=$code key=$ANTHROPIC_API_KEY"
      printf '%s\n' "$prompt" > "note-$NESTLO_TASK_ID.txt"
      case "$prompt" in
        *SLEEP*) sleep 600 ;;
        *FAIL*) exit 3 ;;
        *EMIT*) echo "TOKEN=xyzzy-42" ;;
      esac
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "nestlo-orchestration";
  globalTimeout = 3600;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    # An operator without sudo: tasks must not need it
    users.users.ops.isNormalUser = true;
    security.sudo.wheelNeedsPassword = false;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "admin" "ops" ];
        agents.fake = "fake-task-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      orchestration = {
        enable = true;
        maxWorkers = 2;
        taskCommands.fake = [ "fake-task-agent" "{prompt}" ];
      };
      scheduler = {
        enable = true;
        schedules.weekly-report = {
          calendar = "Sun 03:00";
          agent = "fake";
          workspace = "sched";
          prompt = "weekly report";
          budgetUSD = 5;
        };
      };
    };

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };

    environment.systemPackages = [ fakeTaskAgent pkgs.jq ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-model-gateway.service" ];
      serviceConfig.ExecStart = "${mockLlm}/bin/mock-llm";
    };
  };

  testScript = ''
    import json

    def as_user(user, cmd):
        return machine.succeed(f"su - {user} -c {json.dumps(cmd)}")

    def ops(cmd):
        return as_user("ops", cmd)

    def submit(*args):
        out = ops("nestlo-task submit --agent fake " + " ".join(args) + " 2>/dev/null")
        return out.split()

    def show(task_id):
        return json.loads(ops(f"nestlo-task show {task_id} --json"))

    def wait_for(task_id, statuses, timeout=180):
        machine.wait_until_succeeds(
            f"su - ops -c 'nestlo-task show {task_id} --json' | jq -e '[.status] | inside({json.dumps(statuses)})'",
            timeout=timeout,
        )
        return show(task_id)

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-nestlo.service", "nestlo-model-gateway.service", "nestlo-daemon.service",
                 "nestlo-orchestrator.service", "nestlo-scheduler.service", "mock-llm.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)
    machine.wait_until_succeeds("test -S /run/nestlo-orchestrator/orchestrator.sock")
    machine.wait_until_succeeds("test -S /run/nestlo-scheduler/scheduler.sock")
    for name in ["demo", "swarm", "sched"]:
        as_user("admin", f"nestlo workspace create {name}")

    with subtest("a single task runs sandboxed, metered and budgeted, without sudo"):
        machine.fail("su - ops -c 'sudo -n true'")
        (tid,) = submit("--workspace demo --prompt 'hello there' --budget 5")
        task = wait_for(tid, ["succeeded", "failed"])
        print(task)
        assert task["status"] == "succeeded", task
        out = task["result"]["output_tail"]
        assert "user=nestlo-agent" in out and f"task={tid}" in out, out
        assert "gateway=200 key=nestlo-managed" in out, out
        assert task["result"]["branch"] == f"agent/{tid}", task
        assert "prompt=[hello there]" in ops(f"nestlo-task logs {tid}")
        machine.succeed(f"test -f /var/lib/nestlo/workspaces/demo/note-{tid}.txt")
        budget = json.loads(ops("nestlo budget status --json"))
        assert abs(budget["agents"][tid]["usd"] - 2.0) < 1e-6, budget
        assert budget["agents"][tid]["limit_usd"] == 5.0, budget

    with subtest("pipeline: the second step sees the first step's output and starts after it"):
        (first,) = submit("--workspace demo --prompt 'EMIT a token'")
        (second,) = submit("--workspace demo --after", first, "--prompt 'verify: {prev_result}'")
        a = wait_for(first, ["succeeded", "failed"])
        b = wait_for(second, ["succeeded", "failed"])
        assert a["status"] == b["status"] == "succeeded", (a, b)
        assert "TOKEN=xyzzy-42" in b["resolved_prompt"], b
        assert "TOKEN=xyzzy-42" in b["result"]["output_tail"], b
        assert b["started_at"] >= a["finished_at"], (a, b)

    with subtest("approval gate: nothing runs until the task is approved from the CLI"):
        (gated,) = submit("--workspace demo --prompt 'EMIT gated' --gate")
        (rejected,) = submit("--workspace demo --prompt 'EMIT never' --gate")
        (child,) = submit("--workspace demo --after", rejected, "--prompt 'never: {prev_result}'")
        machine.sleep(5)
        t = show(gated)
        assert t["status"] == "awaiting_approval" and t["started_at"] is None, t
        machine.fail(f"systemctl is-active nestlo-task-runner@{gated}.service")
        machine.fail(f"test -e /var/lib/nestlo/tasks/{gated}.log")
        # a task awaiting approval holds no worker slot: both slots stay free for other work
        (free_a,) = submit("--workspace swarm --isolate --prompt 'EMIT slot a'")
        (free_b,) = submit("--workspace swarm --isolate --prompt 'EMIT slot b'")
        for i in (free_a, free_b):
            assert wait_for(i, ["succeeded", "failed"])["status"] == "succeeded"
        assert show(gated)["status"] == "awaiting_approval"
        # approving something that is not gated, or a task that does not exist, is refused
        machine.fail(f"su - ops -c 'nestlo-task approve {free_a}'")
        machine.fail("su - ops -c 'nestlo-task approve task-nosuch'")
        ops(f"nestlo-task approve {gated} --note 'looks fine'")
        t = wait_for(gated, ["succeeded", "failed"])
        assert t["status"] == "succeeded", t
        # the approver is the kernel-reported caller, with the time and the note
        assert t["approval"]["decision"] == "approved" and t["approval"]["by"] == "ops", t
        assert t["approval"]["note"] == "looks fine" and t["approval"]["at"] <= t["started_at"], t
        machine.fail(f"su - ops -c 'nestlo-task approve {gated}'")
        # rejecting cancels the task and what depends on it
        ops(f"nestlo-task reject {rejected} --note 'not today'")
        assert show(rejected)["status"] == "cancelled" and show(rejected)["approval"]["decision"] == "rejected"
        assert wait_for(child, ["cancelled"])["status"] == "cancelled"
        machine.fail(f"test -e /var/lib/nestlo/tasks/{rejected}.log")

    with subtest("workflow: a 3-node DAG whose last node waits for both parents"):
        wf = {"nodes": {
            "left": {"agent": "fake", "workspace": "swarm", "isolate": True, "prompt": "EMIT left"},
            "right": {"agent": "fake", "workspace": "swarm", "isolate": True, "prompt": "EMIT right"},
            "join": {"agent": "fake", "workspace": "swarm", "isolate": True, "depends_on": ["left", "right"],
                     "prompt": "joined: {nodes.left.result} || {nodes.right.result}"},
            "cleanup": {"agent": "fake", "workspace": "swarm", "isolate": True, "depends_on": ["join"],
                        "when": "any_failed", "prompt": "only after a failure"},
        }}
        machine.succeed("printf '%s' " + json.dumps(json.dumps(wf)) + " > /tmp/wf.json && chmod 644 /tmp/wf.json")
        out = ops("nestlo-task workflow submit /tmp/wf.json 2>/dev/null").split()
        group = out[0]
        assert group.startswith("wf-"), out
        machine.wait_until_succeeds(
            f"su - ops -c 'nestlo-task workflow status {group} --json' | "
            "jq -e '.tasks | (length == 4) and all(.[]; if .node == \"cleanup\" then .status == \"skipped\" else .status == \"succeeded\" end)'",
            timeout=240,
        )
        wfs = json.loads(ops(f"nestlo-task workflow status {group} --json"))
        by = {n: json.loads(ops(f"nestlo-task show {i} --json")) for n, i in wfs["nodes"].items()}
        assert set(by) == {"left", "right", "join", "cleanup"}, by.keys()
        assert by["join"]["started_at"] >= max(by["left"]["finished_at"], by["right"]["finished_at"]), by
        assert by["join"]["resolved_prompt"].count("TOKEN=xyzzy-42") == 2, by["join"]["resolved_prompt"]
        # `when: any_failed` is false when everything succeeded
        assert by["cleanup"]["status"] == "skipped" and "condition not met" in by["cleanup"]["result"]["error"], by["cleanup"]
        # a cyclic or unknown-dependency workflow is refused and creates nothing
        bad = {"nodes": {"x": {"agent": "fake", "workspace": "swarm", "prompt": "x", "depends_on": ["y"]},
                         "y": {"agent": "fake", "workspace": "swarm", "prompt": "y", "depends_on": ["x"]}}}
        machine.succeed("printf '%s' " + json.dumps(json.dumps(bad)) + " > /tmp/bad.json && chmod 644 /tmp/bad.json")
        machine.fail("su - ops -c 'nestlo-task workflow submit /tmp/bad.json'")

    with subtest("swarm: two agents on one prompt, each in its own worktree and branch"):
        ids = submit("--workspace swarm --swarm 2 --prompt 'same prompt for all'")
        assert len(ids) == 2, ids
        done = [wait_for(i, ["succeeded", "failed"]) for i in ids]
        assert all(t["status"] == "succeeded" for t in done), done
        assert done[0]["group"] == done[1]["group"] and done[0]["group"].startswith("swarm-"), done
        branches = {t["result"]["branch"] for t in done}
        assert branches == {f"agent/{i}" for i in ids}, branches
        trees = {t["result"]["worktree"] for t in done}
        assert len(trees) == 2, trees
        for t in done:
            machine.succeed(f"test -f {t['result']['worktree']}/note-{t['id']}.txt")
            ops(f"git -C /var/lib/nestlo/workspaces/swarm rev-parse --verify {t['result']['branch']}")
        summary = ops(f"nestlo-task show {done[0]['group']}")
        assert "2 succeeded" in summary, summary
        listing = ops("nestlo list")
        assert all(i in listing for i in ids), listing

    with subtest("timeout, cancel and failed dependencies"):
        (slow,) = submit("--workspace demo --prompt 'SLEEP' --timeout 5")
        t = wait_for(slow, ["timeout", "succeeded", "failed"])
        assert t["status"] == "timeout", t
        machine.fail(f"systemctl is-active nestlo-agent-{slow}.service")

        (long_run,) = submit("--workspace demo --prompt 'SLEEP'")
        wait_for(long_run, ["running"])
        machine.wait_until_succeeds(f"systemctl is-active nestlo-agent-{long_run}.service")
        ops(f"nestlo-task cancel {long_run}")
        t = wait_for(long_run, ["cancelled"])
        machine.wait_until_fails(f"systemctl is-active nestlo-agent-{long_run}.service")

        (bad,) = submit("--workspace demo --prompt 'FAIL'")
        (after_bad,) = submit("--workspace demo --after", bad, "--prompt 'never runs'")
        assert wait_for(bad, ["failed"])["result"]["exit_code"] == 3
        skipped = wait_for(after_bad, ["skipped"])
        assert "failed" in skipped["result"]["error"], skipped

    with subtest("hostile input is refused or passed through as plain text"):
        for args in ["--workspace /etc --prompt x", "--workspace ../../etc --prompt x",
                     "--workspace demo --prompt '--dangerously-skip-permissions'",
                     "--workspace demo --prompt x --timeout 0"]:
            machine.fail("su - ops -c " + json.dumps("nestlo-task submit --agent fake " + args))
        machine.fail("su - ops -c 'nestlo-task submit --agent nosuchagent --workspace demo --prompt x'")
        machine.succeed("printf '%s' \"\\$(touch /var/lib/nestlo/workspaces/demo/pwned); echo 'x' > /tmp/pwned\" > /tmp/evil.txt")
        machine.succeed("chmod 644 /tmp/evil.txt")
        (evil,) = submit("--workspace demo --prompt-file /tmp/evil.txt")
        t = wait_for(evil, ["succeeded", "failed"])
        assert t["status"] == "succeeded" and "prompt=[$(touch" in t["result"]["output_tail"], t
        machine.fail("test -e /var/lib/nestlo/workspaces/demo/pwned")
        machine.fail("test -e /tmp/pwned")

    with subtest("the orchestrator user can start task runners and nothing else"):
        machine.succeed("su -s /bin/sh nestlo -c 'systemctl start --no-block nestlo-task-runner@nonexistent.service'")
        machine.fail("su -s /bin/sh nestlo -c 'systemctl restart nestlo-daemon.service'")
        machine.fail("su -s /bin/sh nestlo -c 'systemctl start --no-block sshd.service'")
        machine.fail("su -s /bin/sh nestlo -c 'sudo -n true'")
        # the sandboxed agent user cannot reach the orchestrator
        machine.fail("su -s /bin/sh nestlo-agent -c "
                     "'curl -fsS --unix-socket /run/nestlo-orchestrator/orchestrator.sock http://x/tasks'")

    with subtest("schedules: declared ones are listed and read-only, CLI ones fire"):
        listing = ops("nestlo-schedule list")
        print(listing)
        assert "weekly-report" in listing and "declared" in listing, listing
        machine.fail("su - ops -c 'nestlo-schedule remove weekly-report'")
        ops("nestlo-schedule add tick --calendar '*-*-* *:*:00/10' --agent fake --workspace sched "
            "--prompt 'scheduled run' --budget 5")
        machine.fail("su - ops -c 'nestlo-schedule add bad --calendar nonsense --agent fake --workspace sched --prompt x'")
        machine.wait_until_succeeds(
            "su - ops -c 'nestlo-task list --json' | "
            "jq -e '[.tasks[] | select(.origin == \"schedule:tick\" and .status == \"succeeded\")] | length >= 1'",
            timeout=180,
        )
        ops("nestlo-schedule remove tick")
        run = ops("nestlo-schedule run-now weekly-report 2>/dev/null").split()
        t = wait_for(run[0], ["succeeded", "failed"])
        assert t["status"] == "succeeded" and t["origin"] == "schedule:weekly-report", t
        assert t["budget_usd"] == 5, t
        # schedules survive a restart of the scheduler
        machine.succeed("systemctl restart nestlo-scheduler.service")
        machine.wait_until_succeeds("test -S /run/nestlo-scheduler/scheduler.sock")
        machine.wait_until_succeeds("su - ops -c 'nestlo-schedule list' | grep -q weekly-report")
  '';
}
