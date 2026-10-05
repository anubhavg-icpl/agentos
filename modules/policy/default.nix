# ═══════════════════════════════════════════════════════════════════════
# Nestlo Policy-as-code and RBAC Module
# ═══════════════════════════════════════════════════════════════════════
#
# nestlo.policy   typed, versioned task policy, checked at evaluation time
#                  and enforced by the orchestrator at submit
#                  (services/nestlo_services/policy.py, docs/policy.md)
# nestlo.rbac     roles on the orchestrator socket, mapped from unix
#                  groups through SO_PEERCRED (services/.../rbac.py)
#
# Both compile into /etc/nestlo/services.toml ([policy] and [rbac]).
# The policy version is a hash of the compiled policy; every task records
# the policy name and version it was admitted under.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.policy;
  rbac = config.nestlo.rbac;
  rt = config.nestlo.runtime;
  orch = config.nestlo.orchestration;

  num = lib.types.either lib.types.int lib.types.float;

  policyType = lib.types.submodule {
    options = {
      budgetUsd = lib.mkOption {
        type = lib.types.nullOr num;
        default = null;
        example = 5;
        description = "Cap on the budget of one task (USD). A task asking for more, or for none, gets this.";
      };
      dailyBudgetUsd = lib.mkOption {
        type = lib.types.nullOr num;
        default = null;
        example = 50;
        description = ''
          Cap on the budgets committed to tasks of this repository per UTC
          day (the sum of the tasks' budgets, not metered spend).
        '';
      };
      allowedAgents = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "claude" "codex" ];
        description = "Agents (keys of nestlo.runtime.agents) tasks may use; null allows all";
      };
      allowedModels = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "claude-sonnet-5-5" ];
        description = ''
          Models (pricing.json names) a task may request with its `model`
          field; null allows all. A task that names no model is not
          restricted by this list (see docs/policy.md).
        '';
      };
      routing = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        example = { "claude-opus-5-5" = "claude-sonnet-5-5"; };
        description = ''
          Model rewrites for tasks under this policy: a task's `model` is
          replaced as listed. For `nestlo.policy.default` the rewrites are
          also merged into the gateway's global routing rewrites (at
          default priority, so nestlo.budget-controller.routing wins).
        '';
      };
      requireApproval = {
        mode = lib.mkOption {
          type = lib.types.nullOr (lib.types.enum [ "never" "always" "publish" "costAbove" ]);
          default = null;
          description = ''
            When a task is held in awaiting_approval: "always", "publish"
            (tasks that open a pull request) or "costAbove" (budget above
            thresholdUsd, or no budget at all).
          '';
        };
        thresholdUsd = lib.mkOption {
          type = lib.types.nullOr num;
          default = null;
          description = "Budget (USD) above which mode = \"costAbove\" asks for approval";
        };
      };
      maxParallel = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "At most this many tasks of the policy run at once (a concurrency key with a limit)";
      };
      maxRetries = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 0 10);
        default = null;
        description = "Cap on a task's --retries";
      };
      isolation = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "sandbox" "container" ]);
        default = null;
        description = ''
          Minimum isolation. "container" refuses tasks unless the host runs
          agents in containers (nestlo.runtime.defaultIsolation).
        '';
      };
      publish.enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "false refuses tasks that ask for a pull request (`publish`)";
      };
      # Egress: the egress firewall (nestlo.security) is per host and per
      # agent user, not per task or repository, so there is no per-policy
      # allowlist. See docs/policy.md.
    };
  };

  # The set fields of a policy, nulls dropped
  setFields = p: lib.filterAttrs (_: v: v != null) {
    inherit (p) budgetUsd dailyBudgetUsd allowedAgents allowedModels routing maxParallel maxRetries isolation;
    requireApproval =
      let ra = lib.filterAttrs (_: v: v != null) p.requireApproval;
      in if ra == { } then null else ra;
    publish =
      let pb = lib.filterAttrs (_: v: v != null) p.publish;
      in if pb == { } then null else pb;
  };
  # The effective policy of a name: the default with the entry's set fields on top
  effective = p: lib.recursiveUpdate (setFields cfg.default) (setFields p);
  all = { default = cfg.default; } // cfg.repos;

  # snake_case keys for services.toml
  compile = e: lib.filterAttrs (_: v: v != null) {
    budget_usd = e.budgetUsd or null;
    daily_budget_usd = e.dailyBudgetUsd or null;
    allowed_agents = e.allowedAgents or null;
    allowed_models = e.allowedModels or null;
    routing = e.routing or null;
    require_approval =
      if e ? requireApproval then
        lib.filterAttrs (_: v: v != null)
          {
            mode = e.requireApproval.mode or null;
            threshold_usd = e.requireApproval.thresholdUsd or null;
          } else null;
    max_parallel = e.maxParallel or null;
    max_retries = e.maxRetries or null;
    isolation = e.isolation or null;
    publish_enable = e.publish.enable or null;
  };
  compiled = {
    default = compile (setFields cfg.default);
    repos = lib.mapAttrs (_: p: compile (effective p)) cfg.repos;
  };
  version = builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toJSON compiled));

  pricing = builtins.fromJSON (builtins.readFile config.nestlo.budget-controller.pricingFile);
  # pricing.json matches exactly or by longest prefix
  priced = m: lib.any (k: lib.hasPrefix k m) (lib.attrNames pricing.models);

  show = v: builtins.toJSON v;
  bad = name: msg: { assertion = false; message = "nestlo.policy[${name}]: ${msg}"; };
  checks = name: p:
    let e = effective p; in
    lib.optional (builtins.match "[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?" name == null)
      (bad name "name must be a workspace name or owner/name")
    ++ lib.concatMap
      (f: lib.optional (e ? ${f} && e.${f} <= 0)
        (bad name "${f} must be positive (got ${show e.${f}})"))
      [ "budgetUsd" "dailyBudgetUsd" ]
    ++ lib.optional (e ? budgetUsd && e ? dailyBudgetUsd && e.budgetUsd > e.dailyBudgetUsd)
      (bad name "budgetUsd (${show e.budgetUsd}) is above dailyBudgetUsd (${show e.dailyBudgetUsd}): no task could ever run")
    ++ lib.optional (e ? allowedAgents && e.allowedAgents == [ ])
      (bad name "allowedAgents is empty: every task would be refused")
    ++ map (a: bad name "allowedAgents: unknown agent ${a} (not in nestlo.runtime.agents)")
      (lib.filter (a: !(rt.agents ? ${a})) (e.allowedAgents or [ ]))
    ++ lib.optional (e ? allowedModels && e.allowedModels == [ ])
      (bad name "allowedModels is empty: every task naming a model would be refused")
    ++ map (m: bad name "allowedModels: ${m} is not in the pricing file")
      (lib.filter (m: !(priced m)) (e.allowedModels or [ ]))
    ++ lib.concatMap
      (m: map (x: bad name "routing: ${x} is not in the pricing file")
        (lib.filter (x: !(priced x)) [ m e.routing.${m} ]))
      (lib.attrNames (e.routing or { }))
    ++ lib.optional (e ? routing && e ? allowedModels
      && !(lib.all (t: lib.elem t e.allowedModels) (lib.attrValues e.routing)))
      (bad name "routing rewrites a model to one that allowedModels does not list")
    ++ lib.optional ((e.requireApproval.mode or null) == "costAbove" && !(e.requireApproval ? thresholdUsd))
      (bad name "requireApproval.mode = \"costAbove\" needs thresholdUsd")
    ++ lib.optional ((e.requireApproval.mode or "costAbove") != "costAbove" && e.requireApproval ? thresholdUsd)
      (bad name "requireApproval.thresholdUsd only applies to mode = \"costAbove\"")
    ++ lib.optional ((e.requireApproval.thresholdUsd or 1) <= 0)
      (bad name "requireApproval.thresholdUsd must be positive")
    ++ lib.optional ((e.requireApproval.mode or null) == "costAbove" && e ? budgetUsd
      && (e.requireApproval.thresholdUsd or 0) >= e.budgetUsd)
      (bad name "costAbove threshold is not below budgetUsd: approval could never be required")
    ++ lib.optional ((e.isolation or "sandbox") == "container" && rt.defaultIsolation != "container")
      (bad name "isolation = \"container\" needs nestlo.runtime.defaultIsolation = \"container\"")
    ++ lib.optional (e ? maxRetries && e.maxRetries > orch.maxRetries)
      (bad name "maxRetries (${show e.maxRetries}) is above nestlo.orchestration.maxRetries (${show orch.maxRetries})");

  roleType = lib.types.submodule {
    options = {
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Unix groups (primary, supplementary or systemd SupplementaryGroups) whose members have the role";
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Users who have the role";
      };
    };
  };
