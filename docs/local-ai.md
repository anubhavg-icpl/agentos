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

### Pricing contract (needs the gateway side)

The gateway prices a model by name from `pricing.json`; unknown models are
charged the high `default` and reported unpriced. Local model names are
arbitrary, so without more work local calls would be billed as expensive.
This module cannot fix that from configuration. The contract it relies on,
for the `openai-compatible` provider type being added to the gateway:

- `agentos.networking.providers.local.api` is overridable (the module sets
  `lib.mkDefault "openai"`). With the new type, set
  `agentos.networking.providers.local.api = "openai-compatible";` once the
  `api` enum in modules/networking accepts it.
- For a provider of that type the gateway prices every request at zero
  (`input_per_1m = output_per_1m = 0`, `priced = true`) whatever the model
  name, and a missing `key_file` means no key injection.
- For `strategy = "cheapest"`, a model served by `local` must count as cost 0
  and belong to provider `local`, so equivalence groups mixing it with a
  hosted model are skipped (routing never crosses vendors) unless the group
  consists of local models only.

Until then, add zero-priced entries for the models you pull to your
`agentos.budget-controller.pricingFile`:

```json
"qwen2.5-coder:7b": { "provider": "local", "input_per_1m": 0, "output_per_1m": 0 }
```

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
