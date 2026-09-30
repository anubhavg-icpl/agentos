# AgentOS - Disk layout via disko
# btrfs root (with subvolumes) + FAT32 EFI partition.
# disko generates the fileSystems entries for these mounts.
{ lib, ... }:

let
  mountOptions = [ "compress=zstd" "noatime" ];
in
{
  disko.devices = {
    disk.main = {
      device = lib.mkDefault "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          efi = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
              extraArgs = [ "-n" "BOOT" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "agentos-root" ];
              subvolumes = {
                "@root" = { mountpoint = "/"; inherit mountOptions; };
                "@nix" = { mountpoint = "/nix"; inherit mountOptions; };
                "@var" = { mountpoint = "/var"; inherit mountOptions; };
                "@var-lib-agentos" = { mountpoint = "/var/lib/agentos"; inherit mountOptions; };
                "@workspaces" = { mountpoint = "/var/lib/agentos/workspaces"; inherit mountOptions; };
                "@snapshots" = { mountpoint = "/var/lib/agentos/snapshots"; inherit mountOptions; };
              };
            };
          };
        };
      };
    };
  };
}
