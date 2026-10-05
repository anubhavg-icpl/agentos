# VM test of nestlo.a2a (Nestlo agents as A2A agents) and nestlo-acp.
#
#   nix build .#checks.x86_64-linux.a2a
#
# Boots the orchestrator and the A2A server with one agent backed by a fake
# headless agent, then checks, over HTTP on loopback:
#
#   the Agent Card is served without a token (v1.0 shape) and names the
#     configured skill
#   JSON-RPC without a token, or with a wrong one, is 401 and creates no task
#   SendMessage creates a task that `nestlo-task list` shows, with origin
#     a2a:<client>/<agent> and the prompt of the message; the fake agent runs
#     it and GetTask then reports TASK_STATE_COMPLETED with the output
#   the agent, workspace and budget come from the configuration, whatever
#     the request says
#   the token file is not readable by the nestlo user or the agent user
#   a client restricted to other agents cannot reach this one
#   `nestlo-acp --list` names the launchers, and `nestlo-acp fake` starts a
#     command in the workspace with the agent id set and stdout untouched
{ pkgs, nestloModules }:

let
  fakeTaskAgent = pkgs.writeShellApplication {
    name = "fake-task-agent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "task=$NESTLO_TASK_ID"
      echo "prompt=[$1]"
    '';
  };

  fakeAcpAgent = pkgs.writeShellApplication {
    name = "fake-acp-agent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      echo "acp-agent id=$NESTLO_AGENT_ID cwd=$PWD args=$*"
    '';
  };

  tokenA = "tok-alpha-0123456789abcdef";
  tokenB = "tok-bravo-0123456789abcdef";
in
pkgs.testers.runNixOSTest {
  name = "nestlo-a2a";
  globalTimeout = 1800;

  nodes.machine = { lib, ... }: {
    imports = nestloModules ++ [ ../modules/a2a ];

    virtualisation.memorySize = 2048;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "admin" ];
        agents.fake = "fake-task-agent";
      };
      orchestration = {
        enable = true;
        taskCommands.fake = [ "fake-task-agent" "{prompt}" ];
      };
      a2a = {
        enable = true;
        tokenFile = "/etc/nestlo-test/a2a-tokens";
        agents.coder = {
          agent = "fake";
          workspace = "widgets";
          description = "Fixes things in widgets";
          skills = [{ id = "fix"; name = "Fix a bug"; tags = [ "code" ]; }];
          isolate = false;
        };
        agents.other = {
          agent = "fake";
          workspace = "widgets";
          isolate = false;
        };
        acp = {
          enable = true;
          # only the fake agent: the default launchers would put the real
          # agent CLIs (claude-agent-acp, codex-acp, ...) in the VM closure
          agents = lib.mkForce { fake.command = [ "fake-acp-agent" "--acp" ]; };
        };
      };
    };

    environment.etc."nestlo-test/a2a-tokens" = {
      text = ''
        alpha:${tokenA}
        bravo:${tokenB}:other
      '';
      mode = "0400";
    };

    environment.systemPackages = [ fakeTaskAgent fakeAcpAgent pkgs.jq pkgs.curl ];
  };

  testScript = ''
    import json

    BASE = "http://127.0.0.1:9966"

    def rpc(method, params, token="${tokenA}", agent="coder", extra=""):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        auth = f"-H 'Authorization: Bearer {token}'" if token else ""
        out = machine.succeed(
            f"curl -s -w '\\n%{{http_code}}' {auth} -H 'Content-Type: application/json' {extra} "
            f"-d {json.dumps(body)} {BASE}/agents/{agent}"
        )
        text, code = out.rsplit("\n", 1)
        return int(code), (json.loads(text) if text.startswith("{") else text)

    def message(text):
        return {"messageId": "m-" + str(abs(hash(text))), "role": "ROLE_USER", "parts": [{"text": text}]}

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-nestlo.service", "nestlo-daemon.service", "nestlo-orchestrator.service", "nestlo-a2a.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(9966)
    machine.wait_until_succeeds("test -S /run/nestlo-orchestrator/orchestrator.sock")
    machine.succeed("su - admin -c 'nestlo workspace create widgets'")

    with subtest("the Agent Card is public and describes the agent"):
        card = json.loads(machine.succeed(f"curl -sf {BASE}/agents/coder/.well-known/agent-card.json"))
        assert card["name"] == "Nestlo coder" and card["description"] == "Fixes things in widgets", card
        assert card["supportedInterfaces"][0]["protocolBinding"] == "JSONRPC", card
        assert card["skills"][0]["id"] == "fix", card
        assert "/var/lib/nestlo" not in json.dumps(card) and '"fake"' not in json.dumps(card), card
        assert machine.succeed(f"curl -sf {BASE}/health").strip() == '{"status": "ok"}'
        machine.fail(f"curl -sf {BASE}/.well-known/agent-card.json")  # two agents, no default

    with subtest("JSON-RPC needs a valid token"):
        for token in (None, "wrong-token-0123456789abcdef"):
            code, _ = rpc("SendMessage", {"message": message("x")}, token=token)
            assert code == 401, code
        code, _ = rpc("SendMessage", {"message": message("x")}, token="${tokenB}")
        assert code == 404, code  # bravo may only use `other`
        listing = json.loads(machine.succeed("su - admin -c 'nestlo-task list --json'"))
        assert listing["tasks"] == [], listing

    with subtest("SendMessage becomes an orchestrator task that runs"):
        code, out = rpc("SendMessage", {"message": message("fix the flaky test"),
                                        "configuration": {"returnImmediately": True},
                                        "agent": "claude"})
        assert code == 200 and "error" not in out, out
        tid = out["result"]["task"]["id"]
        (task,) = json.loads(machine.succeed("su - admin -c 'nestlo-task list --json'"))["tasks"]
        assert task["id"] == tid and task["origin"] == "a2a:alpha/coder", task
        assert task["agent"] == "fake" and task["prompt"] == "fix the flaky test", task
        machine.wait_until_succeeds(
            f"su - admin -c 'nestlo-task show {tid} --json' | jq -e '.status == \"succeeded\"'", timeout=240)
        code, out = rpc("GetTask", {"id": tid})
        state = out["result"]["status"]["state"]
        assert state == "TASK_STATE_COMPLETED", out
        assert "prompt=[fix the flaky test]" in out["result"]["artifacts"][0]["parts"][0]["text"], out

    with subtest("another client does not see the task"):
        code, out = rpc("GetTask", {"id": tid}, token="${tokenB}", agent="other")
        assert out["error"]["code"] == -32001, out

    with subtest("the token file is private"):
        machine.fail("su -s /bin/sh nestlo -c 'cat /etc/nestlo-test/a2a-tokens'")
        machine.fail("su -s /bin/sh nestlo-agent -c 'cat /etc/nestlo-test/a2a-tokens'")

    with subtest("nestlo-acp starts an agent in its workspace"):
        assert "fake" in machine.succeed("nestlo-acp --list")
        out = machine.succeed("su - admin -c 'nestlo-acp fake --workspace widgets -- extra'")
        assert "acp-agent id=acp-fake-" in out and "cwd=/var/lib/nestlo/workspaces/widgets" in out, out
        assert "args=--acp extra" in out, out
        machine.fail("su - admin -c 'nestlo-acp nosuch'")
  '';
}
