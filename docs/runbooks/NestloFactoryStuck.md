# NestloFactoryStuck

Severity: warning. Part of [operations.md](../operations.md) and [factory.md](../factory.md).

## What it means

A factory item sits in an active state (planning, building, reviewing, fixing, qa, publishing) and was not updated for more than 2 hours (`nestlo_factory_item_age_seconds{line,state}`). The states and the limit are `nestlo.observability.alerts.factoryActiveStates` and `factoryStuckSeconds`.

## Impact

The item makes no progress: the task behind it is stuck, lost or waiting in the orchestrator queue, or the factory loop is not running.

## Diagnose

```sh
nestlo-factory show <item-id>
nestlo-task list --status queued
nestlo-task list --status running
curl -s http://127.0.0.1:9960/metrics | grep nestlo_factory
systemctl status nestlo-factory nestlo-orchestrator
journalctl -u nestlo-factory -n 100 --no-pager
```
A task that stays `queued` points at saturated workers: see [NestloOrchestratorQueueAge](NestloOrchestratorQueueAge.md).

## Mitigate

- Orchestrator saturated or stuck: follow the runbook above.
- Factory loop stuck: `systemctl restart nestlo-factory`. Items live in Redis and are picked up again when their lease (`nestlo.factory.leaseSec`) expires.
- Item still stuck: cancel its task with `nestlo-task cancel <task-id>`; the factory treats that as a failed step and retries or blocks the item.
