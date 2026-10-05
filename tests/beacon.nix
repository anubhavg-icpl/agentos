# VM test of nestlo.beacon (Agent Beacon, local-first session capture).
#
#   nix build .#checks.x86_64-linux.beacon
#
# The collector runs as its own user on loopback only and turns OTLP into
# Beacon events in the shared log; an operator's agent configuration is merged
# with Beacon's hooks and OTLP settings (and what was there stays); hooks of
# an operator land in the shared log, hooks of the sandboxed agent user land
# under its home and are relayed, and that user cannot read the shared log;
# rotated segments are archived and old archives pruned; approved memory
# reaches the agent user and nothing else of the store does; the MCP server
# answers for both; the skill pack and the registry entry exist; and nothing
# is forwarded anywhere (no cloud unit, loopback-only services).
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-beacon";
  globalTimeout = 900;

  nodes.machine = { pkgs, ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 2048;
    environment.systemPackages = [ pkgs.curl pkgs.jq pkgs.zstd ];

    users.users.alice.isNormalUser = true;
    users.users.bob.isNormalUser = true;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      mcp-registry.enable = true;
      skills.enable = true;
      beacon = {
        enable = true;
        # no agent binaries in the VM: configure these explicitly
        harnesses = [ "claude" "codex" "opencode" ];
        retention.days = 1;
      };
    };
  };

  testScript = ''
    import json

    shared_log = "/var/lib/beacon/logs/runtime.jsonl"
    agent_home = "/var/lib/nestlo/agent-home"
    as_agent = f"runuser -u nestlo-agent -- env HOME={agent_home}"
    as_alice = "runuser -u alice -- env HOME=/home/alice"
    as_bob = "runuser -u bob -- env HOME=/home/bob"


    def events(path):
        out = machine.succeed(f"cat {path}")
        return [json.loads(line) for line in out.splitlines() if line.strip()]


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("beacon-collector.service")
    machine.wait_for_unit("beacon-setup-alice.service")
    machine.wait_for_unit("beacon-setup-nestlo-agent.service")
    machine.wait_for_unit("beacon-relay-nestlo-agent.service")

    with subtest("the collector is local only and runs unprivileged"):
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:13133")
        props = machine.succeed(
            "systemctl show beacon-collector -p User -p IPAddressDeny -p IPAddressAllow "
            "-p NoNewPrivileges -p ProtectSystem -p CapabilityBoundingSet"
        )
        assert "User=beacon" in props and "NoNewPrivileges=yes" in props and "ProtectSystem=strict" in props, props
        assert "IPAddressDeny=" in props and "0.0.0.0" in props, props
        listening = machine.succeed("ss -ltn")
        for port in ["4317", "4318", "13133", "9975"]:
            assert f"127.0.0.1:{port}" in listening, listening
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):(4317|4318|13133|9975)'")
        # no Beacon Cloud forwarder, and the collector has no exporter that could send anything
        machine.fail("systemctl cat beacon-asymptote-forwarder.service")
        machine.fail("beacon-otelcol components 2>&1 | grep -Ei 'splunk|falcon|otlphttp'")

    with subtest("OTLP becomes Beacon events in the shared log"):
        payload = json.dumps({"resourceLogs": [{
            "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "claude-code"}}]},
            "scopeLogs": [{"scope": {"name": "com.anthropic.claude_code.events"}, "logRecords": [{
                "timeUnixNano": "1790000000000000000",
                "body": {"stringValue": "claude_code.user_prompt"},
                "attributes": [
                    {"key": "event.name", "value": {"stringValue": "user_prompt"}},
                    {"key": "session.id", "value": {"stringValue": "otlp-1"}},
                    {"key": "prompt", "value": {"stringValue": "hello from otlp"}},
                ],
            }]}],
        }]})
        machine.succeed(f"curl -sf -XPOST http://127.0.0.1:4318/v1/logs -H 'content-type: application/json' -d '{payload}'")
        machine.wait_until_succeeds(f"grep -q 'hello from otlp' {shared_log}")
        ev = [e for e in events(shared_log) if e.get("prompt", {}).get("text") == "hello from otlp"][0]
        assert ev["event"]["action"] == "prompt.submitted" and ev["harness"]["collection_method"] == "otlp", ev
        # the collector's own metrics count it (nestlo.observability scrapes them)
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:9975/metrics | grep -q 'otelcol_exporter_sent_log_records_total{exporter=\"beaconjson\"'")

    with subtest("the shared state is private to the group beacon"):
        assert machine.succeed("stat -c '%U:%G %a' /var/lib/beacon /var/lib/beacon/logs").split() == [
            "beacon:beacon", "2770", "beacon:beacon", "2770"], "state dir"
        assert "alice" in machine.succeed("getent group beacon")
        machine.succeed(f"{as_alice} cat {shared_log} >/dev/null")
        machine.fail(f"{as_bob} cat {shared_log}")
        machine.fail(f"{as_agent} cat {shared_log}")
        assert machine.succeed(f"stat -c %a {shared_log}").strip() in ("666", "664", "660", "644"), "log mode"

    with subtest("an operator's agent configuration is merged with Beacon's, not replaced"):
        settings = json.loads(machine.succeed("cat /home/alice/.claude/settings.json"))
        assert settings["env"]["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://127.0.0.1:4317", settings
        assert any("beacon-hooks" in h["hooks"][0]["command"] for h in settings["hooks"]["SessionStart"]), settings
        assert "[otel.exporter.\"otlp-grpc\"]" in machine.succeed("cat /home/alice/.codex/config.toml")
        machine.succeed("test -f /home/alice/.config/opencode/plugins/beacon.ts")
        # the hook commands name the shared log
        assert shared_log in json.dumps(settings["hooks"]), settings["hooks"]
        # a setting of the user's survives a re-run, with a single backup
        settings["model"] = "opus"
        settings["hooks"]["PreToolUse"] = settings["hooks"].get("PreToolUse", []) + [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "/run/current-system/sw/bin/true"}]}]
        machine.succeed("cat > /home/alice/.claude/settings.json <<'EOF'\n" + json.dumps(settings) + "\nEOF")
        machine.succeed("chown alice /home/alice/.claude/settings.json")
        machine.succeed("systemctl restart beacon-setup-alice.service")
        settings = json.loads(machine.succeed("cat /home/alice/.claude/settings.json"))
        assert settings["model"] == "opus", settings
        assert any(h["hooks"][0]["command"] == "/run/current-system/sw/bin/true" for h in settings["hooks"]["PreToolUse"]), settings
        assert int(machine.succeed("ls /home/alice/.claude/settings.json.beacon.*.bak | wc -l")) == 1

    with subtest("an operator's hooks write the shared log"):
        hook = (
            "echo '{\"session_id\":\"alice-1\",\"cwd\":\"/home/alice\",\"hook_event_name\":\"UserPromptSubmit\","
            "\"prompt\":\"alice asks\"}' | "
            f"{as_alice} beacon-hooks --platform claude --log {shared_log} prompt-submit"
        )
        machine.succeed(hook)
        assert any(e.get("prompt", {}).get("text") == "alice asks" and e["harness"]["collection_method"] == "hook"
                   for e in events(shared_log))

    with subtest("the agent user logs under its home, the relay appends it, and it cannot read the shared log"):
        # the agent's own hook configuration points at its home log, which the sandbox lets it write
        agent_settings = machine.succeed(f"cat {agent_home}/.claude/settings.json")
        assert f"{agent_home}/.beacon/endpoint/logs/runtime.jsonl" in agent_settings, agent_settings
        agent_log = f"{agent_home}/.beacon/endpoint/logs/runtime.jsonl"
        machine.succeed(
            "echo '{\"session_id\":\"agent-1\",\"cwd\":\"/var/lib/nestlo/workspaces\",\"hook_event_name\":\"UserPromptSubmit\","
            "\"prompt\":\"agent works\"}' | "
            f"{as_agent} beacon-hooks --platform claude --log {agent_log} prompt-submit"
        )
        machine.wait_until_succeeds(f"grep -q 'agent works' {shared_log}")
        props = machine.succeed("systemctl show beacon-relay-nestlo-agent -p SupplementaryGroups -p ProtectSystem")
        assert "beacon" in props and "ProtectSystem=strict" in props, props
        machine.fail(f"{as_agent} cat {shared_log}")
        machine.fail(f"{as_agent} sh -c 'echo x >> {shared_log}'")

    with subtest("rotated segments are archived and old archives are pruned"):
        machine.succeed(f"echo '{{\"old\":true}}' > {shared_log}.1 && touch -d '10 minutes ago' {shared_log}.1 && chown beacon:beacon {shared_log}.1")
        machine.succeed("touch -d '3 days ago' /var/lib/beacon/archive/runtime-20200101T000000Z-1.jsonl.zst")
        machine.succeed("systemctl start beacon-archive.service")
        fresh = machine.succeed("ls /var/lib/beacon/archive/ | grep -v 20200101").split()
        assert len(fresh) == 1 and fresh[0].endswith(".jsonl.zst"), fresh
        assert '"old"' in machine.succeed(f"zstdcat /var/lib/beacon/archive/{fresh[0]}")
        machine.fail("test -e /var/lib/beacon/archive/runtime-20200101T000000Z-1.jsonl.zst")

    with subtest("approved memory reaches the agent user and nothing else of the store does"):
        proj = "/var/lib/nestlo/workspaces/proj"
        machine.succeed(f"install -d -o alice -g nestlo-agent {proj}")
        machine.succeed("echo 'warm the cache first' > /tmp/lesson.md")
        machine.succeed(
            f"{as_alice} beacon memory candidates create --trace session:claude_code:alice-1 "
            "--kind gotcha --title 'Warm cache before smoke' --applicability 'when smoke fails on a clean checkout' "
            f"--body-file /tmp/lesson.md --project {proj}"
        )
        cand_id = json.loads(machine.succeed(f"{as_alice} beacon memory candidates list --json --project {proj}"))[0]["id"]
        machine.succeed(f"{as_alice} beacon memory candidates approve {cand_id} --reason ok --project {proj}")
        assert "Warm cache before smoke" in machine.succeed(f"{as_alice} beacon memory list --project {proj}")
        machine.succeed("systemctl start beacon-memory-sync-nestlo-agent.service")
        assert "Warm cache before smoke" in machine.succeed(f"{as_agent} beacon memory list --project {proj}")
        # the candidate (and its trace evidence) stayed behind
        assert cand_id not in machine.succeed(f"{as_agent} beacon memory candidates list --project {proj}")
        machine.fail(f"{as_agent} test -r /var/lib/beacon/memory.db")

    with subtest("the MCP server answers for an operator and for the agent user"):
        rpc = (
            "printf '%s\\n' "
            "'{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"0\"}}}' "
            "'{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}' "
            "'{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}'"
        )
        for who in [as_alice, as_agent]:
            out = machine.succeed(f"{rpc} | {who} timeout 15 nestlo-beacon-mcp")
            assert "search_activity" in out and "get_memory_context" in out, out
        # and it is in the registry
        entry = json.loads(machine.succeed("jq -c '.tools[] | select(.name==\"beacon\")' /etc/nestlo/mcp-tools.json"))
        assert entry["command"].endswith("/nestlo-beacon-mcp") and entry["enabled"], entry

    with subtest("the Beacon skills are linked for the agent user"):
        for s in ["beacon-memory-recall", "beacon-memory-distill", "beacon-memory-promote", "beacon-lens-create"]:
            machine.succeed(f"test -f {agent_home}/.claude/skills/{s}/SKILL.md")

    with subtest("the beacon CLI reads the system collector's log without flags"):
        assert "Warm" in machine.succeed(f"cd {proj} && {as_alice} beacon memory list")
        out = machine.succeed(f"{as_alice} beacon endpoint status --system --log-path {shared_log}")
        assert "running=true" in out, out
  '';
}
