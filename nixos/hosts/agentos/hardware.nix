# AgentOS - Hardware configuration
# This is a generic/VM-friendly config. Override for bare metal.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  # Filesystems come from disko.nix.

  # ── Common VM / bare-metal storage drivers for the initrd ──────────
  boot.initrd.availableKernelModules = [
    "ahci" "nvme" "sd_mod" "usb_storage" "xhci_pci"
    "virtio_pci" "virtio_blk" "virtio_scsi"
  ];

  # ── Swap (zram for minimal RAM usage) ──────────────────────────────
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # ── CPU ───────────────────────────────────────────────────────────
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  # ── Power management (minimal) ────────────────────────────────────
  powerManagement.enable = true;
  powerManagement.cpuFreqGovernor = "performance";

  # ── Graphics (none, headless) ─────────────────────────────────────
  hardware.graphics.enable = false;
}
