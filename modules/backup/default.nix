# AgentOS backup and disaster recovery (restic).
#
# Backs up the control-plane state: /var/lib/agentos (registry, logs,
# workspaces, tasks), the control-plane Redis (a BGSAVE first, then its
# data directory), /var/lib/agentos-stack and /var/lib/agentos-audit when
# they exist, and the sops secrets together with their decryption keys.
# `agentos-restore` puts them back; see docs/operations.md for the drill.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.backup;
  redisCfg = config.services.redis.servers.agentos or { };
  redisEnabled = redisCfg.enable or false;
  redisSocket = redisCfg.unixSocket or null;
  redisCli = "${pkgs.redis}/bin/redis-cli -s ${toString redisSocket}";
  redisDir = "/var/lib/redis-agentos";
  redisUser = redisCfg.user or "redis-agentos";
  redisBin = "${config.services.redis.package}/bin";

  secretsCfg = config.agentos.secrets-manager;

  # Paths that are always candidates; only those that exist are backed up
  candidatePaths =
    [ "/var/lib/agentos" "/var/lib/agentos-stack" "/var/lib/agentos-audit" ]
    ++ lib.optional redisEnabled "/var/lib/redis-agentos"
    ++ lib.optional (secretsCfg.enable or false) secretsCfg.secretsFile
    ++ lib.optionals cfg.includeDecryptionKeys (
      [ "/var/lib/sops-nix" "/etc/ssh/ssh_host_ed25519_key" ]
      ++ lib.optional ((config.sops.age.keyFile or null) != null) (toString config.sops.age.keyFile)
    )
    ++ cfg.extraPaths;

  existingPaths = pkgs.writeShellScript "agentos-backup-paths" ''
    for p in ${lib.escapeShellArgs (lib.unique candidatePaths)}; do
      if [ -e "$p" ]; then echo "$p"; fi
    done
  '';

  # BGSAVE and wait until the RDB is on disk, so the snapshot holds a
  # consistent dump rather than whatever the last periodic save left. The
  # AOF is not backed up (restic could catch it mid-write); a restore
  # rebuilds it from the RDB, see rebuild_redis below.
  prepare = ''
    #!${pkgs.runtimeShell}
    set -eu
    ${lib.optionalString redisEnabled ''
    save_redis() {
      before=$(${redisCli} LASTSAVE)
      out=$(${redisCli} BGSAVE 2>&1 || true)
      scheduled=0
      case "$out" in
        *"Background saving started"*|*"already in progress"*) ;;
        *"scheduled"*) scheduled=1 ;;   # an AOF rewrite is running; Redis saves after it
        *) echo "BGSAVE failed: $out" >&2; return 1 ;;
      esac
      i=0
      while [ "$i" -lt ${toString cfg.redisSaveTimeoutSec} ]; do
        info=$(${redisCli} INFO persistence)
        case "$info" in
          *rdb_bgsave_in_progress:0*)
            now=$(${redisCli} LASTSAVE)
            case "$info" in *rdb_last_bgsave_status:ok*) ;; *) echo "BGSAVE reported an error" >&2; return 1 ;; esac
            if [ "$scheduled" -eq 0 ] || [ "$now" != "$before" ]; then
              echo "redis RDB saved"
              return 0
            fi
            ;;
        esac
        sleep 1
        i=$((i + 1))
      done
      echo "timed out waiting for BGSAVE" >&2
      return 1
    }
    save_redis
    ''}
    ${cfg.prepareCommand}
  '';

  keep = r: [
    "--keep-daily ${toString r.daily}"
    "--keep-weekly ${toString r.weekly}"
    "--keep-monthly ${toString r.monthly}"
    "--keep-yearly ${toString r.yearly}"
  ];

  restoreScript = pkgs.writeShellApplication {
    name = "agentos-restore";
    text = ''
      usage() {
        cat <<'EOF'
      Usage: agentos-restore [--snapshot ID|latest] [--target DIR] [--include PATH]... [--dry-run] [--no-restart]

      Restores the AgentOS backup from the configured restic repository.

        --target /      (default) restore in place: AgentOS services and the
                        control-plane Redis are stopped first and started after.
        --target DIR    restore into DIR for inspection (a restore drill); nothing
                        is stopped and the live system is not touched.
        --include PATH  restore only PATH (repeatable), e.g. /var/lib/agentos/state
        --dry-run       list what would be restored
        --no-restart    leave the services stopped after an in-place restore
      EOF
      }

      snapshot=latest
      target=/
      dry=0
      restart=1
      includes=()
      redis_included=0
      redis_dir=${redisDir}
      while [ $# -gt 0 ]; do
        case "$1" in
          --snapshot) snapshot="$2"; shift 2 ;;
          --target) target="$2"; shift 2 ;;
          --include)
            includes+=(--include "$2")
            case "$redis_dir/" in "''${2%/}/"*) redis_included=1 ;; esac
            shift 2 ;;
          --dry-run) dry=1; shift ;;
          --no-restart) restart=0; shift ;;
          -h|--help) usage; exit 0 ;;
          *) usage >&2; exit 2 ;;
        esac
      done

      if [ "$(id -u)" -ne 0 ]; then
        echo "agentos-restore must run as root" >&2
        exit 1
      fi

      restic="restic-${cfg.name}"
      services=(${lib.escapeShellArgs cfg.restore.stopServices})

      args=(restore "$snapshot" --target "$target")
      if [ "''${#includes[@]}" -gt 0 ]; then args+=("''${includes[@]}"); fi

      # Without --include everything, Redis included, is restored
      redis_restored=1
      if [ "''${#includes[@]}" -gt 0 ]; then redis_restored=$redis_included; fi

      if [ "$dry" -eq 1 ]; then
        "$restic" "''${args[@]}" --dry-run --verbose
        exit 0
      fi

      inplace=0
      if [ "$target" = "/" ]; then inplace=1; fi

      if [ "$inplace" -eq 1 ]; then
        echo "stopping services: ''${services[*]}"
        for s in "''${services[@]}"; do
          if systemctl cat "$s.service" >/dev/null 2>&1; then systemctl stop "$s.service" || true; fi
        done
      fi

      "$restic" "''${args[@]}" --verbose

      ${lib.optionalString redisEnabled ''
      # Redis with appendonly=yes ignores dump.rdb when there is no AOF and
      # would start empty, so load the restored RDB into a temporary server
      # and let it write a fresh AOF before the unit starts.
      rebuild_redis() {
        dir=${redisDir}
        if [ ! -f "$dir/dump.rdb" ]; then
          echo "no dump.rdb restored; Redis keeps the data it has"
          return 0
        fi
        if [ -e "$dir/appendonlydir" ]; then
          mv "$dir/appendonlydir" "$dir/appendonlydir.pre-restore-$(date +%s)"
        fi
        sock="$dir/restore.sock"
        ${pkgs.util-linux}/bin/runuser -u ${redisUser} -- ${redisBin}/redis-server \
          --port 0 --unixsocket "$sock" --dir "$dir" --appendonly no --save "" --daemonize yes
        cli() { ${redisBin}/redis-cli -s "$sock" "$@"; }
        i=0
        until [ "$(cli PING 2>/dev/null)" = PONG ]; do
          i=$((i + 1))
          if [ "$i" -gt 600 ]; then echo "temporary Redis did not start" >&2; return 1; fi
          sleep 1
        done
        cli CONFIG SET appendonly yes >/dev/null
        i=0
        while :; do
          info=$(cli INFO persistence)
          case "$info" in
            *aof_enabled:1*)
              case "$info" in *aof_rewrite_in_progress:0*) break ;; esac ;;
          esac
          i=$((i + 1))
          if [ "$i" -gt ${toString cfg.redisSaveTimeoutSec} ]; then echo "timed out rebuilding the AOF" >&2; cli SHUTDOWN NOSAVE || true; return 1; fi
          sleep 1
        done
        case "$info" in *aof_last_bgrewrite_status:ok*) ;; *) echo "AOF rewrite failed" >&2; cli SHUTDOWN NOSAVE || true; return 1 ;; esac
        echo "redis: rebuilt the AOF from the restored dump"
        cli SHUTDOWN >/dev/null 2>&1 || true
      }
      if [ "$inplace" -eq 1 ] && [ "$redis_restored" -eq 1 ]; then
        rebuild_redis
      fi
      ''}
      if [ "$inplace" -eq 1 ] && [ "$restart" -eq 1 ]; then
        echo "starting services"
        systemctl daemon-reload
        ${lib.optionalString redisEnabled "systemctl start redis-agentos.service"}
        for s in "''${services[@]}"; do
          if [ "$s" = redis-agentos ]; then continue; fi
          if systemctl cat "$s.service" >/dev/null 2>&1; then systemctl start "$s.service" || true; fi
        done
      fi
      echo "restore from $snapshot into $target done"
    '';
  };
