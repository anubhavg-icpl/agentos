# AgentOS - Disk layout via disko
# btrfs root + FAT32 EFI partition
{ lib, ... }:

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
              label = "BOOT";
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "btrfs";
              mountpoint = "/";
              label = "agentos-root";
              extraArgs = [ "-f" ];
              subvolumes = {
                "@root" = { mountpoint = "/"; };
                "@nix" = { mountpoint = "/nix"; };
                "@var" = { mountpoint = "/var"; };
                "@var-lib-agentos" = {
                  mountpoint = "/var/lib/agentos";
                  extraArgs = [ "--compression=zstd" ];
                };
                "@snapshots" = {
                  mountpoint = "/var/lib/agentos/snapshots";
                };
              };
            };
          };
        };
      };
    };
  };
}
