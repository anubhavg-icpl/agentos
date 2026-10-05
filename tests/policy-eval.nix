# Eval-only check for nestlo.policy and nestlo.rbac. Nothing is built or
# booted: a violation makes evaluation fail.
#
#   nix build .#checks.x86_64-linux.policy-eval
#
#   - a valid policy evaluates, its assertions hold, and it compiles into
#     services.toml with a version hash
#   - a deliberately invalid policy (negative budget, unknown agent, model
#     missing from pricing.json, costAbove without a threshold, container
#     isolation on a sandbox host) trips one assertion each
#   - nestlo.rbac defaults keep the nestlo group as admins
{ pkgs, host }:

let
  inherit (pkgs) lib;

  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);
  with' = policy: host.extendModules { modules = [{ nestlo.policy = { enable = true; } // policy; }]; };

  valid = with' {
    default = { budgetUsd = 20; dailyBudgetUsd = 100; maxRetries = 2; };
    repos."acme/widgets" = {
      budgetUsd = 5;
      allowedAgents = [ "claude" "codex" ];
      allowedModels = [ "claude-sonnet-5-5" ];
      routing."claude-opus-5-5" = "claude-sonnet-5-5";
      requireApproval = { mode = "costAbove"; thresholdUsd = 3; };
      maxParallel = 2;
      publish.enable = true;
    };
    repos.scratch.requireApproval.mode = "always";
  };

  invalid = with' {
    default = { budgetUsd = -1; };
    repos."acme/widgets" = {
      allowedAgents = [ "no-such-agent" ];
      allowedModels = [ "no-such-model" ];
      requireApproval.mode = "costAbove";
      isolation = "container";
    };
  };

  messages = failing invalid;
  mentions = s: lib.any (m: lib.hasInfix s m) messages;
  settings = valid.config.nestlo.services.settings;
  roles = valid.config.nestlo.rbac.roles;
in
assert lib.assertMsg (failing valid == [ ]) "valid policy: assertions fail: ${toString (failing valid)}";
assert lib.assertMsg
  (settings.policy.version == valid.config.nestlo.policy.version
    && builtins.stringLength settings.policy.version == 12)
  "policy version is not the compiled hash";
assert lib.assertMsg
  (settings.policy.repos."acme/widgets".require_approval.threshold_usd == 3
    && settings.policy.repos."acme/widgets".budget_usd == 5
    && settings.policy.default.max_retries == 2
    # entries are compiled with the defaults they inherit
    && settings.policy.repos."acme/widgets".max_retries == 2
    && settings.policy.repos.scratch.budget_usd == 20)
  "policy did not compile into services.toml";
assert lib.assertMsg
  (roles.admin.groups == [ "nestlo" ] && settings.rbac.separate_approver == false)
  "rbac defaults changed: operators in the nestlo group must stay admins";
assert lib.assertMsg (mentions "must be positive (got -1)") "negative budget was not caught: ${toString messages}";
assert lib.assertMsg (mentions "unknown agent no-such-agent") "unknown agent was not caught: ${toString messages}";
assert lib.assertMsg (mentions "no-such-model is not in the pricing file") "unknown model was not caught: ${toString messages}";
assert lib.assertMsg (mentions "needs thresholdUsd") "costAbove without threshold was not caught: ${toString messages}";
assert lib.assertMsg (mentions "isolation = \"container\"") "container isolation was not caught: ${toString messages}";
pkgs.runCommand "nestlo-policy-eval" { } "touch $out"
