# Phone app (`nestlo.mobile`)

The Nestlo Android app shows what your agents are doing and lets you act on it
from your phone: agents, spend and budgets, a live event feed (an agent needs
input), approvals, a terminal on the machine and, optionally, its desktop.
`nestlo.mobile` is the server side. The wire format is in
[mobile-protocol.md](mobile-protocol.md); this page is the operator guide.

```nix
nestlo.mobile.enable = true;
```

This starts `nestlo-mobile.service` (HTTPS and WebSocket on port 7443) and a
plain-HTTP onboarding listener on port 7080, opens both in the firewall, and
installs `nestlo-mobile` and `qrencode`. It needs `nestlo.runtime.enable`.

## Pairing walkthrough

1. Boot Nestlo (the ISO on bare metal or in a VM, or an installed system) and
   enable `nestlo.mobile` as above.
2. On the machine, as a user in the admin group (`wheel` by default):

   ```
   nestlo-mobile pair
   ```

   It asks how the phone reaches the machine (same network, tunnel, Tailscale,
   your own URL) unless you pass `--via lan|tunnel|tailscale|url`. Without a
   terminal it uses `nestlo.mobile.connect.default` (`lan`). It prints one QR code,
   the link behind it and the raw `nestlo://` URI. The code is single use and
   valid for 300 seconds (`--ttl SECONDS`).
3. Scan the QR code with the phone camera. The link opens a small landing page
   (served by the machine). If the app is installed, **OPEN NESTLO** starts it and
   pairs; otherwise **GET THE APP** leads to the APK and the steps to allow
   "install unknown apps", and you tap OPEN NESTLO again afterwards. Inside the
   app you can also scan the same QR or paste the link.
4. The app pins the certificate fingerprint from the QR and stores a device
   token. `nestlo-mobile devices` lists paired phones, `nestlo-mobile revoke <id>`
   removes one (its terminals close at once), `nestlo-mobile url` prints the
   addresses and the fingerprint.

The pairing data (code, fingerprint, hosts) sits in the URL **fragment**, which
browsers never send to a server, so it appears in no server log.

## Reaching the machine

The pairing link lists hosts in this order: Tailscale name and address (when
Tailscale is up), `domain`, `advertisedHosts`, every private address (RFC 1918,
ULA, 100.64/10), `publicHost` and, with `discoverPublicIp`, the public IP (one
request to api.ipify.org per `pair`), the host name, `localhost` (for
`adb reverse tcp:7443 tcp:7443` and emulators). The app tries them in order.

| Choice | Use it when | Trust |
|--------|-------------|-------|
| LAN | phone and machine on the same Wi-Fi | pinned certificate |
| Tailscale | both devices on your tailnet (`services.tailscale.enable = true;` and `tailscale up`) | pinned certificate over the tailnet |
| Tunnel | no shared network, nothing to install on the phone | see below |
| Own URL | a reverse proxy or named tunnel in front (`publicUrl`) | WebPKI certificate of that URL |

Never forward port 7443 on your router, and do not expose it to the internet
without a VPN or a tunnel you control: a paired phone holds a shell.

### Tunnels

```nix
nestlo.mobile.tunnel = {
  enable = true;                 # adds the nestlo-mobile-tunnel unit (started on demand)
  provider = "cloudflare";       # the default for `pair --via tunnel`
  # persistent = true;           # start at boot (quick-tunnel URLs change on every start)
};
```

`nestlo-mobile pair --via tunnel` lists the providers (marking which need an
account and whether they are configured) and starts the one you pick;
`--provider NAME` skips the question. `nestlo-mobile tunnel start|stop|status|url`
controls it directly. One tunnel runs at a time. If no endpoint shows up within
60 seconds the unit fails and the command prints the tool's last output lines.
`pair` prints a warning, because a tunnel exposes the API to the internet:
only a pairing code (single use, short TTL, rate-limited per client address) or
a device token gets in. Run `nestlo-mobile tunnel stop` when you are done.

The API port also serves `/pair`, `/app` and `/app/nestlo.apk`, so one tunnel
carries onboarding, the API, events, terminals and the desktop.

| Provider | Account | Endpoint | Trust |
|----------|---------|----------|-------|
| `cloudflare` (default) | none | temporary `https://<random>.trycloudflare.com` | WebPKI; Cloudflare terminates TLS |
| `cloudflare-named` | Cloudflare account, `tokenFile`, `publicUrl` | your hostname | WebPKI |
| `tailscale-funnel` | tailnet with Funnel enabled | `https://<machine>.<tailnet>.ts.net` | WebPKI |
| `tailscale` | tailnet (`--via tailscale`, no process) | tailnet name or 100.x, port 7443 | pinned |
| `ngrok` | ngrok `authtokenFile` (ngrok is unfree: `nixpkgs.config.allowUnfree`) | `https://*.ngrok-free.app` or your reserved `domain` | WebPKI |
| `zrok` | `tokenFile` (zrok.io or `server` for your own) | `https://*.share.zrok.io` | WebPKI |
| `pinggy` | none (free sessions last about an hour) | `<random>.a.pinggy.link:443` raw TLS | pinned end to end |
| `localhost-run` | none | `https://*.lhr.life`, onboarding page only (the API uses the LAN hosts) | WebPKI |
| `bore` | none, or your own server (`server`, `secretFile`) | `bore.pub:<port>` raw TCP | pinned end to end |
| `frp` | your own frps (`server`, `remotePort`, `tokenFile`) | `<server>:<remotePort>` raw TCP | pinned end to end |

