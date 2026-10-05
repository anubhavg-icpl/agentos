"""Task policy: resolution and enforcement at submit.

The NixOS module `nestlo.policy` compiles a typed policy into the [policy]
table of services.toml:

    [policy]
    version = "<hash of the compiled policy>"
    [policy.default]            # keys below; absent = unrestricted
    [policy.repos."owner/name"] # overrides the default key by key

Keys: budget_usd, daily_budget_usd, allowed_agents, allowed_models,
routing {model: model}, require_approval {mode, threshold_usd},
max_parallel, max_retries, isolation, publish_enable.

A task resolves to the first of its candidate names (origin repo, publish
repo, workspace name) that has an entry in `repos`, else to "default". When
no [policy] table exists nothing is enforced.
"""

import hashlib
import json
import re

KEYS = ("budget_usd", "daily_budget_usd", "allowed_agents", "allowed_models", "routing",
        "require_approval", "max_parallel", "max_retries", "isolation", "publish_enable")
APPROVAL_MODES = ("never", "always", "publish", "costAbove")

_ORIGIN_REPO = re.compile(r"^gh:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#")


class PolicyError(Exception):
    """A task the policy refuses. `rule` names the policy entry and key."""

    def __init__(self, rule, message):
        super().__init__("policy violation [%s]: %s" % (rule, message))
        self.rule = rule


class Policy:
    def __init__(self, section):
        section = section or {}
        self.enabled = bool(section)
        self.default = dict(section.get("default") or {})
        self.repos = {k: dict(v) for k, v in (section.get("repos") or {}).items()}
        self.version = section.get("version") or hashlib.sha256(json.dumps(
            {"default": self.default, "repos": self.repos}, sort_keys=True).encode()).hexdigest()[:12]

    @classmethod
    def from_config(cls, cfg):
        return cls(cfg.get("policy"))

    # ── resolution ─────────────────────────────────────────────────────
    def effective(self, name):
        """The default with the entry `name` on top; nested tables (require_approval,
        routing, publish) merge key by key, so an entry that sets only a threshold
        keeps the default approval mode."""
        return _deep_merge(json.loads(json.dumps(self.default)), json.loads(json.dumps(self.repos.get(name) or {})))

    def resolve(self, candidates):
        """(name, effective policy) for the first candidate with an entry."""
        for name in candidates:
            if name in self.repos:
                return name, self.effective(name)
        return "default", self.effective("default")

    def show(self, repo=None):
        """The effective policy for a repository or workspace name, for `policy show`."""
        name, eff = self.resolve([repo] if repo else [])
        return {"enabled": self.enabled, "name": name, "version": self.version,
                "matched": name != "default" or not repo, "policy": eff,
                "repos": sorted(self.repos)}


def _deep_merge(base, top):
    for key, value in top.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            _deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def candidates(fields, workspace_root):
    """Names a task may be governed by: origin repo, publish repo, workspace name."""
    out = []
    m = _ORIGIN_REPO.match(fields.get("origin") or "")
    if m:
        out.append(m.group(1))
    repo = (fields.get("publish") or {}).get("repo")
    if repo:
        out.append(repo)
    ws, root = fields.get("workspace") or "", (workspace_root or "").rstrip("/")
    if root and ws.startswith(root + "/"):
        out.append(ws[len(root) + 1:].split("/", 1)[0])
    return out


def utc_day_start(now):
    return now - (now % 86400)


