# ═══════════════════════════════════════════════════════════════════════
# Nestlo Scheduler Module
# ═══════════════════════════════════════════════════════════════════════
#
# Runs agent tasks on a calendar (services/nestlo_services/scheduler.py):
#   - schedules use systemd OnCalendar syntax, evaluated by
#     `systemd-analyze calendar` (UTC unless the expression names a zone)
#   - each firing submits a task (or a swarm) to the orchestrator, so
#     concurrency, sandboxing, budgets and logs are the orchestrator's
#   - persistent schedules run once at start-up if a run was missed
#   - declare schedules here, or manage them at runtime with `nestlo-schedule`
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.scheduler;
  rt = config.nestlo.runtime;

  scheduleType = lib.types.submodule {
    options = {
      calendar = lib.mkOption {
        type = lib.types.str;
        example = "Mon..Fri 09:00";
        description = "systemd OnCalendar expression (check with `systemd-analyze calendar`)";
      };
      agent = lib.mkOption {
        type = lib.types.str;
        example = "claude";
        description = "Agent to run; it needs an entry in nestlo.orchestration.taskCommands";
      };
      workspace = lib.mkOption {
        type = lib.types.str;
        description = "Workspace name or path under nestlo.runtime.workspaceRoot";
      };
      prompt = lib.mkOption {
        type = lib.types.str;
        description = "Prompt given to the agent";
      };
      budgetUSD = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.int lib.types.float);
        default = null;
        description = "Daily budget for each task's agent (null: the gateway default)";
      };
      timeoutSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Task timeout (null: nestlo.orchestration.taskTimeoutSec)";
      };
      swarm = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1;
        description = "Run this many agents in parallel, each on its own branch";
      };
      persistent = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run once when the scheduler starts if a run came due while it was down";
      };
      allowOverlap = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Start a new run even if the previous one is still queued or running";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this schedule is active";
      };
    };
  };

  toSettings = name: s: {
    inherit name;
    inherit (s) calendar agent workspace prompt swarm persistent;
    allow_overlap = s.allowOverlap;
    enabled = s.enable;
  }
  // lib.optionalAttrs (s.budgetUSD != null) { budget_usd = s.budgetUSD; }
  // lib.optionalAttrs (s.timeoutSec != null) { timeout_sec = s.timeoutSec; };
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "nestlo" "scheduler" "maxConcurrent" ]
      "Concurrency is limited by nestlo.orchestration.maxWorkers.")
    (lib.mkRemovedOptionModule [ "nestlo" "scheduler" "enablePriorityQueues" ]
      "Schedules have no priority queues. Tasks take a priority of their own: `nestlo-task submit --priority`.")
    (lib.mkRemovedOptionModule [ "nestlo" "scheduler" "offHoursOnly" ]
      "Put the window in the schedule's calendar expression instead, e.g. \"*-*-* 22..23,00..05:00/30:00\".")
    (lib.mkRemovedOptionModule [ "nestlo" "scheduler" "offHoursStart" ] "See offHoursOnly.")
    (lib.mkRemovedOptionModule [ "nestlo" "scheduler" "offHoursEnd" ] "See offHoursOnly.")
  ];

  options.nestlo.scheduler = {
    enable = lib.mkEnableOption "Nestlo scheduler";

    schedules = lib.mkOption {
      type = lib.types.attrsOf scheduleType;
      default = { };
      example = lib.literalExpression ''
        {
          nightly-audit = {
            calendar = "*-*-* 02:00:00";
            agent = "claude";
            workspace = "main-project";
            prompt = "Run a security audit of this codebase and fix what you find";
            budgetUSD = 5;
            persistent = true;
          };
        }
      '';
      description = ''
        Schedules managed by the configuration (keyed by name). They are
        re-synced whenever the scheduler starts and cannot be removed with
        `nestlo-schedule`. Schedules added with the CLI are kept separately.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = rt.enable;
        message = "nestlo.scheduler needs nestlo.runtime.enable (it stores schedules in the control-plane Redis)";
      }
      {
        assertion = config.nestlo.orchestration.enable;
        message = "nestlo.scheduler submits its work to the orchestrator; set nestlo.orchestration.enable = true";
      }
    ];

    nestlo.services.settings.scheduler.schedules = lib.mapAttrsToList toSettings cfg.schedules;

    # ─ Scheduler service ─────────────────────────────────────────────
    systemd.services.nestlo-scheduler = {
      description = "Nestlo scheduler";
      after = [ "redis-nestlo.service" "nestlo-orchestrator.service" ];
      requires = [ "redis-nestlo.service" ];
      wants = [ "nestlo-orchestrator.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];
      path = [ config.systemd.package ]; # systemd-analyze

      serviceConfig = {
        Type = "simple";
        User = "nestlo";
        Group = "nestlo";
        SupplementaryGroups = [ "redis-nestlo" ];
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-scheduler";
        Restart = "on-failure";
        RestartSec = 3;
        RuntimeDirectory = "nestlo-scheduler";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    environment.systemPackages = [ pkgs.nestlo.schedule-cli ];
  };
}
