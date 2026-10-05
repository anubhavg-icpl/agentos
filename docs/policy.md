# Policy-as-code and RBAC

Two NixOS options govern the orchestrator (`agentos-task`, the scheduler, the triggers and the OpenClaw bridge all go through its socket):

- `agentos.policy`: a typed policy per repository or workspace. Contradictions fail `nixos-rebuild` with an assertion; the orchestrator enforces the compiled policy when a task is submitted.
- `agentos.rbac`: who may do what on the socket (viewer, submitter, approver, admin), mapped from unix groups.

Code: `services/agentos_services/policy.py`, `rbac.py`, `orchestrator.py`; module `modules/policy`; checks `services/tests/test_policy.py` and `checks.<system>.policy-eval`.

## Policy

```nix
agentos.policy = {
  enable = true;                         # needs agentos.orchestration.enable

  default = {                            # tasks that match no entry below
    budgetUsd = 20;                      # cap on one task's budget
    maxRetries = 2;
    allowedAgents = [ "claude" "codex" "aider" ];
  };

  repos."acme/widgets" = {               # owner/name, or a workspace name
    budgetUsd = 5;
    dailyBudgetUsd = 25;                 # budgets committed per UTC day
    allowedModels = [ "claude-sonnet-5-5" ];
    routing."claude-opus-5-5" = "claude-sonnet-5-5";
    requireApproval = { mode = "costAbove"; thresholdUsd = 3; };
    maxParallel = 2;
    isolation = "container";             # needs agentos.runtime.defaultIsolation = "container"
    publish.enable = true;
  };

  repos.scratch.requireApproval.mode = "always";
};
```

Fields left unset inherit from `default`; a null/unset `default` field means unrestricted.

| Field | Enforced as |
|---|---|
| `budgetUsd` | A task's `budget_usd` is lowered to the cap; a task with no budget gets the cap. |
| `dailyBudgetUsd` | Sum of `budget_usd` committed to tasks of the entry since 00:00 UTC (a swarm counts all members). A submit that does not fit is refused with 403. This is committed budget, not metered spend; the gateway's per-agent daily budgets still meter real spend. |
| `allowedAgents` | Other agents are refused (403). The judge of a swarm is checked too. |
| `allowedModels` | A task's optional `model` field must be listed (403). A task that names no model is not restricted: the agent chooses its model and only the gateway sees it. Use gateway routing (`agentos.budget-controller.routing`) to constrain what is actually served. |
| `routing` | Rewrites a task's `model`. For `default`, also merged into the gateway's global `routing.rewrites` at default priority. Per-repository rewrites are not pushed to the gateway, which routes per agent id, not per repository. |
| `requireApproval.mode` | `never`; `always`; `publish` (the task has a `publish` block); `costAbove` (budget above `thresholdUsd`, or no budget). The orchestrator sets `gate`, so the task waits in `awaiting_approval`. A policy never removes a gate a submitter asked for. |
| `maxParallel` | At most N running tasks per policy entry. Implemented in the scheduling loop like a concurrency key with a limit above one. |
| `maxRetries` | `--retries` is lowered to the cap. |
| `isolation` | `container` refuses tasks unless the host runs agents in containers. Tasks run with the host's `defaultIsolation`; there is no per-task isolation choice. |
| `publish.enable` | `false` refuses tasks with a `publish` block. |
| egress | No per-policy option. The egress firewall (`agentos.security`) is per host and per agent user, not per task or repository, so a per-repository allowlist cannot be enforced; set `agentos.security.allowedEgressDomains` instead. |

### Resolution

A task is governed by the first entry of `repos` that matches, in this order: the repository of its `origin` (`gh:owner/name#42`, set by the triggers), `publish.repo`, then the workspace name. Otherwise by `default`. A refusal looks like:

```
403 policy violation [acme/widgets.allowed_models]: model 'gpt-4o' is not allowed (allowed: claude-sonnet-5-5)
```

### Evaluation-time checks

Assertions fail the build for: non-positive budgets, `budgetUsd` above `dailyBudgetUsd`, agents missing from `agentos.runtime.agents`, models (or routing targets) missing from `pricing.json`, a routing target that `allowedModels` does not list, `costAbove` without a threshold (or a threshold on another mode, or one not below `budgetUsd`), empty allow lists, `maxRetries` above `agentos.orchestration.maxRetries`, container isolation on a sandbox host, and malformed entry names.

### Version and provenance

The module compiles the policy into the `[policy]` table of `/etc/agentos/services.toml` and `version` is the first 12 hex digits of the SHA-256 of that compiled policy (`config.agentos.policy.version`). Each task stores:

