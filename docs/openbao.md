# OpenBao secrets backend (`nestlo.openbao`)

[OpenBao](https://openbao.org) (MPL-2.0, the community fork of HashiCorp
Vault) keeps the secrets agents need and gives each agent only its own, by
identity. With [`nestlo.agentIdentity`](agent-identity.md) an agent logs in
with its SPIFFE JWT-SVID, so there is no long-lived credential to hand it.

| What | How |
|------|-----|
| The server | nixpkgs' `services.openbao` (hardened `DynamicUser` unit), file storage in `/var/lib/openbao`, no UI |
| The listener | `127.0.0.1:8200`, TLS 1.3, certificate from a CA generated on the first boot (`/var/lib/nestlo-openbao/pub/ca.pem`, public) |
| Init and unseal | `nestlo-openbao-setup`: one key share, auto-unseal on every start (see the trade-off below) |
| Secrets | KV v2 at `nestlo/`: `agents/<agent>/*` (that agent only), `shared/*` (all agents), `secrets-manager/<NAME>` |
| Agent login | JWT auth at `auth/spire`, one role `agent-<name>` per agent identity bound to its SPIFFE ID, policy `nestlo-agent-<name>` |
| Audit | File audit device `/var/log/nestlo-openbao/audit.log` (root-only, secrets HMAC-ed, weekly rotation) |
| Metrics | Prometheus scrape job `openbao` in `nestlo.observability` (when that is enabled) |
| Secrets manager | Optional `nestlo-openbao-sync` renders `/run/secrets/<NAME>` from KV |

## Enable

```nix
nestlo.runtime.enable = true;
nestlo.agentIdentity = {
  enable = true;
  agents.claude = { };            # unit nestlo-agent-claude.service, user nestlo-agent
};
nestlo.openbao.enable = true;     # agents defaults to every agentIdentity agent
```

Put a secret in and read it as the agent:

```
sudo nestlo-bao kv put -mount=nestlo agents/claude/github value=ghp_...
sudo nestlo-bao kv put -mount=nestlo shared/motd value=hello

# as the agent (inside its unit; `nestlo spawn claude ...` creates nestlo-agent-claude)
nestlo-openbao-get -a claude agents/claude/github        # prints the value
nestlo-openbao-get -a claude agents/other/anything       # permission denied
```

`nestlo-openbao-get [-a AGENT] PATH [FIELD]` fetches a JWT-SVID for audience
`openbao` (`nestlo-svid jwt openbao --agent AGENT`), logs in to role
`agent-AGENT` and reads `nestlo/PATH`. `nestlo-openbao-login [AGENT]` prints
just the OpenBao token (15 minutes). `AGENT` defaults to `$NESTLO_AGENT_ID`,
then `nestlo-agent`. The SPIRE entry decides who may ask for which SVID: a
process outside `nestlo-agent-claude.service` cannot obtain claude's SVID
(or its secrets). Agents can also use the HTTP API directly with the token.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | `false` | Everything on this page |
| `package` | `pkgs.openbao` | OpenBao build (2.6 in this nixpkgs) |
| `address`, `port` | `127.0.0.1`, `8200` | Listener. Keep it on loopback |
| `extraSans` | `[ ]` | More subjectAltNames for the listener certificate (`DNS:...`, `IP:...`) |
| `kvMount` | `nestlo` | Mount path of the KV v2 engine |
| `autoUnseal` | `true` | Unseal on every start with `unsealKeyFile` |
| `unsealKeyFile` | `/var/lib/nestlo-openbao/init/unseal-key` | Where the key is written at init and read from |
| `keepRootToken` | `true` | Keep the root token in `init/root-token` (root only) |
| `audit.enable`, `audit.file` | `true`, `/var/log/nestlo-openbao/audit.log` | File audit device |
| `jwtAuth.enable` | `nestlo.agentIdentity.enable` | JWT auth method trusting SPIRE |
| `jwtAuth.mountPath` | `spire` | `auth/<path>` |
| `jwtAuth.audience` | `openbao` | Audience of the JWT-SVIDs |
| `jwtAuth.refreshInterval` | `10min` | How often SPIRE's JWT signing keys are re-read (they rotate) |
| `agents` | one per `nestlo.agentIdentity` agent, including `nestlo-agent` | Agents that may log in; see below |
| `secretsManager.enable` | `false` | Render `/run/secrets/<NAME>` from OpenBao |
| `secretsManager.secrets` | `nestlo.secrets-manager.secrets` | Names to render |
| `secretsManager.interval` | `5min` | Refresh period |
| `observability` | `true` | Add the Prometheus scrape job |

