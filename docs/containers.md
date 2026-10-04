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

## Kernel-surface hardening

Sandbox units, container units and the orchestrator's task and verify units
all get the same extra properties (`HARDEN_PROPS` in `nixos/packages/cli.nix`
and `taskrunner.py`):

- `SystemCallFilter=@system-service` minus `@privileged @mount @module
  @raw-io @reboot @swap @obsolete @cpu-emulation @debug`, with
  `SystemCallErrorNumber=EPERM` (denied calls fail instead of killing the
  agent, so libuv falls back from io_uring) and `SystemCallArchitectures=native`
- `RestrictNamespaces=yes` (`unshare -U` fails), `RestrictAddressFamilies=AF_UNIX
  AF_INET AF_INET6 AF_NETLINK` (no raw or packet sockets)
- `ProtectProc=invisible`, `ProtectClock`, `ProtectControlGroups`,
  `ProtectKernelLogs`, `ProtectHostname`, `LockPersonality`, `RestrictRealtime`,
  `RestrictSUIDSGID`
- empty `CapabilityBoundingSet=` and `AmbientCapabilities=`, `MemorySwapMax=0`

Left out on purpose:

- `MemoryDenyWriteExecute`: Node and V8 need writable-executable JIT pages.
- `ProcSubset=pid`: it hides `/proc/cpuinfo`, `/proc/stat` and `/proc/meminfo`,
  so Node's `os.cpus()` returns `[]` and jest, npm and webpack size their worker
  pools wrongly.

Consequence of `RestrictNamespaces=yes`: tools that build their own sandbox
from user namespaces (bubblewrap, Chromium's sandbox, rootless containers)
cannot run inside an agent; run Chromium with `--no-sandbox`. Git, HTTPS
and npm are unaffected.

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
- FORWARD from `agentos0` (chain `agentos-fwd`) is default deny: never to the
  `agentos-llm` ipset (provider APIs only via the gateway), never back out of
  `agentos0` (other containers), never to `169.254.169.254` or any private,
  loopback, CGNAT, link-local, multicast or reserved range (the LAN), even if
  an allowlisted name resolves there. The gateway and DNS forwarder are host
  addresses reached through INPUT (`agentos-in`), not forwarded. With
  `defaultEgress = "deny"` only addresses in `agentos-egress` are then allowed;
  with `"allow"` the remaining public addresses are. IPv6 is rejected.
- Loopback services of the host are unreachable: the container's `127.0.0.1`
  is its own.

## Operating

- `agentos list` shows the isolation mode (and GPUs); the state JSON has
  `isolation` (`sandbox`, `container` or `none`).
- `agentos shell <id>` enters the container's mount, net, PID, IPC and UTS
  namespaces (`nsenter`), picking a process inside the PID namespace.
- Everything under `/run/agentos/net/<id>`, the namespace and the veth are
  removed when the unit stops.
- Before every setup (and on `agentos-netns sweep`) stale `agentos-*`
  namespaces, state directories and `avh*` veths with no live
  `agentos-agent-<id>.service` are removed, so a crash does not leak addresses.

## Limits

- No user namespace (`PrivateUsers=`): the agent is `agentos-agent` in the
  host's user namespace, with no capabilities and `NoNewPrivileges`; creating
  user namespaces inside is blocked (`RestrictNamespaces=yes`).
- The agent binary must live under `/nix/store` or the system profile; tools
  in the operator's home profile are not visible (same as the sandbox).
- The container is not a general OCI container; use `containerRuntime` for
  those.
- The mount layout depends on systemd's handling of `RootDirectory` with
  `TemporaryFileSystem=/:ro` and `PrivatePIDs` (systemd 257 or newer);
  `tests/container.nix` checks it in a VM.
