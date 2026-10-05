# Operations

Running AgentOS in production: health checks, SLOs and alerts, backup and restore, upgrades with rollback, and verifying a release. Each alert has a runbook in [runbooks/](runbooks/).

## Health

Every Python service answers two paths on its existing API.

| Service | Where | `/healthz` (liveness) | `/readyz` (readiness) |
|:---|:---|:---|:---|
| Model gateway | `127.0.0.1:8080` and the admin socket `/run/agentos-gateway/admin.sock` | process serves requests | Redis answers PING, listeners open, admin socket exists |
| Agent daemon | `127.0.0.1:9950` (the metrics port) | process serves requests | Redis, listener, reaper loop ran in the last 30 s (5 intervals), threads alive |
| Orchestrator | unix socket `/run/agentos-orchestrator/orchestrator.sock` | process serves requests | Redis, socket exists, scheduling loop ticked recently |
| Dashboard | `127.0.0.1:8090` | process serves requests (no token needed) | Redis, listener |

`/healthz` returns 200 as long as the process answers. `/readyz` returns 200 or 503 with one entry per check:

```sh
curl -s --unix-socket /run/agentos-gateway/admin.sock http://localhost/readyz
# {"status": "ready", "service": "gateway", "checks": {"redis": "ok", "listening": "ok", "admin_socket": "ok"}}
curl -s http://127.0.0.1:9950/readyz
curl -s --unix-socket /run/agentos-orchestrator/orchestrator.sock http://localhost/readyz
```

The probes carry no data beyond `ok` or the failure reason, so the dashboard serves them without its token. The gateway's `/metrics` is only served to loopback clients.

### systemd readiness and watchdog

The gateway, daemon, orchestrator and dashboard units are `Type=notify`. The service sends `READY=1` once it listens (the orchestrator after crash recovery), so `systemctl start` and units ordered after them wait for a working service. `WatchdogSec` is 30 s for the gateway and dashboard and 60 s for the daemon and orchestrator. The service pings `WATCHDOG=1` every half interval from its main loop, and only while healthy:

- gateway and dashboard probe their own `/healthz` through the real serving path;
- the daemon requires its reaper loop to have run in the last minute;
- the orchestrator pings after every scheduling pass, so a hung tick stops the pings. A failing tick (for example Redis down) shows in `/readyz` and the alerts instead of restart-looping the service.

When pings stop, systemd restarts the service. The protocol is implemented with the standard library in `services/agentos_services/health.py` (a datagram to `$NOTIFY_SOCKET`).

## SLOs and alerts

The rules ship with the observability module (`agentos.observability.alerts.enable`, default on). Prometheus loads them from `services.prometheus.rules`; the series come from the gateway's `/metrics`, the daemon's `:9950/metrics` and the systemd exporter.

### Gateway availability SLO

**99.5% of gateway responses are not 5xx, over 30 days** (`agentos.observability.alerts.sloTarget`). The error budget is 0.5%, about 3 h 36 min of total failure per 30 days. 4xx answers (402 budget, 429 rate limit and loop detection, 401/403) are the client's doing and do not count.

`agentos:gateway_error_ratio:rate<window>` is recorded for 5m, 30m, 1h, 2h, 6h, 1d and 3d. Burn-rate alerts require both a long and a short window above the threshold, so they fire quickly and clear quickly:

| Alert | Burn rate | Windows | Severity | Budget gone in |
|:---|:---|:---|:---|:---|
| `AgentOSGatewaySLOBurnFast` | 14.4x | 1h and 5m | critical | about 2 days |
| `AgentOSGatewaySLOBurnMedium` | 6x | 6h and 30m | critical | about 5 days |
| `AgentOSGatewaySLOBurnSlow` | 3x, or 1x | 1d and 2h, or 3d and 6h | warning | within the month |

### Alert catalogue

