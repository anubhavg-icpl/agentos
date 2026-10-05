# ═══════════════════════════════════════════════════════════════════════
# AgentOS Factory Module
# ═══════════════════════════════════════════════════════════════════════
#
# A software factory on top of the orchestrator (services/agentos_services/
# factory.py, docs/factory.md). A work item (a GitHub issue or one made with
# `agentos-factory`) flows through one line:
#
#   planner -> builder -> verify -> reviewer -> fix loop -> QA against the
#   acceptance criteria -> pull request (supervised) or auto-merge (dark)
#
#   - every step is an orchestrator task, so it is sandboxed, metered by the
#     gateway and budgeted like any other task
#   - the service runs as `agentos` and only talks to the orchestrator
#     socket, the control-plane Redis and its own socket (group agentos)
#   - `dark` merges without a human; it is refused unless the repository
#     allows auto-merge, there is a verify command and a QA role, and a
#     human plan approval or a hard scope guard bounds the change
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.factory;
  orch = config.agentos.orchestration;
  publish = config.agentos.git-automation.publish;
  obs = config.agentos.observability;

  repoType = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+";

  roleType = defaults: lib.types.submodule {
    options = {
      agent = lib.mkOption {
        type = lib.types.str;
        default = defaults.agent or "claude";
        description = "Agent that plays the role; it needs an entry in agentos.orchestration.taskCommands";
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = defaults.model or null;
        description = "Model the role asks for (null: the agent's own default)";
      };
      budgetUSD = lib.mkOption {
        type = lib.types.either lib.types.int lib.types.float;
        default = defaults.budgetUSD or 5;
        description = "Daily budget of the role's agent in USD (enforced by the gateway)";
      };
      timeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = defaults.timeoutSec or 1800;
        description = "Timeout of one run of the role";
      };
    };
  };

  githubIntake = lineName: lineRepo: lib.types.submodule {
    options = {
      label = lib.mkOption {
        type = lib.types.str;
        default = "factory:${lineName}";
        defaultText = lib.literalExpression ''"factory:<line name>"'';
        description = "Issues labelled with this become work items of the line (applying a label needs triage rights)";
      };
      repo = lib.mkOption {
        type = repoType;
        default = lineRepo;
        defaultText = lib.literalExpression "the line's repo";
        description = "Repository whose issues are taken";
      };
    };
  };

  lineType = lib.types.submodule ({ name, config, ... }: {
    options = {
      repo = lib.mkOption {
        type = repoType;
        example = "acme/widgets";
        description = "Repository (owner/name) the line delivers to; it must be listed in agentos.git-automation.publish.repos";
      };
      workspace = lib.mkOption {
        type = lib.types.str;
        example = "widgets";
        description = "Workspace (name or path under agentos.runtime.workspaceRoot) holding a checkout of the repository";
      };
      mode = lib.mkOption {
        type = lib.types.enum [ "supervised" "approval-first" "dark" ];
        default = "supervised";
        description = ''
          `supervised`: the line ends in a pull request a human merges.
          `approval-first`: like supervised, but every plan waits for an
          operator's approval before anything is built.
          `dark`: after verify, review and QA pass, the pull request is
          merged without a human. Needs `allowAutoMerge` on the repository
          under agentos.git-automation.publish.repos, a non-empty `verify`,
          a `qa` role, and either `planApproval != "never"` or
          `enforceScope = true`.
        '';
      };
      maxInFlight = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Items of the line worked on at the same time";
      };
      maxOpenPRs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Open pull requests of the line after which no new item is started";
      };
      maxFixRounds = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 3;
        description = "Review/QA findings are fixed at most this many times before the item is blocked";
      };
      budgetUSDPerItem = lib.mkOption {
        type = lib.types.either lib.types.int lib.types.float;
        default = 20;
        description = "Spend after which an item is blocked instead of continuing";
      };
      verify = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "make" "test" ];
        description = "Verification command as an argument vector, run in the item's worktree (no shell). Empty: none.";
      };
      qaVerify = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra command (argument vector) run for QA; empty: none";
      };
      planApproval = lib.mkOption {
        type = lib.types.enum [ "never" "always" "large" ];
        default = "large";
        description = "When a plan waits for an operator's approval: never, always, or when the plan is large";
      };
      skipReviewForSmall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Skip the reviewer for small changes (verify and QA still run)";
      };
      enforceScope = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Fail an item whose diff touches files outside the plan's declared scope";
      };
      isolation = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Isolation profile the line's tasks run with (null: the orchestrator's default)";
      };
      roles = {
        planner = lib.mkOption {
          type = roleType { agent = "claude"; model = "claude-opus-5-5"; budgetUSD = 5; timeoutSec = 1200; };
          default = { };
          description = "Turns the item into a plan with acceptance criteria";
        };
        builder = lib.mkOption {
          type = roleType { agent = "claude"; model = "claude-sonnet-5-5"; budgetUSD = 15; timeoutSec = 3600; };
          default = { };
          description = "Implements the plan and fixes findings";
        };
        reviewer = lib.mkOption {
          type = roleType { agent = "claude"; model = "claude-opus-5-5"; budgetUSD = 5; timeoutSec = 1200; };
          default = { };
          description = "Reviews the diff; answers `VERDICT: approve` or lists findings";
        };
        qa = lib.mkOption {
          type = lib.types.nullOr (roleType { agent = "claude"; model = "claude-sonnet-5-5"; budgetUSD = 5; timeoutSec = 1800; });
          default = null;
          example = lib.literalExpression "{ }";
          description = "Checks the result against each acceptance criterion; null skips QA. Set to `{ }` for the defaults.";
        };
      };
      intake.github = lib.mkOption {
        type = lib.types.nullOr (githubIntake name config.repo);
        default = null;
        example = lib.literalExpression "{ }";
        description = ''
          Take GitHub issues as items. Set to `{ }` for the defaults. A rule
          for agentos.triggers is generated (issues opened/labeled with the
          label, `factory = "<line>"`) unless you define
          `agentos.triggers.rules.factory-<line>` yourself; agentos.triggers
          must be enabled for it to take effect.
        '';
      };
      paused = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Take no new work on the line (running items finish)";
      };
    };
  });

  roleSettings = r: {
    inherit (r) agent;
    budget_usd = r.budgetUSD;
    timeout_sec = r.timeoutSec;
  } // lib.optionalAttrs (r.model != null) { inherit (r) model; };

  lineSettings = _: l: {
    inherit (l) repo workspace mode verify paused;
    max_in_flight = l.maxInFlight;
    max_open_prs = l.maxOpenPRs;
    max_fix_rounds = l.maxFixRounds;
    budget_usd_per_item = l.budgetUSDPerItem;
    qa_verify = l.qaVerify;
    plan_approval = l.planApproval;
    skip_review_for_small = l.skipReviewForSmall;
    enforce_scope = l.enforceScope;
    roles = {
      planner = roleSettings l.roles.planner;
      builder = roleSettings l.roles.builder;
      reviewer = roleSettings l.roles.reviewer;
    } // lib.optionalAttrs (l.roles.qa != null) { qa = roleSettings l.roles.qa; };
  } // lib.optionalAttrs (l.isolation != null) { inherit (l) isolation; };

  lines = lib.mapAttrsToList lib.nameValuePair cfg.lines;
  allowAutoMerge = l: lib.attrByPath [ l.repo "allowAutoMerge" ] false publish.repos;
  roleAgents = l: map (r: r.agent) ([ l.roles.planner l.roles.builder l.roles.reviewer ] ++ lib.optional (l.roles.qa != null) l.roles.qa);

  # The CLI is a console script of the services package
  factoryCli = pkgs.writeShellApplication {
    name = "agentos-factory";
    text = ''
      exec ${pkgs.agentos.services}/bin/agentos-factory-cli "$@"
    '';
  };
