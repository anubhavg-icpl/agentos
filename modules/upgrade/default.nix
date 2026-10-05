# Nestlo unattended upgrades with a health gate.
#
# Wraps system.autoUpgrade. nixos-upgrade drops a marker once it has built
# the new generation; nestlo-upgrade-gate then waits for the Nestlo
# services to report ready (/readyz) and, when they do not, rolls back with
# `nixos-rebuild switch --rollback`, logs loudly and posts an alert to
# Alertmanager when one is configured. The gate runs right after a
# `switch`, or at boot after a kernel-changing upgrade rebooted into the
# new generation. See docs/operations.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.upgrade;
  gate = cfg.healthGate;

  rt = config.nestlo.runtime;
  curl = "${pkgs.curl}/bin/curl";
  gwSocket = config.nestlo.services.settings.gateway.admin_socket or "/run/nestlo-gateway/admin.sock";
  daemonPort = config.nestlo.services.settings.daemon.metrics_port or 9950;
  orchSocket = config.nestlo.services.settings.orchestrator.socket or "/run/nestlo-orchestrator/orchestrator.sock";
  dashAddr = config.nestlo.dashboard.address;
  # Wildcard binds are probed on loopback; IPv6 literals need brackets in a URL
  dashHost =
    if dashAddr == "0.0.0.0" then "127.0.0.1"
    else if dashAddr == "::" then "[::1]"
    else if lib.hasInfix ":" dashAddr then "[${dashAddr}]"
    else dashAddr;

  checks = lib.concatStringsSep "\n" (
    lib.optional config.nestlo.networking.enable
      "check gateway ${curl} -fsS --max-time 5 --unix-socket ${gwSocket} http://localhost/readyz"
    ++ lib.optional rt.enable
      "check daemon ${curl} -fsS --max-time 5 http://127.0.0.1:${toString daemonPort}/readyz"
    ++ lib.optional config.nestlo.orchestration.enable
      "check orchestrator ${curl} -fsS --max-time 5 --unix-socket ${orchSocket} http://localhost/readyz"
    ++ lib.optional config.nestlo.dashboard.enable
      "check dashboard ${curl} -fsS --max-time 5 http://${dashHost}:${toString config.nestlo.dashboard.port}/readyz"
    ++ gate.extraChecks
  );

  stateDir = "/var/lib/nestlo-upgrade";
  marker = "${stateDir}/pending";

  runbook = "${config.nestlo.observability.alerts.runbookBaseUrl}/NestloUpgradeRolledBack.md";

  gateScript = pkgs.writeShellScript "nestlo-upgrade-gate" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep pkgs.util-linux config.systemd.package ]}:$PATH

    if [ ! -e ${marker} ]; then
      echo "no upgrade pending; nothing to check"
      exit 0
    fi
    generation=$(cat ${marker})
    if [ "$(readlink -f /run/current-system)" != "$generation" ]; then
      echo "generation $generation is staged but not running yet (reboot pending); gate runs after the reboot"
      exit 0
    fi

    failed=""
    check() {
      name=$1; shift
      if out=$("$@" 2>&1); then
        echo "ok: $name"
      else
        echo "FAILED: $name: $out" >&2
        failed="$failed $name"
      fi
    }

    run_checks() {
      failed=""
      ${checks}
      # Any Nestlo unit that crashed is a failure too
      bad=$(systemctl list-units --state=failed --plain --no-legend 'nestlo-*' 'redis-nestlo*' | cut -d' ' -f1 | grep -Ev '^(nestlo-task-runner@|nestlo-agent-)' | tr '\n' ' ')
      if [ -n "$bad" ]; then
        echo "FAILED: units in failed state: $bad" >&2
        failed="$failed units"
      fi
    }

    deadline=$(( $(date +%s) + ${toString gate.timeoutSec} ))
    while :; do
      run_checks
      [ -z "$failed" ] && break
      [ "$(date +%s)" -ge "$deadline" ] && break
      sleep ${toString gate.intervalSec}
    done

    if [ -z "$failed" ]; then
      echo "upgrade to $generation is healthy"
      rm -f ${marker}
      exit 0
    fi

    msg="upgrade to $generation failed its health gate (failed:$failed); rolling back"
    echo "$msg" >&2
    ${pkgs.util-linux}/bin/logger -t nestlo-upgrade -p user.crit "$msg"
    ${lib.optionalString (gate.alertmanagerUrl != null) ''
    ${curl} -fsS --max-time 10 -X POST -H 'Content-Type: application/json' \
      ${gate.alertmanagerUrl}/api/v2/alerts -d "[{\"labels\":{\"alertname\":\"NestloUpgradeRolledBack\",\"severity\":\"critical\"},\"annotations\":{\"summary\":\"An upgrade failed its health gate and was rolled back\",\"description\":\"$msg\",\"runbook_url\":\"${runbook}\"}}]" \
      || echo "could not reach Alertmanager" >&2
    ''}
    ${config.system.build.nixos-rebuild}/bin/nixos-rebuild switch --rollback
    rc=$?
    echo "rollback finished with status $rc" >&2
    ${pkgs.util-linux}/bin/logger -t nestlo-upgrade -p user.crit "rollback finished with status $rc"
    # Keep the marker when the rollback failed, so the boot-time gate retries
    [ "$rc" -eq 0 ] && rm -f ${marker}
    exit 1
  '';
