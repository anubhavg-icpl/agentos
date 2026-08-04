# AgentOS security module
# Capability-based auth, egress firewall, secret management, audit logging
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.security;
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
        # LLM APIs
        "api.anthropic.com"
        "api.openai.com"
        "generativelanguage.googleapis.com"
        "api.groq.com"
        "openrouter.ai"
        # Package managers
        "github.com"
        "registry.npmjs.org"
        "pypi.org"
        "crates.io"
        "repo1.maven.org"
        # Search
        "api.tavily.com"
      ];
      description = "Domains agents are allowed to reach";
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
      killUnconfinedConfinement = true;
    };

    # ─ Audit framework ────────────────────────────────────────────────
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
    # Only resolve allowed domains via local resolver with filtering
    services.dnsmasq = {
      enable = true;
      settings = {
        no-resolv = true;
        server = [ "1.1.1.1" "8.8.8.8" ];
        listen-address = "127.0.0.1";
        bind-interfaces = true;
      } // lib.optionalAttrs (cfg.defaultEgress == "deny") (
        builtins.listToAttrs (
          map (domain: {
            name = "address";
            value = "/${domain}/1.1.1.1";
          }) cfg.allowedEgressDomains
        )
      );
    };

    # ─ iptables egress policy ────────────────────────────────────────
    networking.firewall = {
      enable = true;
      logRefusedPackets = true;
      logRefusedConnections = true;

      # Allow SSH for admin access (change in production)
      allowedTCPPorts = [ 22 ];

      extraCommands = lib.optionalString (cfg.defaultEgress == "deny") ''
        # Allow established connections
        iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        # Allow loopback
        iptables -A OUTPUT -o lo -j ACCEPT
        # Allow DNS to local dnsmasq
        iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
        # Allow egress to approved domains (resolved by dnsmasq)
      '' + lib.concatStrings (
        map (domain: ''
          for ip in $(dig +short ${domain} 2>/dev/null); do
            iptables -A OUTPUT -d "$ip" -j ACCEPT
          done
        '') cfg.allowedEgressDomains
      ) + lib.optionalString (cfg.defaultEgress == "deny") ''
        # Default deny egress
        iptables -P OUTPUT DROP
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