def enforce(eff, name, version, fields, runtime, spent_today=0.0, reserved=0.0, count=1, judge=False):
    """Apply policy `eff` (entry `name`) to validated task fields.

    Mutates `fields` (budget, retries, gate, model) and returns the record to
    store on the task as `policy`. Raises PolicyError for a refusal.
    `spent_today` is the budget already committed today under this entry,
    `reserved` what earlier tasks of this request commit, `count` how many
    tasks this call creates."""
    rule = lambda key: "%s.%s" % (name, key)       # noqa: E731
    applied = []

    if fields.get("kind") == "publish":
        # A publish task runs no agent and spends no budget: only the publish
        # rules apply (agent, model and budget rules would act on placeholders)
        if eff.get("publish_enable") is False:
            raise PolicyError(rule("publish.enable"), "publishing a pull request is not allowed")
        ra = eff.get("require_approval") or {}
        mode = ra.get("mode", "never")
        if mode not in APPROVAL_MODES:
            raise PolicyError(rule("require_approval"), "unknown mode %r" % mode)
        if mode in ("always", "publish") and not fields.get("gate"):
            fields["gate"] = True
            applied.append("gate forced by require_approval=%s" % mode)
        return {"name": name, "version": version, "applied": applied,
                "max_parallel": eff.get("max_parallel")}

    agents = eff.get("allowed_agents")
    if agents is not None and fields["agent"] not in agents:
        raise PolicyError(rule("allowed_agents"), "agent %r is not allowed (allowed: %s)" % (
            fields["agent"], ", ".join(agents) or "none"))

    cap = eff.get("budget_usd")
    budget = fields.get("budget_usd")
    if cap is not None and (budget is None or budget > cap):
        applied.append("budget_usd capped at %s" % cap)
        fields["budget_usd"] = budget = float(cap)

    if judge:
        # A judge only needs the agent and budget rules; its swarm is gated already
        return {"name": name, "version": version, "applied": applied}

    iso = eff.get("isolation")
    if iso == "container" and runtime.get("default_isolation", "sandbox") != "container":
        raise PolicyError(rule("isolation"), "container isolation is required but the host runs agents in a sandbox")

    publishing = fields.get("publish") is not None or fields.get("kind") == "publish"
    if publishing and eff.get("publish_enable") is False:
        raise PolicyError(rule("publish.enable"), "publishing a pull request is not allowed")

    model = fields.get("model")
    if model is not None:
        routed = (eff.get("routing") or {}).get(model)
        if routed:
            applied.append("routing: model %s -> %s" % (model, routed))
            fields["model"] = model = routed
        models = eff.get("allowed_models")
        if models is not None and model not in models:
            raise PolicyError(rule("allowed_models"), "model %r is not allowed (allowed: %s)" % (
                model, ", ".join(models) or "none"))

    daily = eff.get("daily_budget_usd")
    if daily is not None:
        left = float(daily) - spent_today - reserved
        if budget is None:
            budget = fields["budget_usd"] = max(0.0, left / count)
            applied.append("budget_usd set to the daily remainder")
        if budget * count > left + 1e-9:
            raise PolicyError(rule("daily_budget_usd"), "$%.2f/day exceeded: $%.2f committed today, %d task(s) of $%.2f requested" % (
                daily, spent_today + reserved, count, budget))

    retries = eff.get("max_retries")
    if retries is not None and fields.get("max_retries", 0) > retries:
        applied.append("max_retries capped at %d" % retries)
        fields["max_retries"] = retries

    ra = eff.get("require_approval") or {}
    mode = ra.get("mode", "never")
    if mode not in APPROVAL_MODES:
        raise PolicyError(rule("require_approval"), "unknown mode %r" % mode)
    gate = (mode == "always"
            or (mode == "publish" and publishing)
            or (mode == "costAbove" and (budget is None or budget > float(ra.get("threshold_usd", 0)))))
    if gate and not fields.get("gate"):
        fields["gate"] = True
        applied.append("gate forced by require_approval=%s" % mode)

    return {"name": name, "version": version, "applied": applied,
            "max_parallel": eff.get("max_parallel")}


def day_spent(tasks, name, now):
    """Budget committed today (UTC) to tasks admitted under policy entry `name`."""
    start = utc_day_start(now)
    total = 0.0
    for t in tasks:
        pol = t.get("policy") or {}
        if pol.get("name") == name and t.get("created_at", 0) >= start and t.get("status") not in ("cancelled", "skipped") \
                and t.get("role") != "judge" and t.get("kind") != "publish":
            total += float(t.get("budget_usd") or 0)
    return total
