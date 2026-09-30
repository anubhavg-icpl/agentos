# The desktop as a QEMU/KVM guest (see packages.desktop-vm-image): log in
# automatically as admin, with a known password for the lock screen and sudo.
# Change it (`passwd`) if the VM is reachable by anyone else; SSH password
# login stays disabled.
{ lib, ... }:

{
  agentos.desktop.autologin = {
    enable = true;
    user = "admin";
  };

  users.users.admin = {
    hashedPasswordFile = lib.mkForce null;
    initialPassword = "agentos";
  };

  # Clipboard sharing and dynamic resolution with virt-viewer/SPICE
  services.spice-vdagentd.enable = true;
}
