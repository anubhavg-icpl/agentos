# AgentOSFactoryBudgetBurn

Severity: warning. Part of [operations.md](../operations.md) and [factory.md](../factory.md).

## What it means

A factory line spent more than `agentos.observability.alerts.factoryBudgetBurnUSDPerHour` (default 50 USD) in the last hour (`agentos_factory_cost_usd_total{line}`).

## Impact

Money is going out faster than planned, typically through a fix loop that does not converge or many large items started at once. The per-item cap (`budgetUSDPerItem`) and the gateway's daily budgets still apply.

## Diagnose

```sh
agentos-factory list
agentos-factory show <item-id>      # fix rounds and cost of the item
agentos status                      # gateway spend per agent
```

## Mitigate

- Pause the line: set `agentos.factory.lines.<name>.paused = true` and switch; running items finish.
- Lower `maxInFlight`, `maxFixRounds` or `budgetUSDPerItem`.
- Read the review findings of an item that loops: usually the acceptance criteria are unclear.
