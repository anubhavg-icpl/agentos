# Pullrun (experimental)

[Pullrun](https://github.com/pullrun/pullrun) is an OCI runtime that runs one
image as a runc container or as a Firecracker microVM. AgentOS packages it
(`pkgs.agentos.pullrun`, the `pullrun` CLI and the `pullrun-runtime` daemon,
built from source), runs the daemon for operators, and can run agents in
Pullrun containers.

Everything here is experimental. The container path was exercised against a
real daemon (see [What was tested](#what-was-tested)); the microVM path was
not run at all, and `agentos spawn` does not offer it.

## Security model: a root daemon, operators only

`pullrun-runtime` runs as root and runs any image you give it, with any host
directory bind-mounted into it. Whoever can open its socket can therefore
become root on the host. So:

- The socket is `/run/pullrun/pullrun.sock`, mode `0660`, group `agentos`,
  inside `/run/pullrun` (`0750 root:agentos`). Only root and the operators
  (`agentos.runtime.operators`, group `agentos`) can reach it. The sandboxed
  `agentos-agent` user cannot even see it, and neither can other users.
  The service users that are in the `agentos` group (the gateway and the agent
  daemon) can open it, so do not add code to them that forwards requests to
  Pullrun.
- Pullrun creates the socket with mode `0700`; the unit's `ExecStartPost`
  opens it to the group.
- The `pullrun` CLI starts a daemon of its own when it cannot connect ("direct
  mode"). AgentOS always calls it with `--direct=false`; do the same in your
  own scripts.
- The MCP server (`pullrun mcp`, tools: run, stop, exec, list, get, inspect,
  logs, stats, pull_image, list_images, build, push, prune) has no mount or
  network parameters, but it can run arbitrary images as root. It is listed in
  the MCP registry (`/etc/agentos/mcp-servers.json`, category `devops`, flag
  `operatorsOnly`) when both `agentos.mcp-servers.enable` and
  `agentos.pullrun.enable` are set, as
  `pullrun --direct=false --socket /run/pullrun/pullrun.sock mcp`. It is for
  MCP clients that an operator runs. It is not for the agents that
  `agentos spawn` starts: they cannot connect to the socket, and that is the
  only thing keeping them from root. Do not widen the socket permissions to
  make an agent's MCP client work.
- The daemon unit is only lightly sandboxed (`NoNewPrivileges`, `ProtectHome`,
  `ProtectKernelModules`, `ProtectClock`, `LockPersonality`, `RestrictRealtime`,
  `RestrictSUIDSGID`): it has to manage namespaces, mounts, cgroups and network
  devices as root.

## Enabling it

```nix
agentos.pullrun.enable = true;               # daemon, CLI, firecracker, e2fsprogs
agentos.pullrun.agentContainers.enable = true; # for `agentos spawn --isolation pullrun`
```

| Option | Default | |
|:---|:---|:---|
| `agentos.pullrun.enable` | `false` | Install and run the daemon |
| `agentos.pullrun.vm.enable` | `true` | Firecracker backend (`--vm-firecracker`, `--vm-kernel`); needs `/dev/kvm` |
| `agentos.pullrun.kernel` | built from nixpkgs | Uncompressed `vmlinux` for the VMs |
| `agentos.pullrun.storeRoot` | `/var/lib/pullrun` | Images and workload state |
| `agentos.pullrun.agentContainers.enable` | `false` | Bridge, firewall, gateway address and image for `--isolation pullrun`; needs `agentos.networking.enable` and `agentos.runtime.enable` |
| `agentos.pullrun.agentContainers.image` / `.buildImage` | `agentos-agent:latest` / `true` | Agent image tag, and whether to build it at boot |

### The microVM kernel

nixpkgs and our pinned inputs have no kernel Firecracker can boot with
Pullrun, and the stock NixOS kernel cannot do it: it builds `virtio_blk` and
ext4 as modules and expects an initrd, while Pullrun boots
`root=/dev/vda rw init=/init pci=off` with no initrd. Firecracker's own CI
kernels are downloaded binaries. The cheapest correct option is
`modules/pullrun/kernel.nix`: nixpkgs' 6.12 LTS with the x86_64 defconfig plus
virtio-mmio/blk/net/vsock, ext4, devtmpfs, the serial console and kernel `ip=`
autoconfiguration built in. `agentos.pullrun.kernel` is the `vmlinux` in its
`dev` output. It is compiled locally the first time (a defconfig kernel). Container-only users set
`agentos.pullrun.vm.enable = false` and never build it. To use another kernel,
set `agentos.pullrun.kernel` to a store path, for example a pinned
`fetchurl` of a Firecracker CI `vmlinux`.

The kernel builds (a 54 MB ELF `vmlinux`, with the options above set to `y`
in its final config; about 15 minutes on 4 cores). Without `/dev/kvm` the VM
backend cannot start workloads, and whether this kernel boots under the real
Firecracker with Pullrun was not tested.

## `agentos spawn --isolation pullrun`

```
agentos spawn claude --isolation pullrun -- -p "fix the failing tests"
```

The agent runs in a Pullrun runc container (`--backend container`) on the
shared bridge `pullrun-br0` (10.42.0.0/16). It is a headless run: see the
limitations below.

How it works (`spawn_pullrun` in `nixos/packages/cli.nix`):

- **Image.** `pullrun-agent-image.service` builds `agentos-agent:latest` at
  boot with `pullrun build` from a Nix-generated Dockerfile: `FROM scratch`, a
  tiny root with `passwd`, `group`, `nsswitch.conf` and `resolv.conf` (the
  bridge address), and `PATH=/run/current-system/sw/bin`. There is no copy of
  the agent or its closure: `agentos spawn` bind-mounts the host's `/nix/store`
  and system profile read-only (the same files `--isolation container` shows),
  so one small image serves every agent. `pullrun load` cannot be used for a
  Nix-built image: it only accepts Pullrun's own DAG export, not Docker or OCI
  archives, and the alternative, a local registry, was not needed. To use your
  own image, build or pull it into the store, set
  `agentContainers.image` to its tag and `buildImage = false`. `agentos spawn`
  runs it by its root digest, looked up from the tag with `pullrun images
  --json`, because `pullrun run <tag>` always pulls from a registry.
- **Mounts** (`-v`, which work for containers): `/nix/store` and the system
  profile and TLS files read-only, per-agent `passwd` and `group`, the
  workspace and the agent home read-write at their host paths.
- **Identity.** Pullrun starts the container's process as root (uid 0, a
  reduced capability set, no user namespace; the image's `USER` is not used).
  The agent is therefore started through `setpriv`, which drops to the
  `agentos-agent` uid and gid, clears the supplementary groups and the whole
  bounding set, and sets `no_new_privs` before the agent runs. In the
  container the agent has uid `agentos-agent`, `CapEff = CapBnd = 0`,
  `NoNewPrivs = 1`. Files it writes in the workspace belong to `agentos-agent`.
- **Output.** Pullrun discards a container's stdout and stderr (`pullrun logs`
  shows only the state), and `--attach` only polls for the exit code. The
  agent's output is therefore redirected into
  `/var/lib/agentos/pullrun-logs/<id>.log`, which `agentos spawn` follows on
  its own stdout. The exit code of the agent is the exit code of
  `agentos spawn`.
- **Lifecycle.** There is no systemd unit. `agentos spawn` stays running for
  as long as the container does and is the process the agent daemon tracks
  (by pid). `agentos kill <id>` and the daemon's auto-shutdown send it
  SIGTERM, which stops the container (`pullrun stop`). `agentos shell <id>`
  opens a shell as root inside the container (`pullrun exec`).
- **CPU and memory** come from `agentos.runtime.agentLimits` (`--cpu`,
  `--memory`). Pullrun has no task limit.

### Networking and egress

Pullrun's container networking offers `isolated` (loopback only), `bridge`
(the shared `pullrun-br0`) and `host`. `slirp` is for VMs.

`--net host` would be the simplest way to reach the gateway on 127.0.0.1, but
it is not used: the egress rules of the security module match the *uid* of the
sending process (`-m owner --uid-owner agentos-agent`), and a Pullrun container
starts its process as root, so those rules would not apply to it before
`setpriv` and the agent would share the host's loopback services. The modes
use the bridge:

- The module creates `pullrun-br0` with `10.42.0.1/16` (Pullrun's hardcoded
  address) so that it exists when the gateway starts, adds it to the NAT
  internal interfaces, and adds `10.42.0.1` to the gateway's listen addresses
  and to dnsmasq (when enabled). The agent's `ANTHROPIC_BASE_URL` is
  `http://10.42.0.1:8080/agent/<id>:<token>/anthropic`, as with
  `--isolation container` but on the other bridge.
- INPUT from `pullrun-br0` (chain `pullrun-in`): only the gateway port, DNS and
  ping to `10.42.0.1`; every other host service is rejected.
- FORWARD from `pullrun-br0` is sent to the `agentos-fwd` chain when
  `agentos.security.enable` is set: the same policy as `--isolation container`
  (no provider APIs except through the gateway, the egress allowlist with
  `defaultEgress = "deny"`, private ranges blocked with `"allow"`). Without the
  security module there is no egress policy, as for the other modes. IPv6 is
  dropped.
- The containers share one L2 segment: agents in Pullrun containers can reach
  each other (the `agentos0` bridge of `--isolation container` isolates its
  ports). Do not run mutually distrusting agents this way.
- DNS inside the container is `10.42.0.1` (the image's `resolv.conf`); it
  works when dnsmasq is enabled (`defaultEgress = "deny"` does that).
- The agent's environment (including the gateway token) is passed on the
  `pullrun run` command line and stored in Pullrun's workload state. The
  command line is visible to other local users while the agent runs, as with
  `systemd-run --setenv` for the other modes.

### Not supported (fails with a message)

- `--isolation microvm`: "not supported yet: Firecracker has no host mounts in
  Pullrun". The VM backend has no virtio-fs, so the workspace cannot be shared.
  `pullrun cp` is no replacement: it copies a single file to or from the
  host-side rootfs directory of the workload, not into a running VM's disk.
- `--gpu` with `--isolation pullrun` (and with `microvm`).
- `--isolation pullrun --unsandboxed`.
- `agentos.runtime.defaultIsolation` cannot be `pullrun`.

### Limitations

- No stdin and no TTY: use it for non-interactive runs (`-p "..."`). The
  `pullrun run -t` attach, by its source, opens a new exec session and not the agent's terminal.
- Short-lived containers can fail in bridge mode: Pullrun reads the container
  pid from runc after starting it, to wire up the veth, and a container that is
  gone by then makes `pullrun run` fail with "ip link add veth pair failed". A
  real agent lives long enough; a command that exits in milliseconds does not.
- The agent binary must be under `/nix/store` or `/run/current-system`, as for
  `--isolation container`.
- The container has no hardening beyond what Pullrun applies and what
  `setpriv` does; in particular none of the systemd unit properties of the
  other modes (`ProtectSystem`, `MemoryMax` as a unit, device policy).
- `pullrun-agent-image` rebuilds the image at every boot (it is cached by
  content, so this is quick). If you set `buildImage = false` the image must
  already be in `/var/lib/pullrun`.

## What was tested

Against a real `pullrun-runtime` daemon (root, runc, bridge networking) in a
sandbox, with a fake model gateway: the image builds with `pullrun build` from
the Dockerfile above; `agentos spawn --isolation pullrun` runs the agent as
uid 65534 with all capability sets zero and `NoNewPrivs 1`, in the workspace,
with the workspace mount writable by it, its arguments (with commas) intact, its
output streamed, and the gateway URL on `10.42.0.1`; and the failure cases
(`microvm`, `--gpu`, `--unsandboxed`) fail with the messages above.

Not tested here: the NixOS VM test `tests/pullrun.nix` (no KVM in the
build sandbox; it was only built as a driver, which lints it), the firewall
rules, the gateway on `10.42.0.1`, anything under the unit's hardening, and
every Firecracker path including the kernel.

`nix build .#checks.x86_64-linux.pullrun` runs the VM test: the daemon starts,
`pullrun list` and `images` work through the socket, the agent user and an
unrelated user cannot use or see the socket, the bridge carries the gateway,
and an agent runs in a container as above.
