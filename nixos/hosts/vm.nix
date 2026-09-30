# AgentOS as a QEMU/KVM guest: EFI qcow2 image with a single ext4 root.
#   nix build .#vm-image
{ lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/virtualisation/disk-image.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  image.baseName = lib.mkForce "agentos";
  virtualisation.diskSize = lib.mkDefault "auto";

  # The image builder can't write EFI variables
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;

  # No btrfs here, so no btrbk snapshots or dedup
  agentos.storage.filesystem = lib.mkForce "ext4";
}
