## NixOS options

```nix
agentos.orchestration.enable = true;
agentos.git-automation.publish = {
  tokenFile = "/run/secrets/github-token";
  repos."acme/widgets".workspaces = [ "widgets" ];
};
agentos.triggers = { enable = true; secretFile = "/run/secrets/webhook-secret"; };

agentos.factory = {
  enable = true;
  lines.web = {
    repo = "acme/widgets";
    workspace = "widgets";
    verify = [ "make" "test" ];
    roles.qa = { };                 # QA against the acceptance criteria
    intake.github = { };            # label "factory:web" on an issue starts an item
  };
};
```

`agentos.factory`:

| Option | Default | Meaning |
|---|---|---|
| `enable` | false | Run `agentos-factory.service` and install the `agentos-factory` CLI |
| `tickSec` | 5 | How often the factory looks for work to advance |
| `leaseSec` | 300 | Ownership of a step before another tick may pick it up (crash recovery) |
| `itemTtlDays` | 90 | How long finished items are kept |
| `metricsPort` | 9960 | Prometheus metrics on 127.0.0.1 |
| `lines.<name>` | none | One line per repository and set of roles (below) |

`agentos.factory.lines.<name>`:

| Option | Default | Meaning |
|---|---|---|
| `repo` | required | `owner/name`; must be in `agentos.git-automation.publish.repos` |
| `workspace` | required | Workspace holding a checkout |
| `mode` | `supervised` | `supervised` (PR for a human), `approval-first` (every plan is approved first), `dark` (auto-merge) |
| `maxInFlight` | 2 | Items worked on at once |
| `maxOpenPRs` | 5 | No new item starts while this many PRs of the line are open |
| `maxFixRounds` | 3 | Review/QA fix iterations before the item is blocked |
| `budgetUSDPerItem` | 20 | Spend after which an item is blocked |
| `verify` | `[]` | Argument vector run in the worktree (no shell) |
| `qaVerify` | `[]` | Extra argument vector for QA |
| `planApproval` | `large` | `never`, `always` or `large`: when a plan waits for an operator |
| `skipReviewForSmall` | false | No reviewer for small changes |
| `enforceScope` | false | Fail items whose diff leaves the plan's declared scope |
| `isolation` | null | Isolation profile for the line's tasks |
| `roles.planner` / `builder` / `reviewer` | claude; opus-5-5 / sonnet-5-5 / opus-5-5 | `agent`, `model`, `budgetUSD`, `timeoutSec`; the agent needs an entry in `agentos.orchestration.taskCommands` |
| `roles.qa` | null (no QA) | Same sub-options; `{ }` enables QA with the defaults |
| `intake.github` | null | `{ }` takes issues labelled `factory:<name>` from `repo` (`label` and `repo` can be set) |
| `paused` | false | Take no new work; running items finish |

Settings are written to the `[factory]` table of `/etc/agentos/services.toml`
(`socket`, `orchestrator_socket`, `tick_sec`, `lease_sec`, `item_ttl_days`,
`metrics_port`, `lines.<name>.*` in snake_case).

### Dark mode

`dark` merges a pull request without a human. The build is refused unless:

- `agentos.git-automation.publish.repos."<repo>".allowAutoMerge = true`,
- `verify` is not empty (something objective proves the change works),
- the `qa` role is set (the acceptance criteria are checked), and
- `planApproval` is not `never` or `enforceScope = true`: a human approves
  the plan, or a hard scope guard bounds what an unattended merge can touch.

### GitHub intake

With `intake.github` set, a rule `factory-<name>` is added to
`agentos.triggers.rules` (event `issues`, actions `opened` and `labeled`, the
intake label, `factory = "<name>"`). Define a rule with that name yourself to
replace it. A rule with `factory` posts `{line, title, body, source}` to the
factory instead of submitting a task; trust (`trustedAssociations`,
`trustLabeler`), text sanitising and delivery de-duplication are unchanged.
`agentos.triggers.enable` is still needed for the webhook listener.

### Monitoring

Prometheus scrapes `agentos-factory` on `metricsPort`. Series:
`agentos_factory_items{line,state}`, `agentos_factory_item_age_seconds{line,state}`,
`agentos_factory_cost_usd_total{line}`. Alerts `AgentOSFactoryBlocked` (blocked
items for 30 minutes), `AgentOSFactoryStuck` (an item in an active state not
updated for 2 hours; tune with `agentos.observability.alerts.factoryActiveStates`
and `factoryStuckSeconds`) and `AgentOSFactoryBudgetBurn`
(`factoryBudgetBurnUSDPerHour`), with runbooks in `docs/runbooks/`.
