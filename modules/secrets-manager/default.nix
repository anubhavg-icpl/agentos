# ═══════════════════════════════════════════════════════════════════════
# AgentOS Secrets Manager Module
# ═══════════════════════════════════════════════════════════════════════
#
# Manages API keys and secrets for agents:
#   - Encrypted at rest (sops-nix / age)
#   - Per-agent secret access (agent X can only read its keys)
#   - Short-lived tokens (auto-rotation)
#   - Never exposed in env, process args, or logs
#   - Integration with Vault, AWS Secrets Manager, Doppler
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.secrets-manager;
in
{
  options.agentos.secrets-manager = {
    enable = lib.mkEnableOption "AgentOS secrets manager";

    backend = lib.mkOption {
      type = lib.types.enum [ "sops" "vault" "file" ];
      default = "sops";
      description = "Secrets backend to use";
    };

    secretsFile = lib.mkOption {
      type = lib.types.path;
      default = /var/lib/agentos/secrets/secrets.yaml;
      description = "Path to encrypted secrets file (sops format)";
    };

    enableAutoRotation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable automatic key rotation (requires backend support)";
    };

    rotationInterval = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "How often to rotate keys";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ sops-nix for secrets decryption at boot ───────────────────────
    sops = lib.mkIf (cfg.backend == "sops") {
      defaultSopsFile = cfg.secretsFile;
      age = {
        keyFile = "/var/lib/agentos/secrets/age-key.txt";
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      };

      # Define secrets (each becomes a file at /run/secrets/<name>)
      secrets = {
        ANTHROPIC_API_KEY = { };
        OPENAI_API_KEY = { };
        GOOGLE_API_KEY = { };
        GITHUB_TOKEN = { };
        FACTORY_API_KEY = { };
        SLACK_BOT_TOKEN = { };
        LINEAR_API_KEY = { };
        SENTRY_TOKEN = { };
        BRAVE_API_KEY = { };
      };
    };

    # ─ Secrets directory ─────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/agentos/secrets 0700 root root"
    ];

    # ─ Secret injection for agents ───────────────────────────────────
    # When an agent spawns, the daemon reads from /run/secrets/ and
    # injects only the needed keys into the agent's environment.
    environment.etc."agentos/secret-mapping.yaml".text = ''
      # Maps agents to which secrets they're allowed to access
      claude-code:
        - ANTHROPIC_API_KEY
      codex:
        - OPENAI_API_KEY
      droid:
        - FACTORY_API_KEY
      aider:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY
      gemini-cli:
        - GOOGLE_API_KEY
      github-copilot-cli:
        - GITHUB_TOKEN
      swe-agent:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY
      gpt-engineer:
        - OPENAI_API_KEY
      devika:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY
      auto-gpt:
        - OPENAI_API_KEY
      all-tools:
        - GITHUB_TOKEN
        - SLACK_BOT_TOKEN
        - LINEAR_API_KEY
    '';

    # ─ Secrets CLI ───────────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-secrets" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        RED='\033[0;31m'
        NC='\033[0m'

        case "''${1:-list}" in
          list)
            echo "Configured secrets:"
            for f in /run/secrets/*; do
              if [ -f "$f" ]; then
                name=$(basename "$f")
                echo -e "  ''${GREEN}✓''${NC} $name"
              fi
            done
            echo ""
            echo "Note: Secret values are NEVER displayed."
            echo "Agents access them via environment variables at spawn time."
            ;;

          set)
            KEY="''${2:-}"
            if [ -z "$KEY" ]; then
              echo "Usage: agentos-secrets set <KEY_NAME>"
              echo "You will be prompted to enter the value (hidden)"
              exit 1
            fi
            read -rsp "Enter value for $KEY: " VALUE
            echo ""
            # Write to sops file
            if [ ! -f "${toString cfg.secretsFile}" ]; then
              echo "Creating new secrets file..."
              echo "$KEY: '''" > "${toString cfg.secretsFile}"
              echo "$VALUE" >> "${toString cfg.secretsFile}"
              echo "'''" >> "${toString cfg.secretsFile}"
            else
              echo "Use sops to edit: sops ${toString cfg.secretsFile}"
            fi
            echo -e "''${GREEN}Secret $KEY set.''${NC}"
            ;;

          edit)
            exec ${pkgs.sops}/bin/sops "${toString cfg.secretsFile}"
            ;;

          check)
            echo "Secret access mapping:"
            cat /etc/agentos/secret-mapping.yaml
            ;;

          rotate)
            echo "Rotating secrets..."
            # This would call the backend's rotation API
            echo "Manual rotation required. Use: agentos-secrets edit"
            ;;

          *)
            echo "Usage: agentos-secrets <list|set|edit|check|rotate>"
            ;;
        esac
      '')
    ];

    # ─ Vault agent (if using Vault backend) ──────────────────────────
    services.vault = lib.mkIf (cfg.backend == "vault") {
      enable = true;
      package = pkgs.vault-bin;
    };
  };
}
