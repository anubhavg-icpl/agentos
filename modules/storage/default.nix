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

    historyRetentionDays = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Days to keep finished agents' records and gateway logs";
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
    # Workspaces are never deleted automatically (`agentos workspace rm`);
    # this prunes the agent history and gateway logs, and btrbk handles
    # snapshot retention.
    systemd.services.agentos-gc = lib.mkIf config.agentos.runtime.enable {
      description = "AgentOS agent history and log cleanup";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        User = "agentos";
        Group = "agentos";
        ExecStart = toString (pkgs.writeShellScript "agentos-gc" ''
          set -euo pipefail
          ${pkgs.findutils}/bin/find /var/lib/agentos/state/history -maxdepth 1 -name '*.json' \
            -mtime +${toString cfg.historyRetentionDays} -print -delete
          ${pkgs.findutils}/bin/find /var/lib/agentos/logs -maxdepth 1 -name '*.log' \
            -mtime +${toString cfg.historyRetentionDays} -print -delete
        '');
      };
    };

    # ─ Storage tools ──────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      btrfs-progs  # or zfs depending on cfg.filesystem
      git
      rsync
      dust  # disk usage
    ];

    # ─ Deduplication cron (btrfs dedup) ──────────────────────────────
    systemd.services.agentos-dedup = lib.mkIf (cfg.enableDedup && cfg.filesystem == "btrfs") {
      description = "AgentOS content deduplication";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.duperemove}/bin/duperemove -drh ${config.agentos.runtime.workspaceRoot}";
        SuccessExitStatus = [ 0 1 ];
      };
    };
  };
}
