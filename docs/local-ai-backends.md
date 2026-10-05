# LocalAI and vLLM backends (`nestlo.localAI.localai`, `nestlo.localAI.vllm`)

[`nestlo.localAI`](local-ai.md) runs Ollama or llama.cpp. Two more inference
servers can run next to it, each as its own module with its own options:

| Server | Licence | Best for | Option set |
|---|---|---|---|
| [LocalAI](https://localai.io) | MIT | CPU or small-GPU serving of GGUF models, embeddings, many model formats behind one API | `nestlo.localAI.localai` |
| [vLLM](https://github.com/vllm-project/vllm) | Apache-2.0 | Throughput on NVIDIA/AMD GPUs, several concurrent agents on one model | `nestlo.localAI.vllm` |

Both bind to 127.0.0.1 and are registered with the model gateway as providers
of api `openai-compatible` at $0 (`zeroCost`), exactly as `local` is. Agents
therefore use them through the gateway, with budgets, rate limits, loop
detection, DLP and the audit log in front:

```
$OPENAI_BASE_URL = http://127.0.0.1:8080/agent/<id>:<token>/localai/v1
$OPENAI_BASE_URL = http://127.0.0.1:8080/agent/<id>:<token>/vllm-coder/v1
```

The modules live in `modules/local-ai/localai.nix` and `modules/local-ai/vllm.nix`
and are independent of `nestlo.localAI.enable`: any combination of Ollama,
llama.cpp, LocalAI and vLLM can run on one machine (each has its own port).

## Why the servers have an API key

Loopback is reachable by every local user, and the agent user is one. An
unauthenticated server on 127.0.0.1 would let a sandboxed agent skip the
gateway, so a request would escape budgets, DLP and the audit log. Both
modules therefore make the server require a key (`apiKey.enable`, default
true):

- a oneshot unit (`nestlo-localai-key`, `nestlo-vllm-key`) creates a random
  key once, in `/var/lib/nestlo-localai/api-key` or `/var/lib/nestlo-vllm/api-key`,
  owner root, group `nestlo` (the gateway's group), mode 0640, in a 0750
  directory the agent user cannot enter;
- the key is the provider's `keyFile`; the gateway injects it and agents only
  ever hold the placeholder `nestlo-managed`;
- the server receives it as a systemd credential (vLLM, LocalAI package) or
  through a root-only env file (LocalAI container), never on a command line.

Both modules need the group `nestlo` (`nestlo.runtime.enable`) for this and
assert it. Set `apiKey.enable = false` only on a machine without agents.

## LocalAI

```nix
nestlo.networking.enable = true;
nestlo.localAI.localai = {
  enable = true;
  modelConfigs.qwen-coder = {
    backend = "llama-cpp";
    parameters.model = pkgs.fetchurl { url = "https://.../qwen2.5-coder-7b-q4_k_m.gguf"; hash = "sha256-..."; };
    context_size = 8192;
  };
};
```

### Deployment: container by default

| `deployment` | What runs | Status |
|---|---|---|
| `container` (default) | `localai/localai:v3.9.0` (CPU, `-gpu-nvidia-cuda-12` or `-gpu-hipblas` following `nestlo.localAI.resolvedAcceleration`) under Podman, pinned by digest, API published on 127.0.0.1 only | works; needs to pull the image on first start |
| `package` | `pkgs.local-ai` as a hardened systemd unit | `pkgs.local-ai` 2.28.0 is `broken = true` in the pinned nixpkgs (it does not build with the current Go: `cp: cannot stat 'bin/rpc-server'`), and nixpkgs has no `services.local-ai` (only a test-only module that is not in the module list). Use it with your own `package` |

The container is the default because the package does not build, and it is
also the better isolated choice: LocalAI starts its model backends as gRPC
servers on localhost TCP ports. In the container they live in the container's
network namespace and only the API port is published; in the package unit they
are on the host's loopback.

Container hardening: all capabilities dropped, `no-new-privileges`, a PID
limit, models mounted read-only, only the API port published. The container is
not forced offline, because LocalAI downloads a model's backend from its
gallery on first use; once the backends are in `/var/lib/local-ai/backends`
(persisted) an egress filter on the Podman bridge can close that door.

### Options

| Option | Default | Meaning |
|---|---|---|
| `enable` | false | |
| `deployment` | `container` | `container` or `package` |
| `image` | v3.9.0 by digest | Container image (CPU, CUDA 12 or ROCm by `resolvedAcceleration`) |
| `package` | `pkgs.local-ai` | Package for `deployment = package` |
| `port` | 8082 | Loopback port (8080 is the gateway, 8081 llama.cpp, 11434 Ollama) |
| `modelConfigs` | `{}` | Model name to LocalAI model config. A derivation in `parameters.model` is linked next to the generated YAML. Empty: the server starts without models and `GET /v1/models` lists none |
| `modelsPath` | null | Use an existing directory instead (mounted read-only); excludes `modelConfigs` |
| `extraReadPaths` | `[]` | Package mode: further read-only paths for the unit |
| `threads`, `parallelRequests`, `logLevel` | 4, 1, `warn` | Server tuning |
| `memoryMax` | null | systemd `MemoryMax` of the server |
| `gpuDevices` | null | `CUDA_/HIP_VISIBLE_DEVICES` (no `nestlo gpu` lock, see below) |
| `allowOutbound` | false | Package mode: allow non-loopback connections (default: `IPAddressDeny=any`) |
| `extraArgs` | `[]` | Package mode: extra `local-ai` flags |
| `apiKey.enable` | true | See above |
| `providerName` | `localai` | Entry in `nestlo.networking.providers` |

Package mode unit: `DynamicUser`, `ProtectSystem=strict`, `ProtectHome`,
`PrivateTmp`, `NoNewPrivileges`, empty capability set, `@system-service`
minus `@privileged`, only AF_UNIX/AF_INET/AF_INET6, `IPAddressAllow=localhost`
and `IPAddressDeny=any`, `PrivateDevices` except for GPU builds (then
`DevicePolicy=closed` with the NVIDIA/ROCm nodes allowed).

## vLLM

```nix
nestlo.networking.enable = true;
nestlo.localAI.vllm = {
  enable = true;
  models.coder = {
    model = "/var/lib/models/Qwen2.5-Coder-7B-Instruct";   # or a Hugging Face id in cacheDir
    gpus = [ 0 ];
    maxModelLen = 32768;
  };
};
nixpkgs.config.allowUnfree = true;   # CUDA
```

vLLM serves one model per process, so `models` declares one unit per model:
`nestlo-vllm-<name>.service`, port `basePort` plus the model's position in
alphabetical order (8090, 8091, ...) unless set, provider `vllm-<name>`.

| Option | Default | Meaning |
|---|---|---|
| `enable` | false | Needs at least one model |
| `acceleration` | follows `nestlo.localAI.resolvedAcceleration` | `cuda`, `rocm` or `cpu`; picks the package and the device access |
| `package` | `pkgs.unstable.pkgsCuda.vllm` / `pkgsRocm.vllm` / `vllm` | Must have `bin/vllm`. Stable nixpkgs' vLLM 0.16.0 is marked insecure (15 known CVEs); unstable has 0.24.0 |
| `basePort` | 8090 | First port for models without `port` |
| `cacheDir` | `/var/cache/nestlo-vllm` | Hugging Face cache (`HF_HOME`), mounted read-only into the units |
| `offline` | true | `HF_HUB_OFFLINE`, `TRANSFORMERS_OFFLINE` and `IPAddressDeny=any`: the unit cannot download anything |
| `apiKey.enable` | true | See above |
| `models.<name>.model` | | Hugging Face id (needs to be in `cacheDir` when offline) or an absolute path |
| `models.<name>.servedModelName` | `<name>` | The model name clients send |
| `models.<name>.providerName` | `vllm-<name>` | Gateway provider |
| `models.<name>.port` | null | Loopback port |
| `models.<name>.gpus` | `[ 0 ]` | GPU indices: `CUDA_VISIBLE_DEVICES`, the device nodes the unit may open, and `--tensor-parallel-size` when more than one |
| `models.<name>.maxModelLen`, `gpuMemoryUtilization` (0.85), `dtype`, `quantization`, `extraArgs` | | `vllm serve` flags |

The unit is `DynamicUser`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`,
no capabilities, `IPAddressDeny=any` when offline, and for GPU builds
`DevicePolicy=closed` with exactly the device nodes of the listed GPUs
(`/dev/nvidia<N>` plus the shared control nodes, or `/dev/kfd` and the DRM
class for AMD). `HOME` and the Python, Triton and JIT caches are the unit's
cache directory; `/proc/cpuinfo`, `/proc/meminfo` and `/proc/driver/nvidia`
stay visible (other processes are hidden).

### GPU scheduling

`nestlo spawn --gpu` reserves a GPU for an agent through a lock file per
index (`<lockDir>/<index>`, see [gpu.md](gpu.md)). The daemon's reaper frees
the lock of a holder that is not a running agent, so a server cannot keep a
lock. The servers therefore declare their GPUs in `models.<name>.gpus`
instead and take no lock, as the Ollama/llama.cpp module does. To keep the
GPUs of a vLLM server away from agents, give agents explicit indices
(`nestlo spawn --gpu 2`) outside `gpus`, and keep `gpuMemoryUtilization` below
1.0 when an agent shares a GPU with vLLM.

## Budgets and routing

Both kinds of provider are $0, so cost routing may prefer them
([gateway-features.md](gateway-features.md)):

```nix
nestlo.networking.providers.openai.fallbacks = [ { provider = "vllm-coder"; model = "coder"; } ];
```

(A fallback must use the same wire format, so these suit `openai` entries,
not Anthropic's Messages API.)

## Tests

`tests/local-ai-backends.nix` boots a VM with both modules and checks: the key
generator (readable by the gateway's group, not by `nestlo-agent`, stable
across restarts), the LocalAI container definition (loopback publish, digest
pin, dropped capabilities, key from the env file, generated model YAML), the
vLLM unit (hardening, ports, environment, device allow list, key credential,
no key on the command line), and both providers in the gateway's config.

Neither server is started in the test. LocalAI would need its image from
Docker Hub (no network in the VM) and the nixpkgs package is broken; vLLM
needs a GPU. Verified by hand instead, on a machine with network: start the
container, `curl -H "Authorization: Bearer $(cat /var/lib/nestlo-localai/api-key)"
http://127.0.0.1:8082/v1/models` returns an empty list without models, and the
same request without the key is refused.

## Limits

- LocalAI container mode needs the network on first start (image, then the
  backend of each model). The package mode is not buildable until nixpkgs
  fixes `local-ai`.
- The LocalAI environment variable names used for the container
  (`LOCALAI_API_KEY`, `LOCALAI_MODELS_PATH`, `LOCALAI_BACKENDS_PATH`,
  `LOCALAI_THREADS`, `LOCALAI_LOG_LEVEL`, `LOCALAI_PARALLEL_REQUESTS`,
  `LLAMACPP_PARALLEL`) and the package-mode flags (`--address`, `--threads`,
  `--models-path`, `--localai-config-dir`, `--parallel-requests`,
  `--log-level`) were checked against the v3.9.0 sources (`core/cli/run.go`,
  `core/cli/context/context.go`) and the image digests against Docker Hub; the
  container itself was not run in this tree. The vLLM flags and variables
  (`vllm serve`, `--host`, `--port`, `--served-model-name`, `--dtype`,
  `--gpu-memory-utilization`, `--max-model-len`, `--quantization`,
  `--tensor-parallel-size`, `VLLM_API_KEY`, `VLLM_NO_USAGE_STATS`,
  `VLLM_CACHE_ROOT`) were checked against v0.24.0.
- vLLM from source takes hours to build and its CUDA build is unfree. Use a
  binary cache.
- The key protects the API port. The gRPC backends of a LocalAI package unit
  are not protected (use the container).
- No GPU lock is taken (see above).
