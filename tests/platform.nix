# VM test of the AgentOS platform features: web dashboard, remote fleets and
# the agent marketplace.
#
#   nix build .#checks.x86_64-linux.platform
#
# Two nodes:
#   operator  runs the dashboard, agentos-fleet and agentos-market
#   remote    a second AgentOS host that the operator manages over SSH
#
# Dashboard: the API answers with a token (basic auth or bearer) and rejects
# everything else, is bound to loopback, and is read-only.
# Fleet: strict host key checking is on (status fails until the host key is
# trusted), then status, run and spawn work against the remote node.
# Marketplace: the shipped index validates; install registers a spawnable
# command in agents.d (with a stand-in for `nix`, as the VM has no network),
# and the sandboxed agent user cannot write there.
{ pkgs, agentosModules }:

let
  inherit (import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs) snakeOilPrivateKey snakeOilPublicKey;

  dashboardToken = "test-dashboard-token-0123456789";

  # Runs and exits, like a very short coding agent
  fakeAgent = pkgs.writeShellApplication {
    name = "fake-agent";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      id -un > ran.txt
      echo "$AGENTOS_AGENT_ID" > agent-id.txt
    '';
  };

  # Stand-in for `nix` in the marketplace install test: `build` prints a real
  # store path that contains bin/hello, everything else succeeds silently.
  fakeNix = pkgs.writeShellScript "fake-nix" ''
    for a in "$@"; do
      if [ "$a" = build ]; then
        echo ${pkgs.hello}
      fi
    done
  '';

  agentosNode = extra: { ... }: {
    imports = agentosModules ++ [ extra ];

    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [ snakeOilPublicKey ];
    };
    security.sudo.wheelNeedsPassword = false;
    services.openssh.enable = true;

    agentos = {
      runtime.enable = true;
      networking.enable = true;
      budget-controller.enable = true;
    };

    environment.systemPackages = [ pkgs.redis ];
  };
