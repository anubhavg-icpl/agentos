# OpenShell (`nestlo.openshell`)

[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) (Apache-2.0, Rust) is a
runtime for executing autonomous AI agents in sandboxes. Kernel controls
confine what an agent can read, write and call, a declarative YAML policy says
what is allowed, and credentials are handed to the agent only where policy
permits. This page explains the parts you meet in Nestlo and how `nestlo.openshell`
sets them up. OpenShell's own documentation is under `docs/` in its repository
and at docs.nvidia.com/openshell.

## What OpenShell is

| Piece | What it does |
|-------|--------------|
| Gateway (`openshell-gateway`) | The control plane. Creates and tracks sandboxes through a compute driver, stores providers and policies, delivers them to sandboxes, authenticates users |
| Compute driver | Docker, Podman, Kubernetes, or the experimental VM driver. It builds the sandbox boundary |
| Sandbox | A workload (your agent in a container image) with its policy. Created with `openshell sandbox create` |
| Supervisor | The trusted side of the boundary. Checks every network request against policy, adds credentials, resolves DNS, keeps the link to the gateway. The agent never talks to the network directly |
| Policy | YAML: filesystem, process and network rules. Anything not allowed is denied |
| Provider | A named credential (API key, token) with a profile that says which hosts, paths and programs may use it. The agent sees an opaque placeholder; the supervisor substitutes the real value only at an authorized endpoint |
| Prover (`openshell-prover`) | Formal check that a policy stays within a boundary policy you define |
| `openshell` CLI | Everything above from the command line, plus a terminal UI (`openshell term`) |

### Sandboxes

```bash
openshell gateway add http://127.0.0.1:8080 --local --name local   # register a gateway
openshell sandbox create --name work --from registry.example.com/team/agent:1.0 -- claude
openshell sandbox exec --name work -- ls /sandbox
openshell sandbox get work --output json
openshell logs work --since 10m
openshell sandbox delete work
```

The trailing command is the sandbox's main process; without one you get a
login shell. `--detach`, `--no-keep`, `--restart-policy`, `--cpu`, `--memory`
and `--gpu` are documented upstream (`docs/how-it-works/sandboxes/overview.mdx`).
The agent runs as one non-root identity with no Linux capabilities, Landlock
limits the file system, seccomp stages network operations, and the runtime
denies all other egress; the only way out is the supervisor.

### Policies

A policy file has `version: 1` and up to five sections:

| Section | Controls | Takes effect |
|---------|----------|--------------|
| `filesystem_policy` | Paths read-only and read-write (Landlock) | At sandbox start |
| `landlock` | Whether the sandbox still starts if Landlock rules cannot be applied | At sandbox start |
| `process` | User and group of sandbox processes | At creation |
| `network_policies` | Destinations each binary may reach and the requests it may send (L4, or L7 with methods and paths) | While running |
| `network_middlewares` | Extra inspection or blocking of allowed traffic | While running |

Outbound connections are denied unless a `network_policies` rule allows them.
The policy in force is, in order: a gateway-wide global policy, the sandbox's
saved policy (`--policy` at creation), a policy inside the image, or
OpenShell's restrictive default. Providers add network rules for their own
endpoints (the effective policy is the base policy plus those).

```bash
openshell policy get work --base > policy.yaml     # edit it
openshell policy set work --policy policy.yaml --wait
openshell policy list work
```

Network rules change on a running sandbox; file-system and process settings
do not. The schema, with every field, is `docs/how-it-works/policies/schema.mdx`
upstream. The `openshell` skill pack ([skills.md](skills.md)) includes
`generate-sandbox-policy`, which turns plain-language requirements and API
documentation into policy YAML.

### Providers and credentials

```bash
openshell profile list
openshell provider create --name my-claude --type claude-code --from-existing
openshell sandbox create --name work --provider my-claude -- claude
openshell sandbox provider attach work my-claude --wait
```

`--from-existing` reads the credential from your environment; the gateway
stores it. A provider needs an imported profile; `openshell profile lint` and
`openshell profile import -f` add your own. Attaching or rotating a provider
updates running sandboxes, but a process only sees new environment variables
when it is started afterwards.

### Inference

OpenShell no longer has a managed inference route. A workload calls its model
provider's native API; a provider profile allows that endpoint for named
programs and supplies the credential at the supervisor. The client owns the
base URL, the model name and the timeout. The `debug-inference` skill covers
diagnosing this (provider attachment, endpoint policy, credential
substitution, host-local servers).

### Policy proposals and the prover