in
{
  options.nestlo.policy = {
    enable = lib.mkEnableOption "typed task policy, enforced by the orchestrator at submit";

    default = lib.mkOption {
      type = policyType;
      default = { };
      description = "Policy for tasks that match no entry of `repos`; the base the entries of `repos` override";
    };

    repos = lib.mkOption {
      type = lib.types.attrsOf policyType;
      default = { };
      example = lib.literalExpression ''{ "acme/widgets" = { budgetUsd = 5; requireApproval.mode = "publish"; }; }'';
      description = ''
        Policy per repository (`owner/name`, matched against the task's
        origin and `publish.repo`) or per workspace name. Fields left unset
        inherit from `default`.
      '';
    };

    version = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = version;
      description = "Hash of the compiled policy; recorded on every task";
    };
  };

  options.nestlo.rbac = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Check the caller's role on every orchestrator endpoint";
    };

    roles = lib.genAttrs [ "viewer" "submitter" "approver" "admin" ] (role: lib.mkOption {
      type = roleType;
      default = { };
      description = {
        viewer = "list and show tasks, groups and the policy";
        submitter = "viewer, plus submit tasks and workflows and cancel one's own";
        approver = "viewer, plus approve and reject gated tasks";
        admin = "everything, including cancelling other users' tasks";
      }.${role};
    });

    separateApprover = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Four eyes: nobody, admins included, may approve or reject a task they submitted";
    };
  };

  config = lib.mkMerge [
    {
      # Operators in the nestlo group (and the services that run in it)
      # keep today's behaviour: they are admins.
      nestlo.rbac.roles.admin.groups = lib.mkDefault [ "nestlo" ];

      nestlo.services.settings.rbac = {
        enable = rbac.enable;
        separate_approver = rbac.separateApprover;
        roles = lib.mapAttrs (_: r: { inherit (r) groups users; }) rbac.roles;
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = orch.enable;
          message = "nestlo.policy is enforced by the orchestrator; enable nestlo.orchestration";
        }
      ] ++ lib.concatLists (lib.mapAttrsToList checks all);

      nestlo.services.settings.policy = compiled // { inherit version; };

      # The gateway applies the default policy's model rewrites to all agents
      nestlo.services.settings.routing.rewrites =
        lib.mapAttrs (_: lib.mkDefault) (cfg.default.routing or { });
    })
  ];
}
