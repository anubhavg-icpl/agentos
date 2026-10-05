# Agent stack

`agentos.agentStack` runs the apps of
[agent-fleet](https://github.com/anubhavg-icpl/agent-fleet) on the Nestlo host.
agent-fleet deploys them as Hugging Face Docker Spaces; here they are NixOS
services and podman containers behind the model gateway.

```nix
agentos.agentStack = {
  enable = true;                 # allows the apps below; off by default
  n8n.enable = true;
  localChat.enable = true;       # Open WebUI + Ollama through agentos.localAI
  flowise.enable = true;
  langflow.enable = true;
  anythingllm.enable = true;
  lobechat.enable = true;
  # openmuse: see "OpenMuse" below
};
```

Needs `agentos.runtime.enable` and `agentos.networking.enable` (the model
gateway). Everything is off by default; an app enabled without
`agentStack.enable` fails the build.

## Apps

| App | How | Host port (127.0.0.1) | Login |
|---|---|---|---|
| n8n | native, `services.n8n` | 5678 | owner account on first visit |
| local chat | native, `agentos.localAI` (Ollama + `services.open-webui`) | 8180 | first Open WebUI signup is admin |
| Flowise | podman, `flowiseai/flowise` | 3000 | basic auth, `fleet-admin` + generated password |
| Langflow | podman, `langflowai/langflow` | 7860 | `langflow` + generated password |
| AnythingLLM | podman, `mintplexlabs/anythingllm` | 3001 | generated instance password, then the wizard |
| LobeChat | podman, `lobehub/lobe-chat` | 3210 | generated access code |
| OpenMuse | podman, image you build | 7861 | generated access key |

Ports are options (`agentStack.<app>.port`). Nothing is opened in the
firewall and every port is published on `127.0.0.1` only; use an SSH tunnel
(`ssh -L 3000:127.0.0.1:3000 admin@host`) or put your own TLS proxy in front.

### n8n

`services.n8n` bound to `127.0.0.1` (`N8N_LISTEN_ADDRESS`). The encryption key
for stored credentials is generated at first boot and given to n8n as
`N8N_ENCRYPTION_KEY_FILE`, which the pinned module turns into a systemd
credential (the unit runs with `DynamicUser`, the file stays root-only).
`n8n.webhookUrl` sets `WEBHOOK_URL`. Telemetry, version notices, templates and
personalization are off. n8n keeps the default secure cookie: over plain HTTP
use `http://127.0.0.1` or `localhost` through the tunnel.

### Local chat

`agentStack.localChat.enable` turns on `agentos.localAI` (Ollama backend) with
Open WebUI and pulls the agent-fleet models `llama3.2:1b`, `qwen2.5:0.5b` and
`nomic-embed-text` (`localChat.models`, appended to `agentos.localAI.models`).
It is the same instance as in [local-ai.md](local-ai.md), not a second copy;
the `local` gateway provider is registered as usual. `WEBUI_AUTH=True`, and a
generated `WEBUI_SECRET_KEY`. The agent-fleet image bakes the models in; here
the pull unit fetches them after boot and tolerates being offline. Turn off
open signup in Open WebUI after the first account exists.

### Flowise, Langflow, AnythingLLM, LobeChat

`virtualisation.oci-containers` with the podman backend, container names
`agentos-stack-<app>`, units `podman-agentos-stack-<app>.service`. Each one:

- publishes `127.0.0.1:<port>:<container port>`;
- has a persistent directory `/var/lib/agentos-stack/<app>` mounted where the
  app keeps its state (Flowise `/root/.flowise`, Langflow `/app/langflow`,
  AnythingLLM `/app/server/storage`; LobeChat keeps chats in the browser and
  gets an unused `/data`);
- runs with `--cap-drop=ALL`, `--security-opt=no-new-privileges`, no
  `--privileged`, `--memory=<memoryMax>` without swap and `--pids-limit=2048`;
- is on its own podman network `agentstack` (bridge `agentstack0`);
- reads `/var/lib/agentos-stack/secrets/<app>.env` and, where the app takes its
  LLM endpoint from the environment, `<app>.llm.env`.

Capabilities can be added back per app (`agentStack.<app>.capabilities =
{ SYS_ADMIN = true; }`; AnythingLLM's web scraper wants it for Chromium's
sandbox) and `extraOptions` / `environment` extend the container.

The differences from the Spaces: Flowise does not run `npm install -g
flowise@latest` at build time but uses the official image; ports and the
Hugging Face proxy settings (`N8N_SECURE_COOKIE=false`, `WEBHOOK_URL`) are gone;
AnythingLLM stores data in `/app/server/storage` (the Dockerfile's
`/app/worker/storage` is a Spaces choice) and gets an instance password,
which agent-fleet does not set.

### OpenMuse

There is no upstream OpenMuse image. agent-fleet builds one from a `git clone`
of CopilotKit/openmuse (nginx, the Hono API, the task worker and a Playwright
Chromium worker under supervisord) with the public URL inlined into the web
bundle at build time. Shipping that from this flake would mean building a
Node 24 monorepo plus Playwright browsers inside Nix with a floating `git
clone`, which is not reproducible, so it is not part of the module. The option
exists so that an image you build yourself can run with the same hardening:

```sh
git clone https://github.com/anubhavg-icpl/agent-fleet
podman build --build-arg PUBLIC_URL=http://127.0.0.1:7861 \
  -t localhost/openmuse:local agent-fleet/spaces/openmuse
```

```nix
agentos.agentStack.openmuse = {
  enable = true;
  image = "localhost/openmuse:local";            # pin by digest when you can
  cpkKeyFile = "/run/secrets/cpk-intelligence";  # CPK_INTELLIGENCE_API_KEY=...
};
```

Enabling it without `image` and `cpkKeyFile` fails the build with this
explanation. It is untested: Chromium inside the container may need `--cap-add`
or a relaxed seccomp profile that this module does not grant by default.
Treat OpenMuse as unsupported.

## Secrets

`agentos-stack-secrets.service` (root oneshot, before every app) creates
`/var/lib/agentos-stack/secrets` (0700) and these files (0600) when missing:

| File | Content |
|---|---|
| `n8n-encryption-key` | 64 hex characters |
| `flowise.env` | `FLOWISE_USERNAME=fleet-admin`, `FLOWISE_PASSWORD` |
| `langflow.env` | `LANGFLOW_SUPERUSER=langflow`, `LANGFLOW_SUPERUSER_PASSWORD` |
| `lobechat.env` | `ACCESS_CODE` |
| `anythingllm.env` | `AUTH_TOKEN`, `JWT_SECRET` |
| `local-chat.env` | `WEBUI_SECRET_KEY` |
| `openmuse.env` | `OPENMUSE_ACCESS_KEY`, `TOKEN_ENCRYPTION_KEY`, `WORKER_TOKEN` |
| `<app>.gateway-token`, `<app>.llm.env` | gateway token and LLM endpoint (below) |

Read a password with `sudo cat /var/lib/agentos-stack/secrets/flowise.env`.
Rotate by deleting the file and restarting `agentos-stack-secrets` and the
app. Existing files are never overwritten (n8n: changing the key makes stored
credentials unreadable). Nothing generated is in the Nix store or in a unit
file; the container units only reference the paths.

## LLM routing through the model gateway

Every enabled app is a gateway agent `stack-<app>` (`stack-n8n`,
`stack-local-chat`, `stack-flowise`, `stack-langflow`, `stack-anythingllm`,
`stack-lobechat`, `stack-openmuse`). `agentos-stack-gw-<app>.service` creates a
token (`<app>.gateway-token`), registers its sha256 through the admin socket
and sets the daily budget `agentStack.<app>.budgetUsd` (default 2 USD), as
[openclaw.md](openclaw.md) does. It writes `<app>.llm.env` with the OpenAI-
and Anthropic-compatible base URLs
`http://<host>:8080/agent/stack-<app>:<token>/{openai/v1,anthropic}` and the
placeholder key `agentos-managed`; the gateway injects the real key. The apps
never get a provider key. `agentStack.gateway.openaiProvider = "local"` points
the OpenAI-compatible URL at the local Ollama instead.

| App | Gets the endpoint | How |
|---|---|---|
| local chat | automatic | `OPENAI_API_BASE_URL` / key in the Open WebUI environment (Ollama is used directly) |
| LobeChat | automatic | `OPENAI_PROXY_URL`, `ANTHROPIC_PROXY_URL` and keys |
| AnythingLLM | automatic | `LLM_PROVIDER=generic-openai`, `GENERIC_OPEN_AI_*`, model `agentStack.anythingllm.model` |
| Langflow | partly | `OPENAI_*`, `ANTHROPIC_*` in the environment and as global variables; components may still ask for the base URL |
| OpenMuse | best effort | `OPENAI_API_KEY`, `OPENAI_BASE_URL` |
| n8n | UI | add an OpenAI/Anthropic credential with the base URL from `sudo cat .../n8n.llm.env` and any key |
| Flowise | UI | set the node's BasePath and a credential from `.../flowise.llm.env` |

Native apps (n8n, local chat) use `127.0.0.1:8080`. Containers use
`agentStack.network.gatewayAddress` (default `10.89.1.1`): an address of the
host on `lo`, outside the container subnet `10.89.0.0/24`, so it exists at
boot and the gateway (`gateway.listen`, which now has a third entry) can bind
to it before podman creates the bridge. The firewall chain `agentstack-in`
(for `-i agentstack0`) accepts established traffic and TCP to
`10.89.1.1:8080`, and rejects the rest, so containers cannot reach SSH,
Ollama, the dashboard or other host services. The gateway admin socket is a
Unix socket and is not reachable at all.

## Limits

- Containers have outbound internet through podman's NAT (Flowise and others
  fetch URLs and packages); the `agentos.security` egress allowlist applies to
  agents, not to these containers. DNS is not provided on the stack bridge:
  containers inherit the host's resolver configuration, which does not work if
  it is a loopback stub. Set `extraOptions = [ "--dns=1.1.1.1" ]` per app.
