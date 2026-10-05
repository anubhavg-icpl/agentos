# AgentOSStateDiskUsage

Severity: warning. Part of [operations.md](../operations.md).

## What it means

The filesystem holding `/var/lib/agentos` is more than 85% full for 10 minutes.

## Impact

When it fills, the gateway cannot write request logs, workspaces fail, Redis cannot persist, and backups fail.

## Diagnose

```sh
df -h /var/lib/agentos
sudo du -xh --max-depth=2 /var/lib/agentos | sort -h | tail -20
sudo du -xsh /var/lib/redis-agentos /var/lib/agentos-audit
```
Usual causes: gateway `logs/`, `recordings/`, workspaces and swarm worktrees, task logs, old system generations, btrbk snapshots.

## Mitigate

- Remove finished workspaces and old task logs; turn off `recording` or lower `recording.max_body_bytes`.
- `sudo nix-collect-garbage --delete-older-than 14d`.
- Grow the volume if the usage is legitimate.
