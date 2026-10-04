# Web dashboard

A read-only status page for operators: agents (running and recent), spend against budgets, spend by agent and model, the last seven days, recent gateway requests per agent, and service health. It refreshes every 5 seconds.

```nix
agentos.dashboard = {
  enable = true;
  tokenFile = "/run/secrets/agentos-dashboard-token";   # required
  # port = 8090;
};
```

Create the token with `openssl rand -hex 24 > /run/secrets/agentos-dashboard-token` (or a sops secret). The file can be root-only (mode 0400): systemd hands it to the service as a credential.

## Reaching it

The dashboard listens on `127.0.0.1:8090`. Use an SSH tunnel, as for Grafana:

```
ssh -L 8090:127.0.0.1:8090 admin@host
```

Then open <http://127.0.0.1:8090>. The browser asks for a user name and password: use any user name and the token as the password. Scripts can send `Authorization: Bearer <token>`.

## Access control

There is no unauthenticated mode. Every request, including the page itself, needs the token, and the service refuses to start without a token of at least 8 characters. The module asserts that `tokenFile` is set. The token is compared in constant time and re-read from the file on each request, so rotating it needs no restart. Because the transport is plain HTTP, keep the default loopback address and tunnel; only bind elsewhere behind a TLS proxy.

We chose a token over a unix socket because a browser cannot open a socket directly, and the tunnel already gives host-level authentication.

## Read-only by design

The service runs as the `agentos` user with `ProtectSystem=strict` and no writable paths. It only reads Redis, the state directory and the request logs. It has no endpoints that change anything (`POST`, `PUT` and `DELETE` return 405). Killing an agent and changing a budget stay with `agentos kill` and `agentos-budget`, which use the gateway admin socket.

## API

All `GET`, JSON:

| Path | Returns |
|:---|:---|
| `/api/health` | Redis, gateway and daemon reachability |
| `/api/agents` | `running` and `history` (last 25), each with `usd_today`, `limit_usd`, `budget_pct` |
| `/api/spend` | Today's spend per agent (with tokens and request counts) and per model, plus the global limit |
| `/api/history?days=7` | Spend per day (1 to 35), with per-agent and per-model split |
| `/api/requests?agent=ID&limit=50` | Newest first, from `/var/lib/agentos/logs/<id>.log` |

The command is `agentos-dashboard --token-file FILE [--listen ADDR] [--port N] [--config PATH]`.

## Links to other web UIs

`/api/links` returns the links configured in `[dashboard] links` of `services.toml` (only `http(s)` URLs) and the page shows them in the header. Enabling `agentos.dashboard.agentFleetWeb` adds its chat and hub ([docs/agent-fleet-web.md](agent-fleet-web.md)).
