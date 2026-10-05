# VM test of the LocalAI and vLLM backends (modules/local-ai/localai.nix and
# vllm.nix):
#
#   nix build .#checks.x86_64-linux.local-ai-backends
#
# Neither server is started, and that is deliberate:
#   - LocalAI: `pkgs.local-ai` is marked broken in the pinned nixpkgs, so the
#     package deployment cannot be built, and the default container
#     deployment needs to pull an image (about 1 GB) from Docker Hub, which a
#     test VM has no network for. The test therefore checks the container
#     definition (loopback-only publish, digest-pinned image, key env file,
#     dropped capabilities) and the generated model directory.
#   - vLLM needs a GPU and weights (and a multi-hour source build): the test
#     replaces the package with a stub and checks the unit (hardening, ports,
#     environment, GPU device access, key credential).
# What does run for real: the API-key generator, which must give the key to
# group nestlo (the gateway) and not to the agent user, and the gateway, which
# must list both backends as providers of api `openai-compatible` at $0 with
# the generated key files.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-local-ai-backends";
  globalTimeout = 1800;

  nodes.machine = { lib, ... }: {
    imports = nestloModules ++ [
      ./../modules/local-ai/localai.nix
      ./../modules/local-ai/vllm.nix
    ];

    virtualisation.memorySize = 3072;

    nestlo = {
      runtime.enable = true;
      networking.enable = true;
      localAI = {
        localai = {
          enable = true;
          modelConfigs.qwen = {
            backend = "llama-cpp";
            parameters.model = "qwen.gguf";
          };
        };
        vllm = {
          enable = true;
          acceleration = "cuda";
          # a stand-in with bin/vllm: the real package is not built here
          package = pkgs.writeShellScriptBin "vllm" "echo stub vllm \"$@\"";
          models.coder = {
            model = "/var/lib/models/coder";
            gpus = [ 0 1 ];
            maxModelLen = 8192;
          };
        };
      };
    };

    # not started in the VM (no GPU or weights; no network for the image)
    systemd.services.nestlo-vllm-coder.wantedBy = lib.mkForce [ ];
    systemd.services.podman-nestlo-localai.wantedBy = lib.mkForce [ ];
  };

  testScript = ''
    import json

    def unit_text(name):
        # the unit file plus the start script it runs, if the command is one
        text = machine.succeed(f"systemctl cat {name}")
        show = machine.succeed(f"systemctl show {name} -p ExecStart")
        for path in set(__import__("re").findall(r"/nix/store/[^ ;]+", show)):
            rc, body = machine.execute(f"test -f {path} && head -c 20000 {path}")
            if rc == 0:
                text += "\n" + body
        return text

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-localai-key.service")
    machine.wait_for_unit("nestlo-vllm-key.service")

    with subtest("the generated keys are readable by the gateway and not by the agent user"):
        for d in ["nestlo-localai", "nestlo-vllm"]:
            key = machine.succeed(f"cat /var/lib/{d}/api-key").strip()
            assert len(key) == 64, key
            machine.succeed(f"runuser -u nestlo -- cat /var/lib/{d}/api-key")
            machine.fail(f"runuser -u nestlo-agent -- cat /var/lib/{d}/api-key")
            machine.fail(f"runuser -u nestlo-agent -- ls /var/lib/{d}")
        env = machine.succeed("cat /var/lib/nestlo-localai/container.env")
        assert env.startswith("LOCALAI_API_KEY=") and len(env.strip()) == 16 + 64, env
        machine.succeed("test \"$(stat -c %a /var/lib/nestlo-localai/container.env)\" = 600")
        # a second run keeps the key
        before = machine.succeed("cat /var/lib/nestlo-localai/api-key")
        machine.succeed("systemctl restart nestlo-localai-key.service")
        assert machine.succeed("cat /var/lib/nestlo-localai/api-key") == before

    with subtest("LocalAI container: loopback publish only, pinned image, key from the env file"):
        unit = unit_text("podman-nestlo-localai")
        print(unit)
        assert "127.0.0.1:8082:8080" in unit, unit
        assert "localai/localai:v3.9.0@sha256:" in unit, unit
        assert "--cap-drop=ALL" in unit and "no-new-privileges" in unit, unit
        assert "/var/lib/nestlo-localai/container.env" in unit, unit
        assert "LOCALAI_API_KEY=" not in unit, "the key must not be in the unit"
        # the declared model config reached the models directory mounted into the container
        store = __import__("re").search(r"(/nix/store/[^ :]*local-ai-models):/models:ro", unit)
        assert store, unit
        store = store.group(1)
        yaml = machine.succeed(f"cat {store}/qwen.yaml")
        assert "name: qwen" in yaml and "backend: llama-cpp" in yaml, yaml

    with subtest("vLLM unit: one hardened unit per model, GPU access limited to its devices"):
        unit = unit_text("nestlo-vllm-coder")
        print(unit)
        for want in [
            "DynamicUser=true", "ProtectSystem=strict", "NoNewPrivileges=true", "CapabilityBoundingSet=",
            "CUDA_VISIBLE_DEVICES=0,1", "HF_HUB_OFFLINE=1", "IPAddressDeny=any", "DevicePolicy=closed",
            "DeviceAllow=/dev/nvidia0 rw", "DeviceAllow=/dev/nvidia1 rw", "DeviceAllow=/dev/nvidiactl rw",
            "LoadCredential=api-key:/var/lib/nestlo-vllm/api-key", "VLLM_NO_USAGE_STATS=1",
        ]:
            assert want in unit, want
        assert "/dev/nvidia2" not in unit
        body = unit
        for want in [
            "serve /var/lib/models/coder", "--host 127.0.0.1", "--port 8090", "--served-model-name coder",
            "--max-model-len 8192", "--tensor-parallel-size 2",
        ]:
            assert want in body, want
        # the key is passed through the environment, never on the command line
        assert "--api-key" not in body and "VLLM_API_KEY=" in body
        # not started: no GPU here
        machine.require_unit_state("nestlo-vllm-coder.service", "inactive")

    with subtest("both backends are gateway providers of api openai-compatible at zero cost"):
        machine.wait_for_unit("nestlo-model-gateway.service")
        machine.wait_for_open_port(8080)
        cfg = machine.succeed("cat /etc/nestlo/services.toml")
        print(cfg)
        for name, url, keyfile in [
            ("localai", "http://127.0.0.1:8082", "/var/lib/nestlo-localai/api-key"),
            ("vllm-coder", "http://127.0.0.1:8090", "/var/lib/nestlo-vllm/api-key"),
        ]:
            assert f"providers.{name}" in cfg, name
            assert url in cfg and keyfile in cfg, (name, url)
        assert cfg.count("openai-compatible") >= 2 and cfg.count("zero_cost = true") >= 2, cfg
        machine.succeed("curl -sf http://127.0.0.1:8080/_nestlo/health")
  '';
}
