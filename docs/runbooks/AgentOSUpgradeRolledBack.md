# AgentOSUpgradeRolledBack

Severity: critical. Part of [operations.md](../operations.md).

## What it means

`agentos-upgrade-gate` found the services not ready after an upgrade and rolled the system back with `nixos-rebuild switch --rollback`. The gate posts this alert itself.

## Impact

The system runs the previous generation, so it should be healthy, but the new generation is broken and the next scheduled upgrade will try it again.

## Diagnose

```sh
journalctl -t agentos-upgrade -b --no-pager | tail -50
journalctl -u agentos-upgrade-gate -u nixos-upgrade --since -3h --no-pager
nixos-rebuild list-generations | head -5
for u in agentos-model-gateway agentos-daemon agentos-orchestrator; do systemctl is-active $u; done
```
The gate's log says which check failed (gateway, daemon, orchestrator, dashboard, failed units). Look at what changed: `nix flake metadata` and `nix store diff-closures` between the two generations.

## Mitigate

- Confirm the old generation is healthy (`/readyz` on each service).
- Stop the next attempt until fixed: `systemctl stop nixos-upgrade.timer`, or pin the flake input.
- Reproduce in a VM (`nix build .#vm-image`) or with the e2e test, fix, and re-enable the timer.
