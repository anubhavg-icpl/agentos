# AgentOS security module
# Capability-based auth, egress firewall, secret management, audit logging
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.security;
  deny = cfg.defaultEgress == "deny";
  gatewayOnly = lib.unique cfg.gatewayOnlyDomains;
  allowedDomains = lib.unique (cfg.allowedEgressDomains ++ gatewayOnly);
  # The agent-user rules need the user to exist
  sandbox = config.agentos.runtime.enable;
  # Container-isolated agents have their own network namespace on the
  # agentos0 bridge; their traffic is forwarded (and NATed), not local
  containers = config.agentos.networking.enable;
in
{
  options.agentos.security = {
    enable = lib.mkEnableOption "AgentOS security layer";

    defaultEgress = lib.mkOption {
      type = lib.types.enum [ "deny" "allow" ];
      default = "deny";
      description = "Default egress policy for agents";
    };

    allowedEgressDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # LLM APIs used by the pre-installed agents
        "anthropic.com"
        "claude.ai"
        "openai.com"
        "chatgpt.com"
        "googleapis.com"
        "aliyuncs.com"
        "qwen.ai"
        "ampcode.com"
        "cursor.sh"
        "cursor.com"
        "githubcopilot.com"
        "factory.ai"
        "openrouter.ai"
        "groq.com"
        # Source hosting / package registries
        "github.com"
        "githubusercontent.com"
        "npmjs.org"
        "pypi.org"
        "pythonhosted.org"
        "crates.io"
        "maven.org"
        # NixOS itself (binary cache, channels, auto-upgrade)
        "nixos.org"
        # Search
        "tavily.com"
      ];
      description = ''
        Domains (including their subdomains) that the host may reach when
        defaultEgress is "deny".
      '';
    };

    gatewayOnlyDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Hosts that sandboxed agents (the agentos-agent user) may only reach
        through the model gateway. Set from agentos.networking.providers.
      '';
    };

    upstreamDNS = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
      description = "Upstream resolvers used by the local dnsmasq";
    };

    enableAuditLog = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Log every agent action immutably";
    };

    auditLogPath = lib.mkOption {
      type = lib.types.path;
      default = /var/log/agentos/audit;
      description = "Where audit logs are stored";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ AppArmor ───────────────────────────────────────────────────────
    security.apparmor = {
      enable = true;
      killUnconfinedConfinables = true;
    };

    # ─ Audit framework ────────────────────────────────────────────────
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      rules = [
        "-a exit,always -F arch=b64 -S execve"  # log all command exec
        "-w /var/lib/agentos -p wa"              # watch agent workspaces
      ];
    };

    # ─ Kernel hardening ───────────────────────────────────────────────
    boot.kernel.sysctl = {
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "kernel.kptr_restrict" = 2;
      "net.core.bpf_jit_harden" = 2;
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.tcp_syncookies" = 1;
      "dev.tty.ldisc_autoload" = 0;
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "fs.suid_dumpable" = 0;
      "user.max_user_namespaces" = 256;  # enough for agents, not unlimited
    };

    # ─ DNS-based egress filtering ─────────────────────────────────────
    # All DNS goes through a local dnsmasq. With defaultEgress = "deny" it
    # only forwards queries for allowed domains (and their subdomains),
    # answers NXDOMAIN for everything else, and adds every resolved address
    # to the `agentos-egress` ipset. The firewall then only lets outbound
    # traffic through to addresses in that set.
    services.dnsmasq = {
      enable = true;
      resolveLocalQueries = true;
      settings = {
        no-resolv = true;
        listen-address = [ "127.0.0.1" ];
        bind-interfaces = true;
        # IPv4 only: the egress sets and rules are IPv4
        filter-AAAA = true;
        server =
          if deny
          then lib.concatMap (d: map (up: "/${d}/${up}") cfg.upstreamDNS) allowedDomains
          else cfg.upstreamDNS;
        ipset =
          lib.optional deny "/${lib.concatStringsSep "/" allowedDomains}/agentos-egress"
          ++ lib.optional (gatewayOnly != [ ])
            "/${lib.concatStringsSep "/" gatewayOnly}/${lib.optionalString deny "agentos-egress,"}agentos-llm";
      } // lib.optionalAttrs deny {
        address = "/#/";
      };
    };

    # ─ iptables egress policy ────────────────────────────────────────
    networking.firewall = {
      enable = true;
      logRefusedPackets = true;
      logRefusedConnections = true;

      # Allow SSH for admin access (change in production)
      allowedTCPPorts = [ 22 ];

      extraPackages = [ pkgs.ipset ];

      extraCommands = ''
        ipset create agentos-egress hash:ip family inet -exist
        ipset create agentos-llm hash:ip family inet -exist

        for ipt in iptables ip6tables; do
          $ipt -D OUTPUT -j agentos-egress 2>/dev/null || true
          $ipt -F agentos-egress 2>/dev/null || $ipt -N agentos-egress
          $ipt -A OUTPUT -j agentos-egress
          $ipt -A agentos-egress -o lo -j RETURN
          $ipt -A agentos-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        done
      '' + lib.optionalString sandbox ''
        # Sandboxed agents: provider APIs only through the model gateway,
        # DNS only through the local resolver, no IPv6
        iptables -A agentos-egress -m owner --uid-owner agentos-agent -m set --match-set agentos-llm dst -j REJECT
        iptables -A agentos-egress -m owner --uid-owner agentos-agent -p udp --dport 53 -j REJECT
        iptables -A agentos-egress -m owner --uid-owner agentos-agent -p tcp --dport 53 -j REJECT
        ip6tables -A agentos-egress -m owner --uid-owner agentos-agent -j REJECT
      '' + lib.optionalString containers ''
        # Container-isolated agents (agentos0 bridge): the same egress policy
        # in the FORWARD path. They may not reach provider APIs directly,
        # each other, or (with egress denied) anything outside the allowlist;
        # the host itself is limited to the gateway and DNS (networking module).
        iptables -D FORWARD -i agentos0 -j agentos-fwd 2>/dev/null || true
        iptables -F agentos-fwd 2>/dev/null || iptables -N agentos-fwd
        iptables -I FORWARD 1 -i agentos0 -j agentos-fwd
        iptables -A agentos-fwd -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        iptables -A agentos-fwd -m set --match-set agentos-llm dst -j REJECT
        iptables -A agentos-fwd -d ${config.agentos.networking.agentNetCIDR} -j REJECT
      '' + lib.optionalString (containers && deny) ''
        iptables -A agentos-fwd -m set --match-set agentos-egress dst -j RETURN
        iptables -A agentos-fwd -m limit --limit 5/min -j LOG --log-prefix "agentos-fwd-deny: "
        iptables -A agentos-fwd -j REJECT
      '' + lib.optionalString (containers && !deny) ''
        for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
          iptables -A agentos-fwd -d $net -j REJECT
        done
        iptables -A agentos-fwd -j RETURN
      '' + lib.optionalString containers ''
        ip6tables -D FORWARD -i agentos0 -j REJECT 2>/dev/null || true
        ip6tables -I FORWARD 1 -i agentos0 -j REJECT
      '' + lib.optionalString deny ''
        for ipt in iptables ip6tables; do
          # dnsmasq may talk to the upstream resolvers
          $ipt -A agentos-egress -p udp --dport 53 -m owner --uid-owner dnsmasq -j RETURN
          $ipt -A agentos-egress -p tcp --dport 53 -m owner --uid-owner dnsmasq -j RETURN
          # time sync
          $ipt -A agentos-egress -p udp --dport 123 -j RETURN
        done
        # DHCP
        iptables -A agentos-egress -p udp --dport 67:68 -j RETURN
        ip6tables -A agentos-egress -p udp --dport 546:547 -j RETURN
        ip6tables -A agentos-egress -p ipv6-icmp -j RETURN
        # Addresses resolved for allowed domains
        iptables -A agentos-egress -m set --match-set agentos-egress dst -j RETURN

        for ipt in iptables ip6tables; do
          $ipt -A agentos-egress -m limit --limit 5/min -j LOG --log-prefix "agentos-egress-deny: "
          $ipt -A agentos-egress -j REJECT
        done
      '';

      extraStopCommands = ''
        iptables -D FORWARD -i agentos0 -j agentos-fwd 2>/dev/null || true
        iptables -F agentos-fwd 2>/dev/null || true
        iptables -X agentos-fwd 2>/dev/null || true
        ip6tables -D FORWARD -i agentos0 -j REJECT 2>/dev/null || true
        for ipt in iptables ip6tables; do
          $ipt -D OUTPUT -j agentos-egress 2>/dev/null || true
          $ipt -F agentos-egress 2>/dev/null || true
          $ipt -X agentos-egress 2>/dev/null || true
        done
      '';
    };

    # ─ Audit log management ──────────────────────────────────────────
    systemd.tmpfiles.rules = lib.optionals cfg.enableAuditLog [
      "d ${toString cfg.auditLogPath} 0700 root root"
    ];

    systemd.services.agentos-audit-rotator = lib.mkIf cfg.enableAuditLog {
      description = "Rotate AgentOS audit logs";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.logrotate}/sbin/logrotate --state=/var/lib/agentos/logrotate.state ${
          pkgs.writeText "agentos-logrotate" ''
            ${toString cfg.auditLogPath}/*.log {
              daily
              rotate 30
              compress
              delaycompress
              missingok
              notifempty
              create 0644 root root
            }
          ''
        }";
      };
    };

    # ─ SOPS secrets integration ──────────────────────────────────────
    # (secrets defined per-host in sops files)
    environment.systemPackages = [ pkgs.sops ];
  };
}