`agents.<name>` takes `spiffeId` (default `spiffe://<trust domain>/agent/<name>`),
`tokenTtl` (default `15m`) and `extraPolicy` (more policy HCL, for example
`path "nestlo/data/providers/openai" { capabilities = ["read"] }`). Removing an
agent from the list removes its role on the next run of the setup unit; the
policy `nestlo-agent-<name>` stays (harmless without a role).

## Security trade-off: where the unseal key lives

OpenBao encrypts everything it stores with a key that is itself encrypted by
the *unseal key*. Normally nobody can read the data until a human supplies the
unseal key after each start. A machine that must come back after a reboot
without a human has to find the key somewhere, and this module puts it on the
machine:

- `init/unseal-key` and `init/root-token` are files in `/var/lib/nestlo-openbao/init`
  (mode 0600, directory 0700, root). The data is in `/var/lib/openbao`.
- Anyone who is root on this host, or who has the disk (a stolen disk, a VM
  snapshot, a backup that includes both directories), has both and can read
  every secret. The seal only protects against someone who obtains the data
  directory *without* the init directory (for example a backup that excludes
  `/var/lib/nestlo-openbao/init`), and against a process that can reach the API
  but not the files.
- Agents cannot read these files (they run as `nestlo-agent`), and their
  OpenBao tokens are limited to their own paths: that is the boundary this
  module provides.

This is the right trade-off for a single trusted host and unattended
reboots, and the wrong one for anything shared or high-value. Options, from
cheapest to strongest:

1. Exclude `/var/lib/nestlo-openbao/init` from backups and keep disk
   encryption on.
2. `unsealKeyFile` on a tmpfs or a systemd credential that your own tooling
   fills at boot from somewhere else (a TPM-sealed credential, a network
   secret service). The helper writes the key there once at init and reads it
   on each start.
3. `autoUnseal = false`: after init, move the key off the machine and unseal
   by hand (`sudo nestlo-bao operator unseal`) after each start; the setup unit
   leaves the vault sealed and applies the declared configuration on its next
   run. Agents then see `503` until an operator unseals.
4. `keepRootToken = false`: the root token is revoked after the first
   configuration. Changing roles or policies later then needs
   `bao operator generate-root`. Combine with 2 or 3.
5. A real seal: OpenBao supports transit, PKCS#11 and cloud KMS seals
   (`services.openbao.settings.seal`). Not wired here.

One key share and threshold 1 is deliberate: Shamir splitting only helps when
the shares are held by different people.

## Using it from other Nestlo parts

**Secrets manager** (`modules/secrets-manager`, not modified by this module).
That module supports a sops backend and a `vault` backend (which starts a
`vault-bin` service that is unfree and unconnected to anything). How it could
source from OpenBao:

- Today: set `nestlo.openbao.secretsManager.enable = true` and leave sops
  uninitialised (`sopsInitialized = false`; an assertion refuses both). The
  secrets listed in `nestlo.secrets-manager.secrets` appear as
  `/run/secrets/<NAME>` (`root:nestlo`, 0440) from the KV path
  `nestlo/secrets-manager/<NAME>` (field `value`), refreshed every
  `interval` with a periodic token limited to `nestlo/data/secrets-manager/*`.
  The daemon's existing injection and `/etc/nestlo/secret-mapping.yaml` need
  no change. `nestlo-secrets set` still talks to sops: use
  `nestlo-bao kv put -mount=nestlo secrets-manager/NAME value=...` instead.