in
pkgs.testers.runNixOSTest {
  name = "agentos-platform";
  globalTimeout = 3600;

  nodes.operator = agentosNode ({ ... }: {
    agentos = {
      dashboard = {
        enable = true;
        tokenFile = "/etc/agentos-test/dashboard-token";
      };
      fleet = {
        enable = true;
        hosts.decl = { address = "remote"; user = "admin"; };
      };
      marketplace.enable = true;
    };

    environment.etc."agentos-test/dashboard-token" = {
      text = dashboardToken;
      mode = "0400";
    };
    environment.systemPackages = [ pkgs.hello pkgs.jq ];
  });

  nodes.remote = agentosNode ({ ... }: {
    agentos.runtime.agents.fake = "fake-agent";
    environment.systemPackages = [ fakeAgent ];
  });

  testScript = ''
    import json

    def as_admin(machine, cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def fail_as_admin(machine, cmd):
        return machine.fail(f"su - admin -c {json.dumps(cmd)}")

    def seed(machine, agent, usd, pid=1):
        """Fake an agent record and today's spend on `machine`."""
        day = machine.succeed("date -u +%F").strip()
        now = machine.succeed("date +%s").strip()
        redis = "redis-cli -s /run/redis-agentos/redis.sock -n 2"
        machine.succeed(f"{redis} set agentos:spend:{day}:agent:{agent} {usd}")
        machine.succeed(f"{redis} set agentos:spend:{day}:global {usd}")
        machine.succeed(f"{redis} set agentos:spend:{day}:model:claude-test {usd}")
        machine.succeed(f"{redis} hset agentos:tokens:{day}:agent:{agent} input_tokens 1234 output_tokens 56")
        state = {"id": agent, "agent": "claude", "status": "running", "pid": pid,
                 "started_at": int(now), "operator": "admin",
                 "workspace": "/var/lib/agentos/workspaces/demo", "branch": f"agent/{agent}"}
        machine.succeed(f"echo {json.dumps(json.dumps(state))} > /var/lib/agentos/state/{agent}.json")
        log = {"ts": int(now), "method": "POST", "path": "/v1/messages", "provider": "anthropic",
               "status": 200, "model": "claude-test", "duration_ms": 42, "cost_usd": usd}
        machine.succeed(f"echo {json.dumps(json.dumps(log))} > /var/lib/agentos/logs/{agent}.log")

    start_all()
    for m in (operator, remote):
        m.wait_for_unit("multi-user.target")
        for unit in ["redis-agentos.service", "agentos-model-gateway.service", "agentos-daemon.service"]:
            m.wait_for_unit(unit)
    remote.wait_for_unit("sshd.service")
    operator.wait_for_unit("agentos-dashboard.service")
    operator.wait_for_open_port(8090)

    # ── dashboard ─────────────────────────────────────────────────────
    seed(operator, "demo-1", 1.5)
    as_admin(operator, "agentos-budget set demo-1 7")
    api = "http://127.0.0.1:8090"

    def status(path, auth="", method="GET"):
        return operator.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X {method} {auth} {api}{path}").strip()

    with subtest("dashboard rejects requests without the token"):
        for path in ["/", "/api/agents", "/api/spend", "/api/health", "/api/history"]:
            assert status(path) == "401", path
        assert status("/api/agents", "-u admin:wrong") == "401"
        assert status("/api/agents", "-H 'Authorization: Bearer wrong'") == "401"

    with subtest("dashboard answers with the token"):
        basic = "-u admin:${dashboardToken}"
        agents = json.loads(operator.succeed(f"curl -fsS {basic} {api}/api/agents"))
        print(agents)
        (a,) = agents["running"]
        assert a["id"] == "demo-1" and a["branch"] == "agent/demo-1", a
        assert a["usd_today"] == 1.5 and a["limit_usd"] == 7.0, a
        spend = json.loads(operator.succeed(f"curl -fsS -H 'Authorization: Bearer ${dashboardToken}' {api}/api/spend"))
        assert spend["global_usd"] == 1.5 and spend["agents"]["demo-1"]["usd"] == 1.5, spend
        assert spend["models"] == {"claude-test": 1.5}, spend
        hist = json.loads(operator.succeed(f"curl -fsS {basic} {api}/api/history"))
        assert len(hist["days"]) == 7 and hist["days"][0]["global_usd"] == 1.5, hist
        reqs = json.loads(operator.succeed(f"curl -fsS {basic} '{api}/api/requests?agent=demo-1'"))
        assert reqs["requests"][0]["path"] == "/v1/messages", reqs
        health = json.loads(operator.succeed(f"curl -fsS {basic} {api}/api/health"))
        assert health["ok"], health
        page = operator.succeed(f"curl -fsS {basic} {api}/")
        assert "AgentOS" in page and "prefers-color-scheme" in page

    with subtest("dashboard is read-only, loopback-only and unprivileged"):
        assert status("/api/agents", "-u admin:${dashboardToken}", "POST") == "405"
        assert status("/api/spend", "-u admin:${dashboardToken}", "DELETE") == "405"
        listening = operator.succeed("ss -ltnH 'sport = :8090'")
        assert "127.0.0.1:8090" in listening and "0.0.0.0" not in listening, listening
        assert operator.succeed("systemctl show -p User --value agentos-dashboard").strip() == "agentos"
        assert operator.succeed("systemctl show -p ProtectSystem --value agentos-dashboard").strip() == "strict"
        # the token file is a credential: not readable by the service user directly
        operator.fail("su -s /bin/sh agentos -c 'cat /etc/agentos-test/dashboard-token'")

    # ── marketplace ───────────────────────────────────────────────────
    with subtest("the shipped registry validates and can be searched"):
        out = as_admin(operator, "agentos-market validate")
        assert "ok" in out, out
        assert "kilo" in as_admin(operator, "agentos-market search kilo")
        info = json.loads(as_admin(operator, "agentos-market info mini-swe-agent --json"))
        assert info["kind"] == "pypi" and info["bin"] == "mini", info
        # a broken registry is refused
        operator.succeed("echo '{\"agents\": [{\"name\": \"claude\"}]}' > /tmp/bad.json")
        fail_as_admin(operator, "agentos-market --index /tmp/bad.json validate")
        dry = as_admin(operator, "agentos-market install kilo --dry-run")
        assert "@kilocode/cli@7.8.1" in dry and "would run: nix profile install" in dry, dry

    with subtest("install registers a spawnable command in agents.d"):
        index = {"agents": [{
            "name": "hello-agent", "description": "Stand-in agent", "homepage": "https://example.org",
            "license": "GPL-3.0", "kind": "nixpkgs", "package": "hello", "version": "2.12.1",
            "bin": "hello", "commands": ["hello"], "maintainers": ["test"],
        }]}
        operator.succeed(f"echo {json.dumps(json.dumps(index))} > /tmp/index.json")
        env = "AGENTOS_MARKET_INDEX=/tmp/index.json AGENTOS_MARKET_NIX=${fakeNix}"
        as_admin(operator, f"{env} agentos-market install hello-agent")
        doc = json.loads(operator.succeed("cat /var/lib/agentos/agents.d/hello-agent.json"))
        print(doc)
        path = doc["agents"]["hello-agent"]
        assert path.startswith("/nix/store/") and path.endswith("/bin/hello"), doc
        operator.succeed(path)
        # the lookup `agentos spawn` performs (see docs/marketplace.md)
        found = as_admin(operator, "jq -rs --arg a hello-agent "
                         "'[.[] | .agents[$a] // empty] | first // empty' /var/lib/agentos/agents.d/*.json").strip()
        assert found == path, found
        listed = as_admin(operator, "agentos-market list-installed")
        assert "hello-agent" in listed, listed
        # sandboxed agents cannot register commands for themselves
        operator.fail("su -s /bin/sh agentos-agent -c 'touch /var/lib/agentos/agents.d/evil.json'")
        as_admin(operator, f"{env} agentos-market remove hello-agent")
        operator.fail("test -e /var/lib/agentos/agents.d/hello-agent.json")

    # ── fleet ─────────────────────────────────────────────────────────
    remote.succeed("su - admin -c 'agentos workspace create demo'")
    seed(remote, "r-1", 2.25)

    with subtest("fleet: hosts are registered, declarative ones are read-only"):
        as_admin(operator, "agentos-fleet add manual admin@remote")
        listing = json.loads(as_admin(operator, "agentos-fleet list --json"))
        assert listing["decl"]["source"] == "declarative" and listing["manual"]["source"] == "local", listing
        fail_as_admin(operator, "agentos-fleet remove decl")
        fail_as_admin(operator, "agentos-fleet add decl admin@elsewhere")
        fail_as_admin(operator, "agentos-fleet add evil -- -oProxyCommand=touch")
        as_admin(operator, "agentos-fleet remove manual")
        as_admin(operator, "agentos-fleet add remote admin@remote")

    operator.succeed("install -d -m 700 -o admin -g users /home/admin/.ssh")
    operator.succeed("install -m 600 -o admin -g users ${snakeOilPrivateKey} /home/admin/.ssh/id_ecdsa")

    with subtest("fleet: strict host key checking is enforced"):
        out = fail_as_admin(operator, "agentos-fleet status remote")
        print(out)
        assert "DOWN" in out and "Host key verification failed" in out, out
        fail_as_admin(operator, "agentos-fleet run remote -- true")
        as_admin(operator, "ssh-keyscan remote >> ~/.ssh/known_hosts")

    with subtest("fleet: status aggregates the remote host"):
        table = as_admin(operator, "agentos-fleet status")
        print(table)
        assert "r-1" in table and "agent/r-1" in table, table
        data = json.loads(as_admin(operator, "agentos-fleet status remote --json"))[0]
        assert data["up"] and data["services_ok"], data
        assert data["agents_running"] == 1 and data["agents"][0]["id"] == "r-1", data
        assert data["spend_usd"] == 2.25, data

    with subtest("fleet: run executes on the remote host"):
        assert as_admin(operator, "agentos-fleet run remote -- hostname").strip() == "remote"
        out = as_admin(operator, "agentos-fleet run remote -- sh -c 'echo \"$0 $1\"' a 'b c'")
        assert out.strip() == "a b c", out
        fail_as_admin(operator, "agentos-fleet run remote -- false")

    with subtest("fleet: spawn runs the agent sandboxed on the remote host"):
        out = fail_as_admin(operator, "agentos-fleet spawn remote nosuchagent 2>&1")
        assert "Unknown agent" in out, out
        as_admin(operator, "agentos-fleet spawn remote fake --workspace demo")
        assert remote.succeed("cat /var/lib/agentos/workspaces/demo/ran.txt").strip() == "agentos-agent"
        assert remote.succeed("cat /var/lib/agentos/workspaces/demo/agent-id.txt").startswith("fake-")
  '';
}
