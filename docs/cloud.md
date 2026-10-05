# Nestlo Cloud

Nestlo Cloud turns a Nestlo host into a self-hosted platform for persistent
Linux VMs, for people and for coding agents. It follows the design and the
command set of [exe.dev](https://exe.dev), so exe.dev users, scripts and tools
(including exe.dev's agent, Shelley) work with it:

```sh
ssh lobby@cloud.example.com new --name web        # a VM with a persistent disk
ssh -t lobby@cloud.example.com ssh web           # a shell in it
open https://web.cloud.example.com/              # its private HTTPS proxy
ssh lobby@cloud.example.com share set-public web # ... now public
```

```nix
nestlo.cloud = {
  enable = true;
  domain = "cloud.example.com";        # point cloud.example.com and *.cloud.example.com here
  tls = { mode = "acme"; email = "ops@example.com"; };
  users = [{ email = "alice@example.com"; admin = true; keys = [ "ssh-ed25519 AAAA... alice" ]; }];
};
nestlo.networking.enable = true;      # the llm integration (the model gateway)
```

Everything runs on the host: there is no hosted service and no account outside
your machine.

## What exe.dev offers, and where it is here

| exe.dev | Nestlo Cloud |
|---|---|
| `ssh exe.dev <command>` (the lobby) | `ssh lobby@<host> <command>`, the same commands and flags, `--json` |
| VMs with persistent disks, by the second | systemd-nspawn machines with their own ext4 disk image (`--disk`), user-namespaced root, restarted after reboots |
| Pools (shared vCPU/memory) and standalone VMs (sandboxes) | a systemd slice per pool (`billing capacity`), `new --standalone` |
| `https://<vm>.exe.xyz/`, private by default | `https://<vm>.<domain>/` through Caddy and `nestlo-cloudd`'s auth gate |
| Ports 3000 to 9999 at `vm.exe.xyz:PORT` | `https://<vm>-<port>.<domain>/` for any port; `extraPorts` adds `<vm>.<domain>:PORT` |
| `X-ExeDev-Email`, `X-ExeDev-UserID`, login and logout URLs | `X-Nestlo-Email`, `X-Nestlo-UserID` (and the `X-ExeDev-*` names), `/__nestlo/login?redirect=`, `POST /__nestlo/logout` |
| Sharing: web or root access, share links, public | `share add <vm> <email\|team> --role web\|root`, `share add-link`, `share set-public` |
| Custom domains with automatic TLS | `domain add <vm> <domain>`, certificates on demand (`tls.mode = "acme"`) |
| HTTPS API `POST /exec` with `exe0.` tokens | `POST https://<domain>/exec` with `nestlo0.` tokens (`exe0.` accepted), same permissions JSON, limits and status codes |
| `exe1.` short tokens, VM-scoped tokens, `X-Exedev-Authorization`, Basic auth for git | `nestlo1.` (`exe1.` accepted), `token-exchange` (`exe0-to-exe1`), `ssh-key generate-api-key --vm`, the same headers |
| Integrations: http-proxy, GitHub, LLM | the same, plus `peer` (VM to VM); secrets injected by the proxy, never in the VM |
| Reflection integration, metadata at 169.254.169.254, `/exe.dev` marker | the same endpoints and formats |
| Shelley on port 9999, bring your own key, AGENTS.md | Shelley in every VM (`agentUi.enable`), `https://<vm>-9999.<domain>/` |
| Teams: roles, SSO, team VMs, transfer, sharing policy | `team ...` with user/admin/billing_owner, OIDC login (`oidc`), `team settings vm-sharing` |
| Invites | `invite create --email`, redeemed with `ssh lobby@<host> redeem <code>` |
| Plans: Personal, Work, Enterprise | the same limits as quotas (`billing plan`, `billing usage`, `billing capacity`), set per user by an admin |
| Docker in VMs | podman (docker-compatible, `docker` client included) in the `nestlo` image; `/dev/fuse` and `/dev/net/tun` are passed through (tailscale works) |
| `cp` (copy a VM), `resize`, `rename`, `tag`, `comment`, `stat` | the same |
| Email to a VM (`share receive-email`) | not available: run a mail server in the VM behind a custom domain |
| Regions | one region per host (`region`); `set-region` accepts it |
| Nested virtualization (KVM) | not available: VMs are containers with user namespaces |

## Architecture

```
            ssh lobby@host ...                 https://*.domain
                   │                                  │
                 sshd ── AuthorizedKeysCommand     Caddy (on-demand TLS)
                   │      + forced command            │ forward_auth /__auth
           nestlo-cloud-lobby ── lobby.sock ──► nestlo-cloudd ◄── /exec, login, share links
                                                     │      │
                                 vmd.sock (fds) ◄────┘      └──► Redis (state)
                                     │
                          nestlo-cloud-vmd (root)
                                     │ systemd-run
               nestlo-vm-<id>.service: systemd-nspawn (user namespace)
                    disk.img (ext4, loop) · bridge nestlocl0 (isolated port)
                                     │
        VM ──► 10.210.0.1:80  integrations proxy, reflection   (secrets added here)
           ──► 169.254.169.254 metadata service
           ──► 10.210.0.1:53  dnsmasq (*.int.<domain> → the proxy)
           ──► internet (NAT)
```

- **nestlo-cloudd** (user `nestlo-cloud`) keeps all state in Redis and
  decides every access. It never runs anything as root.
- **nestlo-cloud-vmd** (root) only executes: it accepts requests from
  `nestlo-cloudd` (socket group plus an SO_PEERCRED check) and runs the
  VM operations. `ssh <vm>` hands the session's terminal file descriptors
  through `nestlo-cloudd` (which checks root access) to the helper, which
  runs `nsenter` into the VM on them.
- **The lobby** is the SSH user `lobby`: sshd asks `nestlo-cloud-lobby keys`
  whether a key is registered and forces `nestlo-cloud-lobby --key
  <fingerprint>` for it; the command in `SSH_ORIGINAL_COMMAND` goes to
  `nestlo-cloudd`.

### VMs

A VM is a systemd-nspawn machine (`avm-<id>`) with:

- a persistent disk: `/var/lib/nestlo-cloud-vms/vms/<id>/disk.img`, a sparse
  ext4 image of `--disk` size, loop-mounted; `resize --disk` grows it online
- `--private-users=pick`: root in the VM is an unprivileged UID range on the
  host
- CPU and memory caps of its own (`CPUQuota`, `MemoryMax`) inside its owner's
  pool slice (`nestlo-cloud-<pool>.slice`, the pool size), or a slice of its
  own for standalone VMs
- an isolated port on the bridge `nestlocl0`: VMs cannot reach each other
  (use a `peer` integration), and an nftables bridge rule drops frames with
  another source address, so a VM cannot pose as another to the integrations
  proxy
- the host's Nix store read-only: the default `nestlo` image is a small
  skeleton whose tools (`image.packages`: git, Python, Node, podman, Claude
  Code, Codex, Gemini CLI, OpenCode, Goose, Shelley ...) come from the store,
  so a VM's disk holds only its own changes
- an init (`/.nestlo/init`) that runs the setup script once, the VM's own
  sshd (root, keys of everyone with root access), Shelley on port 9999, the
  `--prompt` agent once, and `--command` (restarted when it exits)

`new --image <reference>` creates a VM from any OCI/Docker image instead
(pulled with skopeo, unpacked with umoci); images that contain systemd boot
it. The image needs `/bin/sh`.

The VM firewall lets VMs reach the host only on the resolver (53), the
integrations proxy and the metadata service (80); everything else on the host
is closed to them. Outbound traffic is NATed.

## Commands

`ssh lobby@<host> help` lists them; `<command> --help` gives flags and
examples (as JSON, also over the API). Highlights:

```sh
new [--name N] [--image nestlo|<oci ref>] [--cpu 2] [--memory 8GB] [--disk 20GB]
    [--env K=V]... [--tag T]... [--comment C] [--command CMD] [--setup-script S|/dev/stdin]
    [--prompt TEXT|/dev/stdin] [--integration NAME]... [--standalone] [--port P]
ls [-l] [--shared] [--tag T] [pattern]       rm VM...       restart|stop|start VM
rename VM NEW    tag [-d] VM TAG...    comment VM TEXT    stat VM [--range 24h|7d|30d|cycle]
cp VM [NEW] [--cpu --memory --disk --copy-tags yes|no]   resize VM [--cpu --memory --disk]
ssh VM [command]            tunnel VM [port]   (over SSH only)
share show|port|set-public|set-private|add|remove|add-link|remove-link VM ...
domain add VM DOMAIN | domain ls VM|-a | domain rm VM DOMAIN
ssh-key list | add KEY [--name] [--tag] | remove KEY | rename KEY NEW
ssh-key generate-api-key [--cmds a,b] [--exp 30d] [--vm VM] [--label L]
token-exchange TOKEN [--vm VM]     (alias exe0-to-exe1)
integrations list | add TYPE --name N ... | edit | remove | attach N SPEC | detach | rename
team | team create NAME | members | add EMAIL [--role] | remove | role | rename | transfer VM EMAIL
team settings vm-sharing admins-only|all-members | team vm ls | team auth | team disable --yes
invite create [--email E] [--team] [--days N] | invite ls | invite revoke CODE
billing plan | billing usage [--range] | billing capacity [--cpu N --memory M]
browser          a one-time link that logs a browser in
shelley VM       the agent UI's URL
admin users | admin user add|plan|disable|enable | admin vms    (admins)
```

`--setup-script /dev/stdin` and `--prompt /dev/stdin` read the SSH session's
standard input:

```sh
ssh lobby@host new --name api --setup-script /dev/stdin < setup.sh
```

### SSH into a VM, scp, rsync, VS Code

`ssh -t lobby@<host> ssh <vm>` opens a shell in any VM image. For tools that
need a real SSH server (scp, rsync, VS Code Remote-SSH), the `nestlo` image
runs sshd in the VM; reach it through the lobby:

```
# ~/.ssh/config
Host *.cloud.example.com
  User root
  ProxyCommand ssh lobby@cloud.example.com tunnel %h 22
```

```sh
scp file.txt web.cloud.example.com:~/
code --remote ssh-remote+web.cloud.example.com /root
```

## The HTTPS proxy

`https://<vm>.<domain>/` forwards to the VM's port (`share port`, default 80);
`https://<vm>-<port>.<domain>/` to any other port. Requests are allowed when
the VM is public, the browser has a session for that host (log in through the
lobby), or they carry a VM token. Behind the proxy the VM sees:

| Header | When |
|---|---|
| `X-Nestlo-Email`, `X-Nestlo-UserID` (and `X-ExeDev-Email`, `X-ExeDev-UserID`) | the request is authenticated |
| `X-Nestlo-Token-Ctx` (and `X-ExeDev-Token-Ctx`) | a VM token with a `ctx` |

Client-supplied copies of these headers are always removed. A public site can
ask for a login with `/__nestlo/login?redirect=/path`; `POST
/__nestlo/logout` ends the session for that host. Do not trust these headers
on ports that are reachable without the proxy.

Login: `ssh lobby@<host> browser` prints a one-time link; with `oidc` set,
the login page also offers single sign-on (any OIDC provider, authorization
code flow; `allowedDomains` limits who may sign up). Sessions are per host:
logging in on a VM host goes through the lobby and a one-time code bound to
that host, so a cookie of one VM is never valid on another.

### VM tokens

```sh
ssh lobby@host ssh-key generate-api-key --vm=web --label=deploy
curl -H "X-Nestlo-Authorization: Bearer $TOKEN" https://web.cloud.example.com/api
git clone https://git:$TOKEN@web.cloud.example.com/repo.git      # Basic auth for git
```

`X-Nestlo-Authorization` (and `X-Exedev-Authorization`) is consumed and
removed by the proxy; `Authorization: Bearer` and Basic also work.

## The HTTPS API

```sh
curl -X POST https://cloud.example.com/exec -H "Authorization: Bearer $TOKEN" -d 'ls'
```

The body is a lobby command; the answer is its JSON. Only POST; no stdin, no
terminal; bodies up to 64 KB; 30 s per command (a longer one keeps running,
the answer is 504). Status codes: 400 (empty or unparsable command), 401 (bad,
expired or unknown token), 403 (not in the token's `cmds`), 404 (unknown
command), 405, 413, 422 (the command failed; `error` says why), 429 (per-key
rate limit, `exec_rate_per_minute`), 504.

Tokens are `nestlo0.<base64url(permissions)>.<base64url(SSH signature)>`,
signed by a registered SSH key with the namespace `v0@<domain>` (or
`v0@<vm>.<domain>` for a VM token), exactly like exe.dev's `exe0` tokens:

```sh
PERMISSIONS='{"cmds":["ls","new"],"exp":1798761600}'
PAYLOAD=$(printf %s "$PERMISSIONS" | base64 | tr -d '\n=' | tr '+/' '-_')
SIG=$(printf %s "$PERMISSIONS" | ssh-keygen -Y sign -f ~/.ssh/nestlo_api -n v0@cloud.example.com)
SIGBLOB=$(echo "$SIG" | sed '1d;$d' | tr -d '\n=' | tr '+/' '-_')
printf 'nestlo0.%s.%s\n' "$PAYLOAD" "$SIGBLOB"     # the token
```

Permissions: `exp`, `nbf` (Unix times), `cmds` (command names, subcommands
spelled out: `"ssh-key list"`), `ctx` (signed, passed to the VM as
`X-Nestlo-Token-Ctx`). Without `cmds` a token may run `help ls new whoami
"ssh-key list" "share show" token-exchange team "team members"`. Compact JSON,
no duplicate keys, at most 8 KB. Removing the signing key (`ssh-key remove`)
revokes all its tokens. `ssh-key generate-api-key` mints a token with a fresh
key of its own (`api:<label>`), so it can be revoked alone.

## Integrations

Integrations give VMs authenticated access to other services without putting
the credential in the VM: the VM calls `http://<name>.int.<domain>/...`
(resolved to the host by the VM resolver), and the integrations proxy adds the
secret and forwards the request. Secrets are encrypted at rest
(`/var/lib/nestlo-cloud/secret.key`).

```sh
# any HTTP API
ssh lobby@host integrations add http-proxy --name stripe --target https://api.stripe.com \
    --bearer sk_live_... --attach tag:payments
#   in the VM:  curl http://stripe.int.cloud.example.com/v1/charges

# GitHub repositories over git smart HTTP (read-only with --read-only)
ssh lobby@host integrations add github --name gh --repository acme/web --repository acme/* \
    --bearer github_pat_... --attach vm:web
#   in the VM:  git clone http://gh.int.cloud.example.com/acme/web.git

# VM to VM
ssh lobby@host integrations add peer --name db --vm db --port 5432 --attach tag:app
```

- Attach with `vm:<name>`, `tag:<tag>` or `auto:all`; `new --integration N`
  attaches at creation.
- `--team` makes a team integration, reached at `<name>.team.<domain>`.
- `--header 'Name: value'` adds headers; `--act-as-user` also sends
  `X-Nestlo-Email` of the VM's owner.
- System integrations come from `nestlo.cloud.integrations` (secrets read
  from files at request time).

### The llm integration

With `nestlo.networking.enable`, every VM gets `http://llm.int.<domain>`: the
Nestlo model gateway, with a gateway identity per VM (so the gateway's
budgets, loop detection, DLP and audit apply per VM) and no provider key in the
VM. It speaks the exe.dev LLM integration protocol:

- `GET /models.json`: the catalog (schema 1) from the gateway's price list
- `POST /v1/messages` (Anthropic), `/v1/chat/completions`, `/v1/responses`
  (OpenAI); `/anthropic/...` and `/openai/...` reach a provider explicitly

VMs get `ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL` and placeholder API keys in
their environment, so Claude Code, Codex and other agents work unchanged.

### Reflection and metadata

From inside a VM:

```sh
curl http://169.254.169.254/                          # {"reflection_url": "http://reflection.int.<domain>", ...}
curl http://reflection.int.<domain>/                  # the VM, its owner, its integrations
curl http://reflection.int.<domain>/integrations      # what agents can use (and how to clone the repos)
```

These are the endpoints exe.dev tools use: Shelley finds its LLM integration
this way, with nothing to configure.

## Shelley

[Shelley](https://github.com/boldsoftware/shelley), exe.dev's mobile-friendly
web coding agent, runs in every VM (`agentUi.enable`) on port 9999:
`https://<vm>-9999.<domain>/` (private like the rest of the VM). It uses the
llm integration by default; bring your own key in its settings. It reads
`~/.config/shelley/AGENTS.md` and project `AGENTS.md`/`CLAUDE.md` files.
`shelley <vm>` prints the URL. The binary is `pkgs.nestlo.shelley`, a pinned
release; updating it updates every VM.

## Plans and quotas

| Limit | personal | work | enterprise |
|---|---|---|---|
| Pool VMs | 50 | 1000 | unlimited |
| Pools | 1 | unlimited | unlimited |
| Pool size (default / max) | 2 vCPU, 4 GB / 16 vCPU, 32 GB | 4 vCPU, 8 GB / 512 vCPU, 1024 GB | 16 vCPU, 32 GB / unlimited |
| Disk | 100 GB per 2 vCPU of pool | 100 GB per 2 vCPU of pool | unlimited |
| Network (metered) | 200 GB | 50 GB per vCPU | unlimited |
| Standalone VMs (max size) | 50 (16 vCPU, 32 GB) | 100 (32 vCPU, 64 GB) | unlimited |
| Sharing with users and teams | no (public sites yes) | yes | yes |

These are exe.dev's published plan limits, used as quotas: an administrator
sets each user's plan (`nestlo.cloud.users.*.plan`, `admin user plan`,
`defaultPlan`), and `planOverrides` changes any limit. Users size their pool
with `billing capacity` within the plan's maximum; `billing usage` shows vCPU
hours, disk and network against it. Teams share one pool.

## Security notes

- Root in a VM is not root on the host (user namespaces), but VMs share the
  host kernel. For hostile tenants, run separate hosts per tenant.
- `nestlo-cloud-vmd` is root and does what `nestlo-cloudd` asks; only the
  `nestlo-cloud` user can reach its socket.
- The lobby user has no other rights: its only program is the forced command,
  and TCP, agent and X11 forwarding are off for it.
- Every change is an audit event (`cloud.*`) when `nestlo.audit` is on.

## Operations

| Unit | What |
|---|---|
| `nestlo-cloud.service` | control plane (`journalctl -u nestlo-cloud`) |
| `nestlo-cloud-vmd.service` | VM helper; restarting it leaves VMs running |
| `nestlo-vm-<id>.service` | one VM (`machinectl list` shows `avm-<id>`) |
| `nestlo-cloud-dns.service` | resolver for VMs |
| `caddy.service` | HTTPS |

Prometheus (`127.0.0.1:9941`): `nestlo_cloud_vms{status}`,
`nestlo_cloud_users`, `nestlo_cloud_vcpus_allocated`, and counters for API
requests, logins, proxy decisions, integration requests and VM restarts.
VMs that should run are started again after a reboot or a crash (every
`tick_sec`).

Tests: `services/tests/test_cloud.py` (tokens against OpenSSH's own
signatures, every command, the API, the proxy gate, login, share links, the
integrations proxy, the lobby, the nspawn driver) and the VM test
`nix build .#checks.x86_64-linux.cloud`.
