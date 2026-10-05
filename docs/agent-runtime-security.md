# Agent runtime security (`nestlo.agentRuntimeSecurity`)

Agents run code. The sandbox limits what they can do; this module watches what
they try. It runs [Tetragon](https://tetragon.io) (eBPF, Apache-2.0 userspace
with GPL-2.0 BPF programs, `pkgs.tetragon` 1.6.0) with policies written for
Nestlo's agents, and turns the kernel events of agent users into alerts in the
journal, a JSON log, the Nestlo audit log and Prometheus.

Default mode is **observe**: it detects and reports. Killing is opt-in.

```nix
nestlo.runtime.enable = true;
nestlo.audit.enable = true;
nestlo.agentRuntimeSecurity.enable = true;
```

Falco is not packaged in the pinned nixpkgs (`pkgs.falco` does not exist) and
neither engine has a NixOS module there, so the module defines the units
itself.

## What runs

| Unit | What |
|---|---|
| `nestlo-tetragon.service` | the engine. Loads the TracingPolicies from the Nix store, exports JSON events to `/var/log/tetragon/tetragon.json`, gRPC on `unix:///run/tetragon/tetragon.sock` (use `tetra --server-address unix:///run/tetragon/tetragon.sock getevents -o compact`) |
| `nestlo-agent-security-forwarder.service` | tails the export file, keeps the events of agent users, writes alerts to `/var/log/nestlo-agent-runtime-security/alerts.jsonl`, sends them to the audit writer, serves `nestlo_runtime_security_*` on 127.0.0.1:9976, and in enforce mode kills |