in
{
  options.agentos.backup = {
    enable = lib.mkEnableOption "restic backups of the AgentOS state (and the agentos-restore helper)";

    name = lib.mkOption {
      type = lib.types.str;
      default = "agentos";
      description = "Name of the services.restic.backups entry; the unit is restic-backups-<name>.service and the wrapper restic-<name>.";
    };

    repository = lib.mkOption {
      type = lib.types.str;
      example = "sftp:backup@nas:/srv/agentos-restic";
      description = "restic repository: a local path or any restic backend URL.";
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      example = "/run/secrets/restic-password";
      description = "File holding the repository password. Keep a copy off the machine: without it the backups are unreadable.";
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/restic-env";
      description = "File with backend credentials (AWS_ACCESS_KEY_ID, B2_ACCOUNT_ID, ...).";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "03:00";
      description = "systemd OnCalendar expression for the backup.";
    };

    randomizedDelaySec = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Random delay added to the schedule.";
    };

    retention = {
      daily = lib.mkOption { type = lib.types.ints.unsigned; default = 7; description = "Daily snapshots to keep."; };
      weekly = lib.mkOption { type = lib.types.ints.unsigned; default = 4; description = "Weekly snapshots to keep."; };
      monthly = lib.mkOption { type = lib.types.ints.unsigned; default = 6; description = "Monthly snapshots to keep."; };
      yearly = lib.mkOption { type = lib.types.ints.unsigned; default = 1; description = "Yearly snapshots to keep."; };
    };

    extraPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "More paths to back up (skipped when they do not exist).";
    };

    exclude = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/var/lib/agentos/cache"
        "/var/lib/agentos/snapshots"
        "/var/lib/agentos/**/node_modules"
      ];
      description = "restic exclude patterns. btrbk snapshots are excluded: they already live on the same disk.";
    };

    includeDecryptionKeys = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also back up the keys that decrypt the sops secrets (the age key and the
        SSH host key). Without them a restored secrets file cannot be read on a
        new machine. The repository is encrypted with its own password; disable
        this if you keep those keys elsewhere.
      '';
    };

    redisSaveTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "How long the backup waits for Redis BGSAVE to finish before failing.";
    };

    prepareCommand = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Extra shell commands run after the Redis save and before the backup.";
    };

    extraBackupArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments for `restic backup`.";
    };

    restore.stopServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "agentos-scheduler"
        "agentos-orchestrator"
        "agentos-dashboard"
        "agentos-daemon"
        "agentos-model-gateway"
        "redis-agentos"
      ];
      description = "Services (without .service) that agentos-restore stops during an in-place restore; those that do not exist are skipped.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.restic.backups.${cfg.name} = {
      inherit (cfg) repository passwordFile extraBackupArgs;
      exclude = cfg.exclude ++ lib.optionals redisEnabled [ "${redisDir}/appendonlydir" "${redisDir}/*.aof" ];
      environmentFile = cfg.environmentFile;
      initialize = true;
      dynamicFilesFrom = "${existingPaths}";
      backupPrepareCommand = prepare;
      pruneOpts = keep cfg.retention;
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = cfg.randomizedDelaySec;
      };
    };

    environment.systemPackages = [ restoreScript ];
  };
}
