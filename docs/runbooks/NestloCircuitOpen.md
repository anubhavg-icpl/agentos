# NestloCircuitOpen

Severity: warning. Part of [operations.md](../operations.md).

## What it means

The circuit breaker for an agent (label `agent`) has been open for a minute: it saw `max_consecutive_failures` upstream failures in a row.

## Impact

The agent's requests get 503 `circuit_open` until the cooldown (`cooldown_sec`, default 300 s) ends.

## Diagnose

```sh
journalctl -u nestlo-model-gateway | grep -iE 'circuit|upstream' | tail
curl -s http://127.0.0.1:9950/metrics | grep nestlo_circuit_open
```
Usually the provider is failing (rate limit, outage, bad key). Check the key file and the provider status.

## Mitigate

- Cause fixed: close the circuit early, `curl -X DELETE --unix-socket /run/nestlo-gateway/admin.sock http://localhost/_nestlo/circuit/<agent>`.
- Provider outage: leave it, and configure `fallbacks`.
