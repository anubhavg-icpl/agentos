## Reticle (`skills-reticle`)

Reticle stops an agent from calling an app finished when it is not. It opens the
app in a browser, uses it, and marks each check worked, did not work, or not
enough information, with an explanation for every failure. Source:
https://github.com/reticlehq/reticle (pinned in `sources.nix`).

**Skills (19).** `reticle` (install, instrument and verify), `agentic-tdd`,
`audit-my-app`, `debug-broken-ui`, `design-system-compliance`,
`drive-desktop-app`, `false-green-tests`, `fix-what-i-pointed-at`,
`install-and-verify`, `replay-user-flows`, `test-error-states`,
`verify-cli-run`, `verify-form-validation`, `verify-keyboard-access`,
`verify-login-logout`, `verify-optimistic-update`, `verify-pagination`,
`verify-ui-change`, `verify-unattended`.

**Tools.** `reticle` (the CLI) is on PATH. The pack registers one MCP server,
`reticle` (`reticle mcp`). The CLI is built from the pinned source with pnpm:
only `@reticlehq/server` and the workspace packages it depends on are built, on
Node 22. Nothing is downloaded when it runs. The wrapper sets
`RETICLE_CHROMIUM_PATH` to nixpkgs' Chromium (so Playwright never installs a
browser), `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and `RETICLE_TELEMETRY=0`; all
three can be overridden from the environment.

**Licence.**

| Part | Licence |
| --- | --- |
| The 19 skills, `@reticlehq/core`, `engine`, `browser`, `open-verification` | Apache-2.0 |
| `@reticlehq/server` (the `reticle` CLI and MCP server), `@reticlehq/init` | FSL-1.1-ALv2 |
| `server/src/features/ee` | Reticle Enterprise License |

FSL-1.1-ALv2 allows internal use, development and evaluation. The one
restriction is offering Reticle itself as a competing product or service. Each
version becomes Apache-2.0 two years after its release. The enterprise code is
audit-log functionality that nothing else imports; the build deletes it, so it is
not in the output. The pack's `license` field is `FSL-1.1-ALv2` because that is
the most restrictive licence of what ships.
