# VM test of the local inference module (CPU, Ollama, no model weights):
#
#   nix build .#checks.x86_64-linux.local-ai
#
# Checks that the server starts, listens on loopback only, that the model
# pull oneshot tolerates the VM being offline, and that the backend is
# registered with the gateway as the keyless provider `local`. No GGUF is
# fetched: a fixed-output model would add a hash that has to be maintained,
# so inference itself is not exercised here.
{ pkgs, agentosModules }:

pkgs.testers.runNixOSTest {
  name = "agentos-local-ai";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 2048;

    agentos = {
      runtime.enable = true;
      networking.enable = true;
      localAI = {
        enable = true;
        backend = "ollama";
        acceleration = "cpu";
        # Unreachable in the VM: the pull unit must still succeed
        models = [ "tiny-model:latest" ];
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("ollama.service")
    machine.wait_for_open_port(11434)

    with subtest("listens on loopback only"):
        listeners = machine.succeed("ss -Htln")
        print(listeners)
        assert "127.0.0.1:11434" in listeners, listeners
        for line in listeners.splitlines():
            if ":11434" in line:
                assert "127.0.0.1:11434" in line, line
        machine.succeed("curl -sf http://127.0.0.1:11434/api/version")

    with subtest("an offline model pull does not fail the boot"):
        machine.wait_for_unit("agentos-local-ai-pull.service")
        journal = machine.succeed("journalctl -u agentos-local-ai-pull --no-pager")
        assert "could not pull tiny-model:latest" in journal, journal

    with subtest("registered as the gateway provider 'local'"):
        machine.wait_for_unit("agentos-model-gateway.service")
        machine.wait_for_open_port(8080)
        cfg = machine.succeed("cat /etc/agentos/services.toml")
        print(cfg)
        assert "providers.local" in cfg, cfg
        assert "http://127.0.0.1:11434" in cfg, cfg
        assert "openai-compatible" in cfg and "zero_cost = true" in cfg, cfg
        machine.succeed("curl -sf http://127.0.0.1:8080/_agentos/health")
  '';
}
