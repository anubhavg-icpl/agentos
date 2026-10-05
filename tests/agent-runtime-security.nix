# VM test of nestlo.agentRuntimeSecurity (Tetragon):
#
#   nix build .#checks.x86_64-linux.agent-runtime-security
#
# Boots Tetragon with the Nestlo policies in observe mode, has nestlo-agent
# read a decoy secret (a file under /run/secrets that the user can read) and
# checks that the forwarder turns the kernel event into an alert, while the
# same read by an operator is not reported. Also checks that the policies
# are loaded, the units are hardened, and the metrics count the alert.
#
# This needs the BPF programs to load, which needs a kernel with BTF and
# CONFIG_BPF_SYSCALL and kprobes: the stock NixOS test kernel has them. The
# VM is TCG when /dev/kvm is missing; BPF does not depend on KVM, but the
# test is slower. The audit leg (events sent to nestlo-audit) is not
# asserted here: it needs the event type `runtime.security` added to
# EVENT_TYPES in services/nestlo_services/audit.py. With the type missing
# the writer drops the event and counts it as rejected.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-agent-runtime-security";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = nestloModules ++ [ ./../modules/agent-runtime-security ];

    virtualisation.memorySize = 3072;

    users.users.alice.isNormalUser = true;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      networking.enable = true;
      audit.enable = true;
      agentRuntimeSecurity = {
        enable = true;
        dedupeSeconds = 1;
      };
    };

    # A decoy provider key the agent must never open (but can, to prove the
    # detection rather than the file permissions)
    nestlo.networking.providers.decoy = {
      baseUrl = "https://decoy.invalid";
      api = "openai";
      keyFile = "/run/secrets/DECOY_API_KEY";
    };
  };

  testScript = ''
    import json

    alerts = "/var/log/nestlo-agent-runtime-security/alerts.jsonl"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-tetragon.service")
    machine.wait_for_unit("nestlo-agent-security-forwarder.service")

    with subtest("the kernel has BTF, which Tetragon needs"):
        machine.succeed("test -r /sys/kernel/btf/vmlinux")

    with subtest("Tetragon runs, exports JSON and has our policies loaded"):
        machine.wait_until_succeeds("test -s /var/log/tetragon/tetragon.json || test -e /var/log/tetragon/tetragon.json")
        machine.wait_until_succeeds("tetra --server-address unix:///run/tetragon/tetragon.sock tracingpolicy list | grep -c nestlo-ars- | grep -qv '^0$'", timeout=120)
        listed = machine.succeed("tetra --server-address unix:///run/tetragon/tetragon.sock tracingpolicy list")
        print(listed)
        for rule in ["credential-access", "write-protected", "raw-socket", "ptrace", "kernel-module", "egress-bypass"]:
            assert f"nestlo-ars-{rule}" in listed, rule
        assert "write-outside-workspace" not in listed

    with subtest("units are contained, and observe is the default"):
        for unit in ["nestlo-tetragon", "nestlo-agent-security-forwarder"]:
            props = machine.succeed(f"systemctl show {unit} -p ProtectSystem -p NoNewPrivileges")
            assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props, props
        conf = json.loads(machine.succeed("cat $(systemctl cat nestlo-agent-security-forwarder | grep -o '/nix/store/[^ ]*forwarder.json')"))
        assert conf["mode"] == "observe" and conf["users"] == ["nestlo-agent"], conf
        # only loopback listeners
        listeners = machine.succeed("ss -Htln")
        for line in listeners.splitlines():
            if ":9976" in line or ":9977" in line:
                assert "127.0.0.1:" in line, line

    with subtest("a decoy secret read by nestlo-agent raises an alert; an operator's read does not"):
        machine.succeed("mkdir -p /run/secrets && echo decoy > /run/secrets/DECOY_API_KEY && chmod 0644 /run/secrets/DECOY_API_KEY")
        machine.succeed("runuser -u alice -- cat /run/secrets/DECOY_API_KEY")
        machine.succeed("runuser -u nestlo-agent -- cat /run/secrets/DECOY_API_KEY")
        machine.wait_until_succeeds(f"grep -q credential-access {alerts}", timeout=60)
        lines = [json.loads(l) for l in machine.succeed(f"cat {alerts}").splitlines()]
        hits = [l for l in lines if l["rule"] == "credential-access"]
        print(hits)
        assert hits and all(h["user"] == "nestlo-agent" for h in hits), hits
        h = hits[0]
        assert h["target"] == "/run/secrets/DECOY_API_KEY" and h["binary"].endswith("/cat"), h
        assert h["action"] == "alert" and h["severity"] == "critical", h
        # observe mode: nothing was killed, the read worked
        assert not any(l["action"] != "alert" for l in lines), lines

    with subtest("the alert is counted for Prometheus"):
        machine.wait_until_succeeds(
            "curl -sf http://127.0.0.1:9976/metrics | grep -q 'nestlo_runtime_security_events_total{rule=\"credential-access\",action=\"alert\"} [1-9]'"
        )
  '';
}
