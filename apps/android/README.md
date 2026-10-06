# Nestlo for Android

A phone companion for a Nestlo machine. It pairs once, then streams the machine: agents, spend,
approvals, live terminals and the desktop. The wire protocol is
[`docs/mobile-protocol.md`](../../docs/mobile-protocol.md); this app and `nestlo.mobile` on the
machine both implement exactly that document.

- Package id: `dev.nestlo.app`, minSdk 26, targetSdk/compileSdk 35.
- Kotlin, Jetpack Compose (Material3 only as a base, restyled), CameraX + zxing for QR, OkHttp.
- No Google Play services, no analytics, no ads. The device token is stored encrypted with a
  hardware-backed Android Keystore key.

## Layout

```
apps/android
  core/   standalone JVM Gradle build (no Android): protocol models, pairing URI parser,
          certificate pinning, REST + WebSocket client, endpoint failover, and the
          VT100/xterm terminal emulator with its key encoder. Has its own wrapper and tests.
  app/    the Android application (:app), consumes core as dev.nestlo:nestlo-core
  gradle/ version catalog (libs.versions.toml) and wrapper
```

The root build includes `core` with `includeBuild("core")`, so `:app` always compiles against the
sources in this checkout.

## Build

CI is the reference build: `ci/proposed-workflows/android.yml` (copy it to `.github/workflows/`).
It runs the core tests, then builds a signed release APK when the signing secrets exist
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`)
and a debug APK otherwise. The APK is uploaded as the `nestlo-android.apk` artifact, and on `v*`
tags it is attached to the release as `nestlo-<tag>.apk` and `nestlo-android.apk`.

Locally, with JDK 17 and the Android SDK (platform 35) installed, or by opening this folder in
Android Studio (Ladybug or newer):

```sh
cd apps/android
./gradlew assembleDebug        # app/build/outputs/apk/debug/app-debug.apk
./gradlew :app:assembleRelease # needs the ANDROID_KEYSTORE_* variables, see app/build.gradle.kts
```

Core only (no Android SDK needed):

```sh
cd apps/android/core
./gradlew test
```

## Install

- From a release: download `nestlo-android.apk` from
  <https://github.com/anubhavg-icpl/nestlo/releases/latest/download/nestlo-android.apk>, open it on the
  phone and allow "install unknown apps" for the browser or file manager.
- Over USB: `adb install -r nestlo-android.apk`.
- From the machine: the onboarding page (`/app`) serves the APK when `onboarding.apk` is set.

## Pairing

### One QR: install, then pair

On the machine run `nestlo-mobile pair` and choose how the phone reaches it (same network, a
tunnel, Tailscale or your own URL). It prints one QR code.

1. Scan it with the phone's normal camera. It opens the onboarding page in the browser.
2. If the app is not installed, tap **GET THE APP**, install the APK.
3. Tap **OPEN NESTLO**. The page launches `nestlo://pair?...` and the app pairs by itself.
4. The home screen appears. The status line reads `[PAIRED]` and then `[LIVE]`.

The pairing parameters travel in the URL fragment, so they never reach a web server log.

### Already installed

Open Nestlo and scan the same QR code in the app, or paste the link. The app accepts all three
forms with identical parameters:

- `nestlo://pair?v=1&...` (deep link),
- `http(s)://<host>[:port]/pair#v=1&...` (what the QR encodes),
- either of them pasted as text.

The QR from `nestlo-mobile pair` can be LAN, tunnel or Tailscale. The app tries the endpoints in
the order given: `url` entries first (valid WebPKI certificate), then `host` entries (the
certificate pinned by `fp`), 2 seconds per endpoint. The pairing code is single use and expires
(default 5 minutes).

### Trust

- `host` entries (LAN addresses, Tailscale, raw TCP tunnels such as bore or frp): the app accepts
  exactly the certificate whose SHA-256 matches `fp` from the QR. There is no CA and no host name
  check. A changed certificate means re-pairing.
