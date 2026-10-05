# Data loss prevention in the gateway

Coding agents paste file contents, logs and environment dumps into prompts.
The gateway can check every request body for secrets and personal data before
it is forwarded to a model provider.

```nix
agentos.gateway.dlp = {
  mode = "mask";                       # off | log | mask | block
  detectors = [ "all" ];               # or a list, see the table
  scanResponses = false;               # non-streaming responses only
  overrides = {
    "ci-"      = { mode = "block"; };  # agents whose id starts with ci-
    "scratch-" = { mode = "off"; };
    "review-"  = { mode = "mask"; detectors = [ "private_key" "email" ]; };
  };
};
```

The options live next to the other gateway options (`agentos.networking`) and
are written to `[gateway.dlp]` in `/etc/agentos/services.toml`. The longest
matching prefix in `overrides` wins; an override inherits the global
`detectors` and `scanResponses` unless it sets them.

## Modes

| Mode | Effect on a request that matches |
|:---|:---|
| `off` | Not scanned. |
| `log` | Forwarded unchanged. The detector types and counts are recorded in the audit log (`dlp.detection`), the gateway log (`dlp` field) and the service log. |
| `mask` | Every match is replaced by `[REDACTED:<type>]`, JSON bodies are re-serialised so the provider receives valid JSON, and the masked body is what is recorded when session recording is on. |
| `block` | Refused with `403`, error type `dlp_blocked`, message `request blocked by Nestlo DLP policy: detected aws_access_key, email`. Nothing is sent to the provider. |

**Matched values are never stored or reported**: audit events, log lines and
error messages carry detector names and counts only.

## Detectors

Secrets:

| Name | Finds |
|:---|:---|
| `private_key` | `-----BEGIN ... PRIVATE KEY-----` blocks (to the matching END line, or to the end of the text if truncated) |
| `aws_access_key` | `AKIA`/`ASIA`/... access key ids |
| `aws_secret_key` | a 40 character secret next to an `aws ... secret` name |
| `github_token` | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_` tokens |
| `slack_token` | `xoxb-`, `xoxp-`, ... |
| `api_key` | `sk-ant-...`, `sk-...` (OpenAI style), Stripe live keys, Google `AIza...`, GitLab `glpat-`, npm, SendGrid |
| `jwt` | three-part JSON web tokens |
| `provider_key` | the exact API keys configured in `agentos.networking.providers.*.keyFile` (re-read every 30 s) |
| `credential_assignment` | `password = "..."`, `api_key: '...'` and similar with a quoted value of 12+ characters that is not a path, variable reference, placeholder or kebab-case word |
| `high_entropy` | a 32-200 character token of mixed case and digits with at least 4.25 bits of entropy per character; excludes hex digests and commit ids, UUIDs, SRI hashes (`sha512-...`), paths and camelCase identifiers |

Personal data:

| Name | Finds |
|:---|:---|
| `email` | addresses; not `git@host` remotes, systemd instance names (`getty@tty1.service`) or reserved domains (`example.com`, `.local`, `.test`) |
| `credit_card` | 13-19 digit numbers with a known issuer prefix that pass the **Luhn** check |
| `iban` | IBANs with the registered country length and a valid **mod 97** check |
| `phone` | deliberately strict: `+` international numbers and North American `ddd-ddd-dddd` / `(ddd) ddd-dddd` forms with 9-15 digits |

Detectors are precompiled regular expressions with cheap literal pre-checks,
so a scan of ordinary code costs a few hundred milliseconds per megabyte at
most. They are heuristics: they will miss secrets in unusual formats
(`high_entropy` is the safety net) and `high_entropy`, `credential_assignment`
and `phone` can flag harmless text. Start with `log`, look at the
`dlp.detection` audit events, narrow `detectors`, then move to `mask`.

## What is scanned

* **Requests**: the whole body, always, before routing, loop detection,
  budget estimation and recording. JSON is walked string by string, so a match
  cannot straddle two fields and keys and numbers are untouched. Plain text,
  XML and form bodies are scanned as text. Base64 payloads (`"type":
  "base64"` sources such as images and PDFs) and `data:` URLs are skipped, as
  are binary content types.
* **Size limit**: bodies over `maxScanBytes` (16 MiB) cannot be checked. In
  `mask` and `block` mode such a request is refused with `413
  dlp_scan_limit`; in `log` mode it is forwarded unscanned.
* **Responses** (`scanResponses = true`): only when the response is **not
  streaming** (not `text/event-stream`) and not content-encoded. The gateway
  holds the body back, scans it with the agent's policy and sends it with the
  new `Content-Length`; `mask` redacts it, `block` replaces it with `502
  dlp_blocked`. Spend is recorded either way, because the provider already
  billed it. A session recording stores the response the agent received
  (masked, or the 502), so a replay never returns the unscanned body. **Streamed responses (most agent traffic) pass through
  unscanned**: masking a stream means buffering it, which would remove the
  streaming. Responses over `maxScanBytes` are streamed unscanned.
* Gateway admin endpoints and the inter-agent message bus are not scanned.

## Audit events

Each request or response with findings writes one `dlp.detection` event
(see [audit.md](audit.md)):

```json
{"type":"dlp.detection","actor":"a1","data":{"direction":"request","mode":"mask",
 "action":"masked","provider":"anthropic","detections":{"aws_access_key":1,"email":2}}}
```

`action` is `logged`, `masked` or `blocked`. With the audit log off, the
findings still appear in the gateway log and the service journal.

## Limits

* DLP reduces accidental leaks; it is not a boundary against an agent that
  deliberately encodes data (base64, splitting a key over messages).
* Masking changes what the model sees; a masked key in a shell command the
  model writes back will not work. Prefer fixing the source (keep secrets out
  of the workspace and the environment the agent can read).
* Detector lists are code (`services/agentos_services/dlp.py`); extend them
  there with a test.
