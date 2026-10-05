# NestloFactoryBudgetBurn

Severity: warning. Part of [operations.md](../operations.md) and [factory.md](../factory.md).

## What it means

A factory line spent more than `nestlo.observability.alerts.factoryBudgetBurnUSDPerHour` (default 50 USD) in the last hour (`nestlo_factory_cost_usd_total{line}`).

## Impact

Money is going out faster than planned, typically through a fix loop that does not converge or many large items started at once. The per-item cap (`budgetUSDPerItem`) and the gateway's daily budgets still apply.

## Diagnose

```sh
nestlo-factory list
nestlo-factory show <item-id>      # fix rounds and cost of the item
nestlo status                      # gateway spend per agent
```

## Mitigate

- Pause the line: set `nestlo.factory.lines.<name>.paused = true` and switch; running items finish.
- Lower `maxInFlight`, `maxFixRounds` or `budgetUSDPerItem`.
- Read the review findings of an item that loops: usually the acceptance criteria are unclear.
