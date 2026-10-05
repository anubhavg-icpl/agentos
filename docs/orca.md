# Agent Orca (`nestlo.orca`)

[Agent Orca](https://github.com/heddles/agent-orca) (Apache-2.0, Go) is a
Kubernetes operator for AI agents. Agents, model providers, model selectors,
tools, MCP servers, workflows, guardrail policies and knowledge bases are
custom resources. Each run (`AgentRun`) is a pod: the agent image plus a
model-router sidecar that talks to the models, resolves tool calls, applies
guardrails, tracks spend and checkpoints state. A web UI, an ACP API and an
external task API come with it, and `aoctl` is its command-line client.

`nestlo.orca` makes it part of Nestlo, on one machine:

| What | How |
|------|-----|
| A cluster | Single-node k3s (`services.k3s`), pod and service ranges that stay clear of Nestlo's own networks |
| The platform | Operator, UI proxy, model router, MCP ingester, Redis and the pause image are built by Nix (`packages.<system>.agent-orca`) and loaded into k3s; nothing of the platform is pulled from a registry |
| The chart | The `agent-orca` Helm chart from the same pinned source, deployed by k3s' Helm controller (`services.k3s.autoDeployCharts`) |
| Models | `ModelProvider` resources that point at the Nestlo model gateway as agent `orca`, plus a `ModelSelector` named `default`. Real provider keys never enter the cluster |
| Budget | A daily gateway budget for agent `orca` (`budgetUsd`); the gateway's DLP, loop detection, audit trail and metrics apply to every orca model call |
| Access | The UI, the ACP API and the external task API on loopback ports; `aoctl` and `kubectl` installed and pointed at them |

## Enable

```nix
nestlo.networking.enable = true;        # required: the model gateway
nestlo.orca = {
  enable = true;
  budgetUsd = 20;
  allowedRegistries = [ "ghcr.io/myorg/" ];
};
```

`nestlo.networking.enable` is asserted: orca sends all model calls through the
Nestlo model gateway, and the gateway needs provider keys as usual
([gateway-features.md](gateway-features.md)). The first boot builds the images
and the UI, which takes a while; `packages.<system>.agent-orca` is the same
build.

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Everything on this page |
| `package` | `pkgs.nestlo.agent-orca` | Binaries (`aoctl`, the operator), the chart and the images |
| `namespace` | `agent-orca-system` | Namespace of the operator, the UI and Redis |
| `agentId` | `orca` | Gateway agent id that every orca model call is made as (budget, logs, audit) |
| `budgetUsd` | `20` | Daily gateway budget of `agentId`, in USD |
| `models` | `claude-sonnet` (anthropic, `claude-sonnet-4-6`) and `gpt-4o` (openai) | ModelProviders by name; see below. `{ }` leaves ModelProviders to you |
| `providerNamespaces` | `[ "default" ]` | Namespaces besides `namespace` that get the ModelProviders and the `default` ModelSelector. Create Agents there |
| `allowedRegistries` | `[ ]` | Image prefixes agent and tool images may come from; empty allows every registry |
| `redis.enable` | `true` | Run the chart's Redis (checkpoints, spend, token streams) |
| `chartValues` | `{ }` | Extra values for the chart, merged over Nestlo's. Stored in the world-readable Nix store: no secrets |
| `k3s.clusterCidr` | `10.220.0.0/16` | Pod range (k3s' default `10.42.0.0/16` overlaps the `nestlo0` network) |
| `k3s.serviceCidr` | `10.221.0.0/16` | Service range |
| `k3s.clusterDns` | `10.221.0.10` | Cluster DNS address, inside `serviceCidr` |
| `k3s.disable` | `traefik`, `servicelb`, `metrics-server`, `local-storage` | k3s components left out. CoreDNS stays |
| `network.gatewayAddress` | `10.89.3.1` | Host address, on `lo`, where pods reach the model gateway |
| `ports.ui` | `9980` | Loopback port of the web UI |
| `ports.acp` | `9981` | Loopback port of the ACP API (agent discovery and runs) |
| `ports.tasks` | `9982` | Loopback port of the external task API |

`models.<name>` takes:

| Field | Default | Meaning |
|-------|---------|---------|
| `provider` | required | Nestlo gateway provider (a `nestlo.services.settings.providers` entry) that serves the model. Orca speaks Chat Completions, so the provider must offer `v1/chat/completions`: OpenAI and OpenAI-compatible providers do, and so does `anthropic` (its OpenAI-compatible endpoint) |
| `model` | required | Model name as the provider knows it, sent unchanged |
| `capabilities` | `[ ]` | Tags for orca's rule-based router: `reasoning`, `code`, `vision`, `fast`, `long-context`, `cheap` |
| `latencyProfile` | `medium` | `fast`, `medium` or `slow` |
| `constraints` | `{ }` | The ModelProvider's `spec.constraints` (context window, output limit, prices) |

## What the module sets up

**k3s.** `services.k3s` runs as a server with `--cluster-cidr`,
`--service-cidr` and `--cluster-dns` from the options above, `--pause-image`
set to a Nix-built image, and a kubeconfig readable by root only
(`/etc/rancher/k3s/k3s.yaml`, mode 0600). Traefik, servicelb, metrics-server
and local-storage are disabled. `KUBECONFIG` is set for login sessions and
`kubectl` is installed, so operators use `sudo -i` or root.
`networking.dhcpcd.denyInterfaces` keeps dhcpcd away from `cni0`,
`flannel.1` and `veth*`.

**Images.** The operator, the UI proxy, the model router and the MCP ingester
(built from the pinned Agent Orca source), Redis and the pause image are Nix
images listed in `services.k3s.images`, so k3s imports them from the store at
start. The chart values use `pullPolicy: Never` for them. Not included: the
images of CoreDNS (k3s pulls it from the internet), and any agent or tool
image you use.

**Chart.** `agent-orca` is deployed into `namespace` by the k3s Helm
controller. Nestlo sets: the Nix images, `operator.allowedRegistries` from
`allowedRegistries`, Redis from `redis.enable`, and `metrics.enabled = true`.
It sets `database.enabled = false` and `hindsight.enabled = false`, see
"What is not included". `chartValues` is merged over this.

**Models through the gateway.** `nestlo-orca-setup.service` (a oneshot, after
`k3s.service` and `nestlo-model-gateway.service`, retried every 15 s on
failure):

1. creates a random token in `/var/lib/nestlo-orca/gateway-token` (mode 0600)
   once, and registers agent `orca` with its hash at the gateway's admin
   socket;
2. sets the daily budget of the agent to `budgetUsd`;
3. waits for the chart's CRDs, then applies, in `namespace` and each of
   `providerNamespaces`: a Secret `nestlo-gateway-key` holding the
   placeholder `nestlo-managed`, one `ModelProvider` per entry of `models`,
   and a `ModelSelector` named `default` (strategy `rule-based`) that lists
   them all.

A ModelProvider's `baseURL` is
`http://10.89.3.1:<gateway port>/agent/orca:<token>/<provider>/v1`. The
gateway swaps the placeholder for the provider's real key, so the cluster
holds none. The resources carry the label `app.kubernetes.io/managed-by:
nestlo` and are re-applied on every start of the unit, so edit `models`, not
the resources.

**Loopback ports.** Three units (`nestlo-orca-forward-ui` and
`nestlo-orca-forward-api`, restarted when they stop) run `kubectl
port-forward --address 127.0.0.1`:

| Port | Service | Is |
|------|---------|----|
| `9980` | `agent-orca-ui:80` | The web UI |
| `9981` | `agent-orca-internal-api:8000` | ACP API |
| `9982` | `agent-orca-internal-api:8084` | External task API |

`AOCTL_ENDPOINT` (the task API) and `AOCTL_ACP_ENDPOINT` (the ACP API) are set
to these for login sessions, so `aoctl` works unconfigured.

**Gateway address and firewall.** The gateway also listens on
`network.gatewayAddress` (added to `lo` as a /32; `nestlo-model-gateway`
starts after it). The chain `nestlo-orca-in` (hooked in `INPUT` for `cni0`)
lets pods reach, on the host, established connections, the gateway address on
the gateway port, and the API server on 6443 (the `kubernetes` service is
translated to the node). Everything else from pods to the host is rejected.

## Quick start

```bash
sudo systemctl status nestlo-orca-setup k3s            # both active
sudo -i kubectl get pods -n agent-orca-system          # operator, UI, redis: Running
sudo -i kubectl get modelprovider,modelselector -n default
xdg-open http://127.0.0.1:9980/                        # the UI
```

An agent needs an image. This one is Agent Orca's reference image, a thin
OpenAI-compatible client (see its `docs/agent-images.md`); it comes from
ghcr.io, so it is not part of the offline platform. Replace it with your own.

```yaml
# agent.yaml
apiVersion: agentorca.agentorca.io/v1alpha1
kind: Agent
metadata:
  name: hello-agent
  namespace: default
spec:
  modelSelectorRef: default          # created by nestlo.orca
  systemPrompt: "You are a helpful assistant."
  runtime:
    ociRef: ghcr.io/agentorca/agent-orca/openai-reference:latest
    framework: openai-compatible
---
apiVersion: agentorca.agentorca.io/v1alpha1
kind: AgentRun
metadata:
  name: hello-run
  namespace: default
spec:
  agentRef: hello-agent
  input: "Say hello to the world"
  timeout: 5m
```

```bash
sudo -i kubectl apply -f agent.yaml
sudo -i kubectl get agentrun -n default hello-run -w          # PHASE: Pending, Running, Succeeded
sudo -i kubectl get agentrun -n default hello-run -o jsonpath='{.status.output}'
sudo -i kubectl get agentrun -n default hello-run -o jsonpath='{.status.spendUSD}'
```

Fields used above: `Agent.spec.modelSelectorRef` (required), `systemPrompt`,
`runtime.ociRef` (required) and `runtime.framework` (`openai-compatible` is
the default); `AgentRun.spec.agentRef` and `input` (required) and `timeout`
(default 5 minutes). `AgentRun.status` has `phase` (`Pending`, `Running`,
`Succeeded`, `Failed`, `HandedOff`, `WaitingForInput`), `output`, `spendUSD`,
`failureReason` and `routingDecisions`. The other resources and fields are in
the upstream `docs/crds.md`.

Spend shows in the Nestlo gateway as agent `orca`: `nestlo-budget status`
and the gateway's audit and metrics.

### aoctl and the APIs

```bash
aoctl agents list
aoctl tasks submit --agent hello-agent --input "hi" --stream
```

The ACP and task APIs reject requests without a bearer token (an Agent Orca
JWT from `aoctl login`, a federated OIDC token, or a Kubernetes ServiceAccount
token passed with `--token`). Nestlo does not create tenants or tokens; see
upstream `docs/auth.md`, `docs/aoctl-reference.md` and
`docs/enterprise-integration.md`. The UI proxy holds its own service account
token (upstream `docs/ui-proxy.md`); Nestlo adds no login in front of it, so
it is on loopback only.

## What is not included

- **Run archival to Postgres.** `database.enabled = false`: archiving runs
  needs a separate CloudNativePG cluster. Checkpoints and spend use Redis.
  Add it through `chartValues` if you run one.
- **Hindsight** (long-term memory service): `hindsight.enabled = false`.
- **Offline CoreDNS.** k3s pulls its CoreDNS (and helper) images from the
  internet at first start. For an air-gapped machine add
  `pkgs.k3s.airgap-images` to `services.k3s.images`.
- **Agent and tool images.** They are pulled by k3s from wherever their
  `ociRef` points, unless you load them yourself.
- **Multi-node clusters, ingress, TLS, OIDC.** One node, loopback only.
  `chartValues` can pass OIDC values (`operator.oidc.enabled`) but exposing
  the ports to a network is up to you.

## Security notes

- **The gateway token is readable in the cluster.** The token that lets
  anything use agent `orca`'s budget is part of every ModelProvider's
  `baseURL`, and ModelProviders are not secrets. Anyone who can `get
  modelproviders` (or exec into a router pod) can call the gateway as `orca`,
  within its daily budget, from inside the cluster network. The token also
  sits in `/var/lib/nestlo-orca/gateway-token` (root, 0600). Keep cluster
  access to administrators, keep `budgetUsd` modest, and rotate by deleting
  the token file and restarting `nestlo-orca-setup` (the unit generates a new
  token only if the file is gone, then re-registers and re-applies).
- **Pods reach the gateway, nothing more.** The firewall chain limits pods to
  the gateway port on `network.gatewayAddress` and the API server. Pods still
  reach the internet and other hosts the way any NAT-ed pod does.
- **Agent images come from registries.** An `ociRef` can be any image, and
  its code runs in your cluster, with the model router in the same pod.
  Set `allowedRegistries` to the prefixes you trust (the admission webhook
  rejects other images); the default is empty, which allows all. Upstream
  documents Cosign signature checks as a hook point only, so do not rely on
  signatures. Pin images by digest.
- **`chartValues` is public.** It lives in the Nix store; secrets go in
  Kubernetes Secrets.
- **Provider keys.** They stay with the gateway; the cluster holds
  `nestlo-managed`.
- **Root owns the cluster.** The kubeconfig is 0600 and `aoctl` and the
  forwards are loopback; any local user can still reach the UI port.

## Troubleshooting

```bash
sudo systemctl status k3s nestlo-orca-setup nestlo-orca-forward-ui nestlo-orca-forward-api
sudo journalctl -u nestlo-orca-setup -b            # gateway registration, CRD wait, apply
sudo journalctl -u k3s -b | tail -100              # image import, Helm controller, CNI
sudo -i kubectl get nodes
sudo -i kubectl get pods -A
sudo -i kubectl get helmchart,job -A | grep orca   # the Helm controller's install job
sudo -i kubectl logs -n kube-system job/helm-install-agent-orca
sudo -i kubectl logs -n agent-orca-system deploy/agent-orca       # the operator
sudo -i kubectl describe agentrun -n default hello-run            # events, failureReason
sudo -i kubectl get pod -n default -l agentorca.io/run=hello-run
```

| Symptom | Likely cause |
|---------|--------------|
| `nestlo-orca-setup` keeps restarting | The gateway admin socket is not up (`systemctl status nestlo-model-gateway`), or the CRDs are not installed yet because the Helm job failed; read the k3s journal and the `helm-install-agent-orca` job |
| `ModelProvider` missing in a namespace | The namespace is not in `providerNamespaces`; add it and restart the setup unit |
| Pods in `ErrImagePull` for platform images | The image was not imported; check `journalctl -u k3s` for the import, and that `services.k3s.images` took effect after the rebuild (restart `k3s`) |
| CoreDNS in `ImagePullBackOff` | No internet at first start; see "What is not included" |
| UI on 9980 refuses the connection | The forward unit is waiting for the UI pod: `kubectl get pods -n agent-orca-system`, `systemctl status nestlo-orca-forward-ui` |
| A run fails with an image not allowed | The `ociRef` does not start with an `allowedRegistries` prefix |
| Model calls fail with 401/403 | The token in the ModelProvider is stale (the token file changed): restart `nestlo-orca-setup` |
| Model calls fail with 429 or budget errors | The daily budget of `orca` is used up: `nestlo-budget status`, raise `budgetUsd` |

If the model router in a run pod cannot reach the gateway, check the
per-run NetworkPolicy the operator creates (`kubectl get networkpolicy -n
default`). Besides 443, 6443, 6379, 8082, 53 and declared tool egress rules,
the operator adds an egress rule for the port of every ModelProvider
`baseURL` the run uses (`providerPort` in
`internal/controller/agentrun_controller.go`), so the gateway port
(`nestlo.networking.modelGatewayPort`, 8080 by default) is allowed. The host
side is the `nestlo-orca-in` chain: `iptables -L nestlo-orca-in -nv`.

## Limits

- The VM test `orca` (`nix build .#checks.x86_64-linux.orca`) covers the
  chart deployment, the ModelProviders, a pod calling a mock model through
  the gateway (with the real key added and spend billed to `orca`), the
  firewall and the loopback ports. It does not run an `AgentRun` or `aoctl`
  against the APIs.
- `latest` and floating tags of agent images are as unpinned as ever.
- Upstream is young: the pinned commit is in `nixos/packages/agent-orca.nix`.
