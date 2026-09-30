# ═══════════════════════════════════════════════════════════════════════
# AgentOS Environment Provisioning Module
# ═══════════════════════════════════════════════════════════════════════
#
# Automatically provisions the right dev environment for each project:
#   - Detects project type (Python, Node, Go, Rust, etc.)
#   - Installs the right language runtime and tools
#   - Sets up Nix dev shells per project
#   - Caches dependencies for fast agent startup
#   - Pre-builds common images for instant agent launch
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.provisioning;
in
{
  options.agentos.provisioning = {
    enable = lib.mkEnableOption "AgentOS environment provisioning";

    enableCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable local Nix binary cache";
    };

    prebuildImages = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [
        "python-3.11"
        "python-3.12"
        "node-20"
        "node-22"
        "go-1.22"
        "go-1.23"
        "rust-stable"
        "rust-nightly"
        "cpp-gcc"
        "java-21"
        "ruby-3.3"
        "haskell"
        "elixir"
        "ocaml"
        "zig"
      ]);
      default = [
        "python-3.11" "python-3.12" "node-22" "go-1.23" "rust-stable"
      ];
      description = "Which dev environment images to pre-build";
    };

    enableAutoDetect = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Auto-detect project type from files in workspace";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Local Nix cache (speeds up agent launches) ────────────────────
    services.nix-serve = lib.mkIf cfg.enableCache {
      enable = true;
      port = 5000;
      secretKeyFile = "/var/lib/agentos/cache-priv-key.pem";
    };

    # Generate cache key on first boot
    systemd.services.agentos-cache-key = lib.mkIf cfg.enableCache {
      description = "Generate Nix cache signing key";
      after = [ "local-fs.target" ];
      before = [ "nix-serve.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = toString (pkgs.writeShellScript "gen-key" ''
          if [ ! -f /var/lib/agentos/cache-priv-key.pem ]; then
            mkdir -p /var/lib/agentos
            ${config.nix.package}/bin/nix-store --generate-binary-cache-key \
              agentos-local /var/lib/agentos/cache-priv-key.pem /var/lib/agentos/cache-pub-key.pem
            echo "[cache-key] Generated local cache key"
          fi
        '');
      };
    };

    # ─ Environment templates ─────────────────────────────────────────
    environment.etc."agentos/env-templates/python-3.11.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ python311 python311Packages.pip python311Packages.virtualenv ];
        shellHook = '''
          if [ ! -d .venv ]; then
            python -m venv .venv
          fi
          source .venv/bin/activate
        ''';
      }
    '';

    environment.etc."agentos/env-templates/python-3.12.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ python312 python312Packages.pip python312Packages.virtualenv ];
      }
    '';

    environment.etc."agentos/env-templates/node-22.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ nodejs_22 nodePackages.npm nodePackages.pnpm nodePackages.yarn ];
      }
    '';

    environment.etc."agentos/env-templates/node-20.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ nodejs_20 nodePackages.npm ];
      }
    '';

    environment.etc."agentos/env-templates/go-1.23.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ go_1_23 gopls gotools go-tools ];
      }
    '';

    environment.etc."agentos/env-templates/rust-stable.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ rustc cargo rustfmt clippy rust-analyzer ];
        RUST_SRC_PATH = "''${pkgs.rust.packages.stable.rustPlatform.rustLibSrc}";
      }
    '';

    environment.etc."agentos/env-templates/cpp-gcc.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ gcc gnumake cmake pkg-config ];
      }
    '';

    environment.etc."agentos/env-templates/java-21.nix".text = ''
      { pkgs ? import <nixpkgs> {} }:
      pkgs.mkShell {
        packages = with pkgs; [ jdk21 maven gradle ];
      }
    '';

    # ─ Provisioning service ──────────────────────────────────────────
    systemd.services.agentos-provisioner = lib.mkIf config.agentos.daemons.enable {
      description = "AgentOS Environment Provisioner";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        AGENTOS_ENV_TEMPLATES = "/etc/agentos/env-templates";
        AGENTOS_AUTO_DETECT = lib.boolToString cfg.enableAutoDetect;
      };

      serviceConfig = {
        Type = "simple";
        User = "agentos";
        Group = "agentos";
        ExecStart = "${pkgs.agentos.provisioner}/bin/agentos-provisioner";
        Restart = "on-failure";
        RestartSec = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/agentos" ];
      };
    };

    # ─ Provisioning CLI ──────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-env" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        BOLD='\033[1m'
        NC='\033[0m'
        info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()   { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        TEMPLATES="/etc/agentos/env-templates"

        detect_project() {
          if [ -f "package.json" ]; then
            echo "node"
            if ${pkgs.jq}/bin/jq -r '.engines.node' package.json 2>/dev/null | grep -q "20"; then
              echo "node-20"
            else
              echo "node-22"
            fi
          elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
            echo "python"
            if grep -q "python_requires.*3\.12" setup.py pyproject.toml 2>/dev/null; then
              echo "python-3.12"
            else
              echo "python-3.11"
            fi
          elif [ -f "go.mod" ]; then
            echo "go-1.23"
          elif [ -f "Cargo.toml" ]; then
            echo "rust-stable"
          elif [ -f "CMakeLists.txt" ] || [ -f "Makefile" ]; then
            echo "cpp-gcc"
          elif [ -f "build.gradle" ] || [ -f "pom.xml" ]; then
            echo "java-21"
          else
            echo "unknown"
          fi
        }

        case "''${1:-detect}" in
          detect)
            echo -e "''${BOLD}Project Detection''${NC}"
            PROJECT=$(detect_project | head -1)
            SPECIFIC=$(detect_project | tail -1)
            echo "  Type: $PROJECT"
            echo "  Template: $SPECIFIC"
            ;;

          list)
            echo -e "''${BOLD}Available Environments:''${NC}"
            ls -1 "$TEMPLATES" 2>/dev/null | sed 's/\.nix$//' | while read -r env; do
              echo "  $env"
            done
            ;;

          shell)
            ENV="''${2:-}"
            if [ -z "$ENV" ]; then
              ENV=$(detect_project | tail -1)
              if [ "$ENV" = "unknown" ]; then
                echo "Could not auto-detect environment. Specify manually:"
                echo "  agentos-env shell python-3.11"
                exit 1
              fi
              info "Auto-detected: $ENV"
            fi

            TEMPLATE="$TEMPLATES/$ENV.nix"
            if [ ! -f "$TEMPLATE" ]; then
              echo "Environment not found: $ENV"
              echo "Available: $(ls $TEMPLATES/*.nix 2>/dev/null | xargs -n1 basename | sed 's/.nix//' | tr '\n' ' ')"
              exit 1
            fi

            ok "Launching $ENV environment..."
            nix-shell "$TEMPLATE"
            ;;

          init)
            # Create a shell.nix in the current project
            ENV=$(detect_project | tail -1)
            if [ "$ENV" = "unknown" ]; then
              warn "Could not detect project type. Creating generic shell."
              ENV="python-3.11"
            fi
            info "Detected: $ENV"
            cp "$TEMPLATES/$ENV.nix" ./shell.nix
            ok "Created shell.nix for $ENV"
            echo "Enter shell with: nix-shell"
            ;;

          prebuild)
            echo -e "''${BOLD}Pre-building environment images:''${NC}"
            for img in ${lib.concatStringsSep " " cfg.prebuildImages}; do
              info "Building $img..."
              nix-build "$TEMPLATES/$img.nix" --out-link "/var/lib/agentos/cache/$img" 2>/dev/null && \
                ok "Built: $img" || warn "Failed: $img"
            done
            ;;

          *)
            echo "Usage: agentos-env <detect|list|shell|init|prebuild> [args]"
            ;;
        esac
      '')
    ];

    networking.firewall.interfaces.agentos0.allowedTCPPorts = lib.optional cfg.enableCache 5000;
  };
}
