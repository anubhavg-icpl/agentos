# Agent identity and authorization (`nestlo.agentIdentity`, `nestlo.cedar`)

Two small pieces that answer "who is this agent?" and "may it do this?":

- **SPIFFE/SPIRE** ([spiffe.io](https://spiffe.io), Apache-2.0) gives every
  agent and Nestlo service a short-lived, automatically rotated, verifiable
  identity (an *SVID*) in place of a static secret. `nestlo.agentIdentity`
  runs a single-host SPIRE.
- **Cedar** ([cedarpolicy.com](https://www.cedarpolicy.com), Apache-2.0) is a
  policy language for authorization. `nestlo.cedar` renders policies and a
  schema, validates them at build time and adds the `nestlo-authz` command.

The identity answers "who": `spiffe://nestlo.local/agent/claude`. Cedar
answers "may it": agent `claude`, action `push`, resource
`github.com/acme/app`, branch `main`. `nestlo.policy` stays responsible for
what a *task* may cost and how it runs. [openbao.md](openbao.md) uses the
identity to hand each agent its own secrets.

## SPIRE

```nix
nestlo.runtime.enable = true;            # the nestlo-agent user
nestlo.agentIdentity = {
  enable = true;
  agents.claude = { };                   # spiffe://nestlo.local/agent/claude
};
```

What runs, all on this host:

| Unit | What |
|------|------|
| `nestlo-spire-pki` | One-shot. Generates a node certificate for this host from a CA that is deleted right after signing |
| `nestlo-spire-server` | `spire-server` on `127.0.0.1:8081`, SQLite and disk keys in `/var/lib/nestlo-spire-server`, hardened `DynamicUser` unit |
| `nestlo-spire-bundle` + timer | Writes the bootstrap bundle and the public trust bundle (JWKS) to `/var/lib/nestlo-spire/pub/bundle.json` (world-readable), every `bundleRefreshInterval` |
| `nestlo-spire-agent` | `spire-agent` as root, node attestation `x509pop`, workload attestors `unix` and `systemd`, Workload API socket `/run/nestlo-spire/agent/api.sock` |
| `nestlo-spire-entries` | Reconciles the registration entries declared in Nix with the server |

Why the agent is root: attesting a process means reading its `/proc` entries
and asking systemd for its unit. The unit keeps only `CAP_SYS_PTRACE` and
`CAP_DAC_READ_SEARCH`, and is otherwise confined (`ProtectSystem=strict`,
`NoNewPrivileges`, system call filter, no network except the loopback server).

The Workload API socket is world-connectable. That is how SPIFFE works: the
agent decides what a caller gets by attesting the caller (user, unit, ...),
not by file mode. A process with no registration entry gets "no identity".
`SPIFFE_ENDPOINT_SOCKET` is set for login shells; units that start agents
must set it themselves (the `nestlo-svid` command does not need it).

### Which identities exist

`nestlo.agentIdentity.agents.<name>` gives `spiffe://<td>/agent/<name>` to a
workload that runs as `user` (default `nestlo-agent`) and, if `unit` is set,
inside that systemd unit (default `nestlo-agent-<name>.service`, which is
what `nestlo spawn` and the task runner create with `systemd-run`). Both must
match. `genericAgent` (default on) additionally registers
`spiffe://<td>/agent/nestlo-agent` for any process of the `nestlo-agent`
user, so every agent has *some* identity; add named agents to tell them
apart. A process in a named agent's unit gets both identities and chooses
with `--agent` / `-spiffeID`.

All agents run as the one user `nestlo-agent`, so the user alone cannot
separate them: the transient unit name is the discriminator. A unit name is
not a secret, but only root (or the daemon, which is root-equivalent through
`systemd-run`) can start a unit; the agent itself, as `nestlo-agent`, cannot
create a unit called `nestlo-agent-claude`. Do not give the agent user
polkit rights to start units.

Agents spawned under ids you cannot list at build time are registered at
runtime: `sudo nestlo-identity register <id> [unit] [user]` (and
`unregister`). Those entries are marked `nestlo-dyn` and the declarative
reconcile leaves them alone. A follow-up could call this from the task runner
before `systemd-run`.

Also registered when the module is enabled and `serviceIdentities` is true
(selected by systemd unit, since several run as the same `nestlo` user):

| SPIFFE ID | Unit | When |
|-----------|------|------|
| `service/gateway` | `nestlo-model-gateway.service` | `nestlo.networking.enable` |
| `service/daemon` | `nestlo-daemon.service` | `nestlo.runtime.enable` |
| `service/orchestrator` | `nestlo-orchestrator.service` | `nestlo.orchestration.enable` |
| `service/audit` | `nestlo-audit.service` | `nestlo.audit.enable` |
| `service/cloud`, `service/cloud-vmd` | `nestlo-cloud.service`, `nestlo-cloud-vmd.service` | `nestlo.cloud.enable` |

`workloads.<name>` adds any other identity (`path`, `selectors`, TTLs, DNS
names). A workload must have at least one selector (asserted).

### Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Everything above |
| `package` | `pkgs.spire` | SPIRE build (1.15 in this nixpkgs) |
| `trustDomain` | `nestlo.local` | SPIFFE trust domain. Not resolved via DNS. Changing it later means starting over (`/var/lib/nestlo-spire*`) |
| `x509SvidTtl` | `3600` | Default X.509-SVID lifetime (s); rotated at half-life |
| `jwtSvidTtl` | `300` | Default JWT-SVID lifetime (s). Bearer tokens, no revocation except expiry |
| `caTtl` | `24h` | Lifetime of SPIRE's CA and JWT signing keys |
| `jwtIssuer` | `https://spire.<td>` | `iss` claim of JWT-SVIDs |
| `serverPort` | `8081` | Loopback port of the server API |
| `logLevel` | `INFO` | |
| `gatewayAudience` | `nestlo-gateway` | Audience the model gateway expects (see below) |
| `bundleRefreshInterval` | `10min` | How often `bundle.json` is rewritten |
| `serviceIdentities` | `true` | Register the service identities above |
| `genericAgent` | `true` | Also register `agent/nestlo-agent` for the whole `nestlo-agent` user |
| `agents` | `{ }` | Named agent identities (user + unit); see above |
| `workloads` | `{ }` | Other identities |
| `workloadSocket`, `bundleFile`, `svidTool`, `nodeId`, `agentNames` | read-only | For other modules |

### Commands

```
nestlo-svid jwt <audience> [--agent NAME]   # JWT-SVID for this process; prints the token
nestlo-svid x509 [--write DIR]              # X.509-SVID (spire-agent api fetch x509)
nestlo-svid verify [--token T] [--audience A]   # verify against the bundle; JSON, exit 1 if invalid
nestlo-svid jwks-pem                         # the bundle's JWT keys as PEM (for OpenBao)
sudo nestlo-identity status|list|register|unregister|jwt-bundle
```

`nestlo-svid verify` checks the signature against the key with the token's
`kid` (algorithms: ES/RS/PS only, never `none` or HMAC), `exp`, that the
audience matches, and that the subject is in the trust domain.

### Using it: the model gateway accepts a JWT-SVID

Today an agent calls `http://127.0.0.1:8080/agent/<id>:<token>/<provider>/...`
or sends `x-nestlo-token`, a static random token registered by `nestlo spawn`
through the admin socket. With SPIRE the agent can instead present a
JWT-SVID as the token: nothing to register, nothing to leak for longer than
`jwtSvidTtl`, and the agent id is *derived from the verified identity*, so an
agent cannot claim another's id.

The model gateway (`services/nestlo_services/gateway.py`) is not edited by
this module. The design:

1. Verification is `modules/agent-identity/svid.py` (library, PyJWT with
   `cryptography`). Copy it to `services/nestlo_services/svid.py` and add
   `pyjwt` to the services' Python dependencies.
2. A config section (rendered by the Nix side) names the bundle file, trust
   domain and audience: `[agent_identity] enable, bundle_file, trust_domain,
   audience`, mirroring `/etc/nestlo/agent-identity.json`.
3. In `Gateway.authenticate()` after the static token check fails, and only
   when the token looks like a JWT (three dot-separated segments):

```python
from . import svid

def _svid_agent(self, agent, token):
    ai = self.cfg.get("agent_identity") or {}
    if not ai.get("enable") or token.count(".") != 2:
        return False
    try:
        claims = svid.verify(token, self._jwks(ai["bundle_file"]), ai["audience"], ai["trust_domain"])
    except (svid.SvidError, OSError, ValueError):
        return False
    # the path segment must name the agent the SVID belongs to
    return svid.agent_id(claims["sub"], ai["trust_domain"]) == agent
```

   `_jwks()` caches the parsed file by mtime. `authenticate()` becomes: static
   token matches, or `_svid_agent(agent, token)`; otherwise 401 as now (the
   failure counting and `auth.failure` audit event stay; add
   `reason="bad_svid"`). Budgets, DLP and logs are per agent id as before, and
   the audit event can carry `spiffe_id`.
4. An agent obtains the token with
   `nestlo-svid jwt nestlo-gateway --agent <id>` and uses it where it used the
   static token (`x-nestlo-token`, which keeps it out of URLs and logs).
   Tokens last 5 minutes, so a long-running agent refreshes; a base-URL
   wrapper or the daemon can do that.

Static tokens keep working. To go identity-only, set
`gateway.require_agent_tokens` semantics aside and reject static tokens in
that branch.

## Cedar authorization

```nix
nestlo.cedar = {
  enable = true;
  agents.claude = { groups = [ "coding" ]; tier = "trusted"; };
  agents.scraper = { groups = [ "research" ]; tier = "untrusted"; };
};
```

`/etc/nestlo/cedar` gets `schema.cedarschema`, `policies.cedar` and
`entities.json`. The build runs `cedar check-parse` and `cedar validate`
(policies against the schema) and a dummy authorization that checks the
entities against the schema, so a typo in a policy fails `nixos-rebuild`,
not an agent at 3 am.

The shipped schema has `Agent` (in `Group`, with a `tier` string),
`Repo` (in `RepoSet`), `Tool` (in `ToolSet`), `Provider` (in `ProviderSet`) and
`Secret`, and the actions `clone`, `push` (context `branch`), `use_tool`,
`call_provider` (context `model`) and `read_secret`. The example policies
(options `policies` and `entities`, replace or extend freely):

| Policy id | Effect |
|-----------|--------|
| `coding-clone` | Group `coding` may clone repos in `RepoSet::"internal"` |
| `coding-push` | ...and push to them when `tier == "trusted"` |
| `no-default-branch-push` | forbid pushes to `main` / `master`, whatever else permits |
| `tools-safe` | everyone may use tools in `ToolSet::"safe"` |
| `tools-shell-trusted` | `ToolSet::"shell"` only for trusted agents |
| `providers-approved` | calls to providers in `ProviderSet::"approved"` |
| `untrusted-no-secrets`, `untrusted-no-push` | forbid for tier `untrusted` |

Cedar is deny by default and `forbid` beats `permit`. Each policy is one
attribute of `nestlo.cedar.policies`; its name becomes the policy's `@id`,
which `nestlo-authz` reports.

```
$ nestlo-authz check --principal claude --action push \
      --resource Repo:github.com/nestlo/nestlo --context '{"branch":"main"}'
DENY (no-default-branch-push)
$ nestlo-authz check --json --principal claude --action clone --resource Repo:github.com/nestlo/nestlo
{"decision":"allow","principal":"Agent::\"claude\"", ..., "reasons":["coding-clone"]}
```

`P` and `R` accept `Type::"id"`, `Type:id` or a bare id (principal defaults to
`Agent`); the action is a bare name. Exit status: 0 allow, 2 deny, 1 error
(unknown action, bad context, entities that violate the schema).
`NESTLO_CEDAR_DIR` and `--entities` point it elsewhere (for tests, or for a
runtime entity store).

### Calling it from `policy.py`

nixpkgs has no Python binding for Cedar, so `nestlo-authz` shells out to the
`cedar` CLI (a few milliseconds). `services/nestlo_services/policy.py`
`enforce()` could add an optional `cedar` rule:

```python
def cedar_check(principal, action, resource, context=None):
    cmd = ["nestlo-authz", "check", "--json", "--principal", principal, "--action", action, "--resource", resource]
    if context:
        cmd += ["--context", json.dumps(context)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    if r.returncode not in (0, 2):
        raise PolicyError("cedar", "authorization check failed: " + r.stderr.strip()[:200])   # fail closed
    res = json.loads(r.stdout)
    if res["decision"] != "allow":
        raise PolicyError("cedar", "%s denied (%s)" % (action, ", ".join(res["reasons"]) or "no matching permit"))
```

with `PolicyError(rule, message)` as today: call it for `clone`/`push` when
a task names a repository (`workspace`, `publish`) and for `call_provider`
with the task's model. A Nix switch (`nestlo.policy.cedar.enable`) would
add `cedar = true` to the compiled `[policy]` section. Because
`nestlo-authz` is a child process, `policy.py` should treat a missing
binary as "feature off" only when the switch is off, never as "allow".

## Limits

- Single host. The node attestor is `x509pop` with a certificate generated on
  this host; there is no federation and no multi-node SPIRE. The server and
  agent trust each other through that certificate and the loopback.
- The agent runs as root (see above). Anything that can register entries
  (`nestlo-identity`, the server socket, `/var/lib/nestlo-spire-server`) is
  root-equivalent for identity; the server socket is in a root-only directory.
- Unit names are the discriminator between agents of one user; they are only
  as trustworthy as who may start units (see above).
- Nestlo Cloud VMs (systemd-nspawn machines) cannot reach the host's Workload
  API socket and are not given identities; the control plane and the VM
  daemon are. A follow-up could expose the socket into VMs through a
  per-VM bind mount and register the VM's machine unit (`systemd:id:` of the
  machine scope) as `vm/<name>`.
- k3s/Orca pods (`nestlo.orca`) are not attested. SPIRE's `k8s_psat` node
  attestor and `k8s` workload attestor would do it (a `spire-agent`
  DaemonSet or a second agent on the node, an `orca/<agent>` identity per
  service account); it is a documented follow-up, not implemented.
- JWT-SVIDs are bearer tokens. Keep `jwtSvidTtl` short and use the Nestlo model gateway
  audience only for the Nestlo model gateway.
- `nestlo-authz` fails closed on errors but nothing calls it yet: wiring it
  into `policy.py` and the Nestlo model gateway is the integration above.
- The VM test `agent-identity` (`nix build .#checks.x86_64-linux.agent-identity`)
  covers SPIRE health, node attestation, the registered entries, X.509 and
  JWT SVIDs for a user, for a spawned unit and for a runtime-registered
  agent, JWT verification (audience, tampering, `alg=none`), and Cedar
  allow/deny.