- Proposed change: add `"openbao"` to its `backend` enum, make
  `nestlo.openbao.secretsManager.enable` default from it, and have
  `nestlo-secrets list/set` call `nestlo-bao kv`. Per-agent mapping
  (`secret-mapping.yaml`) maps naturally onto `agents/<agent>/` paths and the
  agent's own login, replacing the injection of environment variables with a
  fetch by identity.

**Nestlo Cloud integrations.** The integrations proxy keeps its own secrets
store (`nestlo.cloud`); pointing it at `nestlo/cloud/...` would work the same
way as the sync unit does (a read-only token for one prefix). Not done: the
store is part of `modules/cloud` and the cloud service already runs as a
dedicated user with a state directory it protects.

**Observability.** With `nestlo.observability.enable` the module adds a
Prometheus job `openbao` (`/v1/sys/metrics?format=prometheus`, TLS verified
with the generated CA; the listener serves metrics without a token on
loopback only). The audit log is a separate JSON file, not part of the Nestlo
audit chain (`nestlo.audit` accepts only its own event types; a forwarder
would need a new event type there). Logs are in the journal (`openbao`,
`nestlo-openbao-setup`).

**Gateway.** The model gateway holds the provider keys today
(`nestlo.networking`). Provider keys could live in OpenBao and be rendered
for the gateway through the secrets-manager route above.

## Operations

```
sudo nestlo-bao status                 # nestlo-bao = bao with the root token and the CA preset
sudo nestlo-bao kv list -mount=nestlo agents
sudo systemctl status openbao nestlo-openbao-setup
sudo journalctl -u nestlo-openbao-setup -b
sudo systemctl restart openbao         # seals; the setup unit (PartOf) unseals again
sudo systemctl start nestlo-openbao-jwks   # re-read SPIRE's JWT keys now
```

`openbao.service` is not restarted by `nixos-rebuild switch` (nixpkgs' choice:
a restart seals the vault); restart it yourself to apply listener or storage
changes. Changes to `agents`, `kvMount` and the other declared configuration
are applied by the setup unit, which does restart on switch.

| Symptom | Likely cause |
|---------|--------------|
| `nestlo-openbao-setup` fails with "does not answer" | `openbao.service` failed: `journalctl -u openbao` (certificate missing: `nestlo-openbao-pki`) |
| Agent login: `invalid subject (sub) claim` | The SVID is for another identity than the role's: ask for the right one with `--agent` |
| Login: `no identity issued` | No SPIRE entry matches the process (user and unit), or an entry was added less than ~5 seconds ago |
| Login: signature or key errors after a day | SPIRE rotated its JWT key and the refresh timer has not run: `systemctl start nestlo-openbao-jwks` |
| `403` on KV | The path is not under `agents/<your agent>/` or `shared/` |
| Everything `503` after a reboot | Sealed: `autoUnseal = false`, or the unseal key file is missing |

## Limits

- Single node, file storage: no high availability, no replication. OpenBao's
  documentation treats `file` as suitable for development and small installs;
  switching to integrated storage (Raft) needs a migration.
- The key and root token sit on the host (see the trade-off above).
- The TLS CA key stays on the host (`pki/ca.key`, root-only) so the listener
  certificate can be renewed (every start, 30 days before expiry). Clients
  trust the CA only through `BAO_CACERT`/`/var/lib/nestlo-openbao/pub/ca.pem`.
- JWT-SVIDs are bearer tokens for `jwtSvidTtl` seconds (5 minutes by default);
  the OpenBao token they buy lasts `tokenTtl`.
- Nothing in Nestlo reads secrets from OpenBao by itself yet except the sync
  unit; the secrets-manager and cloud integrations above are proposals.
- The VM test `openbao` (`nix build .#checks.x86_64-linux.openbao`) covers
  init and unseal, the loopback TLS listener, KV v2, login with a SPIRE
  JWT-SVID and the per-agent isolation, the audit log, the `/run/secrets`
  sync, re-unseal after a restart and the metrics endpoint.
