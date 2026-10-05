# AgentOSGatewayHighErrorRatio

Severity: warning. Part of [operations.md](../operations.md).

## What it means

More than 5% of gateway responses were 5xx over 5 minutes, held for 10 minutes. 4xx answers do not count.

## Impact

Agents see failures: 502/504 from providers, 503 when Redis is unavailable or a circuit is open. If it continues it trips the SLO burn-rate alerts.

## Diagnose

```sh
journalctl -u agentos-model-gateway --since -30min | grep -iE 'error|unavailable|upstream'
curl -s http://127.0.0.1:8080/metrics | grep agentos_gateway_responses_total
```
Which code dominates? 502/504: provider outage, egress or DNS. 503 `store_unavailable`: Redis ([AgentOSRedisDown](AgentOSRedisDown.md)). 503 `circuit_open`: [AgentOSCircuitOpen](AgentOSCircuitOpen.md). Check the provider's status page.

## Mitigate

- Provider outage: configure a `fallbacks` provider (docs/gateway-features.md) or wait; nothing to fix locally.
- Redis: restore it first.
- One misbehaving agent: `agentos kill <id>`.