Who is an agent: the users in `users`, by default `nestlo-agent` (everything
`nestlo spawn` and the task runner start, including the transient
`nestlo-agent-<id>` units, and herdr's server) and `openclaw` when
`nestlo.openclaw.enable` is set. Tetragon cannot select by uid in kernel hooks,
so the policies match on what is touched, and the forwarder applies the uid
test (resolved by name, re-resolved every minute). Events of other users are
dropped; they are still in the export file.

## Rules

Each is a TracingPolicy named `nestlo-ars-<rule>` and can be switched off
under `policies`.

| Rule | Fires when an agent | Hook | Severity |
|---|---|---|---|
| `credential-access` | opens a file under `policies.credentialAccess.paths` (`/run/secrets`, `/run/credentials`, `/var/lib/nestlo/secrets`, the audit and LocalAI/vLLM key directories, SSH host keys, the agent's `~/.ssh`, `/root`), the `keyFile` of any `nestlo.networking.providers`, or a private key or credential file in any home (`.ssh/id_*`, `.aws/credentials`, `.netrc`, `.git-credentials`, `gh/hosts.yml`, `.docker/config.json`) | `security_file_open` | critical |
| `write-protected` | writes under `/etc`, `/usr`, `/boot`, `/bin`, `/sbin`, `/lib`, `/root`, `/run/current-system`, the secret directories | `security_file_permission`, MAY_WRITE | high |
| `write-outside-workspace` (off) | writes anywhere except `allowedPaths` (workspace root, agent home, `/tmp`, `/var/tmp`, `/dev`, `/proc`, `/sys`, ...) | same, `NotPrefix` | high |
| `raw-socket` | creates an `AF_PACKET` socket, or `SOCK_RAW` on IPv4/IPv6 (netlink is also `SOCK_RAW` and is not matched) | `security_socket_create` | high |
| `ptrace` | `ptrace` ATTACH, SEIZE, POKE*, SETREGS, SETFPREGS, or `process_vm_writev` | `sys_ptrace`, `sys_process_vm_writev` | high |
| `kernel-module` | calls `init_module`, `finit_module`, `delete_module` | those syscalls | critical |
| `egress-bypass` | opens a TCP connection to port 443 (`ports`) on an address that is not loopback or exempt | `tcp_connect` (`sock` argument: `DPort`, `NotDAddr`) | medium |

### "Write outside the workspace"

A kernel rule for "any write outside the workspace" cannot tell an agent from
journald or the audit writer, so every write of every process would reach
userspace and only be dropped there. That costs CPU and export-file space on a
busy machine, so the default rule `write-protected` lists the places that
matter instead. `write-outside-workspace` implements the literal rule; enable
it for an investigation or on a machine that runs little besides agents.

### Egress bypass, and noise

Agents reach models through the model gateway on 127.0.0.1:8080 (container
agents on the host address of their bridge, port 8080), so a TCP connect to
port 443 elsewhere is a bypass of budgets, DLP and the audit log. To keep the
rule quiet:

- loopback is always exempt; add networks to `exemptDestinations`;
- binaries are exempt by the end of their path: `git-remote-https`,
  `git-remote-http` and `ssh` by default (agents push branches over git);
- identical alerts within `dedupeSeconds` (30) are folded into one with a
  `repeats` count;
- only port 443 is watched by default (`ports`).

Expect alerts from agent tools that phone home (update checks, telemetry,
package fetches). That is the information: either exempt the destination or
block it. The rule is a policy option; `policies.egressBypass.enable = false`
turns it off.

## Alerts

An alert, as written to `alerts.jsonl` (one line), to the journal
(`journalctl -u nestlo-agent-security-forwarder`) and sent to the audit log:

```json
{"rule":"credential-access","severity":"critical","user":"nestlo-agent","uid":990,
 "pid":4242,"binary":"/run/current-system/sw/bin/cat","arguments":"/run/secrets/ANTHROPIC_API_KEY",
 "cwd":"/var/lib/nestlo/workspaces/job1","parent_binary":"/run/current-system/sw/bin/bash",
 "target":"/run/secrets/ANTHROPIC_API_KEY","function":"security_file_open",
 "policy":"nestlo-ars-credential-access","action":"alert","unit":"nestlo-agent-7f3a.service","repeats":0}
```

`action` is `alert`, or in enforce mode `killed`, `kill_failed`, `kill_skipped`
(the PID had been reused) or `gone`.

### Audit log

The forwarder sends each alert to the audit socket as an event of type
`runtime.security` (`audit.eventType`), actor = the agent user, source
`agent-runtime-security`, data = the alert above (no file contents; arguments
are cut at 512 bytes). It buffers up to 1000 events while the writer is down
and counts what it drops.

**Needed in services/nestlo_services/audit.py:** the writer accepts only the
types in `EVENT_TYPES` and silently counts others as rejected. Add

```python
"runtime.security",     # agent runtime security alert (modules/agent-runtime-security)
```

to `EVENT_TYPES` (one type; `data.rule` and `data.severity` distinguish the
alerts). Until then alerts reach the journal, the JSON log and Prometheus but
not the audit chain.

### Prometheus

`nestlo_runtime_security_events_total{rule,action}`, `..._audit_sent_total`,
`..._audit_dropped_total`, `..._parse_errors_total` on 127.0.0.1:9976, and
Tetragon's own metrics on 127.0.0.1:9977. With `nestlo.observability.enable`
the module adds both scrape targets and two rules: `NestloAgentRuntimeSecurityEvent`
(critical, any event in 10 minutes) and `NestloAgentRuntimeSecurityDown`.

## Enforcement

```nix
nestlo.agentRuntimeSecurity = {
  mode = "enforce";
  enforcement.rules = [ "credential-access" "raw-socket" "ptrace" "kernel-module" ];  # default
  enforcement.scope = "unit";   # or "process"
};
```

In enforce mode the forwarder, on an event of an agent user for one of
`enforcement.rules`, checks that the event is under a minute old and that the PID still has that uid, binary and start time
(PIDs are reused), then sends SIGKILL to the process, or with `scope = "unit"`
kills the whole systemd unit it runs in (`systemctl kill`), which ends an
agent's task. This is detection plus fast reaction, not prevention: the
`open` that raised the alert has already happened. What prevents is the file
permission model (the agent user cannot read the real secrets) and the sandbox;
the rule shows who tried.

### In-kernel Sigkill

`enforcement.sigkill.enable = true` additionally adds Tetragon's `Sigkill`
action to `raw-socket`, `ptrace` and `kernel-module`. The kernel kills the
caller synchronously, before the call completes. Tetragon has no uid selector,
so this kills **every** process that triggers the hook, root included, except
the binaries in `sigkill.exemptBinaries` (gdb, strace, perf, ping, modprobe,
systemd, ...). It needs `mode = "enforce"` and logs a build warning. Do not
enable it on a machine where operators debug with ptrace unless they use an
exempt binary.

Why not `credential-access` and `egress-bypass` in the kernel: the gateway and
the daemon legitimately open the secrets and connect out.

## Kernel requirements

Tetragon loads CO-RE BPF programs against the kernel's BTF
(`/sys/kernel/btf/vmlinux`), so the kernel needs `CONFIG_DEBUG_INFO_BTF=y`
(plus `CONFIG_BPF_SYSCALL`, `CONFIG_KPROBES`, `CONFIG_BPF_EVENTS`, which NixOS
kernels have). nixpkgs' common kernel config sets `DEBUG_INFO_BTF` (as
`option yes`, for kernels from 5.11) in every stock kernel, including the
7.2.x kernel of this tree's default. The module checks the kernel's structured
config at build time (`requireBTF`, default true; a custom
`boot.kernelPackages` without that attribute fails the check, set
`requireBTF = false` if you know the kernel has BTF) and the unit checks
`/sys/kernel/btf/vmlinux` before starting, with a message that says so.

Tetragon also resolves kprobe targets through `/proc/kallsyms`. Nestlo's
kernel hardening (`modules/security`) sets `kernel.kptr_restrict = 2`, which
hides kernel addresses even from processes with `CAP_SYSLOG`, and then no
policy loads ("no kernel symbols found"). With this module enabled the value
is `1`: kernel pointers stay hidden from every process without `CAP_SYSLOG`
(agents included) and are readable by Tetragon. Override
`boot.kernel.sysctl."kernel.kptr_restrict"` with `lib.mkForce` if you need 2
and can do without the monitor.

## Options

| Option | Default | Meaning |
|---|---|---|
| `enable` | false | |
| `package` | `pkgs.tetragon` | |
| `mode` | `observe` | `observe` or `enforce` |
| `users` | `[ "nestlo-agent" ]` (+ `openclaw` when enabled) | Agent users |
| `policies.credentialAccess.{enable,paths,providerKeyFiles,fileSuffixes}` | on | See the rules table |
| `policies.writeProtected.{enable,paths}` | on | |
| `policies.writeOutsideWorkspace.{enable,allowedPaths}` | off | |
| `policies.rawSockets.enable`, `ptrace.enable`, `kernelModules.enable` | on | |
| `policies.egressBypass.{enable,ports,exemptDestinations,exemptBinaries}` | on, `[443]`, none, git/ssh helpers | |
| `extraPolicies` | `{}` | Further TracingPolicies as attrsets; name them `nestlo-ars-<rule>` to get alerts |
| `enforcement.rules` | credential-access, raw-socket, ptrace, kernel-module | Rules that kill in enforce mode |
| `enforcement.scope` | `unit` | `process` or `unit` |
| `enforcement.sigkill.{enable,exemptBinaries}` | off | In-kernel kill, global |
| `export.file` | `/var/log/tetragon/tetragon.json` | Tetragon's JSON export; directory `root:nestlo`, 2750 |
| `export.maxSizeMB`, `rotationInterval`, `processExec` | 50, `24h`, false | Rotation (5 files kept); `processExec` also exports every exec/exit |
| `audit.enable`, `audit.eventType` | follows `nestlo.audit.enable`, `runtime.security` | |
| `metrics.port`, `metrics.tetragonPort` | 9976, 9977 | Loopback |
| `dedupeSeconds` | 30 | |
| `logLevel` | `info` | Tetragon |
| `requireBTF` | true | |

Operators in the `nestlo` group can read `/var/log/tetragon` and
`/var/log/nestlo-agent-runtime-security`. The audit log is read with
`nestlo-audit tail`.

## Security of the monitor itself

Tetragon runs as root with `CAP_SYS_ADMIN`, `CAP_BPF`, `CAP_PERFMON`,
`CAP_SYS_RESOURCE`, `CAP_NET_ADMIN`, `CAP_SYS_PTRACE`, `CAP_DAC_OVERRIDE` and
`CAP_DAC_READ_SEARCH` and nothing else (the set Tetragon's own service needs),
`ProtectSystem=strict` with only the log directory writable, no network except
loopback, no new privileges. The forwarder runs as root with an empty
capability set in observe mode (`CAP_KILL` and `CAP_SYS_PTRACE` in enforce
mode), `ProtectSystem=strict`, loopback only, and the group `nestlo-audit` for
the audit socket. Agents cannot read the exports (root:nestlo 2750) or the
alerts, and cannot signal root processes.

## Test

`tests/agent-runtime-security.nix` boots Tetragon with the policies, lets
`nestlo-agent` read a decoy file under `/run/secrets` (made readable, to
exercise the detection and not the file permissions) and an operator read the
same file, then checks that exactly one user's read became a
`credential-access` alert with the right path and binary, that nothing was
killed in observe mode, and that the Prometheus counter moved. It also checks
that the policies are loaded (`tetra tracingpolicy list`) and the units are
contained. The test needs BPF in the VM; it was not run in this tree (no KVM).
The forwarder alone was exercised against synthetic events (alert, dedupe,
other-user filtering, kill with PID check, audit socket delivery).

## Limits

- Not run against a live kernel here: the TracingPolicies follow Tetragon
  1.6.0's CRD and examples (`security_file_open`, `tcp_connect`,
  `sys_ptrace`, ...) but their loading and hook arguments were not exercised.
  A hook that cannot load makes Tetragon refuse that policy and log why
  (`journalctl -u nestlo-tetragon`); the test lists the loaded policies.
- Userspace enforcement acts after the event. Use the sandbox and file
  permissions for prevention.
- Prefix and postfix matches are textual: a path reached through a symlink or
  bind mount is seen as the kernel resolves it, and hard links defeat
  name-based rules.
- No uid selector means policies cost kernel-side work for all users (small
  for the default rules; `write-outside-workspace` is not).
- The audit event type must be added to `audit.py` (see above).
- Container-isolated agents run in a network namespace: their connects are
  seen, but exemptions by address refer to the destination, not the bridge.
