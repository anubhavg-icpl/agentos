# VM test of nestlo.herdr.
#
#   nix build .#checks.x86_64-linux.herdr
#
# herdr is installed; the headless server runs for the agent user (and is not
# restarted by the plugin unit); `nestlo-herdr status` and the loopback
# metrics see a pane created in that server; the Nestlo plugin and a
# declared local plugin are linked for the agent user and for an operator
# whose herdr server is not running (link needs none), and re-running the
# oneshot changes nothing; the marketplace CLI fails cleanly without network.
# Plugins from GitHub need the network, so they are covered by the unit tests
# against a fake GitHub and a fake herdr (services/tests/test_herdr_plugins.py).
{ pkgs, nestloModules }:

let
  vmPlugin = pkgs.runCommand "nestlo-vm-test-plugin" { } ''
    mkdir -p $out
    cat > $out/herdr-plugin.toml <<'EOF'
    id = "test.vm"
    name = "VM test"
    version = "0.1.0"
    min_herdr_version = "0.8.2"
    platforms = ["linux"]

    [[actions]]
    id = "hello"
    title = "Hello"
    command = ["sh", "-c", "true"]
    EOF
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-herdr";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 2048;

    users.users.alice.isNormalUser = true;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      herdr = {
        enable = true;
        localPlugins = [ vmPlugin ];
        monitor.intervalSeconds = 2;
      };
    };
  };

  testScript = ''
    import json

    agent_home = "/var/lib/nestlo/agent-home"
    as_agent = f"runuser -u nestlo-agent -- env HOME={agent_home}"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-herdr-server-nestlo-agent.service")
    machine.wait_for_unit("nestlo-herdr-plugins-nestlo-agent.service")
    machine.wait_for_unit("nestlo-herdr-plugins-alice.service")
    machine.wait_for_unit("nestlo-herdr-monitor-nestlo-agent.service")
    machine.wait_for_unit("nestlo-herdr-monitor-alice.service")

    with subtest("herdr is installed and the agent user's server answers"):
        assert "herdr 0." in machine.succeed("herdr --version")
        machine.wait_until_succeeds(f"test -S {agent_home}/.config/herdr/herdr.sock")
        machine.wait_until_succeeds(f"{as_agent} herdr status server | grep -q 'status: running'")
        # not an operator-visible default config: the server is the agent user's
        machine.fail("test -e /home/alice/.config/herdr/herdr.sock")

    with subtest("the agent user's server is contained, and a rebuild does not restart it"):
        props = machine.succeed("systemctl show nestlo-herdr-server-nestlo-agent -p ProtectSystem -p NoNewPrivileges")
        assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props, props
        assert "nestlo-herdr-server-nestlo-agent" in machine.succeed("systemctl list-units --state=active 'nestlo-herdr-server-*' --no-legend")

    with subtest("the Nestlo plugin and the declared local plugin are linked"):
        for who in [as_agent, "runuser -u alice -- env HOME=/home/alice"]:
            plugins = json.loads(machine.succeed(f"{who} herdr plugin list --json"))["result"]["plugins"]
            ids = sorted(p["plugin_id"] for p in plugins)
            assert ids == ["nestlo.dashboard", "test.vm"], ids
            assert all(p["enabled"] for p in plugins)
        actions = machine.succeed(f"{as_agent} herdr plugin action list --plugin nestlo.dashboard")
        assert "tasks" in actions and "approve" in actions, actions

    with subtest("the oneshot is idempotent"):
        machine.succeed("systemctl restart nestlo-herdr-plugins-nestlo-agent.service")
        machine.succeed("systemctl restart nestlo-herdr-plugins-alice.service")
        plugins = json.loads(machine.succeed(f"{as_agent} herdr plugin list --json"))["result"]["plugins"]
        assert sorted(p["plugin_id"] for p in plugins) == ["nestlo.dashboard", "test.vm"]
        out = machine.succeed("runuser -u alice -- env HOME=/home/alice nestlo-herdr-plugins list")
        assert out.count("declarative-link") == 2 and "manual" not in out, out

    with subtest("nestlo-herdr status and metrics see the server"):
        machine.succeed(f"{as_agent} herdr workspace create --cwd /tmp --label vm-test")
        out = json.loads(machine.succeed("nestlo-herdr status --user nestlo-agent --json"))
        assert out[0]["user"] == "nestlo-agent" and out[0]["up"] is True and len(out[0]["panes"]) >= 1, out
        text = machine.succeed("nestlo-herdr status")
        assert "nestlo-agent: " in text and "alice: herdr not available (server not running)" in text, text
        metrics = "curl -sf http://127.0.0.1:9971/metrics"
        machine.wait_until_succeeds(f"{metrics} | grep -q 'nestlo_herdr_up{{user=\"nestlo-agent\"}} 1'")
        machine.wait_until_succeeds(f"{metrics} | grep -Eq 'nestlo_herdr_panes{{user=\"nestlo-agent\",state=\"[a-z]+\"}} 1'")
        machine.succeed("curl -sf http://127.0.0.1:9970/metrics | grep -q 'nestlo_herdr_up{user=\"alice\"} 0'")
        # loopback only
        assert "127.0.0.1:9971" in machine.succeed("ss -ltn")
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):996[01]'")

    with subtest("the marketplace CLI fails cleanly without network"):
        machine.succeed("nestlo-herdr-plugins --help")
        rc, out = machine.execute("runuser -u alice -- env HOME=/home/alice nestlo-herdr-plugins catalog 2>&1")
        assert rc == 1 and "nestlo-herdr-plugins:" in out, (rc, out)
        # nothing is installed without a confirmation
        rc, out = machine.execute("runuser -u alice -- env HOME=/home/alice nestlo-herdr-plugins install bad-source 2>&1")
        assert rc == 1 and "not a plugin source" in out, (rc, out)
        # the marketplace timer is off by default
        machine.fail("systemctl list-timers --all | grep nestlo-herdr-marketplace")
  '';
}
