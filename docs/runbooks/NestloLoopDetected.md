# NestloLoopDetected

Severity: warning. Part of [operations.md](../operations.md).

## What it means

Loop detection refused requests: an agent sent the same request `loop_repeat_threshold` times in a row, or alternated between two requests.

## Impact

The agent gets 429 `loop_detected`; it is probably stuck and burning budget.

## Diagnose

```sh
journalctl -u nestlo-model-gateway | grep loop_detected | tail
nestlo logs <agent>
```
Read what the agent keeps repeating (a tool error it cannot fix, an impossible prompt).

## Mitigate

- `nestlo kill <agent>` and restart it with a better prompt.
- If the repetition is legitimate, reset it with `curl -X DELETE --unix-socket /run/nestlo-gateway/admin.sock http://localhost/_nestlo/loop/<agent>`, or tune `limits.loop_repeat_threshold`.
