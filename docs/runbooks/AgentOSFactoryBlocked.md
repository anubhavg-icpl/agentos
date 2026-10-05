# AgentOSFactoryBlocked

Severity: warning. Part of [operations.md](../operations.md) and [factory.md](../factory.md).

## What it means

A factory line has had at least one item in the `blocked` state for 30 minutes (`agentos_factory_items{line,state="blocked"}`).

## Impact

The item is waiting for a human: it hit a limit (`budgetUSDPerItem`, `maxFixRounds`), a plan needs approval, or a step failed in a way the factory does not retry. Nothing else on the line is affected, but the item will not move on its own.

## Diagnose

```sh
agentos-factory list --state blocked
agentos-factory show <item-id>      # the reason and the last task of the item
agentos-task show <task-id>         # output of the step that blocked it
journalctl -u agentos-factory -n 100 --no-pager
```

## Mitigate

- Plan waiting for approval: approve or reject it with `agentos-factory`.
- Budget or fix rounds exhausted: read the review findings, then raise `agentos.factory.lines.<name>.budgetUSDPerItem` / `maxFixRounds`, or finish the item by hand on its `agent/<task-id>` branch and cancel it.
- Unclear issue: cancel the item and relabel the issue once it says what is wanted.
