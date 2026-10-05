# Agent security (`nestlo.agentSecurity`)

Three open-source tools that test and gate the AI side of a Nestlo host. Each
is switched on on its own; all send their model calls through the Nestlo model
gateway and report to the audit log and notifications.

| Component | Upstream | Licence | Commands | What it does |
|-----------|----------|---------|----------|--------------|
| `promptfoo` | [promptfoo/promptfoo](https://github.com/promptfoo/promptfoo) | MIT | `nestlo-redteam`, `nestlo-eval` | Red-team and eval suites against a model behind the gateway, as gateway agent `redteam` with its own budget |
| `agentScan` | [snyk/agent-scan](https://github.com/snyk/agent-scan) (formerly mcp-scan) | Apache-2.0 | `nestlo-agent-scan` | Admission check for the MCP server configs and skill packs Nestlo installs: tool poisoning, prompt injection in descriptions, toxic flows |
| `prReview` | [qodo-ai/pr-agent](https://github.com/qodo-ai/pr-agent) | MIT | `nestlo-pr-review` | AI review of a pull request; model calls through the gateway as agent `pr-review`; optional automatic review of the `agent/*` pull requests the publisher opens |

```nix
nestlo.networking.enable = true;               # the model gateway (required by promptfoo and prReview)
nestlo.agentSecurity = {
  enable = true;                               # user, state directory, shared wiring
  promptfoo = {
    enable = true;
    target = { api = "anthropic"; model = "claude-sonnet-4-6"; };
    schedule.enable = true;                    # weekly red team
  };
  agentScan.enable = true;                     # local rules only
  prReview = {
    enable = true;
    github.tokenFile = "/run/secrets/nestlo-github-pr-token";
    auto.enable = true;                        # review agent/* PRs of nestlo.git-automation.publish.repos
  };
};
```

Everything lives in `/var/lib/nestlo-agent-security` (group `nestlo-security`,
setgid; `operators` are members, default `nestlo.runtime.operators`):

| Path | Contents |
|------|----------|
| `tokens/<agent-id>` | Gateway tokens of `redteam` and `pr-review`, generated on first start; `0640 root:nestlo-security`. The only place a token is stored. Never in the Nix store |
| `reports/redteam/<time>/`, `reports/eval/<time>/` | The promptfoo config used, promptfoo's JSON output, `summary.json`; `reports/latest-redteam.json`, `latest-eval.json` link to the last summary |
| `reports/agent-scan/` | `scan-<time>.json`, `latest.json`, and with `inspect`/`remote` the raw tool lists and Snyk's answer |
| `pr-review/seen.json` | Head commit last reviewed per pull request (the auto mode reviews each head once) |
| `home/`, `promptfoo/`, `uv-cache/`, `tiktoken/` | The tools' own state and caches |

Non-secret settings are rendered to `/etc/nestlo/agent-security/config.json`.

## Shared behaviour

**Gateway agents.** `nestlo-agent-security-setup.service` registers the agent
ids of the enabled components (`redteam`, `pr-review`) on the gateway's admin
socket: token hash and a daily budget (`promptfoo.budgetUsd` default 10,
`prReview.budgetUsd` default 5). It re-runs when the gateway restarts. A model
call is made as that agent (`/agent/<id>:<token>/<provider>/...` or the
`x-nestlo-token` header), so the gateway's budget, DLP, loop detection, circuit
breaker, audit entries and metrics apply and the real provider keys never reach
the tools. When a budget is spent the gateway refuses further calls: the run
reports errors instead of continuing. The gateway's DLP and loop detection also
see the attack prompts of a red-team run and may block some of them.

**Audit.** `audit.enable` (default: `nestlo.audit.enable`) sends one event per
run to the audit writer: `security.redteam` (kind, target, passed/failed/errors,
failure rate, report path), `security.agent_scan` (mode, finding counts, report
path) and `security.pr_review` (repo, PR number, command, ok). Events carry
counts and paths only, never prompts, descriptions or tokens.

**These types are not in the audit writer yet.** `EVENT_TYPES` in
`services/nestlo_services/audit.py` has to list `security.redteam`,
`security.agent_scan` and `security.pr_review`; until then the writer rejects
them and logs a warning (the runs are not affected). The module sends them
best effort and never fails because the writer is unreachable or refuses.

**Notifications.** `notify.enable` (default: `nestlo.notifications.enable`)
posts a one-line summary through `nestlo-notify` after a red-team run and when
an agent-scan fails. `nestlo-notify` has no send command, so the summary goes
out as its `test` message to the configured webhooks; the webhook files must be
readable by group `nestlo-security`. A failure to send is ignored.

**Units.** The run units are oneshot services under the user `nestlo-security`
with `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, no capabilities, no
new privileges and only the state directory writable. `nestlo-redteam.service`
may only reach loopback (the gateway); the local agent-scan unit has no network
at all (`PrivateNetwork`).

Common options: `enable`, `operators`, `audit.enable`, `notify.enable`,
`gatewayProviders.openai` (default `openai`) and `gatewayProviders.anthropic`
(default `anthropic`) name the gateway providers (`nestlo.networking.providers`)
that serve each wire format.

## promptfoo: `nestlo-redteam`, `nestlo-eval`

```
nestlo-redteam [--target MODEL] [-c CONFIG] [-- promptfoo args]
nestlo-eval    [--target MODEL] [-c CONFIG] [-- promptfoo args]
```

`nestlo-redteam` generates a promptfoo config in the report directory and runs
`promptfoo redteam run` on it. The default config tests the `target` model for:

| Risk | Plugins / strategies |
|------|----------------------|
| Prompt injection | strategy `prompt-injection` (static injection templates) |
| Jailbreak | strategy `jailbreak` (iterative, attacker = `generator`) |
| PII leakage | `pii:direct`, `pii:session`, `pii:social`, `pii:api-db` |
| Excessive agency | `excessive-agency` |
| System prompt extraction | `prompt-extraction` |
| Shell injection | `shell-injection` |

plus `basic` (the plain test cases). Plugins, strategies, `numTests` (default 5
per plugin), `purpose` (what the deployment is for; the attacks and grading are
derived from it) and extra `redteam:` keys are options. The attacks and the
grading are produced by `generator` (default `gpt-4o` via the `openai` gateway
provider), the target is `target` (default `claude-sonnet-4-6` via
`anthropic`); both through the gateway as agent `redteam`.

How the token stays out of files: the generated config contains
only a dummy `apiKey` (promptfoo 0.118 does not expand `{{ env.X }}` in the
`openai:` and `anthropic:` provider options, but both read
`OPENAI_BASE_URL` / `ANTHROPIC_BASE_URL`). `nestlo-redteam` reads `tokens/redteam` and puts the full gateway URLs
(`http://127.0.0.1:8080/agent/redteam:<token>/openai/v1`, `.../anthropic`) into
the environment of promptfoo only, together with `OPENAI_BASE_URL`,
`ANTHROPIC_BASE_URL` and dummy API keys. Your own configs (`-c`) can rely on the
standard variables (no `apiBaseUrl`), or use `{{ env.NESTLO_OPENAI_BASE_URL }}`
where promptfoo does expand templates (e.g. an `http` provider URL).
promptfoo's telemetry, update checks and sharing are switched off.

Remote generation: promptfoo normally generates attacks on its hosted service
(`api.promptfoo.app`). `remoteGeneration = false` (default) sets
`PROMPTFOO_DISABLE_REDTEAM_REMOTE_GENERATION=true`, so the attacks are
generated by your own `generator` model through the gateway. The attacks are
then less varied than with the hosted service, and plugins and strategies that
exist only on the hosted service (`hijacking`, `ssrf`, `bola`, `off-topic`,
`jailbreak:composite`, `jailbreak:likert`, `citation`, `gcg`, `best-of-n`,
`goat`, ...) are rejected by an assertion unless `remoteGeneration = true`. `true` sends the plugin list and
the `purpose` to promptfoo's servers and needs internet for the run.

`nestlo-eval` runs `promptfoo eval`: with no `-c` and no `evalConfig`, a small
generated suite (instruction injected in quoted content, system prompt leak,
shell-command request, a plain control question) against `target`.

Both exit 0 when promptfoo ran, even if attacks succeeded (promptfoo's exit
status 100 is a result, not a crash). `maxFailureRatePercent` turns a failure
rate above the limit into exit 1. The summary has passed/failed/errors overall
and per plugin.

Schedule: `promptfoo.schedule.enable = true` creates `nestlo-redteam.timer`
(`onCalendar`, default `weekly`, persistent, up to 1 h random delay) that starts
`nestlo-redteam.service`.

| Option | Default |
|--------|---------|
| `promptfoo.enable` | `false` |
| `promptfoo.package` | `pkgs.promptfoo` |
| `promptfoo.agentId` / `budgetUsd` | `redteam` / `10` |
| `promptfoo.target` / `generator` | `{ api = "anthropic"; model = "claude-sonnet-4-6"; }` / `{ api = "openai"; model = "gpt-4o"; maxTokens = 4096; }` |
| `promptfoo.purpose` | a general coding assistant that must not leak instructions, credentials or personal data |
| `promptfoo.plugins` / `strategies` | see above |
| `promptfoo.numTests` / `maxConcurrency` | `5` / `2` |
| `promptfoo.remoteGeneration` | `false` |
| `promptfoo.extraRedteamConfig` | `{ }` |
| `promptfoo.evalConfig` | `null` (generated suite) |
| `promptfoo.maxFailureRatePercent` | `null` |
| `promptfoo.schedule.enable` / `onCalendar` | `false` / `weekly` |

nixpkgs' promptfoo is 0.118.x, older than the upstream documentation; plugin and
strategy names are those of that line (`prompt-injection`, not the later
`jailbreak-templates`).

## agent-scan: `nestlo-agent-scan`

```
nestlo-agent-scan [--path FILE_OR_DIR]... [--skills-dir DIR]... [--no-defaults]
                  [--no-skills] [--fail-on high|medium|low|never] [--json] [--no-emit]
                  [--inspect] [--remote]
```

Exit status 0: no finding at or above `failOn` (default `high`); 1: findings;
2: usage error or a mode that is not enabled. `--no-defaults --path FILE` checks
one file and is the admission check for a new MCP server or skill before it is
added.

**What is scanned.** The MCP server lists Nestlo writes
(`/etc/nestlo/mcp-tools.json` from `nestlo.mcp-registry`, including the skill
packs' servers, and `/etc/nestlo/mcp-servers.json` from `nestlo.mcp-servers`),
`extraPaths` (agent CLI configs such as `~/.claude.json`, `.mcp.json`), and the
skill bundle that `nestlo.skills` installs (found through
`/etc/nestlo/skills.json`) plus `skillDirs`. Disabled servers are ignored.

**What is checked (local rules, no network).** Rule ids are also what
`ignoreRules` takes:

| Rule | Severity | Finds |
|------|----------|-------|
| `hidden-unicode` | high | zero-width, bidi-control and Unicode tag characters (instructions the user cannot see) |
| `instruction-override` | high | "ignore previous instructions" and variants |
| `hidden-instruction-tag` | high | `<IMPORTANT>`, `<system>`, `[SYSTEM]` blocks addressed to the model |
| `concealment` | high | "do not tell the user", "without informing the user" |
| `sensitive-file-access` | high | directions to read or send `~/.ssh`, `id_rsa`, `.env`, `/etc/passwd`, credentials |
| `exfiltration` | high | directions to send data to a URL, webhook or address |
| `tool-shadowing` | high | descriptions that claim priority over, or change the use of, other tools |
| `remote-exec` | high | `curl ... \| sh`, `base64 -d \| sh` in descriptions, commands or skills |
| `encoded-payload` | medium | very long base64-looking blobs |
| `model-addressing` | medium | "you must always first ..." inside a description |
| `toxic-flow` | medium | one config with a server that reads untrusted content (fetch, browser, GitHub, Slack...), one that reaches private data (filesystem, databases...) and one that can send data out; roles via `flowRoles` |
| `plain-http` | medium | remote MCP server over `http://` (not loopback) |
| `inline-secret` | medium | literal secret in a server's `env` (use `${VAR}`) |
| `unpinned-package` | low | `npx`/`uvx` without a version (a later release is run unreviewed) |
| `unreadable-config`, `inspect-failed`, `remote-analysis` | medium/high | the scan itself could not complete |

These are pattern rules over the text of configs, descriptions and skill files:
they catch the published tool-poisoning and injection patterns, not novel
phrasing, and a skill that quotes an attack string legitimately (a security
skill) is flagged: use `ignorePaths`. They do not replace review.

**Live inspection (`inspect = true`, default off).** MCP servers can change
their tool descriptions after you reviewed the config. With `inspect`, the unit
writes a plain `mcpServers` file of the enabled servers, runs
`snyk-agent-scan inspect --json --dangerously-run-mcp-servers`, and lints the
descriptions it returns with the same rules. This **executes the servers'
commands** (`npx -y ...`, `uvx ...`), so it needs internet, runs with network
and the servers' dependencies on `PATH`, and trusts Nestlo's registries.
`snyk-agent-scan inspect` itself contacts nothing but the servers
(verified in the source: `run_scan` stops after inspection in `inspect` mode;
the only network code besides the MCP clients is the analysis/push pipeline).

**Remote analysis (`remote.enable`, default off).** `snyk-agent-scan scan`
**always** sends its results to Snyk's Agent Scan API (default
`https://api.snyk.io/hidden/mcp-scan/analysis-machine`) and needs a Snyk API
token: it has no local-only analysis mode. mcp-scan, its predecessor, did the
same against Invariant Labs' API. Nestlo therefore does not run `scan` unless
you set `agentScan.remote.enable`, `remote.acceptDataSharing = true` (an
assertion) and `remote.tokenFile`. What leaves the machine, per the upstream
README and source (`verify_api.py`, `redact.py`): agent application details
(which agent clients are installed), the MCP server configurations and
signatures (command, arguments, URLs; environment variable values, headers,
secret-looking arguments and URL query values are redacted before sending),
the names and descriptions of tools, prompts and resources fetched from the
servers, the content of skill files, home-relative config paths, and information about the scanning
user and environment (`ScanUserInfo` in the source). It is covered by Snyk's
[terms for Agent Scan](https://github.com/snyk/agent-scan/blob/main/TERMS.md)
(Invariant Labs AG). With `remote.enable`, the scan also starts the servers
(`--dangerously-run-mcp-servers`; `--ci` needs it). `remote.analysisUrl`
points the client at another endpoint if you run a compatible one.
Nothing else in this module contacts Snyk.

**Unit.** `nestlo-agent-scan.service` (oneshot) runs the check at boot
(`scanOnBoot`, default on) and from `nestlo-agent-scan.timer` (`daily`). A
failing check leaves the unit `failed`. `gateUnits` makes other services depend
on it (`requires` + `after`), so they do not start while the check fails:

```nix
nestlo.agentSecurity.agentScan.gateUnits = [ "nestlo-orchestrator" ];
```

| Option | Default |
|--------|---------|
| `agentScan.enable` | `false` |
| `agentScan.package` | `snyk-agent-scan` 0.6.8 built from the PyPI sdist (`nixos/packages/agent-scan.nix`) |
| `agentScan.mcpConfigs` | `/etc/nestlo/mcp-tools.json`, `/etc/nestlo/mcp-servers.json` |
| `agentScan.extraPaths`, `skillDirs` | `[ ]` |
| `agentScan.skills`, `maxSkillFiles` | `true`, `5000` |
| `agentScan.failOn` | `high` |
| `agentScan.ignoreRules`, `ignorePaths`, `flowRoles` | none |
| `agentScan.inspect`, `serverTimeoutSec`, `timeoutSec` | `false`, `30`, `900` |
| `agentScan.remote.enable`, `acceptDataSharing`, `tokenFile`, `analysisUrl` | `false`, `false`, `null`, Snyk's endpoint |
| `agentScan.scanOnBoot` | `true` |
| `agentScan.schedule.enable` / `onCalendar` | `true` / `daily` |
| `agentScan.gateUnits` | `[ ]` |

## PR-Agent: `nestlo-pr-review`

```
nestlo-pr-review OWNER/REPO NUMBER [--dry-run] [--command review|describe|improve]...
nestlo-pr-review PULL_REQUEST_URL
nestlo-pr-review --auto            # what the timer runs
nestlo-pr-review --warm            # fetch PR-Agent into the cache (needs internet)
```

PR-Agent talks to its model through litellm. The wrapper sets
`OPENAI__API_BASE=http://127.0.0.1:<port>/agent/pr-review:<token>/<provider>/v1`
and a dummy `OPENAI__KEY`, so every model call goes through the gateway as
agent `pr-review` (budget `prReview.budgetUsd`, default 5). `CONFIG__MODEL` is
`prReview.model` (default `gpt-4o`); no fallback models are configured, so a
refused call (budget spent) fails the review instead of switching model.
`gatewayProvider` can be any gateway provider that offers
`v1/chat/completions` (OpenAI-compatible, or `anthropic` through its
OpenAI-compatible endpoint; set `model` to `openai/<name>` for a name litellm would send to another vendor); `maxTokens` sets the context size for models litellm
does not know. The GitHub token (`github.tokenFile`, default
`nestlo.git-automation.publish.tokenFile`) goes to PR-Agent as
`GITHUB__USER_TOKEN`; the units receive it as a systemd credential. Anything
else PR-Agent supports (`.pr_agent.toml` in the repository, `--pr_reviewer.*`
settings) works as usual. `publish = true` posts the review as comments;
`--dry-run` does not.

**Automatic review of factory pull requests.** `auto.enable = true` creates
`nestlo-pr-review.timer` (every `auto.interval`, default 10 min). Each run lists
the open pull requests of `prReview.repos` (default: the repositories under
`nestlo.git-automation.publish.repos`, i.e. where the publisher opens PRs),
selects those whose head branch starts with `auto.branchPrefix` (default
`nestlo.git-automation.branchPrefix`, `agent/`, the branches the publisher
pushes; drafts only with `auto.drafts`), skips heads already reviewed
(`pr-review/seen.json`) and reviews at most `auto.maxPerRun` (5). The publisher,
the factory and the triggers are not changed; the review is a separate reader
of the same pull requests. Nothing is merged or approved: PR-Agent only posts
comments.

**Packaging.** PR-Agent needs Python 3.12 or newer and pins about 60 packages
(litellm 1.103, opentelemetry, langfuse, tiktoken, ...) that nixpkgs does not
have, so it is not built by Nix. `nixos/packages/pr-agent.nix` is a pinned `uvx`
launcher (`pr-agent==0.47.0` on nixpkgs' Python 3.13), the pattern of
`mkUvxLauncher` in `agents/default.nix`. The first run downloads the release
into `/var/lib/nestlo-agent-security/uv-cache` (run `nestlo-pr-review --warm`
once with internet); later runs reuse the cache. tiktoken fetches its encodings
from the internet on first use (cached under `tiktoken/`), and litellm is told
to use its bundled model price list (`LITELLM_LOCAL_MODEL_COST_MAP`).

| Option | Default |
|--------|---------|
| `prReview.enable` | `false` |
| `prReview.package` | uvx launcher of PR-Agent 0.47.0 |
| `prReview.agentId` / `budgetUsd` | `pr-review` / `5` |
| `prReview.gatewayProvider` / `model` / `maxTokens` | `gatewayProviders.openai` / `gpt-4o` / `128000` |
| `prReview.commands` | `[ "review" ]` |
| `prReview.publish` | `true` |
| `prReview.extraInstructions` | `null` |
| `prReview.repos` | `nestlo.git-automation.publish.repos` names |
| `prReview.github.tokenFile` | `nestlo.git-automation.publish.tokenFile` |
| `prReview.apiUrl` / `webUrl` | `nestlo.git-automation.publish.apiUrl` / `https://github.com` |
| `prReview.auto.enable` | `false` |
| `prReview.auto.branchPrefix` | `nestlo.git-automation.branchPrefix` |
| `prReview.auto.interval` / `maxPerRun` / `drafts` | `10min` / `5` / `false` |

## Limits

- promptfoo's own execution, `snyk-agent-scan inspect` against live servers,
  Snyk's API and PR-Agent's litellm calls need internet or the real tools and
  are not covered by the VM test (`tests/agent-security.nix`, which stubs
  promptfoo and PR-Agent and checks the wiring, tokens, units and the local
  scanner).
- The `{{ env.* }}` templates in generated promptfoo configs assume promptfoo
  renders environment templates in provider settings, as its documentation
  shows for `apiKey`. The same URLs are also exported as `OPENAI_BASE_URL` and
  `ANTHROPIC_BASE_URL`, which promptfoo's providers read as defaults.
- The red team tests a model through the gateway, not a running Nestlo agent
  with its tools; excessive-agency results therefore measure what the model
  claims it can do.
- Gateway DLP can block or alter red-team prompts that contain secrets or
  personal-data patterns; the run then counts them as errors.
- Local agent-scan rules are heuristics. `remote.enable` adds Snyk's analysis
  and sends the data listed above; it is the only way to get it.
- Audit events need the three `security.*` types added to the audit writer.
- PR-Agent's first run and tiktoken's first use need internet.
