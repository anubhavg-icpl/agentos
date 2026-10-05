# NestloRedisDown

Severity: critical. Part of [operations.md](../operations.md).

## What it means

The control-plane Redis (`redis-nestlo`) does not answer PING (`nestlo_redis_up == 0`), or its systemd unit is not active.

## Impact

The gateway fails closed: every request gets 503 `store_unavailable` and nothing is proxied unmetered. The orchestrator cannot schedule, the dashboard shows errors, budgets cannot be read.

## Diagnose

```sh
systemctl status redis-nestlo
journalctl -u redis-nestlo -n 100 --no-pager
redis-cli -s /run/redis-nestlo/redis.sock ping
df -h /var/lib/redis-nestlo; free -m
```
Typical causes: disk full, a corrupt AOF after a crash. (`maxmemory 256mb` with `noeviction` makes writes fail, not the server.)

## Mitigate

- `systemctl restart redis-nestlo`. The services reconnect by themselves.
- Corrupt AOF: first copy it aside (`cp -a /var/lib/redis-nestlo/appendonlydir /root/aof-$(date +%s)`), then run `redis-check-aof /var/lib/redis-nestlo/appendonlydir/*.manifest` without `--fix` to see what is damaged. Only if losing the tail it reports is acceptable, run it again with `--fix`, then start. Otherwise restore (below).
- Data lost: `nestlo-restore --include /var/lib/redis-nestlo` (see [operations.md](../operations.md#disaster-recovery-in-place)). Spend counters since the last backup are lost.
