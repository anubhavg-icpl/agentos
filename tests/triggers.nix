# VM test of the GitHub triggers and the publish step.
#
#   nix build .#checks.x86_64-linux.triggers
#
# Boots a VM with the orchestrator, the webhook listener and a rule that
# publishes. A signed fake "issue opened" webhook is posted with curl:
#
#   unsigned / badly signed / wrongly signed -> 401, no task
#   signed, trusted author -> a task with origin gh:acme/widgets#42, run by a
#     fake agent that leaves a file in its workspace
#   the task result carries pr_url: the root task runner pushed
#     agent/<id> to a local bare repository and called a mock GitHub API
#     with the token, which the agent user and the logs never see
#   a replayed delivery and an untrusted author create no second task
#   hostile issue text reaches the agent as plain data
{ pkgs, agentosModules }:

let
  # Mock of the GitHub REST API: records every request, answers POST .../pulls
  mockGithub = pkgs.writers.writePython3Bin "mock-github" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            with open("/tmp/github-requests.jsonl", "a") as f:
                f.write(json.dumps({
                    "path": self.path,
                    "auth": self.headers.get("Authorization"),
                    "body": body,
                }) + "\n")
            data = json.dumps({
                "html_url": "http://github.test/acme/widgets/pull/1",
                "number": 1,
            }).encode()
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9998), H).serve_forever()
  '';

  # A headless "coding agent": leaves a change in its workspace and echoes
  # the prompt and its environment so the test can look for secrets in it.
  fakeTaskAgent = pkgs.writeShellApplication {
    name = "fake-task-agent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "user=$(id -un) task=$AGENTOS_TASK_ID branch=$AGENTOS_BRANCH"
      echo "prompt=[$1]"
      echo "env=$(env | sort | tr '\n' ' ')"
      printf '%s\n' "$1" > "change-$AGENTOS_TASK_ID.txt"
    '';
  };

  webhookSecret = "test-webhook-secret-0123456789";
  githubToken = "ghp_test_token_must_stay_private";
