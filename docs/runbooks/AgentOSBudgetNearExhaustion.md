# AgentOSBudgetNearExhaustion

Severity: warning. Part of [operations.md](../operations.md).

## What it means

An agent (label `agent`) or the global total (no label) has spent more than 90% of its daily USD cap.

## Impact

At 100% the gateway answers 402 and the daemon stops the agent. Work in flight stops.

## Diagnose

```sh
agentos budget
curl -s --unix-socket /run/agentos-gateway/admin.sock http://localhost/_agentos/spend | jq
agentos logs <agent>
```
Is the spend expected (a long task) or runaway (a loop, an expensive model)? Check [AgentOSLoopDetected](AgentOSLoopDetected.md) and the per-model spend in the output.

## Mitigate

- Expected: raise today's cap, `agentos budget set <agent> <usd>`.
- Runaway: `agentos kill <agent>`, then fix the prompt or enable cost routing (docs/gateway-features.md).
- Global cap: set `agentos.budget-controller` options. Budgets reset at 00:00 UTC.
