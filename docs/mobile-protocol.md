# Nestlo mobile protocol (v1)

The contract between the Nestlo machine (`nestlo.mobile`, server in
`services/nestlo_services/mobile.py`) and the Android app (`apps/android`).
Both sides implement exactly this; change it here first.

## Transport and trust

- HTTPS and WebSocket (`wss://`) on one port, default **7443**.
- The server generates a self-signed ECDSA P-256 certificate on first start
  (`/var/lib/nestlo-mobile/tls/{cert.pem,key.pem}`), valid 10 years, CN = host name.
- **Pinning:** the app trusts exactly the certificate whose SHA-256 over the
  DER encoding matches the `fp` it got from the pairing QR code. No CA, no
  hostname check. A changed certificate means re-pairing.
- Every request except `POST /v1/pair` needs `Authorization: Bearer <device token>`.
  WebSockets send the same header (OkHttp can). The desktop WebView uses the
  cookie set by `GET /desktop/?t=<token>` (HttpOnly, Secure, SameSite=Strict, path `/`).
- Errors: JSON `{"error": "<message>"}` with 400/401/403/404/409/429/500.
  `401` means the token is unknown or revoked: the app returns to pairing.

## Pairing

On the machine, an operator runs `nestlo-mobile pair` (optionally `--ttl SECONDS`,
default 300). It prints a QR code in the terminal (ANSI, from `qrencode -t ANSIUTF8`)
and the URI as text. The URI:

```
nestlo://pair?v=1&name=<server name>&port=7443&fp=<base64url sha256 of cert DER, no padding>&code=<base64url 16 random bytes, no padding>&host=<addr1>&host=<addr2>...
```

`host` repeats: every non-loopback address of the machine, then its host name.
The app tries them in order (2 s connect timeout each) and remembers the first
that answers.

The pairing code is single-use and expires after the TTL. The server keeps only
its SHA-256.

`POST /v1/pair`
```json
{"code": "<code>", "device_name": "Pixel 9", "device_model": "google/tokay"}
```
→ `200`
```json
{"device_id": "d_<12 hex>", "token": "<base64url 32 random bytes>", "server_name": "nestlo", "server_version": "0.5.0"}
```
`403` for a wrong, used or expired code; `429` after 10 failed attempts per
source address in 10 minutes. The server stores `sha256(token)` per device,
with name, model, paired_at, last_seen.

`GET /v1/devices` → `[{"device_id","device_name","device_model","paired_at","last_seen","current": bool}]`
`DELETE /v1/devices/{device_id}` → `{"ok": true}` (a device may revoke itself or others).
On the machine: `nestlo-mobile devices` and `nestlo-mobile revoke <device_id>`.

## REST (JSON, GET unless noted)

| Path | Body |
|---|---|
| `/v1/info` | `{"name","version","nixos","uptime_s","features":["agents","terminal","desktop","approvals"]}`: features lists what this machine has enabled |
| `/v1/overview` | `{"agents":{"total","working","blocked","idle","done"},"spend":{"today_usd","budget_usd"},"health":{"redis":bool,"gateway":bool,"daemon":bool}}` |
| `/v1/agents` | `[{"id","agent","workspace","status","spend_usd","budget_usd","started_at"}]`. `status` is one of `working`, `blocked`, `idle`, `done`, `failed`, `killed` |
| `/v1/agents/{id}/requests?limit=50` | `[{"ts","provider","model","input_tokens","output_tokens","cost_usd","status"}]` |
| `POST /v1/agents/{id}/kill` | `{"ok": true}` |
| `/v1/approvals` | `[{"id","kind","summary","requested_by","created_at"}]` (empty when the machine has no approval queue) |
| `POST /v1/approvals/{id}` | body `{"decision":"approve"\|"deny"}` → `{"ok": true}` |
| `/v1/sessions` | `[{"id","title","kind":"tuios"\|"shell","user"}]`, the terminals the phone may open |

Times are ISO 8601 UTC strings, money is a float in USD.

## Live events: `WS /v1/events`

Text frames, one JSON object each:

- `{"type":"hello","server_name","version"}`, sent first
- `{"type":"agent","agent":{...same shape as /v1/agents...}}`, on any change
- `{"type":"agent_gone","id"}`
- `{"type":"needs_input","id","agent","workspace","since"}`, when an agent turns `blocked`
- `{"type":"approval","approval":{...}}` and `{"type":"approval_done","id"}`
- `{"type":"spend","today_usd","budget_usd"}`
- `{"type":"ping"}` every 20 s; the client may send `{"type":"pong"}`

## Terminal: `WS /v1/term?session=<id>&cols=<n>&rows=<n>`

- The server runs the session on a pseudo-terminal of `cols`×`rows` with
  `TERM=xterm-256color`:
  - `tuios:<user>:<session>`: `nestlo-tuios --user <user> attach <session>`, the
    whole TUIOS screen;
  - `shell:<user>`: that user's login shell.
- server → client: **binary** frames, raw PTY output (UTF-8 with ANSI/xterm escapes).
- client → server: **binary** frames, keyboard input bytes; **text** frames for control:
  `{"type":"resize","cols":n,"rows":n}`.
- On process exit the server sends text `{"type":"exit","code":n}` and closes with 1000.
- At most 8 terminals at once per device.

## Desktop: `GET /desktop/` and `WS /v1/desktop`

When `desktop` is in `features`:

- `GET /desktop/?t=<token>` sets the auth cookie and redirects to `/desktop/`.
- `/desktop/` serves noVNC (`vnc.html`), which connects to `wss://<same host>/v1/desktop`.
- `/v1/desktop` bridges binary WebSocket frames to the local wayvnc (RFB) at
  `127.0.0.1:5900`.
- The app opens `/desktop/?t=<token>` in a WebView that accepts only the pinned certificate.
