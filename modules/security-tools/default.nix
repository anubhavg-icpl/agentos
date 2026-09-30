# ═══════════════════════════════════════════════════════════════════════
# AgentOS Security Tools Module
# ═══════════════════════════════════════════════════════════════════════
#
# Security analysis and vulnerability scanning tools so agents can
# perform security audits on code they write or review.
#
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.agentos.security-tools;
in
{
  options.agentos.security-tools = {
    enable = lib.mkEnableOption "AgentOS security analysis tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      # ════════════════════════════════════════════════════════════════
      # CODE SECURITY SCANNERS
      # ════════════════════════════════════════════════════════════════
      semgrep          # multi-language static analysis
      trivy            # container/filesystem/repo scanner
      snyk             # dependency vulnerability scanner
      bandit           # Python security linter
      ruff             # Python linter (includes security rules)
      gosec            # Go security scanner
      cargo-audit      # Rust vulnerability scanner
      pip-audit        # Python dependency scanner
      osv-scanner      # open source vulnerability scanner
      grype            # container image vulnerability scanner

      # ════════════════════════════════════════════════════════════════
      # SECRET DETECTION
      # ════════════════════════════════════════════════════════════════
      gitleaks         # git secrets scanner
      trufflehog       # secrets scanner (deep)
      detect-secrets   # Yelp's secrets detector

      # ════════════════════════════════════════════════════════════════
      # NETWORK SECURITY
      # ════════════════════════════════════════════════════════════════
      nmap             # network scanner
      masscan          # fast port scanner
      nikto            # web server scanner
      sqlmap           # SQL injection tool
      wpscan           # WordPress scanner

      # ════════════════════════════════════════════════════════════════
      # CRYPTO / HASHING
      # ════════════════════════════════════════════════════════════════
      hashcat          # GPU hash cracker
      john             # CPU hash cracker
      hash-identifier  # identify hash types

      # ════════════════════════════════════════════════════════════════
      # FORENSICS
      # ════════════════════════════════════════════════════════════════
      binwalk          # firmware analysis
      foremost         # file recovery
      volatility3      # memory forensics
      radare2          # reverse engineering
      ghidra           # decompiler

      # ════════════════════════════════════════════════════════════════
      # TLS / CERTIFICATES
      # ════════════════════════════════════════════════════════════════
      certbot          # Let's Encrypt
      mkcert           # local dev certs
      step-cli         # Smallstep CA

      # ════════════════════════════════════════════════════════════════
      # CLI security tool
      # ════════════════════════════════════════════════════════════════
      (pkgs.writeShellScriptBin "agentos-scan" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        RED='\033[0;31m'
        YELLOW='\033[1;33m'
        NC='\033[0m'

        TARGET="''${1:-.}"

        case "''${2:-all}" in
          secrets)
            echo -e "''${YELLOW}[1/4] Scanning for leaked secrets...''${NC}"
            ${pkgs.gitleaks}/bin/gitleaks detect --source "$TARGET" --no-banner 2>/dev/null || true
            ;;
          deps)
            echo -e "''${YELLOW}[2/4] Scanning dependencies for vulnerabilities...''${NC}"
            ${pkgs.osv-scanner}/bin/osv-scanner -r "$TARGET" 2>/dev/null || true
            ;;
          code)
            echo -e "''${YELLOW}[3/4] Running static code analysis...''${NC}"
            ${pkgs.semgrep}/bin/semgrep scan --config=auto "$TARGET" 2>/dev/null || true
            ;;
          all)
            echo -e "''${YELLOW}Running full security audit of: $TARGET''${NC}"
            echo ""
            echo -e "''${YELLOW}[1/4] Scanning for leaked secrets...''${NC}"
            ${pkgs.gitleaks}/bin/gitleaks detect --source "$TARGET" --no-banner 2>/dev/null || true
            echo ""
            echo -e "''${YELLOW}[2/4] Scanning dependencies...''${NC}"
            ${pkgs.osv-scanner}/bin/osv-scanner -r "$TARGET" 2>/dev/null || true
            echo ""
            echo -e "''${YELLOW}[3/4] Running static analysis...''${NC}"
            ${pkgs.semgrep}/bin/semgrep scan --config=auto "$TARGET" 2>/dev/null || true
            echo ""
            echo -e "''${YELLOW}[4/4] Checking containers...''${NC}"
            ${pkgs.trivy}/bin/trivy fs "$TARGET" 2>/dev/null || true
            echo ""
            echo -e "''${GREEN}Security scan complete.''${NC}"
            ;;
          *)
            echo "Usage: agentos-scan <path> [secrets|deps|code|all]"
            ;;
        esac
      '')
    ]);
  };
}
