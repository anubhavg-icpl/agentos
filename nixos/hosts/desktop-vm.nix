# The desktop as a QEMU/KVM guest (see packages.desktop-vm-image): log in
# automatically as admin. There is no fixed password. On first boot a random
# one is generated, shown on the VM console (login prompt) and kept in
# /var/lib/agentos/first-boot-password (root only) until you change it. It is
# marked expired (`chage -d 0`), so the first interactive login (lock screen,
# tty, `su`) forces a new one. Because an expired password blocks autologin,
# the first boot lands on the login screen; later boots log in automatically.
# sudo asks for the password. SSH password login stays disabled.
{ lib, pkgs, ... }:

let
  stateDir = "/var/lib/agentos";
  stateFile = "${stateDir}/first-boot-password";
  doneFile = "${stateDir}/.first-boot-done";
  issueFile = "/run/issue.d/50-agentos-password.issue";
in
{
  agentos.desktop.autologin = {
    enable = true;
    user = "admin";
  };

  users.users.admin.hashedPasswordFile = lib.mkForce null;

  # The server host has passwordless sudo because admin has no password;
  # here admin has one, so use it.
  security.sudo.wheelNeedsPassword = lib.mkForce true;

  systemd.services.agentos-first-boot-password = {
    description = "Set a random first-boot password for admin";
    wantedBy = [ "multi-user.target" ];
    before = [
      "getty@tty1.service"
      "serial-getty@ttyS0.service"
      "display-manager.service"
    ];
    path = [ pkgs.coreutils pkgs.openssl pkgs.shadow pkgs.gnugrep ];
    environment.LC_ALL = "C";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      UMask = "0077";
    };
    script = ''
      mkdir -p ${stateDir}
      install -d -m 0755 /run/issue.d
      if [ ! -e ${doneFile} ]; then
        pw="$(openssl rand -base64 12 | tr '/+' 'xy')"
        printf '%s\n' "$pw" > ${stateFile}
        printf 'admin:%s\n' "$pw" | chpasswd
        chage -d 0 admin
        touch ${doneFile}
      fi
      # While the password is still the expired first-boot one, announce it
      # on the console; afterwards drop the plaintext copy.
      if [ -e ${stateFile} ] && chage -l admin | grep -q 'Last password change.*must be changed'; then
        pw="$(cat ${stateFile})"
        {
          echo
          echo "AgentOS desktop VM: first-boot password for 'admin': $pw"
          echo "You must change it at the first login (also kept in ${stateFile}, root only)."
          echo
        } | tee ${issueFile} > /dev/console || true
        chmod 600 ${issueFile}
      else
        rm -f ${stateFile} ${issueFile}
      fi
    '';
  };

  # Clipboard sharing and dynamic resolution with virt-viewer/SPICE
  services.spice-vdagentd.enable = true;
}
