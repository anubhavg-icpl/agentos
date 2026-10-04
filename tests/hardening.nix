# Eval-only checks for the image hardening. No VM is booted: the check fails
# at evaluation time, so it costs one NixOS evaluation of each host.
#
#   nix build .#checks.x86_64-linux.hardening
#
#   - the live ISO has sshd disabled or key-only (no passwords, no empty
#     passwords), enforced by an assertion in nixos/hosts/iso.nix, and the
#     assertion really fires when someone enables password logins
#   - the desktop VM image has no fixed password and sudo asks for one
{ pkgs, self }:

let
  inherit (pkgs) lib;
  iso = self.nixosConfigurations.agentos-iso;
  desktopVm = self.nixosConfigurations.agentos-desktop-vm.config;

  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);

  isoSsh = iso.config.services.openssh;
  isoOk =
    !isoSsh.enable || (
      isoSsh.settings.PasswordAuthentication == false
      && isoSsh.settings.KbdInteractiveAuthentication == false
      && isoSsh.settings.PermitEmptyPasswords == false
    );

  weakened = iso.extendModules {
    modules = [{
      services.openssh.settings.PasswordAuthentication = lib.mkOverride 40 true;
    }];
  };

  admin = desktopVm.users.users.admin;
in
assert lib.assertMsg isoOk "live ISO: sshd must be disabled or key-only";
assert lib.assertMsg (failing iso == [ ]) "live ISO: assertions fail: ${toString (failing iso)}";
assert lib.assertMsg (failing weakened != [ ])
  "live ISO: enabling SSH password logins must trip the hardening assertion";
assert lib.assertMsg
  (admin.initialPassword == null && admin.password == null
    && admin.initialHashedPassword == null && admin.hashedPassword == null)
  "desktop VM: admin must not have a fixed password";
assert lib.assertMsg desktopVm.security.sudo.wheelNeedsPassword
  "desktop VM: sudo must require the password";
pkgs.runCommand "agentos-hardening" { } "touch $out"
