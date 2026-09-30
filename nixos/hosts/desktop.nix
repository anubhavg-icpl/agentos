# The graphical session, shared by the desktop host (agentos-desktop), the
# desktop VM image (agentos-desktop-vm) and the desktop live ISO
# (agentos-desktop-iso).
{ lib, ... }:

{
  agentos.desktop = {
    enable = true;
    windowManager = lib.mkDefault "i3";
  };

  # The server host turns these off; a desktop needs them
  services.displayManager.enable = true;
}
