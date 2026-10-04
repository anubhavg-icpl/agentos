# Guest kernel for Pullrun's Firecracker microVMs.
#
# Neither nixpkgs nor microvm.nix ships a kernel that Pullrun can boot:
#   - the NixOS kernels build virtio_blk, ext4 and friends as modules and
#     rely on an initrd, but Pullrun boots `root=/dev/vda rw init=/init` with
#     no initrd and an `ip=` boot argument for networking;
#   - Firecracker's own CI kernels are downloaded binaries (not reproducible).
#
# So this is the upstream 6.12 LTS kernel from nixpkgs with the x86_64
# defconfig plus what a Firecracker guest needs built in (virtio over MMIO,
# block, net and vsock, ext4, devtmpfs, the serial console, kernel IP
# autoconfiguration). It is a small kernel (a defconfig, not the NixOS
# one), but it is compiled locally: expect 15-30 minutes on a few cores the
# first time. `agentos.pullrun.vm.enable = false` avoids building it.
{ pkgs, lib }:

let
  inherit (lib.kernel) yes no;
in
pkgs.linuxKernel.kernels.linux_6_12.override {
  argsOverride = {
    # Only the defconfig and the options below; none of NixOS's own config
    # (which would turn most drivers into modules)
    enableCommonConfig = false;
    autoModules = false;
    structuredExtraConfig = {
      # Devices Firecracker exposes (no PCI: Pullrun boots with pci=off)
      VIRTIO_MENU = yes;
      VIRTIO = yes;
      VIRTIO_MMIO = yes;
      VIRTIO_MMIO_CMDLINE_DEVICES = yes;
      BLK_DEV = yes;
      VIRTIO_BLK = yes;
      NETDEVICES = yes;
      VIRTIO_NET = yes;
      VSOCKETS = yes;
      VIRTIO_VSOCKETS = yes;

      # Root filesystem and /dev
      EXT4_FS = yes;
      DEVTMPFS = yes;
      DEVTMPFS_MOUNT = yes;
      TMPFS = yes;
      OVERLAY_FS = yes;

      # Console and boot-time networking (`ip=` in the kernel command line)
      TTY = yes;
      SERIAL_8250 = yes;
      IP_PNP = yes;
      IP_PNP_DHCP = no;
      IP_PNP_BOOTP = no;
      IP_PNP_RARP = no;
    } // lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
      # x86-only options (they do not exist on aarch64, where a mandatory
      # unknown option fails the build): paravirtualised guest, serial console
      HYPERVISOR_GUEST = yes;
      PARAVIRT = yes;
      KVM_GUEST = yes;
      SERIAL_8250_CONSOLE = yes;
    };
  };
}
