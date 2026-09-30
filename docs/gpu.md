# GPU support and scheduling

## NixOS module

```nix
agentos.gpu = {
  enable = true;
  vendor = "nvidia";      # or "amd", "intel"
  nvidia.open = true;     # false for pre-Turing cards
};
```

- `nvidia`: NVIDIA driver (`hardware.nvidia`, open kernel module by default,
  persistence daemon), `hardware.nvidia-container-toolkit` (CDI spec for
  podman/docker/containerd), Ollama built with CUDA (`ollama-cuda`).
- `amd`: `amdgpu`, ROCm OpenCL/HIP runtime (`/opt/rocm/hip`), `rocminfo`,
  Ollama with ROCm (`ollama-rocm`).
- `intel`: media and compute runtimes; Ollama uses Vulkan (`ollama-vulkan`).
- Sets `hardware.graphics.enable` (the stock host disables it).

The Ollama package is only changed when `agentos.ai-ml.enableOllama` is on and
uses `mkDefault`, so `services.ollama.package` can still be overridden. The
NVIDIA driver is unfree; the flake already allows unfree packages.

## Scheduling

```
agentos gpu                     # GPUs and the agent holding each
agentos spawn claude --gpu      # any free GPU
agentos spawn claude --gpu 1    # GPU 1 (or 0,1)
agentos spawn claude --gpu any --isolation container
```

`agentos-gpu` (services/agentos_services/gpu.py) discovers GPUs from `/dev`
and `/sys`: NVIDIA by `/dev/nvidia<N>` (plus `nvidiactl`, `nvidia-uvm*`,
`nvidia-modeset`), AMD and Intel by DRM render node and PCI vendor (AMD also
`/dev/kfd`). Without GPUs, `agentos gpu` prints "No GPUs" and `--gpu` fails
with "no GPUs on this machine".

A GPU is held by one agent at a time. The holder is recorded in
`/run/agentos/gpu/<index>` (directory `root:agentos` 2770, updates under a
`flock`). `agentos spawn --gpu`:

1. reserves the GPU as root (`sudo agentos-gpu alloc <id> <spec>`), failing
   if it is held or does not exist
2. gives the unit `DeviceAllow=<node> rw` for exactly the granted nodes and
   the `render`/`video` groups; in a container the nodes are bind-mounted
   and `/run/opengl-driver` is mounted read-only
3. exports `CUDA_VISIBLE_DEVICES`/`NVIDIA_VISIBLE_DEVICES`,
   `HIP_VISIBLE_DEVICES`/`ROCR_VISIBLE_DEVICES`, `AGENTOS_GPUS` and
   `LD_LIBRARY_PATH=/run/opengl-driver/lib`
4. records `gpus` in the agent state
5. releases the lock in the unit's `ExecStopPost=+`; the daemon's reaper also
   frees locks whose agent is no longer running (30 s grace, `[gpu]` in
   services.toml)

With `agentos.gpu.enable`, every sandboxed agent gets `DevicePolicy=closed`,
so agents without `--gpu` cannot open GPU devices. `--gpu` needs a sandboxed
or container agent (not `--unsandboxed`).
