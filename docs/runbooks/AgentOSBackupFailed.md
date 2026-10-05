# AgentOSBackupFailed

Severity: warning. Part of [operations.md](../operations.md).

## What it means

A `restic-backups-*` unit is in the failed state: the last backup run did not complete.

## Impact

State is unprotected since the last good snapshot; if the machine is lost now, work since then is gone.

## Diagnose

```sh
systemctl status restic-backups-agentos
journalctl -u restic-backups-agentos -n 100 --no-pager
sudo restic-agentos snapshots --compact | tail
sudo restic-agentos check
```
Common causes: Redis `BGSAVE` failed or timed out ("BGSAVE failed", "timed out waiting"), the repository is unreachable or full, a wrong password file, a lock left by a killed run.

## Mitigate

- Fix the cause, run `systemctl start restic-backups-agentos`, and confirm a new snapshot.
- Locked repository: `sudo restic-agentos unlock`.
- Redis save failing: see [AgentOSRedisDown](AgentOSRedisDown.md) and check disk space.
