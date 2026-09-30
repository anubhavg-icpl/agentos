# AgentOS Cloud Tools Module
# CLI tools for every major cloud provider
{ config, pkgs, lib, ... }:

let cfg = config.agentos.cloud-tools; in
{
  options.agentos.cloud-tools = {
    enable = lib.mkEnableOption "AgentOS cloud CLI tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
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
    ];
  };
}
