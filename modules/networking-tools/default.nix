# Nestlo Networking Tools Module
# Network diagnostics and analysis
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.nestlo.networking-tools;
in
{
  options.nestlo.networking-tools = {
    enable = lib.mkEnableOption "Nestlo networking tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      nmap
      tcpdump
      wireshark-cli
      tshark
      dig
      dnsutils
      traceroute
      mtr
      netcat-openbsd
      socat
      iperf3
      bandwhich
      gping
      doggo
      httpie
      mitmproxy
      charles
    ]);
  };
}
