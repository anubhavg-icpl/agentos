# VM test of the agent-stack module (n8n native, Flowise as a container):
#
#   nix build .#checks.x86_64-linux.agent-stack
#
# Checks that n8n starts and listens on 127.0.0.1 only, that the secrets
# oneshot creates 0600 files in a 0700 directory, that the apps are
# registered with the gateway (which also listens on the stack address, with
# only the gateway port open from the stack bridge), and, for the Flowise
# container, the generated podman unit: loopback publish, env files, dropped
# capabilities, no privileges, memory limit. The VM has no network, so no
# image is pulled and no container is started.
{ pkgs, agentosModules }:

pkgs.testers.runNixOSTest {
  name = "agentos-agent-stack";
  globalTimeout = 1800;

  nodes.machine = { lib, ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 3072;

    agentos = {
      runtime.enable = true;
      networking.enable = true;
      agentStack = {
        enable = true;
        n8n.enable = true;
        flowise.enable = true;
      };
    };

    # no registry in the VM: do not try to start the container at boot
    virtualisation.oci-containers.containers.agentos-stack-flowise.autoStart = lib.mkForce false;
  };

  testScript = ''
    import re

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("agentos-stack-secrets.service")
    machine.wait_for_unit("n8n.service")
    machine.wait_for_open_port(5678)

    with subtest("n8n listens on loopback only"):
        listeners = machine.succeed("ss -Htln")
        print(listeners)
        assert "127.0.0.1:5678" in listeners, listeners
        for line in listeners.splitlines():
            if ":5678" in line:
                assert "127.0.0.1:5678" in line, line

    with subtest("secrets are created root-only, 0600"):
        out = machine.succeed("stat -c '%a %U %n' /var/lib/agentos-stack/secrets /var/lib/agentos-stack/secrets/*")
        print(out)
        lines = out.strip().splitlines()
        assert lines[0].startswith("700 root "), lines[0]
        names = [l.split()[-1].rsplit("/", 1)[-1] for l in lines[1:]]
        for n in ["n8n-encryption-key", "flowise.env"]:
            assert n in names, names
        for l in lines[1:]:
            assert l.startswith("600 root "), l
        key = machine.succeed("cat /var/lib/agentos-stack/secrets/n8n-encryption-key")
        assert re.fullmatch("[0-9a-f]{64}", key), key
        env = machine.succeed("cat /var/lib/agentos-stack/secrets/flowise.env")
        assert "FLOWISE_USERNAME=fleet-admin" in env and "FLOWISE_PASSWORD=" in env, env
        # a second run keeps the values
        machine.succeed("systemctl restart agentos-stack-secrets.service")
        assert machine.succeed("cat /var/lib/agentos-stack/secrets/n8n-encryption-key") == key

    with subtest("no secret in the unit files or in the store scripts"):
        password = re.search("FLOWISE_PASSWORD=(.*)", env).group(1)
        machine.fail(f"grep -rlF '{password}' /etc/systemd /run/current-system/etc")
        machine.fail(f"grep -rlF '{key}' /etc/systemd /run/current-system/etc")

    with subtest("apps are registered with the gateway and get a token file"):
        for app in ["n8n", "flowise"]:
            machine.wait_for_unit(f"agentos-stack-gw-{app}.service")
            machine.succeed(f"test -s /var/lib/agentos-stack/secrets/{app}.gateway-token")
            llm = machine.succeed(f"cat /var/lib/agentos-stack/secrets/{app}.llm.env")
            assert f"/agent/stack-{app}:" in llm, llm
            assert "OPENAI_API_KEY=agentos-managed" in llm, llm
            machine.succeed(f"stat -c %a /var/lib/agentos-stack/secrets/{app}.llm.env | grep -qx 600")
        # n8n reaches the gateway on loopback, containers on the stack address
        assert "http://10.89.1.1:8080/agent/stack-flowise:" in machine.succeed(
            "cat /var/lib/agentos-stack/secrets/flowise.llm.env")
        assert "http://127.0.0.1:8080/agent/stack-n8n:" in machine.succeed(
            "cat /var/lib/agentos-stack/secrets/n8n.llm.env")

    with subtest("the gateway listens on the stack address, the firewall allows only its port"):
        machine.wait_for_unit("agentos-model-gateway.service")
        machine.wait_for_open_port(8080)
        listeners = machine.succeed("ss -Htln")
        assert "10.89.1.1:8080" in listeners, listeners
        rules = machine.succeed("iptables -S agentstack-in")
        print(rules)
        assert "-d 10.89.1.1/32 -p tcp -m tcp --dport 8080 -j ACCEPT" in rules, rules
        assert "-j REJECT" in rules.strip().splitlines()[-1], rules
        machine.succeed("iptables -S INPUT | grep -- '-i agentstack0 -j agentstack-in'")
        machine.succeed("curl -sf http://10.89.1.1:8080/_agentos/health")

    with subtest("the Flowise container unit"):
        show = machine.succeed("systemctl show -p ExecStart --value podman-agentos-stack-flowise.service")
        start = re.search(r"path=(/nix/store/\S+)", show).group(1)
        script = machine.succeed(f"cat {start}")
        print(script)
        for want in [
            "-p 127.0.0.1:3000:3000",
            "--env-file /var/lib/agentos-stack/secrets/flowise.env",
            "-v /var/lib/agentos-stack/flowise:/root/.flowise",
            "--cap-drop=ALL",
            "--security-opt=no-new-privileges",
            "--memory=2G",
            "--network=agentstack",
            "flowiseai/flowise:3.1.4@sha256:",
        ]:
            assert want in script, (want, script)
        assert "--privileged" not in script, script
        assert "--cap-add" not in script, script
        assert "flowise.llm.env" not in script, script
        unit = machine.succeed("systemctl cat podman-agentos-stack-flowise.service")
        assert "agentos-stack-secrets.service" in unit and "agentos-stack-gw-flowise.service" in unit, unit
        machine.succeed("test -f /etc/containers/networks/agentstack.json")
  '';
}