| Alert | Severity | Fires when |
|:---|:---|:---|
| `AgentOSServiceDown` | critical | an AgentOS systemd unit is not active, or a scrape target is down, for 2 min |
| `AgentOSGatewayHighErrorRatio` | warning | 5xx ratio over 5 min is above 5% for 10 min |
| `AgentOSGatewaySLOBurnFast` / `Medium` / `Slow` | critical / critical / warning | see above |
| `AgentOSBudgetNearExhaustion` | warning | an agent's or the global daily spend passes 90% of its cap |
| `AgentOSCircuitOpen` | warning | an agent's circuit breaker is open for 1 min |
| `AgentOSLoopDetected` | warning | loop detection refused requests in the last 10 min |
| `AgentOSOrchestratorQueueAge` | warning | the oldest queued task is older than 600 s for 5 min |
| `AgentOSStateDiskUsage` | warning | the filesystem holding `/var/lib/agentos` is above 85% |
| `AgentOSRedisDown` | critical | Redis does not answer PING, or its unit is not active |
| `AgentOSBackupFailed` | warning | a `restic-backups-*` unit is in the failed state |
| `AgentOSUpgradeRolledBack` | critical | the upgrade health gate rolled back (posted to Alertmanager by the gate) |

Thresholds are options under `agentos.observability.alerts` (`gatewayErrorRatio`, `budgetRatio`, `queueAgeSeconds`, `diskUsedRatio`). The `runbook_url` annotation points to `<runbookBaseUrl>/<alert>.md`; set `runbookBaseUrl` if you host the runbooks elsewhere.

### Alertmanager

Off by default. Enable it with a receiver:

```nix
agentos.observability.alertmanager = {
  enable = true;
  webhook.urlFile = "/run/secrets/alert-webhook-url";   # POSTs alerts as JSON
  # and/or
  email = { to = "ops@example.com"; from = "agentos@example.com"; smarthost = "smtp.example.com:587";
            authUsername = "agentos"; authPasswordFile = "/run/secrets/smtp-password"; };
};
```

It listens on `127.0.0.1:9093` and Prometheus is pointed at it. Enabling it without a receiver fails the build.

## Backup and restore

`agentos.backup` wraps `services.restic.backups.agentos`:

```nix
agentos.backup = {
  enable = true;
  repository = "sftp:backup@nas:/srv/agentos-restic";   # or a local path, s3:..., etc.
  passwordFile = "/run/secrets/restic-password";
  # environmentFile = "/run/secrets/restic-env";          # backend credentials
  schedule = "03:00";
  retention = { daily = 7; weekly = 4; monthly = 6; yearly = 1; };
};
```

What is saved (paths that do not exist are skipped):

- `/var/lib/agentos` (registry, logs, workspaces, tasks), minus `cache/` and btrbk `snapshots/`
- the control-plane Redis data directory `/var/lib/redis-agentos`. Before each backup the unit runs `redis-cli BGSAVE` and waits until the RDB is on disk (fails after `redisSaveTimeoutSec`, default 300). The AOF is not backed up, since restic could catch it mid-write; an in-place `agentos-restore` loads the restored `dump.rdb` into a temporary Redis, writes a fresh AOF from it and keeps the old AOF as `appendonlydir.pre-restore-<time>`
- `/var/lib/agentos-stack` and `/var/lib/agentos-audit`
- the sops secrets file (`agentos.secrets-manager.secretsFile`) and, with `includeDecryptionKeys` (default on), the keys that decrypt it (`/var/lib/sops-nix`, the SSH host key, `sops.age.keyFile`). Turn that off if you hold those keys elsewhere.
- anything in `extraPaths`

The timer is persistent and randomised by `randomizedDelaySec`; `retention` becomes `restic forget --prune` after each run. The unit is `restic-backups-agentos.service`; `restic-agentos` is a wrapper with the repository and password already set (`restic-agentos snapshots`).

**Keep the repository password somewhere else too.** Without it every backup is unreadable.

### Restore drill

Do this quarterly, and after changing the backup setup. It does not touch the live system.

```sh
# 1. Is there a recent backup?
sudo restic-agentos snapshots --compact
systemctl status restic-backups-agentos.timer

# 2. Restore the state into a scratch directory
sudo agentos-restore --target /tmp/drill
ls /tmp/drill/var/lib/agentos /tmp/drill/var/lib/redis-agentos

# 3. Check the data, e.g. open the restored Redis dump read-only on another socket
sudo redis-server --port 0 --unixsocket /tmp/drill/r.sock \
  --dir /tmp/drill/var/lib/redis-agentos --appendonly no --daemonize yes
redis-cli -s /tmp/drill/r.sock DBSIZE
redis-cli -s /tmp/drill/r.sock shutdown nosave

# 4. Clean up
sudo rm -rf /tmp/drill
```

