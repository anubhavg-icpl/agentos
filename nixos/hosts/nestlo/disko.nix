# Nestlo - Disk layout via disko
# btrfs root (with subvolumes) + FAT32 EFI partition.
# disko generates the fileSystems entries for these mounts.
#
# With nestlo.disk.encrypt the btrfs root sits inside a LUKS2 container
# (`nestlo-install --encrypt` sets this; the passphrase is asked at boot).
# TPM2 auto-unlock is a follow-up: after install, enrol it with
#   systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-partlabel/disk-main-root
# and add `crypttabExtraOpts = [ "tpm2-device=auto" ]` to the LUKS device.
{ config, lib, ... }:

let
  cfg = config.nestlo.disk;
  mountOptions = [ "compress=zstd" "noatime" ];

  btrfsRoot = {
    type = "btrfs";
    extraArgs = [ "-f" "-L" "nestlo-root" ];
    subvolumes = {
      "@root" = { mountpoint = "/"; inherit mountOptions; };
      "@nix" = { mountpoint = "/nix"; inherit mountOptions; };
      "@var" = { mountpoint = "/var"; inherit mountOptions; };
      "@var-lib-nestlo" = { mountpoint = "/var/lib/nestlo"; inherit mountOptions; };
      "@workspaces" = { mountpoint = "/var/lib/nestlo/workspaces"; inherit mountOptions; };
      "@snapshots" = { mountpoint = "/var/lib/nestlo/snapshots"; inherit mountOptions; };
    };
  };
in
{
  options.nestlo.disk = {
    encrypt = lib.mkEnableOption "LUKS2 encryption of the root partition";
    luksPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File holding the LUKS passphrase while disko formats the disk (used
        by the installer; never read at boot). When null, disko asks for the
        passphrase interactively.
      '';
    };
  };

  config.disko.devices = {
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
            content =
              if cfg.encrypt then {
                type = "luks";
                name = "cryptroot";
                passwordFile = cfg.luksPasswordFile;
                settings.allowDiscards = true;
                content = btrfsRoot;
              } else btrfsRoot;
          };
        };
      };
    };
  };
}