```json
"policy": {"name": "acme/widgets", "version": "3f9a1c0b7d2e", "applied": ["budget_usd capped at 5"], "max_parallel": 2}
```

`applied` lists what the policy changed. The orchestrator restarts with the new version after a rebuild, so tasks from before a change keep the old version.

```sh
agentos-task policy show               # the default policy
agentos-task policy show acme/widgets  # the effective policy for a repository or workspace
```

## RBAC

The caller is identified by `SO_PEERCRED` (kernel-supplied uid, gid and pid); groups are the primary and supplementary groups, including the ones systemd grants with `SupplementaryGroups=`, read from `/proc/<pid>/status`.

| Role | May |
|---|---|
| viewer | list and show tasks, groups, workflows, the policy |
| submitter | viewer, plus submit tasks and workflows, cancel tasks it submitted |
| approver | viewer, plus approve and reject gated tasks |
| admin | everything, including cancelling other users' tasks |

uid 0 is always admin. `GET /health` is open to anyone who can reach the socket. A caller with no role is refused everywhere (403, naming the roles that would work).

```nix
agentos.rbac = {
  roles.viewer.groups = [ "auditors" ];
  roles.submitter.groups = [ "developers" ];
  roles.approver.groups = [ "tech-leads" ];
  roles.admin.users = [ "alice" ];
  separateApprover = true;       # four eyes
};
```

Defaults: `roles.admin.groups = [ "agentos" ]`, so operators in the `agentos` group, the scheduler, the triggers and the OpenClaw bridge (whose unit has `SupplementaryGroups = agentos`) keep today's behaviour. The socket itself stays mode 0660 group `agentos`: roles narrow what its callers may do, they do not widen who can connect. Every caller on the socket is in the `agentos` group, so with the default every caller is an admin. To narrow someone, move the admin role to a dedicated group (`roles.admin.groups = [ "agentos-admins" ]`) and list the other callers under `submitter`, `approver` or `viewer`; services such as the scheduler, triggers and the bridge need `submitter`.

`separateApprover = true`: nobody, admins included, may approve or reject a task they submitted (`submitted_by`). The decision of a second person is recorded on the task (`approval.by`, `at`, `note`). Tasks created by internal callers without a peer (no unix socket client) have `submitted_by` unset, so `separateApprover` does not restrict who decides them; tasks from `agentos-task`, OpenClaw and the triggers always carry a submitter.

```sh
agentos-task whoami      # user, groups, roles
```

## Standards mapping

These options are controls that support an assessment; they do not make a deployment compliant by themselves.

**EU AI Act, Article 14 (human oversight).**

| Art. 14 | Control |
|---|---|
| 14(4)(a), (c) understand and interpret the system's operation | `agentos-task show` and `policy show` state what ran, under which policy and version, and what the policy changed (`applied`). |
| 14(4)(b) automation bias | `requireApproval` holds tasks by rule (all, publishing, or above a cost) instead of leaving gating to the submitter. |
| 14(4)(d) decide not to use the output, override | Approvers reject or approve with a note; `publish` gating stops an agent's branch from becoming a pull request without review. |
| 14(4)(e) intervene, stop | `cancel` (own tasks for submitters, any for admins) stops a running task; budgets and `maxParallel` bound what runs unattended. |
| 14(3) measures commensurate with risk | Per-repository policy sets stricter approval and limits where the risk is higher. |

**ISO/IEC 27001:2022, Annex A 5.15 (access control)** and related 5.3 (segregation of duties), 5.18 (access rights), 8.2 (privileged access).

| Requirement | Control |
|---|---|
| Rules based on business and security requirements | The policy and role tables are declared in version-controlled Nix and checked at evaluation. |
| Least privilege, need to know | Four roles; viewers cannot change anything; submitters cannot approve; only admins act on others' tasks. |
| Segregation of duties | `separateApprover`: the person who submits a task is not the one who approves it. |
| Authenticated identity | Kernel-supplied `SO_PEERCRED`; no tokens or passwords on the socket. |
| Review and revocation of access | Membership is unix group membership; `whoami` shows the effective roles; removing a user from the group revokes access on the next request. |
| Audit | Tasks record `submitted_by`, `approval` and `policy`. |

## Limitations

- `allowedModels` only constrains tasks that declare a `model`; it does not inspect what an agent requests from the gateway.
- `dailyBudgetUsd` counts committed budgets of tasks recorded in Redis (retained 30 days), not metered spend.
- `maxParallel` and the daily budget are per policy entry, and consider only tasks submitted while the entry applied.
- Direct access to the orchestrator's Redis or to the root task runner bypasses the policy; both are outside the agentos group's sockets.
