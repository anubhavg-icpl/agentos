# Local AI

`agentos.localAI` runs a local model server on the machine and exposes it to
agents through the model gateway, so local models get the same budgets, rate
limits, loop detection and recording as hosted ones.

```nix
agentos.localAI = {
  enable = true;
  backend = "ollama";            # or "llama-cpp"
  acceleration = "auto";         # "cuda" | "rocm" | "cpu"
  models = [ "qwen2.5-coder:7b" ];
  webui.enable = true;           # Open WebUI on 127.0.0.1:8180
};
```

## Options

| Option | Meaning |
|---|---|
| `backend` | `ollama` (`services.ollama`, port 11434) or `llama-cpp` (`services.llama-cpp`, port 8081; 8080 is the gateway) |
| `acceleration` | `auto` follows `agentos.gpu.vendor` (nvidia = cuda, amd = rocm) or `services.xserver.videoDrivers`, else cpu. Intel resolves to cpu. `resolvedAcceleration` shows the result |
| `models` | Ollama models pulled by `agentos-local-ai-pull.service` (oneshot) |
| `modelFile`, `extraFlags` | llama-cpp: GGUF path (required) and extra `llama-server` flags |
| `gpuDevices` | restrict to GPU indices (`CUDA_/HIP_/ROCR_VISIBLE_DEVICES`) |
| `keepAlive` | Ollama `OLLAMA_KEEP_ALIVE`, how long an idle model keeps its VRAM |
| `webui.enable`, `webui.port` | `services.open-webui` on loopback, pointed at the backend (telemetry off) |

The pinned nixpkgs has no `services.ollama.acceleration` (it is a removed
option); acceleration is chosen by package: `ollama-cuda`, `ollama-rocm`,
`ollama-cpu`, and `llama-cpp` overridden with `cudaSupport`/`rocmSupport`. The
package is set with `mkOverride 900`, above the `mkDefault` of `agentos.gpu`.

Everything binds to 127.0.0.1. Nothing is opened in the firewall.

The pull unit does not use `services.ollama.loadModels`, which retries
forever when offline. It waits up to 60 s for the server, tries each pull,
logs failures and exits 0. Retry with `systemctl restart agentos-local-ai-pull`.

## Gateway provider `local`

The module registers `agentos.networking.providers.local`:
`baseUrl = http://127.0.0.1:<port>`, `api = "openai"`, no `keyFile`. The
backend's OpenAI-compatible API is at `/v1`, so an agent uses

```
$OPENAI_BASE_URL = http://127.0.0.1:8080/agent/<id>:<token>/local/v1
```

and any key (the gateway injects none).

### Pricing

The module registers `local` with `api = "openai-compatible"` and
`zeroCost = true` (`agentos.networking.providers.local.*`), so every request
to it is metered at $0 and cost routing can send work there. See
[gateway-features.md](gateway-features.md) for routing rules.

### Routing example

The routing rules rewrite the model within one provider, so cost routing
between hosted and local models cannot cross providers. Within local, route
all CI agents to a small model, and pick the cheapest of a local group:

```nix
agentos.budget-controller.routing = {
  strategy = "cheapest";
  agentRewrites."ci-"."qwen2.5-coder:7b" = "qwen2.5-coder:1.5b";
  equivalenceGroups = [ [ "qwen2.5-coder:7b" "qwen2.5-coder:1.5b" ] ];
};
```

Choosing `local` instead of a hosted provider is done by the agent's base
URL (`/local/` instead of `/anthropic/`), for example by running the agent
with `OPENAI_BASE_URL` pointing at the local route.

## GPU interaction

The inference server is a system service, not an agent: it does not take a
lock from `agentos gpu` (the reaper in the agent daemon would free any lock
whose holder is not a running agent). It holds GPU memory while a model is
loaded, so an agent started with `--gpu` on the same device competes for
VRAM, and may fail with out-of-memory. Options:

- On multi-GPU machines pin the server with `gpuDevices = "0"` and spawn
  agents with `--gpu 1`.
- Set `keepAlive` (Ollama) low so idle models release VRAM.
- On one GPU, stop the server (`systemctl stop ollama`) before GPU agents.

The server's unit keeps the upstream device policy, independent of the
agent sandbox's `DevicePolicy=closed`, which only affects agents.

## Checks

`checks.x86_64-linux.local-ai` boots a VM with the CPU Ollama backend and
checks that the server listens on 127.0.0.1 only, that the offline model pull
does not fail boot, and that `providers.local` is in `services.toml`. No
model weights are fetched, so inference is not exercised.