### Disaster recovery (in place)

On a rebuilt or damaged host, with the same NixOS configuration (and `agentos.backup` pointing at the repository):

```sh
sudo agentos-restore --dry-run            # what would come back
sudo agentos-restore                      # latest snapshot into /
sudo agentos-restore --snapshot 1a2b3c4d  # a specific snapshot
sudo agentos-restore --include /var/lib/agentos/state   # only part of it
```

An in-place restore stops the AgentOS services and `redis-agentos`, restores, then starts them (`--no-restart` leaves them stopped). On a new machine restore, then `nixos-rebuild switch` so ownership and units match, and check `/readyz` on each service.

The VM test `checks.x86_64-linux.backup` runs this end to end: back up to a local repository, delete the state and stop Redis, restore, compare. It needs KVM, so CI only builds its driver (`.#checks.x86_64-linux.backup.driver`).

## Upgrades and rollback

```nix
agentos.upgrade = {
  enable = true;
  flake = "github:anubhavg-icpl/agentos#agentos";
  dates = "04:40";
  allowReboot = true;
  rebootWindow = { lower = "01:00"; upper = "05:00"; };
  healthGate.alertmanagerUrl = "http://127.0.0.1:9093";   # optional
};
```

This sets `system.autoUpgrade` (flake, dates, `allowReboot`, `rebootWindow`) and adds the health gate. The host's own `system.autoUpgrade` values are defaults, so these options win.

1. `nixos-upgrade.service` runs. When the system profile changed, it records the new generation in `/var/lib/agentos-upgrade/pending`.
2. `agentos-upgrade-gate` runs right after a live `switch`, or at boot after an upgrade that rebooted into the new generation. If the pending generation is not the running one yet (reboot still outside the window), it waits.
3. The gate polls `/readyz` of every enabled service, and checks that no `agentos-*` or `redis-agentos` unit is failed (task runner and agent units are ignored). It retries every `intervalSec` for up to `timeoutSec` (180 s).
4. On success the marker is removed. On failure the gate logs at `crit` level to the journal (`journalctl -t agentos-upgrade`), posts `AgentOSUpgradeRolledBack` to Alertmanager when `alertmanagerUrl` is set, and runs `nixos-rebuild switch --rollback`.

A night without changes writes no marker and is never judged. After a rollback the next scheduled upgrade will try the same new generation again; fix the flake input or pin it (`extraFlags`) before the next run, or disable the timer meanwhile (`systemctl stop nixos-upgrade.timer`). Add your own checks with `healthGate.extraChecks` (`check <name> <command...>`).

Manual rollback at any time: `sudo nixos-rebuild switch --rollback`, or pick an older generation in the boot menu.

## Release verification

Each release attaches the ISO, `SHA256SUMS`, a CycloneDX SBOM, and cosign bundles (`*.sigstore.json`); GitHub also stores build-provenance and SBOM attestations. (This needs the workflows in [ci/proposed-workflows](../ci/proposed-workflows/README.md) to be installed in `.github/workflows/`.) Check them before you write the ISO to disk:

```sh
tag=v0.4.0
# 1. Checksums
sha256sum -c SHA256SUMS --ignore-missing

# 2. Keyless signature: made by this repository's release workflow on a tag
cosign verify-blob "agentos-$tag.iso" \
  --bundle "agentos-$tag.iso.sigstore.json" \
  --certificate-identity-regexp '^https://github.com/anubhavg-icpl/agentos/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
cosign verify-blob SHA256SUMS --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp '^https://github.com/anubhavg-icpl/agentos/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# 3. Build provenance and the attested SBOM
gh attestation verify "agentos-$tag.iso" --repo anubhavg-icpl/agentos
gh attestation verify "agentos-$tag.iso" --repo anubhavg-icpl/agentos --predicate-type https://cyclonedx.org/bom
```

Local SBOM of the system closure (CycloneDX): `nix run .#sbom` writes `sbom.cdx.json`; pass another installable after `--`. Vulnerability disclosure: [SECURITY.md](../SECURITY.md).
