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

## One QR: install the app, then pair

`nestlo-mobile pair` prints a single QR code that works whether or not the app is
installed. It encodes a plain web URL (any phone camera opens it in the browser),
with the pairing parameters in the URL **fragment**. A fragment is never sent to
a server and never written to a server log:

```
http://<entry host>:7080/pair#v=1&name=<n>&port=7443&fp=<fp>&code=<code>&host=<h1>&host=<h2>...
```

or `<publicUrl>/pair#...` when `nestlo.mobile.publicUrl` is set (for example an
HTTPS name behind a reverse proxy).

- **Onboarding listener:** plain HTTP, default port **7080** (`onboarding.port`).
  It serves only static, unauthenticated, cache-free pages:
  - `GET /pair`: the landing page (black and white, Nothing style). Its inline
    script reads `location.hash` and offers two buttons:
    - **OPEN NESTLO**: `intent://pair?<same params>#Intent;scheme=nestlo;package=dev.nestlo.app;S.browser_fallback_url=<url-encoded /app>;end`.
      Chrome opens the app when it is installed; otherwise it follows the fallback.
      The page tries this automatically once on load.
    - **GET THE APP**: `/app`.
  - `GET /app`: a page with a link to the APK, its SHA-256, and the steps to allow
    "install unknown apps". The link points to `/app/nestlo.apk` when the machine
    has a local APK (`onboarding.apk`); otherwise it points to
    `https://github.com/anubhavg-icpl/nestlo/releases/latest/download/nestlo-android.apk`.
  - `GET /app/nestlo.apk`: served with `application/vnd.android.package-archive`,
    only when `onboarding.apk` is set.
  - After installing, the user taps **OPEN NESTLO** again (or rescans), and the app
    receives `nestlo://pair?...`.
- **The app accepts all three forms:**
  - `nestlo://pair?...` (deep link);
  - `http(s)://<anything>/pair#...` (scanned in-app or opened through an App Link);
  - a pasted link of either form.

  The parameters are the same in query or fragment form.
- **Hosts, in order:**
  1. `domain` (when set);
  2. `advertisedHosts`;
  3. every private (RFC 1918 / ULA) address;
  4. the public IP (only when `discoverPublicIp = true`; looked up once per
     `pair` from `https://api.ipify.org`), or a fixed `publicHost`;
  5. the host name;
  6. `localhost` (for `adb reverse tcp:7443 tcp:7443` and emulators).

  The **entry host**, the one in the URL authority, is the first of `domain`,
  `publicHost`, the first private address.
- **Trust:** the onboarding page is plain HTTP, so on an untrusted network it could
  be tampered with. The pinned fingerprint and the code still come from the QR
  itself, and the app pins `fp` from the QR it decoded. When pairing over the
  internet, use `publicUrl` with HTTPS, or a VPN (Tailscale/WireGuard). `7443`
  (the API) and `7080` (onboarding) are opened in the firewall only when
  `openFirewall = true`.
- **Android package id:** `dev.nestlo.app`. **Release asset:** `nestlo-android.apk`
  (stable name), plus `nestlo-<tag>.apk`.

## Reaching the machine from anywhere: tunnels

`nestlo-mobile pair` **asks** how the phone should reach the machine. With
`--via lan|tunnel|tailscale|url`, it skips the question; without a terminal, it
uses the configured default (`nestlo.mobile.connect.default`, default `lan`):

```
How should your phone reach this machine?
  [1] same network (LAN)            phone and machine on the same Wi-Fi
  [2] quick tunnel (Cloudflare)     works anywhere, no account, temporary URL
  [3] tailscale                     both devices on your tailnet
  [4] my own URL                    nestlo.mobile.publicUrl (reverse proxy, named tunnel)
```

- **Quick tunnel:**
  - The `nestlo-mobile-tunnel` unit runs
    `cloudflared tunnel --no-autoupdate --url https://127.0.0.1:7443 --no-tls-verify`
    and reads the `https://<random>.trycloudflare.com` URL from its log.
  - `pair --via tunnel` starts the unit if needed, waits (up to 60 s) for the URL,
    and keeps the unit running.
  - With `nestlo.mobile.tunnel.persistent = true`, the unit runs at boot, but
    the URL changes on every restart.
  - For a stable name, set `tunnel.tokenFile` (a named Cloudflare tunnel token)
    and `publicUrl`.
  - Cloudflare terminates TLS, so over a tunnel the app validates the normal
    WebPKI certificate of the tunnel host instead of pinning `fp`.
  - The pairing code (single use, short TTL) and the device token still protect
    the API.
- **Tailscale:** uses the machine's tailnet name or `100.x` address
  (`tailscale ip -4` and `tailscale status --json`) as the first host, with the
  pinned certificate.
- **Single port for everything:** the API port (7443) also serves the
  unauthenticated onboarding pages `/pair`, `/app` and `/app/nestlo.apk`, so one
  tunnel carries onboarding, the API, events, terminals and the desktop. The
  plain-HTTP onboarding listener on 7080 stays for LAN use.
- **New URI parameter, `url`** (repeatable, tried before any `host`): a complete
  base URL such as `https://abc-def.trycloudflare.com`. For a `url` with an
  `https` scheme and a host that is not an IP literal, the app validates the
  certificate with the system trust store (WebPKI) and ignores `fp`. For bare
  `host` entries, the pinned `fp` applies as before.
- **QR entry for a tunnel:** `https://<random>.trycloudflare.com/pair#v=1&...&url=https://<random>.trycloudflare.com&host=<private ips>...`.
  The page loads with a valid certificate and no warnings.
- **Safety:**
  - A tunnel exposes the API to the internet. `pair` says so, prints that only a
    holder of a pairing code or a device token can use it, and suggests
    `nestlo-mobile tunnel stop` when done.
  - Failed pairing attempts are rate-limited per client IP (the
    `CF-Connecting-IP` header, trusted only on connections from loopback).
