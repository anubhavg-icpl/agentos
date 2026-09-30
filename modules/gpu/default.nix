# AgentOS GPU module
#
# Driver stack for one GPU vendor, GPU-accelerated Ollama, and the state
# behind per-agent GPU scheduling:
#   - `agentos spawn --gpu [N|any]` reserves GPUs through `agentos-gpu`
#     (services/agentos_services/gpu.py). A GPU is held by one agent at a
#     time: <lockDir>/<index> contains the holder's agent id.
#   - the agent's unit gets access to exactly those device nodes
#     (DeviceAllow=; bind-mounted into container-isolated agents)
#   - the lock is released by the unit's ExecStopPost, and by the agent
#     daemon's reaper if that did not run
# Without GPUs (or with the module off) `agentos gpu` reports "No GPUs".
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.gpu;
  ollamaOn = config.agentos.ai-ml.enable && config.agentos.ai-ml.enableOllama;
  lockDir = "/run/agentos/gpu";
in
{
  options.agentos.gpu = {
    enable = lib.mkEnableOption "GPU drivers and per-agent GPU scheduling";

    vendor = lib.mkOption {
      type = lib.types.enum [ "nvidia" "amd" "intel" ];
      description = "GPU vendor of this machine; selects the driver stack";
    };

    nvidia.open = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use NVIDIA's open kernel modules (Turing and newer). Set to false
        for older cards, which need the proprietary module.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [{
        assertion = config.agentos.runtime.enable;
        message = "agentos.gpu needs agentos.runtime.enable";
      }];

      # The stock host is headless (hardware.graphics.enable = false)
      hardware.graphics.enable = lib.mkForce true;

      # Allocation registry. Group agentos = operators and the daemon; the
      # sandboxed agent user cannot even see the directory.
      systemd.tmpfiles.rules = [
        "d /run/agentos 0755 root root"
        "d ${lockDir} 2770 root agentos"
      ];
      agentos.services.settings.gpu.lock_dir = lockDir;
      systemd.services.agentos-daemon.serviceConfig.ReadWritePaths = [ "-${lockDir}" ];
    }

    (lib.mkIf (cfg.vendor == "nvidia") {
      # The driver is selected through videoDrivers even on a headless host
      services.xserver.videoDrivers = [ "nvidia" ];
      hardware.nvidia = {
        open = cfg.nvidia.open;
        modesetting.enable = true;
        nvidiaPersistenced = true;
      };
      # CDI spec for container runtimes (podman, docker, containerd)
      hardware.nvidia-container-toolkit.enable = true;
      services.ollama.package = lib.mkIf ollamaOn (lib.mkDefault pkgs.ollama-cuda);
    })

    (lib.mkIf (cfg.vendor == "amd") {
      services.xserver.videoDrivers = [ "amdgpu" ];
      hardware.graphics.extraPackages = [ pkgs.rocmPackages.clr.icd ];
      # Many ROCm programs look for HIP under /opt/rocm
      systemd.tmpfiles.rules = [ "L+ /opt/rocm/hip - - - - ${pkgs.rocmPackages.clr}" ];
      environment.systemPackages = [ pkgs.rocmPackages.rocminfo ];
      services.ollama.package = lib.mkIf ollamaOn (lib.mkDefault pkgs.ollama-rocm);
    })

    (lib.mkIf (cfg.vendor == "intel") {
      hardware.graphics.extraPackages = with pkgs; [
        intel-media-driver
        intel-compute-runtime
        vpl-gpu-rt
      ];
      # No CUDA/ROCm: Ollama uses Vulkan
      services.ollama.package = lib.mkIf ollamaOn (lib.mkDefault pkgs.ollama-vulkan);
    })
  ]);
}
