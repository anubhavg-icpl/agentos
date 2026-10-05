# NestloBudgetNearExhaustion

Severity: warning. Part of [operations.md](../operations.md).

## What it means

An agent (label `agent`) or the global total (no label) has spent more than 90% of its daily USD cap.

## Impact

At 100% the gateway answers 402 and the daemon stops the agent. Work in flight stops.

## Diagnose

```sh
nestlo budget
curl -s --unix-socket /run/nestlo-gateway/admin.sock http://localhost/_nestlo/spend | jq
nestlo logs <agent>
```
Is the spend expected (a long task) or runaway (a loop, an expensive model)? Check [NestloLoopDetected](NestloLoopDetected.md) and the per-model spend in the output.

## Mitigate

- Expected: raise today's cap, `nestlo budget set <agent> <usd>`.
- Runaway: `nestlo kill <agent>`, then fix the prompt or enable cost routing (docs/gateway-features.md).
- Global cap: set `nestlo.budget-controller` options. Budgets reset at 00:00 UTC.