- `url` entries with an https host name (Cloudflare, ngrok, Tailscale Funnel, your reverse proxy):
  normal system trust store and host name verification; `fp` is ignored.
- If the stored endpoint stops answering the app walks the whole list again, so a LAN address works
  when a quick tunnel URL expires. When nothing answers it shows
  `[TUNNEL EXPIRED — RE-PAIR OR USE LAN]`.
- A `401` from the server (token revoked) returns the app to the pairing screen.

## Screens

| Screen | What it does |
|:--|:--|
| Pair | Camera QR scanner, paste-a-link fallback, deep link `nestlo://pair`, inline status |
| Home | Working agents as a dot-matrix hero in a dot ring, segmented spend bar, health dots, agent list, red `NEEDS INPUT` row only when something is blocked |
| Agent | Request log in mono type, hold-to-confirm kill |
| Approvals | Approve or deny |
| Terminal | Session picker, then a full-screen terminal drawn from the core emulator: pinch to zoom, drag to scroll history (arrow keys in full-screen apps), long-press pastes, extra keys row (ESC TAB CTRL ALT arrows \| - /), screen stays on |
| Desktop | WebView on `/desktop/?t=<token>`, immersive, rotatable. The pinned certificate is the only certificate it will override an SSL error for; WebPKI endpoints never override |
| Settings | Server info, devices, revoke this or other devices, unpair, background alerts |

Background alerts are an opt-in foreground service (`dataSync`) that keeps `/v1/events` open and
notifies for `needs_input` and approvals. It asks for the notification permission on Android 13+.
Android 15 limits such services to six hours per day; the app then switches the toggle off.

## Design notes

Nothing-style black and white, with one accent.

- OLED `#000000` background, white primary, grays `#E8E8E8` / `#999999` / `#666666`, borders
  `#222222` / `#333333`. Red `#D71921` is used only for interrupts: needs input, errors, destructive
  actions.
- Doto (dot matrix) for hero numbers and headlines only, Space Grotesk for body, Space Mono for
  labels (upper case, letter-spaced) and the terminal. All three are SIL OFL fonts; the licenses are
  in `app/src/main/assets/licenses/`. The upstream repository ships Doto and Space Grotesk only as
  variable fonts, so weights are selected with font variation settings (Android 8+).
- No gradients, shadows or blur. Flat surfaces with 1 px borders, a dot-grid background, segmented
  bars, one circular element (the dot ring) per screen at most.
- Status is inline text (`[CONNECTING…]`, `[PAIRED]`, `[ERROR: …]`), never a toast.
- Transitions are short and linear with no springs; buttons invert instantly when pressed; hold to
  confirm fills a segmented bar with a tick per segment. Haptics on key actions.
- Launcher icon: adaptive, a white dot-matrix bird on black (vector made of dots), with a
  monochrome variant for themed icons.

## What is verified where

Verified in the development sandbox (no Android SDK, Google Maven unreachable):

- `core` compiles and its unit tests pass with JDK 17 and Gradle 8.14: protocol models, all three
  pairing URI forms and rejection cases, endpoint trust selection and failover, TLS pinning against
  a local HTTPS/WebSocket server (REST, events with reconnect and pong, terminal binary in/out,
  resize, exit), key encoding, and the terminal emulator on captured vim, htop and alt-screen
  sequences.

Only verified in CI or on a device:

- Everything under `app/`: it has never been compiled in the sandbox, because AGP, AndroidX and
  Compose come from Google Maven. Expect the first CI run to surface compile errors to fix.
- Camera scanning, the soft keyboard input view, the WebView SSL handling (including noVNC's
  WebSocket on a pinned certificate), the foreground service and notifications, haptics, and the
  look of the Doto/Space fonts.

Open questions to check on a device:

- `SslCertificate.saveState(...)["x509-certificate"]` is used for the certificate on Android 8-9
  (API 29+ uses `getX509Certificate()`); if that key is absent the desktop is refused there.
- Whether WebView reuses the SSL exception for the noVNC WebSocket on the same host.
