# ═══════════════════════════════════════════════════════════════════════
# Nestlo Orchestration Module
# ═══════════════════════════════════════════════════════════════════════
#
# Runs coding agents headless, as tasks (services/nestlo_services/orchestrator.py):
#   - single tasks, pipelines (--after <task>, prompt uses {prev_result})
#     and swarms (--swarm N: N agents, same prompt, one worktree and
#     branch each)
#   - at most maxWorkers tasks at a time; task state lives in the
#     control-plane Redis
#   - `nestlo-task` submits and follows them
#
# The orchestrator runs as `nestlo` and cannot start agents itself. To run
# task <id> it starts nestlo-task-runner@<id>.service (allowed by a polkit
# rule for exactly that unit pattern). That root helper re-validates the
# task and launches the same sandbox as `nestlo spawn`, so tasks are
# metered by the gateway, budgeted, and visible in `nestlo list`.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.orchestration;
  rt = config.nestlo.runtime;
  tasksDir = "/var/lib/nestlo/tasks";
in
{
  imports = [
    (lib.mkRemovedOptionModule [ "nestlo" "orchestration" "mode" ]
      "Use `nestlo-task submit` (single task), `--after` (pipeline) or `--swarm N`.")
    (lib.mkRemovedOptionModule [ "nestlo" "orchestration" "resultStrategy" ]
      "Swarm results are per task; compare the agent/<task-id> branches.")
  ];

  options.nestlo.orchestration = {
    enable = lib.mkEnableOption "Nestlo multi-agent orchestration";

    maxWorkers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Maximum number of tasks running at the same time. Agents started by
        hand count against `nestlo.runtime.maxAgents` as well.
      '';
    };

    maxWorkflowNodes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 50;
      description = "Largest workflow (DAG of tasks) `nestlo-task workflow submit` accepts";
    };

    maxRetries = lib.mkOption {
      type = lib.types.ints.between 0 10;
      default = 5;
      description = "Largest `--retries` a task may ask for (the hard ceiling is 10)";
    };

    taskTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = "Default task timeout (1 hour); `nestlo-task submit --timeout` overrides it";
    };

    resultTailKB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = ''
        How much of a task's output (its tail) is kept in the task record.
        This is what a later pipeline step sees as {prev_result}; the full
        output is in /var/lib/nestlo/tasks/<id>.log.
      '';
    };

    taskCommands = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      example = { fake = [ "my-agent" "--headless" "{prompt}" ]; };
      description = ''
        How to run each agent non-interactively: agent name (or its
        command) mapped to an argument vector. `{prompt}`, `{workspace}` and
        `{task_id}` are replaced inside single arguments; the prompt is never
        passed through a shell. Agents without an entry cannot run tasks.
        Entries you add are merged with the defaults; use `lib.mkForce` to
        replace one. The commands run inside the `nestlo spawn` sandbox as
        `nestlo-agent`, so agents that ask for permissions need their
        auto-approve mode here (the defaults use it where one exists).
      '';
    };

    enableMessageBus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable inter-agent message bus (Redis pub/sub)";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = rt.enable;
      message = "nestlo.orchestration needs nestlo.runtime.enable (Redis, the agent user and the sandbox)";
    }];

    # Headless invocations. Verify against the agent versions you install;
    # they change between releases.
    nestlo.orchestration.taskCommands = lib.mapAttrs (_: lib.mkDefault) {
      claude = [ "claude" "-p" "{prompt}" "--permission-mode" "acceptEdits" ];
      codex = [ "codex" "exec" "{prompt}" ];
      aider = [ "aider" "--yes-always" "--message" "{prompt}" ];
      gemini = [ "gemini" "-p" "{prompt}" ];
      qwen = [ "qwen" "-p" "{prompt}" ];
      goose = [ "goose" "run" "-t" "{prompt}" ];
      opencode = [ "opencode" "run" "{prompt}" ];
      amp = [ "amp" "-x" "{prompt}" ];
      cursor-agent = [ "cursor-agent" "-p" "{prompt}" ];
      copilot = [ "copilot" "-p" "{prompt}" ];
      droid = [ "droid" "exec" "{prompt}" ];
    };

    nestlo.services.settings.orchestrator = {
      max_workers = cfg.maxWorkers;
      max_workflow_nodes = cfg.maxWorkflowNodes;
      max_retries_cap = cfg.maxRetries;
      default_timeout_sec = cfg.taskTimeoutSec;
      result_tail_kb = cfg.resultTailKB;
      tasks_dir = tasksDir;
      task_commands = cfg.taskCommands;
    };

    # Task logs: written by the root helper, readable by operators
    systemd.tmpfiles.rules = [ "d ${tasksDir} 2750 nestlo nestlo" ];

    # ─ Orchestrator service ──────────────────────────────────────────
    systemd.services.nestlo-orchestrator = {
      description = "Nestlo orchestrator (task queue, pipelines, swarms)";
      after = [ "redis-nestlo.service" "nestlo-daemon.service" ];
      requires = [ "redis-nestlo.service" ];
      wants = [ "nestlo-daemon.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];
      path = [ config.systemd.package ]; # systemctl

      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # The service sends READY=1 once listening and WATCHDOG=1 while healthy
        WatchdogSec = 60;
        TimeoutStartSec = 60;
        User = "nestlo";
        Group = "nestlo";
        SupplementaryGroups = [ "redis-nestlo" ];
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-orchestrator";
        Restart = "on-failure";
        RestartSec = 3;
        # Control socket: reachable by the nestlo group (operators), not agents
        RuntimeDirectory = "nestlo-orchestrator";
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

    # ─ Root helper: one instance per task ────────────────────────────
    # Started by the orchestrator, never enabled. It validates the task
    # again and runs the agent in the `nestlo spawn` sandbox.
    systemd.services."nestlo-task-runner@" = {
      description = "Nestlo task %i";
      after = [ "redis-nestlo.service" "nestlo-daemon.service" ];
      path = [ config.systemd.package pkgs.git ]; # systemd-run, systemctl, git
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-task-runner %i";
        TimeoutStartSec = "infinity";
        # `systemctl stop` (cancel) signals the helper only; it stops the
        # agent's unit itself and records the result before it exits
        KillMode = "mixed";
        UMask = "0002";

        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/nestlo/state" tasksDir rt.workspaceRoot rt.agentHome ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
      };
    };

    # The orchestrator may start and stop task runners, nothing else
    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.user == "nestlo") {
          var unit = action.lookup("unit") || "";
          var verb = action.lookup("verb") || "";
          if (/^nestlo-task-runner@[A-Za-z0-9][A-Za-z0-9._-]*\.service$/.test(unit) &&
              (verb == "start" || verb == "stop")) {
            return polkit.Result.YES;
          }
        }
      });
    '';

    environment.systemPackages = [ pkgs.nestlo.task-cli ];
  };
}