in
{
  options.agentos.factory = {
    enable = lib.mkEnableOption "the AgentOS software factory (planner, builder, verify, reviewer, QA, pull request)";

    lines = lib.mkOption {
      type = lib.types.attrsOf lineType;
      default = { };
      example = lib.literalExpression ''
        {
          web = {
            repo = "acme/widgets";
            workspace = "widgets";
            verify = [ "make" "test" ];
            intake.github = { };
          };
        }
      '';
      description = "Factory lines keyed by name: one repository, one set of roles, one mode";
    };

    tickSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "How often the factory looks for work to advance";
    };

    leaseSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long an item is owned by one factory step before it can be picked up again (crash recovery)";
    };

    itemTtlDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Finished items are kept this long";
    };

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 9960;
      description = "Prometheus metrics port (loopback)";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = orch.enable;
          message = "agentos.factory runs its steps as orchestrator tasks; set agentos.orchestration.enable = true";
        }
        {
          assertion = cfg.lines != { };
          message = "agentos.factory.enable needs at least one line in agentos.factory.lines";
        }
      ] ++ lib.concatMap
        (nl:
          let n = nl.name; l = nl.value; in [
            {
              assertion = publish.repos ? ${l.repo};
              message = "agentos.factory.lines.${n}: repo ${l.repo} must be listed in agentos.git-automation.publish.repos (the factory publishes through it)";
            }
            {
              assertion = lib.all (a: orch.taskCommands ? ${a}) (roleAgents l);
              message = "agentos.factory.lines.${n}: every role agent needs a command in agentos.orchestration.taskCommands (missing: ${lib.concatStringsSep ", " (lib.filter (a: !(orch.taskCommands ? ${a})) (roleAgents l))})";
            }
            {
              assertion = l.mode != "dark" || allowAutoMerge l;
              message = "agentos.factory.lines.${n}: mode \"dark\" merges without a human, so agentos.git-automation.publish.repos.\"${l.repo}\".allowAutoMerge must be true";
            }
            {
              assertion = l.mode != "dark" || l.verify != [ ];
              message = "agentos.factory.lines.${n}: mode \"dark\" merges without a human, so it needs a non-empty `verify` command that proves the change works";
            }
            {
              assertion = l.mode != "dark" || l.roles.qa != null;
              message = "agentos.factory.lines.${n}: mode \"dark\" merges without a human, so it needs a `roles.qa` that checks the acceptance criteria";
            }
            {
              assertion = l.mode != "dark" || l.planApproval != "never" || l.enforceScope;
              message = "agentos.factory.lines.${n}: mode \"dark\" merges without a human, so something must bound what it can touch: a human plan approval (planApproval = \"always\" or \"large\") or a hard scope guard (enforceScope = true)";
            }
          ])
        lines;

      agentos.services.settings.factory = {
        socket = "/run/agentos-factory/factory.sock";
        orchestrator_socket = "/run/agentos-orchestrator/orchestrator.sock";
        tick_sec = cfg.tickSec;
        lease_sec = cfg.leaseSec;
        item_ttl_days = cfg.itemTtlDays;
        metrics_port = cfg.metricsPort;
        lines = lib.mapAttrs lineSettings cfg.lines;
      };

      systemd.services.agentos-factory = {
        description = "AgentOS software factory";
        after = [ "redis-agentos.service" "agentos-orchestrator.service" ];
        requires = [ "redis-agentos.service" "agentos-orchestrator.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ config.environment.etc."agentos/services.toml".source ];
        path = [ pkgs.git ];

        serviceConfig = {
          Type = "notify";
          NotifyAccess = "all";
          WatchdogSec = 60;
          TimeoutStartSec = 60;
          # `agentos` is the group of the orchestrator socket, like the
          # scheduler and the triggers; the service has no other privileges
          User = "agentos";
          Group = "agentos";
          SupplementaryGroups = [ "redis-agentos" ];
          ExecStart = "${pkgs.agentos.services}/bin/agentos-factory-server";
          Restart = "on-failure";
          RestartSec = 3;
          # Control socket: the agentos group (operators, agentos-triggers), not agents
          RuntimeDirectory = "agentos-factory";
          RuntimeDirectoryMode = "0750";
          UMask = "0007";

          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = "";
        };
      };

      environment.systemPackages = [ factoryCli ];
    }

    (lib.mkIf obs.enable {
      services.prometheus.scrapeConfigs = [{
        job_name = "agentos-factory";
        static_configs = [{ targets = [ "127.0.0.1:${toString cfg.metricsPort}" ]; }];
      }];
    })

    (lib.mkIf (obs.enable && config.agentos.dashboard.enable) {
      agentos.services.settings.dashboard.links = lib.mkAfter [{
        name = "Factory items (Prometheus)";
        url = "http://127.0.0.1:9001/graph?g0.expr=agentos_factory_items&g0.tab=0";
      }];
    })
  ]);
}
