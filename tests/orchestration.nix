# VM test of the orchestrator and the scheduler.
#
#   nix build .#checks.x86_64-linux.orchestration
#
# Boots a VM with the runtime, gateway, orchestrator and scheduler. A fake
# headless agent calls the (mock) model API through the gateway, and tasks
# are submitted as an operator who has no sudo:
#
#   single task -> 2-step pipeline ({prev_result}) -> swarm of 2 (own
#   worktree and branch each) -> timeout / cancel / failed dependency ->
#   a schedule firing -> what the orchestrator user may and may not do
{ pkgs, agentosModules }:

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
      echo "user=$(id -un) task=$AGENTOS_TASK_ID cwd=$PWD branch=$AGENTOS_BRANCH"
      echo "prompt=[$prompt]"
      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "x-api-key: $ANTHROPIC_API_KEY" -H 'content-type: application/json' \
        -d '{"model": "claude-sonnet-5-5", "max_tokens": 16, "messages": []}' \
        "$ANTHROPIC_BASE_URL/v1/messages")
      echo "gateway=$code key=$ANTHROPIC_API_KEY"
      printf '%s\n' "$prompt" > "note-$AGENTOS_TASK_ID.txt"
      case "$prompt" in
        *SLEEP*) sleep 600 ;;
        *FAIL*) exit 3 ;;
        *EMIT*) echo "TOKEN=xyzzy-42" ;;
      esac
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "agentos-orchestration";
  globalTimeout = 3600;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    # An operator without sudo: tasks must not need it
    users.users.ops.isNormalUser = true;
    security.sudo.wheelNeedsPassword = false;

    agentos = {
      runtime = {
        enable = true;
        operators = [ "admin" "ops" ];
        agents.fake = "fake-task-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/agentos-test/anthropic.key";
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

    environment.etc."agentos-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "agentos";
    };

    environment.systemPackages = [ fakeTaskAgent pkgs.jq ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "agentos-model-gateway.service" ];
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
        out = ops("agentos-task submit --agent fake " + " ".join(args) + " 2>/dev/null")
        return out.split()

    def show(task_id):
        return json.loads(ops(f"agentos-task show {task_id} --json"))

    def wait_for(task_id, statuses, timeout=180):
        machine.wait_until_succeeds(
            f"su - ops -c 'agentos-task show {task_id} --json' | jq -e '[.status] | inside({json.dumps(statuses)})'",
            timeout=timeout,
        )
        return show(task_id)

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-model-gateway.service", "agentos-daemon.service",
                 "agentos-orchestrator.service", "agentos-scheduler.service", "mock-llm.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)
    machine.wait_until_succeeds("test -S /run/agentos-orchestrator/orchestrator.sock")
    machine.wait_until_succeeds("test -S /run/agentos-scheduler/scheduler.sock")
    for name in ["demo", "swarm", "sched"]:
        as_user("admin", f"agentos workspace create {name}")

    with subtest("a single task runs sandboxed, metered and budgeted, without sudo"):
        machine.fail("su - ops -c 'sudo -n true'")
        (tid,) = submit("--workspace demo --prompt 'hello there' --budget 5")
        task = wait_for(tid, ["succeeded", "failed"])
        print(task)
        assert task["status"] == "succeeded", task
        out = task["result"]["output_tail"]
        assert "user=agentos-agent" in out and f"task={tid}" in out, out
        assert "gateway=200 key=agentos-managed" in out, out
        assert task["result"]["branch"] == f"agent/{tid}", task
        assert "prompt=[hello there]" in ops(f"agentos-task logs {tid}")
        machine.succeed(f"test -f /var/lib/agentos/workspaces/demo/note-{tid}.txt")
        budget = json.loads(ops("agentos budget status --json"))
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
            ops(f"git -C /var/lib/agentos/workspaces/swarm rev-parse --verify {t['result']['branch']}")
        summary = ops(f"agentos-task show {done[0]['group']}")
        assert "2 succeeded" in summary, summary
        listing = ops("agentos list")
        assert all(i in listing for i in ids), listing

    with subtest("timeout, cancel and failed dependencies"):
        (slow,) = submit("--workspace demo --prompt 'SLEEP' --timeout 5")
        t = wait_for(slow, ["timeout", "succeeded", "failed"])
        assert t["status"] == "timeout", t
        machine.fail(f"systemctl is-active agentos-agent-{slow}.service")

        (long_run,) = submit("--workspace demo --prompt 'SLEEP'")
        wait_for(long_run, ["running"])
        machine.wait_until_succeeds(f"systemctl is-active agentos-agent-{long_run}.service")
        ops(f"agentos-task cancel {long_run}")
        t = wait_for(long_run, ["cancelled"])
        machine.wait_until_fails(f"systemctl is-active agentos-agent-{long_run}.service")

        (bad,) = submit("--workspace demo --prompt 'FAIL'")
        (after_bad,) = submit("--workspace demo --after", bad, "--prompt 'never runs'")
        assert wait_for(bad, ["failed"])["result"]["exit_code"] == 3
        skipped = wait_for(after_bad, ["skipped"])
        assert "failed" in skipped["result"]["error"], skipped

    with subtest("hostile input is refused or passed through as plain text"):
        for args in ["--workspace /etc --prompt x", "--workspace ../../etc --prompt x",
                     "--workspace demo --prompt '--dangerously-skip-permissions'",
                     "--workspace demo --prompt x --timeout 0"]:
            machine.fail("su - ops -c " + json.dumps("agentos-task submit --agent fake " + args))
        machine.fail("su - ops -c 'agentos-task submit --agent nosuchagent --workspace demo --prompt x'")
        machine.succeed("printf '%s' \"\\$(touch /var/lib/agentos/workspaces/demo/pwned); echo 'x' > /tmp/pwned\" > /tmp/evil.txt")
        machine.succeed("chmod 644 /tmp/evil.txt")
        (evil,) = submit("--workspace demo --prompt-file /tmp/evil.txt")
        t = wait_for(evil, ["succeeded", "failed"])
        assert t["status"] == "succeeded" and "prompt=[$(touch" in t["result"]["output_tail"], t
        machine.fail("test -e /var/lib/agentos/workspaces/demo/pwned")
        machine.fail("test -e /tmp/pwned")

    with subtest("the orchestrator user can start task runners and nothing else"):
        machine.succeed("su -s /bin/sh agentos -c 'systemctl start --no-block agentos-task-runner@nonexistent.service'")
        machine.fail("su -s /bin/sh agentos -c 'systemctl restart agentos-daemon.service'")
        machine.fail("su -s /bin/sh agentos -c 'systemctl start --no-block sshd.service'")
        machine.fail("su -s /bin/sh agentos -c 'sudo -n true'")
        # the sandboxed agent user cannot reach the orchestrator
        machine.fail("su -s /bin/sh agentos-agent -c "
                     "'curl -fsS --unix-socket /run/agentos-orchestrator/orchestrator.sock http://x/tasks'")

    with subtest("schedules: declared ones are listed and read-only, CLI ones fire"):
        listing = ops("agentos-schedule list")
        print(listing)
        assert "weekly-report" in listing and "declared" in listing, listing
        machine.fail("su - ops -c 'agentos-schedule remove weekly-report'")
        ops("agentos-schedule add tick --calendar '*-*-* *:*:00/10' --agent fake --workspace sched "
            "--prompt 'scheduled run' --budget 5")
        machine.fail("su - ops -c 'agentos-schedule add bad --calendar nonsense --agent fake --workspace sched --prompt x'")
        machine.wait_until_succeeds(
            "su - ops -c 'agentos-task list --json' | "
            "jq -e '[.tasks[] | select(.origin == \"schedule:tick\" and .status == \"succeeded\")] | length >= 1'",
            timeout=180,
        )
        ops("agentos-schedule remove tick")
        run = ops("agentos-schedule run-now weekly-report 2>/dev/null").split()
        t = wait_for(run[0], ["succeeded", "failed"])
        assert t["status"] == "succeeded" and t["origin"] == "schedule:weekly-report", t
        assert t["budget_usd"] == 5, t
        # schedules survive a restart of the scheduler
        machine.succeed("systemctl restart agentos-scheduler.service")
        machine.wait_until_succeeds("test -S /run/agentos-scheduler/scheduler.sock")
        machine.wait_until_succeeds("su - ops -c 'agentos-schedule list' | grep -q weekly-report")
  '';
}
