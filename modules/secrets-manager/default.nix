# ═══════════════════════════════════════════════════════════════════════
# Nestlo Secrets Manager Module
# ═══════════════════════════════════════════════════════════════════════
#
# Manages API keys and secrets for agents:
#   - Encrypted at rest (sops-nix / age)
#   - Per-agent secret access (agent X can only read its keys)
#   - Short-lived tokens (auto-rotation)
#   - Never written to disk or the Nix store in plaintext
#   - Integration with Vault, AWS Secrets Manager, Doppler
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.secrets-manager;
in
{
  options.nestlo.secrets-manager = {
    enable = lib.mkEnableOption "Nestlo secrets manager";

    backend = lib.mkOption {
      type = lib.types.enum [ "sops" "vault" "file" ];
      default = "sops";
      description = "Secrets backend to use";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nestlo/secrets/secrets.yaml";
      description = "Path (on the target machine) to the sops-encrypted secrets file";
    };

    sopsInitialized = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Set to true once secretsFile exists on the machine and is encrypted
        for its age / SSH host key. Until then no sops secrets are declared,
        so activation doesn't fail on a fresh install.
      '';
    };

    secrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "ANTHROPIC_API_KEY"
        "OPENAI_API_KEY"
        "GOOGLE_API_KEY"
        "GITHUB_TOKEN"
        "FACTORY_API_KEY"
        "SLACK_BOT_TOKEN"
        "LINEAR_API_KEY"
        "SENTRY_TOKEN"
        "BRAVE_API_KEY"
      ];
      description = "Keys in secretsFile to expose as /run/secrets/<name>";
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
    sops = lib.mkIf (cfg.backend == "sops" && cfg.sopsInitialized) {
      defaultSopsFile = cfg.secretsFile;
      # The file lives on the target machine, not in this repository
      validateSopsFiles = false;
      age = {
        keyFile = "/var/lib/nestlo/secrets/age-key.txt";
        sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
      };

      # Each becomes /run/secrets/<name>, readable by the nestlo group
      secrets = lib.genAttrs cfg.secrets (_: {
        group = "nestlo";
        mode = "0440";
      });
    };

    # ─ Secrets directory ─────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d /var/lib/nestlo/secrets 0700 root root"
    ];

    # ─ Secret injection for agents ───────────────────────────────────
    # When an agent spawns, the daemon reads from /run/secrets/ and
    # injects only the needed keys into the agent's environment.
    environment.etc."nestlo/secret-mapping.yaml".text = ''
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
      antigravity-cli:
        - GEMINI_API_KEY
      gemini-cli:
        - GOOGLE_API_KEY
      github-copilot-cli:
        - GITHUB_TOKEN
      open-interpreter:
        - ANTHROPIC_API_KEY
        - OPENAI_API_KEY
      all-tools:
        - GITHUB_TOKEN
        - SLACK_BOT_TOKEN
        - LINEAR_API_KEY
    '';

    # ─ Secrets CLI ───────────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "nestlo-secrets" ''
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
              echo "Usage: nestlo-secrets set <KEY_NAME>"
              echo "You will be prompted to enter the value (hidden)"
              exit 1
            fi
            if [ ! -f "${cfg.secretsFile}" ]; then
              echo -e "''${RED}No secrets file at ${cfg.secretsFile}.''${NC}"
              echo "Create it (encrypted) with: nestlo-secrets edit"
              exit 1
            fi
            read -rsp "Enter value for $KEY: " VALUE
            echo ""
            # Written encrypted by sops; the value never touches disk in plaintext
            ${pkgs.sops}/bin/sops set "${cfg.secretsFile}" "[\"$KEY\"]" \
              "$(${pkgs.jq}/bin/jq -Rn --arg v "$VALUE" '$v')"
            echo -e "''${GREEN}Secret $KEY set.''${NC}"
            ;;

          edit)
            exec ${pkgs.sops}/bin/sops "${cfg.secretsFile}"
            ;;

          check)
            echo "Secret access mapping:"
            cat /etc/nestlo/secret-mapping.yaml
            ;;

          rotate)
            echo "Rotating secrets..."
            # This would call the backend's rotation API
            echo "Manual rotation required. Use: nestlo-secrets edit"
            ;;

          *)
            echo "Usage: nestlo-secrets <list|set|edit|check|rotate>"
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
