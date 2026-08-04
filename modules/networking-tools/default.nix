# AgentOS Networking Tools Module
# Network diagnostics and analysis
{ config, pkgs, lib, ... }:

let cfg = config.agentos.networking-tools; in
{
  options.agentos.networking-tools = {
    enable = lib.mkEnableOption "AgentOS networking tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
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
      dogdns
      httpie
      mitmproxy
      charles
    ];
  };
}
