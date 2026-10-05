# AgentOSRedisDown

Severity: critical. Part of [operations.md](../operations.md).

## What it means

The control-plane Redis (`redis-agentos`) does not answer PING (`agentos_redis_up == 0`), or its systemd unit is not active.

## Impact

The gateway fails closed: every request gets 503 `store_unavailable` and nothing is proxied unmetered. The orchestrator cannot schedule, the dashboard shows errors, budgets cannot be read.

## Diagnose

```sh
systemctl status redis-agentos
journalctl -u redis-agentos -n 100 --no-pager
redis-cli -s /run/redis-agentos/redis.sock ping
df -h /var/lib/redis-agentos; free -m
```
Typical causes: disk full, a corrupt AOF after a crash. (`maxmemory 256mb` with `noeviction` makes writes fail, not the server.)

## Mitigate

- `systemctl restart redis-agentos`. The services reconnect by themselves.
- Corrupt AOF: `redis-check-aof --fix /var/lib/redis-agentos/appendonlydir/*.manifest`, then start.
- Data lost: `agentos-restore --include /var/lib/redis-agentos` (see [operations.md](../operations.md#disaster-recovery-in-place)). Spend counters since the last backup are lost.
