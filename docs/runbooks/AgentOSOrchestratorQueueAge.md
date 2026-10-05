# AgentOSOrchestratorQueueAge

Severity: warning. Part of [operations.md](../operations.md).

## What it means

The oldest queued task has waited longer than 600 s for 5 minutes (`agentos_orchestrator_queue_oldest_age_seconds`).

## Impact

Submitted work is not starting: workers are saturated, the orchestrator is stuck, or the budget blocks new agents.

## Diagnose

```sh
agentos-task list --status queued
agentos-task list --status running
curl -s --unix-socket /run/agentos-orchestrator/orchestrator.sock http://localhost/readyz
journalctl -u agentos-orchestrator -n 100 --no-pager
```
`running` equal to `max_workers` means saturation. Tasks in `awaiting_approval` do not count as queued. A failing `loop` check in `/readyz` means the scheduling loop is stuck.

## Mitigate

- Saturation: wait, cancel stale tasks (`agentos-task cancel <id>`), or raise `agentos.orchestration.maxWorkers`.
- Stuck loop: `systemctl restart agentos-orchestrator` (the watchdog does this by itself within 60 s).
- Budget exhausted: see [AgentOSBudgetNearExhaustion](AgentOSBudgetNearExhaustion.md).
