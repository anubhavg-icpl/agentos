# AgentOSFactoryStuck

Severity: warning. Part of [operations.md](../operations.md) and [factory.md](../factory.md).

## What it means

A factory item sits in an active state (planning, building, verifying, reviewing, fixing, qa, publishing) and was not updated for more than 2 hours (`agentos_factory_item_age_seconds{line,state}`). The states and the limit are `agentos.observability.alerts.factoryActiveStates` and `factoryStuckSeconds`.

## Impact

The item makes no progress: the task behind it is stuck, lost or waiting in the orchestrator queue, or the factory loop is not running.

## Diagnose

```sh
agentos-factory show <item-id>
agentos-task list --status queued
agentos-task list --status running
curl -s http://127.0.0.1:9960/metrics | grep agentos_factory
systemctl status agentos-factory agentos-orchestrator
journalctl -u agentos-factory -n 100 --no-pager
```
A task that stays `queued` points at saturated workers: see [AgentOSOrchestratorQueueAge](AgentOSOrchestratorQueueAge.md).

## Mitigate

- Orchestrator saturated or stuck: follow the runbook above.
- Factory loop stuck: `systemctl restart agentos-factory`. Items live in Redis and are picked up again when their lease (`agentos.factory.leaseSec`) expires.
- Item still stuck: cancel its task with `agentos-task cancel <task-id>`; the factory treats that as a failed step and retries or blocks the item.
