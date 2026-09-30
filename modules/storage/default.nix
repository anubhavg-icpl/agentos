# AgentOS storage module
# btrfs with CoW snapshots, content-addressed dedup, git-native workspaces
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.storage;
in
{
  options.agentos.storage = {
    enable = lib.mkEnableOption "AgentOS storage management";

    filesystem = lib.mkOption {
      type = lib.types.enum [ "btrfs" "ext4" "zfs" ];
      default = "btrfs";
      description = "Filesystem for agent workspaces (btrfs recommended for snapshots)";
    };

    snapshotInterval = lib.mkOption {
      type = lib.types.str;
      default = "hourly";
      description = "How often to snapshot agent workspaces";
    };

    snapshotRetention = lib.mkOption {
      type = lib.types.int;
      default = 24;
      description = "How many snapshots to keep";
    };

    enableDedup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable content-addressed deduplication";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ btrfs snapshot management ──────────────────────────────────────
    # The workspace root must be a btrfs subvolume (see disko.nix).
    services.btrbk.instances."agentos-workspaces" = lib.mkIf (cfg.filesystem == "btrfs") {
      onCalendar = cfg.snapshotInterval;
      settings = {
        timestamp_format = "long";
        snapshot_preserve_min = "2h";
        snapshot_preserve = "${toString cfg.snapshotRetention}h 7d 4w";
        volume."/var/lib/agentos" = {
          snapshot_dir = "snapshots";
          subvolume = "workspaces";
        };
      };
    };

    # ─ Workspace GC (clean up old, abandoned workspaces) ──────────────
    systemd.services.agentos-gc = {
      description = "AgentOS workspace garbage collection";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        User = "agentos";
        ExecStart = toString (pkgs.writeShellScript "agentos-gc" ''
          set -euo pipefail
          WS_ROOT="${toString config.agentos.runtime.workspaceRoot}"
          STATE_DIR="/var/lib/agentos/state"

          # Remove workspaces not accessed in 7 days and not marked persistent
          find "$WS_ROOT" -maxdepth 1 -type d -mtime +7 -name 'agent-*' | while read -r ws; do
            if [ ! -f "$ws/.agentos-persistent" ]; then
              echo "[gc] removing stale workspace: $ws"
              rm -rf "$ws"
            fi
          done

          # Snapshot retention is handled by btrbk (snapshot_preserve).
        '');
      };
    };

    # ─ Storage tools ──────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      btrfs-progs  # or zfs depending on cfg.filesystem
      git
      rsync
      du-dust  # disk usage
    ];

    # ─ Deduplication cron (btrfs dedup) ──────────────────────────────
    systemd.services.agentos-dedup = lib.mkIf (cfg.enableDedup && cfg.filesystem == "btrfs") {
      description = "AgentOS content deduplication";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.duperemove}/bin/duperemove -drh /var/lib/agentos/workspaces";
        SuccessExitStatus = [ 0 1 ];
      };
    };
  };
}
