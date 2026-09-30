# Desktop edition of the installed host (agentos-desktop and
# agentos-desktop-vm): local login for the admin user.
{ lib, ... }:

{
  # Local login needs a password, unlike the SSH-key-only server. The
  # installer (`agentos-install --desktop`) writes the hash of the password
  # entered at install time to this file. Until it exists the account stays
  # locked for local login; SSH keys keep working.
  users.users.admin = {
    hashedPasswordFile = lib.mkDefault "/etc/agentos/admin-password";
    extraGroups = [ "networkmanager" "video" "audio" ];
  };
}
