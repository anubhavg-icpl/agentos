# Desktop edition of the installed host (nestlo-desktop and
# nestlo-desktop-vm): local login for the admin user.
{ config, lib, ... }:

let
  passwordFile = "/etc/nestlo/admin-password";
  fallback = config.nestlo.desktop.initialHashedPassword;
in
{
  options.nestlo.desktop.initialHashedPassword = lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    default = null;
    example = "$y$j9T$...";
    description = ''
      Fallback password hash (from `mkpasswd -m yescrypt`) for the local
      login of `admin`, used only when `${passwordFile}` does not exist and
      only when the account is first created (NixOS sets initial passwords
      on user creation, never afterwards). The hash ends up in the
      world-readable Nix store, so treat this as a bootstrap password and
      change it with `passwd` after the first login. If this option is
      unset and the file is missing, local login stays locked and the
      activation prints a warning.
    '';
  };

  config = {
    # Local login needs a password, unlike the SSH-key-only server. The
    # installer (`nestlo-install --desktop`) writes the hash of the password
    # entered at install time to this file. Until it exists the account stays
    # locked for local login; SSH keys keep working.
    users.users.admin = {
      hashedPasswordFile = lib.mkDefault passwordFile;
      initialHashedPassword = lib.mkIf (fallback != null) fallback;
      extraGroups = [ "networkmanager" "video" "audio" ];
    };

    assertions = [{
      assertion = fallback == null || lib.hasPrefix "$" fallback;
      message = "nestlo.desktop.initialHashedPassword must be a password hash (mkpasswd -m yescrypt), not plain text or an empty string.";
    }];

    # NixOS only prints a terse "password file does not exist" for a missing
    # hashedPasswordFile. Say what that means and how to fix it.
    system.activationScripts.nestloAdminPassword = lib.mkIf
      (config.users.users.admin.hashedPasswordFile == passwordFile)
      {
        text = ''
          if [ ! -s ${passwordFile} ]; then
            echo "" >&2
            echo "################################################################" >&2
            echo "WARNING: ${passwordFile} is missing or empty." >&2
            ${if fallback != null then ''
              echo "Falling back to nestlo.desktop.initialHashedPassword for a new" >&2
              echo "admin account; an existing account keeps its current password." >&2
            '' else ''
              echo "The desktop login for 'admin' is LOCKED (SSH keys still work)." >&2
              echo "Fix: run  mkpasswd -m yescrypt > ${passwordFile}  as root," >&2
              echo "chmod 600 it, and rebuild; or set" >&2
              echo "nestlo.desktop.initialHashedPassword in your configuration." >&2
            ''}
            echo "################################################################" >&2
            echo "" >&2
          fi
        '';
      };
  };
}
