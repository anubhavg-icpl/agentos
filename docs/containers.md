# Container isolation

`agentos spawn <agent> --isolation container` runs an agent in its own
namespaces instead of the host's. Set `agentos.runtime.defaultIsolation =
"container"` to make it the default (`--isolation sandbox` opts out). Needs
`agentos.networking.enable`.

An agent is still a transient systemd unit (`agentos-agent-<id>.service`, user
`agentos-agent`, the same memory/CPU/task limits and hardening as a sandboxed
agent). A container additionally gets:

| Namespace | How |
|:---|:---|
| Mount | `RootDirectory=/var/empty` with `TemporaryFileSystem=/:ro`. Mounted read-only: `/nix/store`, `/run/current-system/sw`, the TLS trust store, `/etc/gitconfig`, `/bin/sh`, `/usr/bin/env`, and a per-agent `resolv.conf`, `hosts`, `nsswitch.conf`, minimal `passwd` and `group`. Read-write: the workspace and the agent home. Nothing else of the host is visible (no `/var/lib/agentos/state`, no Redis socket, no gateway admin socket, no `/home`). |
| PID | `PrivatePIDs=yes` |
| IPC, hostname | `PrivateIPC=yes`, `ProtectHostname=yes` |
| Network | A network namespace `agentos-<id>` joined with `NetworkNamespacePath=` |
| Devices | `PrivateDevices=yes`; granted GPUs are bind-mounted (see [gpu.md](gpu.md)) |

## Network

`agentos-netns setup <id>` runs as `ExecStartPre=+` of the unit (root) and
`agentos-netns teardown <id>` as `ExecStopPost=+`, whether the agent exits,
is killed, or fails to start. Setup:

- creates the namespace and a veth pair; `eth0` in the namespace gets the
  first free address of `agentos.networking.agentNetCIDR` (`10.200.0.2`,
  `.3`, ...; allocations are serialized with a lock and recorded in
  `/run/agentos/net/<id>/ip`), the host end joins the `agentos0` bridge as an
  *isolated* port, so containers cannot reach each other
- default route via the bridge address (`10.200.0.1`), IPv6 off
- the container's `resolv.conf` points at the bridge address, where dnsmasq
  now listens too (same allowlist and `agentos-egress` ipset as the host)

The model gateway listens on `127.0.0.1` and on the bridge address
(`gateway.listen` is a list). A container gets
`ANTHROPIC_BASE_URL=http://10.200.0.1:8080/agent/<id>/anthropic`.

Firewall (security and networking modules):

- INPUT from `agentos0` (chain `agentos-in`): only the gateway port, DNS and
  ping to the bridge address. Other host services, even ones open to all
  interfaces such as SSH, are rejected.
- FORWARD from `agentos0` (chain `agentos-fwd`): never to the `agentos-llm`
  ipset (provider APIs only via the gateway), never to the agent subnet. With
  `defaultEgress = "deny"` only addresses in `agentos-egress` are allowed;
  with `"allow"` RFC1918 and link-local ranges are refused. IPv6 is rejected.
- Loopback services of the host are unreachable: the container's `127.0.0.1`
  is its own.

## Operating

- `agentos list` shows the isolation mode (and GPUs); the state JSON has
  `isolation` (`sandbox`, `container` or `none`).
- `agentos shell <id>` enters the container's mount, net, PID, IPC and UTS
  namespaces (`nsenter`), picking a process inside the PID namespace.
- Everything under `/run/agentos/net/<id>`, the namespace and the veth are
  removed when the unit stops.

## Limits

- No user namespace (`PrivateUsers=`): the agent is `agentos-agent` in the
  host's user namespace, with no capabilities and `NoNewPrivileges`.
- The agent binary must live under `/nix/store` or the system profile; tools
  in the operator's home profile are not visible (same as the sandbox).
- The container is not a general OCI container; use `containerRuntime` for
  those.
- The mount layout depends on systemd's handling of `RootDirectory` with
  `TemporaryFileSystem=/:ro` and `PrivatePIDs` (systemd 257 or newer);
  `tests/container.nix` checks it in a VM.
