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
    services.btrbk = lib.mkIf (cfg.filesystem == "btrfs") {
      enable = true;
      instances."agentos-workspaces" = {
        onCalendar = cfg.snapshotInterval;
        settings = {
          timestamp_format = "long";
          snapshot_preserve = "${toString cfg.snapshotRetention}h 7d 4w";
          snapshot_dir = "/var/lib/agentos/snapshots";
          subvolume."/var/lib/agentos/workspaces" = { };
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

          # Remove snapshots older than retention period
          ${pkgs.findutils}/bin/find /var/lib/agentos/snapshots -maxdepth 1 -type d -mtime +${toString cfg.snapshotRetention} -exec rm -rf {} \;
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
        ExecStart = "${pkgs.btrfs-dedupe}/bin/duperemove -drh /var/lib/agentos/workspaces || true";
      };
    };
  };
}