An agent that is blocked can propose a narrow network rule (the policy
advisor: `openshell rule get <sandbox> --status pending`, `openshell rule
approve|reject`). Before a proposal can be approved automatically the prover
checks it for risky new access: credentialed reach to a new host, new HTTP
methods, cloud metadata addresses. Any finding needs a human.

The standalone prover checks a candidate policy against a boundary policy
and needs no gateway:

```bash
openshell-prover check candidate.yaml --boundary boundary.yaml
# result: within_boundary | exceeds_boundary (with a counterexample)
```

It covers file system, process identity, Landlock, L4 network and REST
requests. Policies that use anything else (GraphQL or MCP rules) are reported
as not checkable, not ignored. Use it in CI to keep per-agent policies inside
the most access your environment allows.

### Logging (OCSF)

Each sandbox logs network, HTTP, SSH, process, configuration and lifecycle
events as [OCSF](https://ocsf.io) v1.8.0 events next to ordinary tracing lines:

```text
OCSF NET:OPEN [INFO] ALLOWED /usr/bin/curl(58) -> api.github.com:443 [policy:github_api engine:opa]
OCSF NET:OPEN [MED] DENIED /usr/bin/curl(64) -> httpbin.org:443 [policy:- engine:opa] [reason:no matching policy]
```

`openshell logs <sandbox>` shows them; OpenShell can also export OCSF as JSON
(`docs/observability/ocsf-json-export.mdx` upstream). A denial is a `[MED]`
event with `DENIED` and the reason.

## How it fits Nestlo

Nestlo already has a model gateway, policies, an audit trail and agent
sandboxes of its own (`nestlo spawn`, [containers.md](containers.md),
[policy.md](policy.md)). OpenShell is an additional runtime for agents that
you want inside OpenShell's boundary, not a replacement for those. Nestlo's
policy and audit ([policy.md](policy.md), [audit.md](audit.md)) stay separate:
OpenShell enforces what runs inside its sandboxes; Nestlo meters and audits
their model calls.

| What | How |
|------|-----|
| Packages | `packages.<system>.openshell` builds `openshell`, `openshell-gateway`, `openshell-supervisor`, `openshell-sandbox` and `openshell-prover` from the pinned source (`nixos/packages/openshell.nix`). The microVM compute driver is not built |
| The gateway | `nestlo-openshell-gateway.service`: a hardened systemd service under its own user `openshell`, state in `/var/lib/openshell`, on loopback with mutual TLS, driving the podman or docker compute driver |
| The CLI | `openshell` for operators (and optionally the agent user), pointed at the local gateway with their client certificate |
| Inference | Sandboxes call the Nestlo model gateway as agent `openshell`: a provider profile `nestlo-gateway` and a provider instance `nestlo`. The real provider key never enters a sandbox, and neither does the gateway token |
| Policies | Declared in Nix (`nestlo.openshell.policies`), checked at evaluation, rendered to `/etc/openshell/policies/<name>.yaml`, optionally applied as the gateway-global policy |
| Providers | Upstream profiles (`providers/*.yaml`), your own profiles and provider instances from secret files |
| Logging | The gateway's OCSF events as JSON lines, and traces to the Nestlo OpenTelemetry collector |
| Skills | Skill pack `openshell` ([skills.md](skills.md)): `openshell-cli`, `generate-sandbox-policy`, `debug-inference`, `debug-openshell-cluster` |

### Inference through the Nestlo model gateway

With `inference.enable` (on by default when `nestlo.networking.enable` is
set), `nestlo-openshell-gateway-agent.service` registers the gateway agent
`openshell` with a random token (`/var/lib/openshell/nestlo-gateway-token`,
readable by the `openshell` user only) and a daily budget, and
`nestlo-openshell-setup.service` imports the profile `nestlo-gateway` and
creates the provider `nestlo` holding that token.

Attach the provider to a sandbox and point the client at the Nestlo gateway
with the placeholder variable. The sandbox only ever sees the placeholder in
`NESTLO_GATEWAY_TOKEN`; the sandbox proxy substitutes the token in the URL
path, and the Nestlo gateway adds the real provider key and applies budget,
DLP, loop detection and audit.

```bash
openshell sandbox create --name work --from registry.example.com/team/agent:1.0 \
  --provider nestlo --policy /etc/openshell/policies/restrictive.yaml -- \
  sh -c 'ANTHROPIC_BASE_URL=http://host.openshell.internal:8080/agent/openshell:${NESTLO_GATEWAY_TOKEN}/anthropic claude'
```

The module exposes the ready-made URLs as the read-only option
`nestlo.openshell.inference.baseUrls.anthropic` and `.openai` (host, port and
provider names follow your configuration; `8080` is the default
`nestlo.networking.modelGatewayPort`). The profile allows only
`inference.gatewayHost`:port for the executables in `inference.binaries`
(curl, python, node by default); extend the list to match your image.
Spend appears in the gateway as agent `openshell`.

`gatewayHost` defaults to `host.openshell.internal`. With the podman driver
that is the host's loopback, where the Nestlo gateway listens. With the docker
driver it is the bridge address, which the Nestlo gateway does not listen on
by default; the module warns, and you set `inference.gatewayHost` to an
address it serves.

## Enable

```nix
nestlo.runtime = { enable = true; operators = [ "alice" ]; };
nestlo.networking.enable = true;          # the Nestlo model gateway

nestlo.openshell = {
  enable = true;

  policies.github-readonly = {
    filesystem_policy = {
      read_only = [ "/usr" "/lib" "/etc" ];
      read_write = [ "/tmp" "/sandbox" ];
    };
    network_policies.github = {
      endpoints = [{
        host = "api.github.com";
        port = 443;
        protocol = "rest";
        access = "read-only";
        enforcement = "enforce";
      }];
      binaries = [ "/usr/bin/curl" ];      # plain paths are accepted
    };
  };
  defaultPolicy = "github-readonly";       # used by `openshell sandbox create` without --policy

  providers.upstream = [ "github" ];       # import providers/github.yaml
  providers.instances.my-github = {
    type = "github";
    credentialFiles.GITHUB_TOKEN = "/run/secrets/GITHUB_TOKEN";
  };
};
```

The module enables podman (or docker, see `computeDriver`) and uses its socket.

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | The gateway, the CLI and everything below |
| `package` | `pkgs.nestlo.openshell` | OpenShell build; must provide `openshell`, `openshell-gateway` and a `providers` attribute |
| `computeDriver` | `docker` if `nestlo.runtime.containerRuntime` is docker, else `podman` | `podman` or `docker`. The gateway user joins that runtime's group, which is root-equivalent on the host |
| `listen.address` | `127.0.0.1` | IPv4 address of the gRPC, health and metrics listeners. Non-loopback gives an evaluation warning |
| `ports.grpc` | `17670` | Gateway API port (mutual TLS) |
| `ports.health` | `17671` | Plain-HTTP health port (`/healthz`, `/readyz`, `/health`) |
| `ports.metrics` | `null` | Prometheus `/metrics` port; scraped by Nestlo's Prometheus when `nestlo.observability` is enabled (job `openshell-gateway`) |
| `logLevel` | `info` | Gateway log level: `trace`, `debug`, `info`, `warn`, `error` |
| `policyValidationFailureMode` | `fail_closed` | When a sandbox rejects a new policy revision: `fail_closed` blocks network traffic, `retain_last_valid` keeps the last valid policy |
| `images.pullPolicy` | `if_not_present` | `always`, `if_not_present`, `never` or `newer` |
| `images.sandbox` | `null` | Default image of `sandbox create` without `--from` (null: the driver's default) |
| `images.runtime` | `null` | Image the trusted `openshell-sandbox` binary is taken from (null: upstream's version-pinned `ghcr.io/nvidia/openshell/sandbox`) |
| `images.supervisor` | `null` | Image with `openshell-supervisor` (null: upstream's version-pinned `ghcr.io/nvidia/openshell/supervisor`) |
| `tls.extraSans` | `[ ]` | Extra names in the gateway certificate (it always covers localhost, 127.0.0.1 and `host.openshell.internal`) |
| `users` | `nestlo.runtime.operators` | Users of the CLI. They join the `openshell` group and get the client certificate |
| `includeAgentUser` | `false` | Also give `nestlo-agent` the certificate, so agents can create OpenShell sandboxes. Evaluation warning |
| `inference.enable` | `nestlo.networking.enable` | See "Inference through the Nestlo model gateway" |
| `inference.agentId` | `openshell` | Gateway agent id that sandbox model calls are made as |
| `inference.budgetUsd` | `20` | Daily budget of that agent in USD; the gateway answers 402 once it is spent |
| `inference.providerName` | `nestlo` | Name of the OpenShell provider instance carrying the token |
| `inference.gatewayHost` | `host.openshell.internal` | Host name sandboxes use for the Nestlo model gateway |
| `inference.binaries` | curl, python3, `/sandbox/.venv/**`, node | Executables in the sandbox allowed to reach the gateway |
| `inference.anthropicProvider` / `openaiProvider` | `anthropic` / `openai` | Nestlo gateway providers used in `baseUrls` |
| `inference.baseUrls` | read-only | Ready-made base URLs `anthropic` and `openai` with the placeholder variable |
| `policies` | `{ }` | Policies by name, in OpenShell's YAML shape (`filesystem_policy`, `landlock`, `process`, `network_policies`, `network_middlewares`). Unknown fields, missing `host`/`port`, `port` together with `ports`, and `access` together with `rules` fail at evaluation |
| `upstreamDefaultPolicy` | `true` | Also render OpenShell's restrictive built-in default as policy `restrictive` |
| `defaultPolicy` | `null` | Policy for `sandbox create` without `--policy`, via `OPENSHELL_SANDBOX_POLICY` in login sessions |
| `globalPolicy` | `null` | Policy applied as the gateway-global policy at every start. It locks every sandbox to it and drops provider-contributed rules, so list everything sandboxes need |
| `providers.upstream` | `[ ]` | Upstream profiles to import: `anthropic`, `aws`, `aws-bedrock`, `aws-s3`, `claude-code`, `codex`, `copilot`, `cursor`, `deepinfra`, `github`, `google-cloud`, `google-vertex-ai`, `nvidia`, `oci-genai`, `openai`, `openrouter`, `pypi`. Their `binaries` assume a reference image layout; read the file header first |
| `providers.profilesDir` | the package's `providers` | Directory the upstream profiles come from |
| `providers.custom` | `{ }` | Own profiles by id (`display_name` required), in OpenShell's profile YAML shape |
| `providers.instances` | `{ }` | `{ type; credentialFiles; config; }` per provider, created once from secret files (`credentialFiles.VAR = path`, read as systemd credentials). Delete one in OpenShell to have it recreated |
| `observability.ocsf.enable` | `true` | Write the gateway's OCSF events to `/var/log/openshell/gateway-ocsf.jsonl` (daily rotation) |
| `observability.ocsf.retainDays` | `14` | Rotated files kept |
| `observability.ocsf.sandboxJson` | `false` | Set the global setting `ocsf_json_enabled`: supervisors also write OCSF JSON inside each sandbox |
| `observability.otlp.enable` | `true` | OTLP/gRPC traces to the Nestlo collector when `nestlo.observability` is enabled |
| `driverSettings` | `{ }` | Extra keys for `[openshell.drivers.<computeDriver>]`; unknown keys make the gateway refuse to start |
| `settings` | `{ }` | Extra gateway TOML merged over the generated one (schema v2). Stored in the Nix store: no secrets |

Assertions: `inference.enable` needs `nestlo.networking.enable`; `listen.address`
must be IPv4; ports must differ; `defaultPolicy`, `globalPolicy` and `users`
must exist; policy names cannot use rule keys starting with `_provider_`.

## What the module sets up

- **Gateway.** `nestlo-openshell-gateway.service` runs `openshell-gateway`
  as user `openshell` with systemd hardening
  (strict file system, no capabilities, no new privileges, private devices),
  with `/var/lib/openshell` as state and `/var/log/openshell` for logs. Its
  configuration is generated TOML (`OPENSHELL_GATEWAY_CONFIG`).
- **Certificates.** Before start it runs `openshell-gateway generate-certs`
  into `/var/lib/openshell/state/openshell/tls` (skipped when all files exist;
  delete the directory to rotate) and copies the client bundle to
  `/var/lib/openshell/client` (group `openshell`, read-only).
- **CLI users.** Users in `users` join group `openshell` and get
  `~/.config/openshell/gateways/openshell/mtls` linked to that bundle.
  `/etc/openshell` registers the gateway `openshell` at
  `https://127.0.0.1:17670` as the active gateway for everyone, so
  `openshell status` works after login.
- **Setup.** `nestlo-openshell-setup.service` (oneshot, retried every 15 s)
  imports the provider profiles, creates the provider `nestlo` and your
  `providers.instances` if they do not exist, applies `globalPolicy`, and sets
  `ocsf_json_enabled` when asked. It runs on every start and rebuild that
  changes it.
- **Policies.** Every entry of `policies` (plus `restrictive`) is a file
  `/etc/openshell/policies/<name>.yaml`.

## Quick start

```bash
systemctl status nestlo-openshell-gateway nestlo-openshell-setup
openshell status                                  # as a user in nestlo.openshell.users
openshell profile list
openshell provider list

openshell sandbox create --name demo \
  --policy /etc/openshell/policies/github-readonly.yaml --provider my-github -- bash
# inside: curl https://api.github.com/zen works, anything else is denied

openshell logs demo --since 10m                   # ALLOWED and DENIED events
openshell policy get demo --full                  # the effective policy
openshell sandbox delete demo
```

To change the network rules of a running sandbox, edit the policy in Nix and
rebuild for new sandboxes, or use `openshell policy get demo --base`,
edit, and `openshell policy set demo --policy policy.yaml --wait` for this one.
`openshell-prover check candidate.yaml --boundary boundary.yaml` checks a
policy file against a boundary without a gateway.

## Security notes

- **The gateway user is root-equivalent.** To create containers it needs the
  podman or docker socket, which is root-equivalent on the host. The service
  is hardened and loopback-only, but whoever can talk to it can start
  containers with the policies and images it admits.
- **The client certificate is the key.** Anyone who can read
  `/var/lib/openshell/client/tls.key` (group `openshell`, that is `users`)
  can create sandboxes. Keep `users` to operators. `includeAgentUser` lets an
  agent create sandboxes with a policy it chooses; it is off by default and
  warned about.
- **Credentials.** Provider instances read their secrets from the files you
  name, as systemd credentials; the gateway stores them. Sandboxes receive
  opaque placeholders, substituted by the supervisor only at endpoints the
  profile authorizes. The gateway token of agent `openshell` is readable by
  the `openshell` user only, and never enters a sandbox.
- **Global policy.** `globalPolicy` replaces each sandbox's own policy.
  Provider rules, including `nestlo-gateway`, no longer apply while it is set,
  so include the Nestlo gateway endpoint in it if sandboxes need inference.
- **Policy strictness.** Policies are checked at evaluation for unknown fields
  but not for meaning: review `network_policies` as you would a firewall.
  Use the prover in CI to keep policies inside a boundary.
- **Network exposure.** `listen.address` is loopback; sandboxes reach the
  Nestlo gateway at `host.openshell.internal`, which with podman is the host's
  loopback.
- **Images.** `images.runtime` and `images.supervisor` default to upstream's
  version-pinned images on ghcr.io, pulled at first use. Pin your own for
  air-gapped or reviewed setups.

## Troubleshooting

```bash
systemctl status nestlo-openshell-gateway nestlo-openshell-gateway-agent nestlo-openshell-setup
journalctl -u nestlo-openshell-gateway -b
journalctl -u nestlo-openshell-setup -b           # profile imports, providers, global policy
curl -s http://127.0.0.1:17671/healthz            # plain-HTTP health
openshell status                                  # reachability, auth and version
openshell logs <sandbox> --since 10m              # network allow/deny events
openshell policy get <sandbox> --full             # the effective policy
```

| Symptom | Likely cause |
|---------|--------------|
| `openshell status` cannot connect or fails TLS | You are not in `nestlo.openshell.users` (log in again after a rebuild), or the gateway is down |
| Gateway fails to start | Wrong key in `settings` or `driverSettings` (unknown keys are rejected), or the container runtime socket is missing |
| Sandbox pending or failing to create | The images are not pulled (`images.pullPolicy`, network) or the runtime is down; see `debug-openshell-cluster` |
| Model calls from a sandbox denied | The executable is not in `inference.binaries`, or a `globalPolicy` leaves out the gateway endpoint |
| Model calls time out with the docker driver | `host.openshell.internal` is the bridge address; set `inference.gatewayHost` |
| 402 from the gateway | The daily budget of agent `openshell` is spent: `nestlo-budget status`, raise `inference.budgetUsd` |
| `nestlo-openshell-setup` keeps failing | The gateway is not ready, a profile file is invalid (`openshell profile lint -f <file>`), or a `credentialFiles` path is unreadable by root |

The `debug-openshell-cluster` and `debug-inference` skills walk through the
common failures.

## Limits

- Only the podman and docker compute drivers are built into the gateway;
  Kubernetes and microVM are not used.
- Provider instances are created once; changing a credential file does not
  update an existing instance. Delete it in OpenShell (`openshell provider
  delete`) and rebuild or restart `nestlo-openshell-setup`.
- The prover's guarantees cover the policy features it models (file system,
  process, Landlock, L4 and REST network rules).
- Policy fields follow the pinned OpenShell commit; a newer OpenShell may add
  fields the module's evaluation-time check rejects until it is updated.
- The VM test `openshell` (`nix build .#checks.x86_64-linux.openshell`)
  covers the service, mutual TLS, the rendered and global policy, the
  profiles and providers, and the gateway agent. It does not start a
  sandbox or run a model call from inside one.