in
pkgs.testers.runNixOSTest {
  name = "agentos-triggers";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    users.users.ops.isNormalUser = true;
    security.sudo.wheelNeedsPassword = false;

    agentos = {
      runtime = {
        enable = true;
        operators = [ "admin" "ops" ];
        agents.fake = "fake-task-agent";
      };
      orchestration = {
        enable = true;
        maxWorkers = 2;
        taskCommands.fake = [ "fake-task-agent" "{prompt}" ];
      };
      git-automation = {
        enable = true;
        autoPR = false; # only the rule's `publish = true` asks for a PR
        publish = {
          tokenFile = "/etc/agentos-test/github-token";
          apiUrl = "http://127.0.0.1:9998";
          repos."acme/widgets" = {
            url = "/var/lib/test-remote.git";
            base = "main";
          };
        };
      };
      triggers = {
        enable = true;
        secretFile = "/etc/agentos-test/webhook-secret";
        rules.fix-issue = {
          event = "issues";
          action = [ "opened" ];
          repo = "acme/widgets";
          workspace = "widgets";
          agent = "fake";
          prompt = "Fix #{issue.number}: {issue.title}";
          publish = true;
        };
      };
    };

    # root-only, like a real secret
    environment.etc."agentos-test/webhook-secret" = {
      text = webhookSecret;
      mode = "0400";
    };
    environment.etc."agentos-test/github-token" = {
      text = githubToken;
      mode = "0400";
    };

    environment.systemPackages = [ fakeTaskAgent pkgs.jq pkgs.curl pkgs.git ];

    systemd.services.mock-github = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${mockGithub}/bin/mock-github";
    };
  };

  testScript = ''
    import base64
    import hashlib
    import hmac
    import json

    SECRET = b"${webhookSecret}"
    TOKEN = "${githubToken}"

    def ops(cmd):
        return machine.succeed(f"su - ops -c {json.dumps(cmd)}")

    def issue(number, title, assoc="MEMBER", action="opened"):
        return json.dumps({
            "action": action,
            "repository": {"full_name": "acme/widgets"},
            "sender": {"login": "alice", "type": "User"},
            "issue": {"number": number, "title": title, "body": "details",
                      "author_association": assoc, "labels": []},
        })

    def post(body, delivery, secret=SECRET, signature=None, event="issues"):
        b64 = base64.b64encode(body.encode()).decode()
        machine.succeed(f"echo {b64} | base64 -d > /tmp/body.json")
        headers = f"-H 'X-GitHub-Event: {event}' -H 'X-GitHub-Delivery: {delivery}'"
        if signature != "none":
            sig = signature or "sha256=" + hmac.new(secret, body.encode(), hashlib.sha256).hexdigest()
            headers += f" -H 'X-Hub-Signature-256: {sig}'"
        out = machine.succeed(
            "curl -s -w '\\n%{http_code}' " + headers +
            " --data-binary @/tmp/body.json http://127.0.0.1:8787/webhook"
        )
        text, code = out.rsplit("\n", 1)
        return int(code), text

    def tasks(origin):
        data = json.loads(ops("agentos-task list --json"))
        return [t for t in data["tasks"] if t.get("origin") == origin]

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-daemon.service", "agentos-orchestrator.service",
                 "agentos-triggers.service", "mock-github.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8787)
    machine.wait_for_open_port(9998)
    machine.wait_until_succeeds("test -S /run/agentos-orchestrator/orchestrator.sock")
    machine.succeed("su - admin -c 'agentos workspace create widgets'")
    machine.succeed("git init --bare -q -b main /var/lib/test-remote.git")

    with subtest("unsigned, badly signed and wrongly signed webhooks get 401 and create nothing"):
        body = issue(42, "Crash on start")
        assert post(body, "unsigned-0001", signature="none")[0] == 401
        assert post(body, "badsig-0001", signature="sha256=" + "0" * 64)[0] == 401
        assert post(body, "wrongkey-0001", secret=b"not-the-secret-xx")[0] == 401
        assert tasks("gh:acme/widgets#42") == []

    with subtest("a signed webhook from a member becomes a task that is run and published"):
        code, text = post(body, "delivery-0001")
        assert code == 200, text
        assert json.loads(text)["results"][0]["status"] == "submitted", text
        (task,) = tasks("gh:acme/widgets#42")
        tid = task["id"]
        machine.wait_until_succeeds(
            f"su - ops -c 'agentos-task show {tid} --json' | jq -e '.status == \"succeeded\"'",
            timeout=240,
        )
        done = json.loads(ops(f"agentos-task show {tid} --json"))
        print(done)
        assert "Fix #42: Crash on start" in done["prompt"], done
        assert done["result"]["pr_url"] == "http://github.test/acme/widgets/pull/1", done
        machine.succeed(f"git -C /var/lib/test-remote.git rev-parse --verify agent/{tid}")
        machine.succeed(f"git -C /var/lib/test-remote.git show agent/{tid}:change-{tid}.txt | grep -q 'Fix #42'")
        machine.fail("git -C /var/lib/test-remote.git rev-parse --verify main")
        reqs = [json.loads(l) for l in machine.succeed("cat /tmp/github-requests.jsonl").splitlines()]
        assert len(reqs) == 1, reqs
        assert reqs[0]["path"] == "/repos/acme/widgets/pulls", reqs
        assert reqs[0]["auth"] == "Bearer " + TOKEN, reqs
        assert reqs[0]["body"]["head"] == f"agent/{tid}" and reqs[0]["body"]["base"] == "main", reqs

    with subtest("the token never reaches the agent, its log or the task record"):
        log = ops(f"agentos-task logs {tid}")
        assert TOKEN not in log and TOKEN not in json.dumps(done), log
        machine.fail("su -s /bin/sh agentos-agent -c 'cat /etc/agentos-test/github-token'")
        machine.fail("su -s /bin/sh agentos -c 'cat /etc/agentos-test/github-token'")
        machine.fail("su -s /bin/sh agentos -c 'cat /etc/agentos-test/webhook-secret'")

    with subtest("a replayed delivery and an untrusted author create no task"):
        code, text = post(body, "delivery-0001")
        assert code == 200 and json.loads(text)["status"] == "duplicate", text
        assert len(tasks("gh:acme/widgets#42")) == 1
        code, text = post(issue(43, "From a stranger", assoc="NONE"), "delivery-0002")
        assert code == 200 and json.loads(text)["status"] == "ignored", text
        assert tasks("gh:acme/widgets#43") == []

    with subtest("hostile issue text is data"):
        evil = "$(touch /tmp/pwned) `touch /tmp/pwned` {prev_result}"
        code, text = post(issue(44, evil), "delivery-0003")
        assert code == 200, text
        (t,) = tasks("gh:acme/widgets#44")
        machine.wait_until_succeeds(
            f"su - ops -c 'agentos-task show {t['id']} --json' | jq -e '.status == \"succeeded\" or .status == \"failed\"'",
            timeout=240,
        )
        assert "prompt=[Fix #44: $(touch /tmp/pwned)" in ops(f"agentos-task logs {t['id']}")
        machine.fail("test -e /tmp/pwned")
  '';
}
