# AgentOSGatewaySLOBurnMedium

Severity: critical. Part of [operations.md](../operations.md).

## What it means

The gateway is spending its 99.5% availability error budget at 6x the sustainable rate (the 6h and 30m windows are both above the threshold). Left alone, the 30-day budget is gone in about 5 days.

## Impact

Agents are getting 5xx responses at a rate that, sustained, breaks the SLO. The alert fires before the SLO is missed.

## Diagnose

```sh
# Prometheus listens on localhost:9001
# the windows this alert compares
curl -s localhost:9001/api/v1/query --data-urlencode 'query=agentos:gateway_error_ratio:rate6h'
curl -s localhost:9001/api/v1/query --data-urlencode 'query=agentos:gateway_error_ratio:rate30m'
curl -s localhost:9001/api/v1/query --data-urlencode 'query=sum by (code) (rate(agentos_gateway_responses_total{code=~"5.."}[30m]))'
journalctl -u agentos-model-gateway --since -1h | tail -100
```
Then follow [AgentOSGatewayHighErrorRatio](AgentOSGatewayHighErrorRatio.md) to find the failing status code and its cause.

## Mitigate

Fix or work around the cause (provider fallback, Redis, a bad upgrade: `nixos-rebuild switch --rollback`). The alert clears when the short window recovers; the budget already burned stays burned. For the slow-burn warning, open a ticket and fix within days, and hold risky changes.