- Apps that call providers directly (a key entered in the UI) bypass the
  gateway and its budgets. The apps hold no key unless you type one in.
- Apps with UI-only LLM configuration (n8n, Flowise) route through the gateway
  only if you enter the URL. Langflow components and OpenMuse may ignore the
  environment.
- Budgets are per app and per day. Local models cost 0.
- Container images are untested in the VM test (no network): only the
  generated unit and options are checked. First start pulls the image, so the
  unit is slow to start and fails until the registry is reachable (it retries).
- Each enabled app is linked from the Nestlo dashboard (`/api/links`) when
  the dashboard is enabled.
- The cap-drop default is conservative. If an image misbehaves (entrypoints
  that `chown` or `su`), add the capability for that app instead of
  `--privileged`.

## Pinning images

Defaults are `name:tag@sha256:<digest>`; podman verifies the digest. To bump:

```sh
skopeo inspect --override-os linux docker://docker.io/flowiseai/flowise:3.1.5 | jq -r .Digest
# or, without skopeo, the Docker-Content-Digest header of
# GET https://registry-1.docker.io/v2/<repo>/manifests/<tag> (with a pull token)
```

Pinned at the time of writing (indexes, multi-arch):

| App | Image |
|---|---|
| Flowise | `flowiseai/flowise:3.1.4` |
| Langflow | `langflowai/langflow:1.12.4` |
| LobeChat | `lobehub/lobe-chat:1.143.3` |
| AnythingLLM | `mintplexlabs/anythingllm:master` (upstream has no version tags, only `latest`/`master` and `render-*`; the digest is what is pinned) |

## Relation to the Hugging Face deployment

agent-fleet's `deploy.py` creates public Docker Spaces and injects generated
secrets as Space secrets; its Dockerfiles build on the same upstream images.
Here the same apps run on your machine, private by construction, with the
secrets generated locally and LLM spend metered by the Nestlo gateway. The two
are independent: nothing here talks to Hugging Face, and the static `chat` and
`agent-hub` Spaces (browser inference, a landing page) are not part of the
stack.

Test: `nix build .#checks.x86_64-linux.agent-stack` (n8n native, secrets,
gateway registration and listener, and the Flowise container unit).
