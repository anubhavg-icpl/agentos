# VM test of the software factory (agentos.factory).
#
#   nix build .#checks.x86_64-linux.factory
#
# Boots a VM with the orchestrator, the factory and one supervised line whose
# four roles are fake agents that follow the protocols (planner prints
# PLAN-READY, reviewer VERDICT: approve, QA CRITERION 1: pass and
# VERDICT: pass). The publish step pushes to a local bare repository and
# calls a mock GitHub API. An item is submitted with `agentos-factory`; when
# it is ready, the pull request body must carry the evidence.
#
# NOTE: written against the interface agreed with the service builder
# (`agentos-factory submit|export`, item states).
{ pkgs, agentosModules }:

let
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

  fake = name: text: pkgs.writeShellApplication {
    name = "fake-${name}";
    runtimeInputs = [ pkgs.coreutils ];
    inherit text;
  };

  fakePlanner = fake "planner" ''
    echo "role=planner prompt=[$1]"
    echo "Plan: add hello.txt containing the greeting."
    echo "Acceptance criteria:"
    echo "1. hello.txt exists and says hello"
    echo "PLAN-READY"
  '';
  fakeBuilder = fake "builder" ''
    echo "role=builder prompt=[$1]"
    echo "hello" > hello.txt
  '';
  fakeReviewer = fake "reviewer" ''
    echo "role=reviewer prompt=[$1]"
    echo "VERDICT: approve"
  '';
  fakeQa = fake "qa" ''
    echo "role=qa prompt=[$1]"
    echo "CRITERION 1: pass (hello.txt exists)"
    echo "VERDICT: pass"
  '';

  githubToken = "ghp_test_token_must_stay_private";
in
pkgs.testers.runNixOSTest {
  name = "agentos-factory";
  globalTimeout = 2400;

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
        agents = {
          fplanner = "fake-planner";
          fbuilder = "fake-builder";
          freviewer = "fake-reviewer";
          fqa = "fake-qa";
        };
      };
      orchestration = {
        enable = true;
        maxWorkers = 2;
        taskCommands = {
          fplanner = [ "fake-planner" "{prompt}" ];
          fbuilder = [ "fake-builder" "{prompt}" ];
          freviewer = [ "fake-reviewer" "{prompt}" ];
          fqa = [ "fake-qa" "{prompt}" ];
        };
      };
      git-automation = {
        enable = true;
        autoPR = false;
        publish = {
          tokenFile = "/etc/agentos-test/github-token";
          apiUrl = "http://127.0.0.1:9998";
          repos."acme/widgets" = {
            url = "/var/lib/test-remote.git";
            base = "main";
          };
        };
      };
      factory = {
        enable = true;
        tickSec = 1;
        lines.web = {
          repo = "acme/widgets";
          workspace = "widgets";
          roles = {
            planner = { agent = "fplanner"; model = null; };
            builder = { agent = "fbuilder"; model = null; };
            reviewer = { agent = "freviewer"; model = null; };
            qa = { agent = "fqa"; model = null; };
          };
        };
      };
    };

    environment.etc."agentos-test/github-token" = {
      text = githubToken;
      mode = "0400";
    };

    environment.systemPackages = [
      fakePlanner
      fakeBuilder
      fakeReviewer
      fakeQa
      pkgs.jq
      pkgs.curl
      pkgs.git
    ];

    systemd.services.mock-github = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${mockGithub}/bin/mock-github";
    };
  };

  testScript = ''
    import json

    def ops(cmd):
        return machine.succeed(f"su - ops -c {json.dumps(cmd)}")

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-daemon.service", "agentos-orchestrator.service",
                 "agentos-factory.service", "mock-github.service"]:
        machine.wait_for_unit(unit)
    machine.wait_until_succeeds("test -S /run/agentos-factory/factory.sock")
    machine.wait_for_open_port(9960)
    machine.succeed("su - admin -c 'agentos workspace create widgets'")
    machine.succeed("git init --bare -q -b main /var/lib/test-remote.git")

    with subtest("the factory exports its metrics"):
        metrics = machine.succeed("curl -s http://127.0.0.1:9960/metrics")
        assert "agentos_factory_items" in metrics, metrics

    with subtest("an item runs through the line and ends ready with a pull request"):
        out = ops("agentos-factory submit --line web --title 'Add hello' --body 'Add hello.txt with a greeting.'")
        item = out.split()[0]
        machine.wait_until_succeeds(
            f"su - ops -c 'agentos-factory export {item}' | jq -e '.state == \"ready\"'",
            timeout=600,
        )
        done = json.loads(ops(f"agentos-factory export {item}"))
        print(done)

    with subtest("the pull request carries the evidence"):
        reqs = [json.loads(l) for l in machine.succeed("cat /tmp/github-requests.jsonl").splitlines()]
        pulls = [r for r in reqs if r["path"] == "/repos/acme/widgets/pulls"]
        assert len(pulls) == 1, reqs
        assert pulls[0]["auth"] == "Bearer ${githubToken}", pulls
        body = pulls[0]["body"]["body"]
        assert "CRITERION 1" in body or "hello.txt exists" in body, body
        assert "approve" in body.lower(), body
        assert "${githubToken}" not in body

    with subtest("the factory has no way to merge in supervised mode"):
        assert not any(r["path"].endswith("/merge") for r in reqs), reqs
  '';
}
