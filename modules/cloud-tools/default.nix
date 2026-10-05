# Nestlo Cloud Tools Module
# CLI tools for every major cloud provider
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.nestlo.cloud-tools;
in
{
  options.nestlo.cloud-tools = {
    enable = lib.mkEnableOption "Nestlo cloud CLI tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      awscli2
      google-cloud-sdk
      azure-cli
      cloudflared
      flyctl
      doctl
      scaleway-cli
      hcloud  # Hetzner
      talosctl
      k3s
      k3sup
    ]);
  };
}
