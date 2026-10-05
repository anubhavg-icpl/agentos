# NestloServiceDown

Severity: critical. Part of [operations.md](../operations.md).

## What it means

A Nestlo systemd unit (`nestlo-model-gateway`, `nestlo-daemon`, `nestlo-orchestrator`, `nestlo-dashboard`, `nestlo-scheduler`) is not active for 2 minutes, or Prometheus cannot scrape the gateway or daemon. The alert labels say which.

## Impact

Gateway down: agents cannot reach providers and nothing is metered. Daemon down: no auto-shutdown on budget, no notifications, no agent metrics. Orchestrator down: queued tasks wait.

## Diagnose

```sh
systemctl status nestlo-model-gateway nestlo-daemon nestlo-orchestrator nestlo-dashboard
journalctl -u <unit> -n 100 --no-pager
curl -s http://127.0.0.1:9950/readyz        # daemon
curl -s --unix-socket /run/nestlo-gateway/admin.sock http://localhost/readyz   # gateway
```
A unit that restarts with `watchdog` in its log hung and was killed by systemd. One that fails at start usually has a config or Redis problem: read the `/readyz` output and see [NestloRedisDown](NestloRedisDown.md).

## Mitigate

- `systemctl restart <unit>` once the cause is clear (Redis up, config valid).
- After a bad config or upgrade, `nixos-rebuild switch --rollback`.
- Confirm `/readyz` returns 200 and the alert clears.