in
{
  options.nestlo.upgrade = {
    enable = lib.mkEnableOption "unattended upgrades (system.autoUpgrade) with an Nestlo health gate and automatic rollback";

    flake = lib.mkOption {
      type = lib.types.str;
      example = "github:anubhavg-icpl/nestlo#nestlo";
      description = "Flake reference of the configuration to upgrade to, including the host (passed to system.autoUpgrade.flake).";
    };

    dates = lib.mkOption {
      type = lib.types.str;
      default = "04:40";
      description = "systemd OnCalendar expression for the upgrade (system.autoUpgrade.dates).";
    };

    allowReboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reboot when the new generation changes the kernel or initrd
        (system.autoUpgrade.allowReboot). Without it, such upgrades are only
        applied by the next manual reboot, and everything else is switched live.
      '';
    };

    rebootWindow = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          lower = lib.mkOption { type = lib.types.str; example = "01:00"; description = "Start of the window (HH:MM)."; };
          upper = lib.mkOption { type = lib.types.str; example = "05:00"; description = "End of the window (HH:MM)."; };
        };
      });
      default = null;
      description = "Only reboot inside this window (system.autoUpgrade.rebootWindow). null allows a reboot at any time.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--update-input" "nixpkgs" ];
      description = "More arguments for nixos-rebuild.";
    };

    healthGate = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Check readiness after an upgrade and roll back when it fails.";
      };
      timeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 180;
        description = "How long the services get to become ready before the upgrade is rolled back.";
      };
      intervalSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Pause between readiness polls.";
      };
      extraChecks = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "check ssh systemctl is-active sshd.service" ];
        description = "Extra lines for the gate; use `check <name> <command...>`, a non-zero exit fails the gate.";
      };
      alertmanagerUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://127.0.0.1:9093";
        description = "Alertmanager base URL; the gate posts NestloUpgradeRolledBack there on a rollback. A rollback is always logged to the journal at crit level.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    system.autoUpgrade = {
      enable = true;
      flake = cfg.flake;
      dates = cfg.dates;
      allowReboot = cfg.allowReboot;
      rebootWindow = cfg.rebootWindow;
      flags = cfg.extraFlags;
    };

    systemd.tmpfiles.rules = [ "d ${stateDir} 0750 root root" ];

    systemd.services.nixos-upgrade = lib.mkIf gate.enable {
      serviceConfig = {
        # Remember the generation before, and mark the new one only when the
        # upgrade changed it: a night without changes must not roll back.
        ExecStartPre = pkgs.writeShellScript "nestlo-upgrade-before" ''
          ${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system > ${stateDir}/before
        '';
        # After a live `switch` judge it right away; after a reboot the
        # boot-time unit below does.
        ExecStartPost = [
          (pkgs.writeShellScript "nestlo-upgrade-mark" ''
            now=$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system)
            if [ "$now" != "$(cat ${stateDir}/before)" ]; then
              echo "$now" > ${marker}
            fi
          '')
          gateScript
        ];
      };
    };

    systemd.services.nestlo-upgrade-gate = lib.mkIf gate.enable {
      description = "Nestlo post-upgrade health gate (rolls back a failing upgrade)";
      wantedBy = [ "multi-user.target" ];
      # The rollback switches configurations; it must not stop the gate running it
      restartIfChanged = false;
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "redis-nestlo.service"
        "nestlo-model-gateway.service"
        "nestlo-daemon.service"
        "nestlo-orchestrator.service"
        "nestlo-dashboard.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = gateScript;
        TimeoutStartSec = gate.timeoutSec + 600; # rollback may take a while
      };
    };
  };
}
