# VM test of nestlo.tuios.
#
#   nix build .#checks.x86_64-linux.tuios
#
# One daemon per user (alice, and the sandboxed agent user) with the declared
# config: socket and runtime directory are private, the declared layout and
# hook are there, a pane holds only the strict default grants, and the agent
# user's pane cannot write its own TUIOS config. The CLI works against a
# detached session (new, ls, send-text/capture-pane round trip); a tape needs
# an attached client and fails cleanly on the headless daemon. The bridge
# turns events into audit records, metrics and a notification (webhook sink)
# when an agent reports needs_input. The MCP server is registered read-only.
# The SSH server accepts the key it was given and refuses another; the web
# terminal answers 401 without the password and 200 with it. VM under TCG:
# timeouts are generous.
{ pkgs, nestloModules }:

let
  snakeoil = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  # Receives the notification webhook and keeps every body
  sink = pkgs.writers.writePython3Bin "webhook-sink" { } ''
    import http.server

    LOG = "/var/lib/webhook-sink/bodies.log"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            with open(LOG, "ab") as f:
                f.write(self.rfile.read(n) + b"\n")
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9100), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-tuios";
  globalTimeout = 1800;

  nodes.machine = { pkgs, ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.openssh ];
    users.users.alice.isNormalUser = true;

    environment.etc."nestlo-test/web-password" = {
      text = "web-secret-pw\n";
      mode = "0600";
    };

    systemd.services.webhook-sink = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-tuios-bridge-alice.service" ];
      serviceConfig = {
        ExecStart = "${sink}/bin/webhook-sink";
        StateDirectory = "webhook-sink";
      };
    };

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      audit.enable = true;
      notifications = {
        enable = true;
        webhookUrl = "http://127.0.0.1:9100/nestlo";
      };
      mcp-registry.enable = true;

      tuios = {
        enable = true;
        monitor.graceSeconds = 2;

        hooks.after-new-window = [
          "${pkgs.coreutils}/bin/touch /var/lib/nestlo-tuios-$(${pkgs.coreutils}/bin/id -un)/hook-ran"
        ];

        layouts.dev.windows = [
          { name = "shell"; }
          { name = "marker"; command = [ "${pkgs.bash}/bin/sh" "-c" "echo layout-marker; exec ${pkgs.coreutils}/bin/sleep 3600" ]; }
        ];

        integrations = [ "claude-code" ];
        mcp.enable = true;

        ssh = {
          enable = true;
          authorizedKeys = [ snakeoil.snakeOilEd25519PublicKey ];
          user = "alice";
        };
        web = {
          enable = true;
          passwordFile = "/etc/nestlo-test/web-password";
        };
      };
    };
  };

  testScript = ''
    import json

    agent_home = "/var/lib/nestlo/agent-home"
    alice = "runuser -u alice -- env HOME=/home/alice nestlo-tuios"
    agent = "nestlo-tuios --user nestlo-agent"
    ssh_opts = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -p 2222"

    def audit():
        raw = machine.succeed("runuser -u alice -- nestlo-audit tail -n 5000 --json")
        recs = [json.loads(l) for l in raw.splitlines() if l.strip()]
        return [r for r in recs if r["type"] == "terminal.tuios"]

    def capture(who, session, window):
        return machine.succeed(f"{who} capture-pane -s {session} -w {window}")

    machine.wait_for_unit("multi-user.target")
    for unit in ["nestlo-tuios-alice", "nestlo-tuios-nestlo-agent",
                 "nestlo-tuios-layouts-alice", "nestlo-tuios-layouts-nestlo-agent",
                 "nestlo-tuios-bridge-alice", "nestlo-tuios-bridge-nestlo-agent",
                 "nestlo-tuios-integrations-alice", "nestlo-tuios-ssh", "nestlo-tuios-web"]:
        machine.wait_for_unit(unit + ".service", timeout=300)

    with subtest("each user has a private daemon socket and runtime directory"):
        machine.succeed("tuios --version")
        machine.wait_until_succeeds("test -S /run/nestlo-tuios-alice/tuios/tuios.sock")
        machine.wait_until_succeeds("test -S /run/nestlo-tuios-nestlo-agent/tuios/tuios.sock")
        assert machine.succeed("stat -c '%a %U' /run/nestlo-tuios-alice").strip() == "700 alice"
        assert machine.succeed("stat -c '%a %U' /run/nestlo-tuios-nestlo-agent").strip() == "700 nestlo-agent"
        assert machine.succeed("stat -c '%a' /run/nestlo-tuios-alice/tuios/tuios.sock").strip() == "700"
        assert machine.succeed("stat -c '%a %U' /var/lib/nestlo-tuios-alice").strip() == "700 alice"
        # not the default location: a plain tuios in a login shell is another daemon
        machine.fail("test -e /run/user/1000/tuios/tuios.sock")

    with subtest("the declared config is what the daemon and the CLI read"):
        assert machine.succeed(f"{alice} config path").strip() == "/etc/xdg/tuios/config.toml"
        cfg = machine.succeed("cat /etc/xdg/tuios/config.toml")
        assert "strict" in cfg and "after-new-window" in cfg, cfg
        hooks = machine.succeed(f"{alice} list-hooks --json")
        assert "after-new-window" in hooks, hooks

    with subtest("the declared layout was created by the oneshot, without a client"):
        for who in [alice, agent]:
            machine.wait_until_succeeds(f"{who} list-windows -s dev --json | jq -e '.total == 2'", timeout=180)
            names = machine.succeed(f"{who} list-windows -s dev --json | jq -r '.windows[].display_name'").split()
            assert sorted(names) == ["marker", "shell"], names
        machine.wait_until_succeeds(f"{alice} capture-pane -s dev -w marker | grep -q layout-marker", timeout=120)
        # the hook ran in the daemon, as the user
        machine.wait_until_succeeds("test -e /var/lib/nestlo-tuios-alice/hook-ran")
        # a second run leaves existing sessions alone
        machine.succeed("systemctl restart nestlo-tuios-layouts-alice.service")
        assert machine.succeed(f"{alice} list-windows -s dev --json | jq .total").strip() == "2"

    with subtest("a detached session, send-text and capture-pane round trip"):
        machine.succeed(f"{alice} new ci --detach")
        assert "ci" in machine.succeed(f"{alice} ls")
        machine.succeed(f"{alice} new-window -s ci probe")
        machine.succeed(f"{alice} send-text -s ci -w probe 'echo ROUNDTRIP-$((20+22))\n'")
        machine.wait_until_succeeds(f"{alice} capture-pane -s ci -w probe | grep -q ROUNDTRIP-42", timeout=120)

    with subtest("a tape needs an attached client; a broken tape is refused"):
        machine.succeed("printf 'Run \"echo hi\"\\n' > /tmp/good.tape")
        machine.succeed("printf 'NotACommand foo\\n' > /tmp/bad.tape")
        machine.succeed("chmod 644 /tmp/*.tape")
        rc, out = machine.execute(f"{alice} tape exec -s ci /tmp/good.tape 2>&1")
        assert rc != 0 and "attached client" in out, (rc, out)
        rc, out = machine.execute(f"{alice} tape exec -s ci /tmp/bad.tape 2>&1")
        assert rc != 0, (rc, out)

    with subtest("a pane holds only the strict grants"):
        machine.succeed(f"{alice} send-text -s dev -w shell 'tuios run-command NewWindow denied-by-grants; echo GRANTS-RC=$?\n'")
        machine.wait_until_succeeds(f"{alice} capture-pane -s dev -w shell | grep -Eq 'GRANTS-RC=[0-9]'", timeout=120)
        out = capture(alice, "dev", "shell")
        assert "GRANTS-RC=0" not in out, out
        assert machine.succeed(f"{alice} list-windows -s dev --json | jq .total").strip() == "2"

    with subtest("the agent user's daemon is contained and its config is read-only"):
        props = machine.succeed("systemctl show nestlo-tuios-nestlo-agent -p ProtectSystem -p NoNewPrivileges -p KillMode")
        assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props and "KillMode=mixed" in props, props
        machine.succeed(f"{agent} send-text -s dev -w shell 'touch $HOME/.config/tuios/config.toml; echo RO-RC=$?\n'")
        machine.wait_until_succeeds(f"{agent} capture-pane -s dev -w shell | grep -Eq 'RO-RC=[0-9]'", timeout=120)
        assert "RO-RC=0" not in machine.succeed(f"{agent} capture-pane -s dev -w shell")
        # a rebuild reloads the daemon (config apply) and never restarts it
        assert "ExecReload" in machine.succeed("systemctl cat nestlo-tuios-alice")

    with subtest("integrations and the read-only MCP registration"):
        settings = machine.succeed("cat /home/alice/.claude/settings.json")
        assert "agent-hook" in settings, settings
        tools = json.loads(machine.succeed("cat /etc/nestlo/mcp-tools.json"))["tools"]
        entry = [t for t in tools if t["name"] == "tuios"][0]
        assert entry["args"] == ["mcp", "--scope", "own"] and "--write" not in entry["args"], entry

    with subtest("the bridge audits windows and commands, counts agents and notifies on needs_input"):
        metrics = "curl -sf http://127.0.0.1:9985/metrics"
        machine.wait_until_succeeds(f"{metrics} | grep -q 'nestlo_tuios_up{{user=\"alice\"}} 1'", timeout=120)
        machine.succeed(f"{alice} new-window -s ci fresh")
        machine.wait_until_succeeds(
            "runuser -u alice -- nestlo-audit tail -n 5000 --json | grep terminal.tuios | grep -q window-created", timeout=120)
        machine.succeed(f"{alice} set-agent-state needs_input -s ci -w probe -m 'awaiting approval'")
        machine.wait_until_succeeds(f"{metrics} | grep -q 'nestlo_tuios_agents{{user=\"alice\",state=\"needs_input\"}} 1'", timeout=120)
        machine.wait_until_succeeds(f"{metrics} | grep -q 'nestlo_tuios_needs_input_notifications_total{{user=\"alice\"}} 1'", timeout=120)
        machine.wait_until_succeeds("grep -q 'waits for input' /var/lib/webhook-sink/bodies.log", timeout=120)
        recs = audit()
        states = [r["data"] for r in recs if r["data"].get("event") == "agent-state"]
        assert any(d["state"] == "needs_input" and d["session"] == "ci" for d in states), states
        assert all(r["actor"] in ("alice", "nestlo-agent") for r in recs), recs
        assert not any("cmdline" in r["data"] for r in recs)
        # loopback only
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):998[56]'")
        machine.succeed(f"{alice} set-agent-state none -s ci -w probe")
        machine.wait_until_succeeds(f"{metrics} | grep -q 'nestlo_tuios_agents{{user=\"alice\",state=\"needs_input\"}} 0'", timeout=120)

    with subtest("ssh: the given key gets in, another is refused, authentication is never off"):
        machine.succeed("install -m 600 ${snakeoil.snakeOilEd25519PrivateKey} /root/id_tuios")
        machine.succeed("ssh-keygen -q -t ed25519 -N \"\" -f /root/id_wrong")
        machine.wait_for_open_port(2222)
        assert "127.0.0.1:2222" in machine.succeed("ss -ltn")
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):2222'")
        # an accepted key reaches the TUIOS session handler, which wants a terminal
        rc, out = machine.execute(f"ssh {ssh_opts} -i /root/id_tuios tuios@127.0.0.1 true 2>&1")
        assert "No terminal" in out, (rc, out)
        rc, out = machine.execute(f"ssh {ssh_opts} -i /root/id_wrong tuios@127.0.0.1 true 2>&1")
        assert rc != 0 and "Permission denied" in out, (rc, out)
        unit = machine.succeed("systemctl cat nestlo-tuios-ssh")
        assert "--no-auth" not in unit and "--authorized-keys" in unit and "User=alice" in unit, unit
        machine.succeed("test -s /var/lib/nestlo-tuios-ssh/host_key")

    with subtest("web: 401 without the password, 200 with it, loopback only"):
        machine.wait_for_open_port(7681)
        code = machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7681/").strip()
        assert code == "401", code
        code = machine.succeed("curl -s -o /dev/null -w '%{http_code}' -u tuios:wrong http://127.0.0.1:7681/").strip()
        assert code == "401", code
        code = machine.succeed("curl -s -o /dev/null -w '%{http_code}' -u tuios:web-secret-pw http://127.0.0.1:7681/").strip()
        assert code == "200", code
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):7681'")
        assert "password-file" in machine.succeed("systemctl cat nestlo-tuios-web")
  '';
}
