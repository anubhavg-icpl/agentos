# The graphical session, shared by the desktop host (nestlo-desktop), the
# desktop VM image (nestlo-desktop-vm) and the desktop live ISO
# (nestlo-desktop-iso).
{ lib, ... }:

{
  nestlo.desktop = {
    enable = true;
    windowManager = lib.mkDefault "i3";
  };

  # The server host turns these off; a desktop needs them
  services.displayManager.enable = true;
}