Providers that terminate TLS (Cloudflare, ngrok, zrok, Funnel) see the traffic
in the clear on their side; the app validates the normal WebPKI certificate of
the tunnel host. Raw-TCP providers (bore, frp, pinggy, Tailscale) keep the
machine's own certificate end to end, and the app pins it. For those, the page
the QR opens is served with that self-signed certificate, so the browser warns
once; the pairing itself is unaffected. Enable the providers you want with
`nestlo.mobile.tunnel.providers.<name>.enable = true;` (tokens as files, passed
to the unit as systemd credentials; they never enter the Nix store or a QR code):

```nix
nestlo.mobile.tunnel.providers.ngrok = {
  enable = true;
  authtokenFile = "/run/secrets/ngrok-authtoken";
};
nestlo.mobile.tunnel.providers.cloudflare-named = {
  enable = true;
  tokenFile = "/run/secrets/cloudflared-token";   # route the hostname to https://127.0.0.1:7443
};
nestlo.mobile.publicUrl = "https://nestlo.example.org";
```

A named tunnel gives a stable name; with Tailscale there is nothing public at
all, which is the safest choice if you already use it.

## Security model

- **Pinning.** The server makes a self-signed ECDSA P-256 certificate on first
  start (10 years). The QR carries its SHA-256; the app trusts exactly that
  certificate. A changed certificate means pairing again. The onboarding page is
  plain HTTP and can be tampered with on a hostile network; the pinned values
  come from the QR, not from the page. Over the internet use a tunnel, a VPN or
  `publicUrl` with HTTPS.
- **Device tokens.** Pairing codes are single use, short lived and rate-limited
  (10 failures per 10 minutes per address); only SHA-256 of codes and tokens is
  stored, in `/var/lib/nestlo-mobile`. Revoke a lost phone at once.
- **The terminal is a shell.** Whoever holds a paired phone gets a login shell
  as every user in `terminal.users` (default: the `nestlo.runtime` operators),
  and can attach their TUIOS sessions. The agent user is opt-in
  (`terminal.includeAgentUser`). Each open and close is audited
  (`mobile.terminal`), as are pairing (`mobile.pair`) and revocation
  (`mobile.revoke`), when `nestlo.audit` is enabled. At most 8 terminals per device.
- **Service hardening.** The server runs as root to start terminals as other
  users, with a reduced capability set and restricted address families. The
  usual file-system sandbox (`ProtectSystem`, `PrivateTmp`) and
  `NoNewPrivileges` are not applied: terminals inherit them, and a shell that
  cannot write or use `sudo` is not useful. The tunnel unit is fully sandboxed.
- **Approvals.** With `nestlo.orchestration`, tasks awaiting approval appear
  in the app; a decision is made as root with a note naming the phone.

## Desktop streaming

```nix
nestlo.desktop = { enable = true; windowManager = "sway"; autologin = { enable = true; user = "admin"; }; };
nestlo.mobile.desktop.enable = true;
```

`nestlo-mobile-wayvnc` runs wayvnc on `127.0.0.1:5900` inside that user's Wayland
session; the server bridges `/v1/desktop` to it and serves noVNC under
`/desktop/`. Limits: it needs a wlroots compositor (sway or hyprland, not i3)
and a logged-in session (autologin); wayvnc has no authentication of its own and
listens on loopback only, so access is exactly that of a paired device; there is
no audio.

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `enable` | false | Run the server |
| `port` | 7443 | HTTPS and WebSocket port |
| `listen` | `0.0.0.0` | Bind address |
| `openFirewall` | true | Open the API and onboarding ports |
| `advertisedHosts` | `[]` | Hosts in pairing links, after `domain` |
| `domain` | `""` | First host and entry host of the pairing link |
| `publicHost` | `""` | Fixed public address or name |
| `publicUrl` | `""` | Base URL of the landing page behind a proxy (also the cloudflare-named hostname) |
| `discoverPublicIp` | false | Look up the public IP once per `pair` |
| `onboarding.port` | 7080 | Plain-HTTP landing and app pages |
| `onboarding.apk` | null | APK served at `/app/nestlo.apk` (otherwise `/app` links to the GitHub release) |
| `adminGroup` | `wheel` | Group allowed to run `nestlo-mobile` |
| `connect.default` | `lan` | `pair` choice without a terminal |
| `terminal.users` | existing `nestlo.runtime.operators` | Users whose shell and TUIOS sessions the phone may open |
| `terminal.includeAgentUser` | false | Also allow `nestlo-agent` |
| `desktop.enable` | false | wayvnc and noVNC |
| `desktop.user` | `nestlo.desktop.autologin.user` | Whose session is shared |
| `tunnel.enable` | false | Provide the tunnel unit (on demand) |
| `tunnel.persistent` | false | Start the tunnel at boot |
| `tunnel.provider` | `cloudflare` | Default provider |
| `tunnel.package` | `pkgs.cloudflared` | cloudflared for both Cloudflare providers |
| `tunnel.providers.<name>.*` | | `enable`, `package`, and per provider `tokenFile`, `authtokenFile`, `secretFile`, `domain`, `server`, `serverPort`, `remotePort` |
