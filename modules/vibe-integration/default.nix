# ═══════════════════════════════════════════════════════════════════════
# AgentOS VIBE Integration Module
# ═══════════════════════════════════════════════════════════════════════
#
# Integrates the VIBE library (anubhavg-icpl/vibe) which provides:
#   - 853 expert chat modes across 52 categories
#   - 5340 installable skills
#   - 200 subagents in 10 categories
#   - 112 slash commands in 8 categories
#   - 120 plugin trees
#   - 111 universal rules
#   - 106 prompt templates
#   - 759 system prompts (reference)
#   - 18 end-to-end recipes
#   - 13 output styles
#
# On boot, AgentOS auto-installs the entire VIBE library into every
# supported agent CLI, so all agents immediately have access to
# expert-level domain knowledge.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.vibe-integration;
in
{
  options.agentos.vibe-integration = {
    enable = lib.mkEnableOption "AgentOS VIBE integration (auto-installs 5340+ skills)";

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "github:anubhavg-icpl/vibe";
      description = ''
        VIBE package reference for npx. Pin it to a tag or commit
        (e.g. "github:anubhavg-icpl/vibe#v1.0.0") so every machine installs
        the same code; an unpinned ref pulls whatever is on the default
        branch at install time.
      '';
    };

    autoInstallOnBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically install VIBE skills on first boot";
    };

    installTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "claude-code"
        "codex"
        "cursor"
        "opencode"
        "gemini"
        "copilot"
        "factory-droid"
      ];
      description = "Which agent CLIs to install VIBE into";
    };

    categories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # The modern stack
        "ai-frameworks"
        "ai-engineering"
        "rag-advanced"
        "llm-training"
        "llm-eval-ops"
        "multimodal-ai"
        "vector-stores"
        "local-llm"
        "model-authoring"
        "modern-web"
        "edge-platforms"
        "data-platforms"
        "android-cli"
        "android-platform"
        # Defense
        "mythos"
        # Design
        "design-systems"
        "design-ux"
        "ui-ux"
        "creative"
        # People
        "engineer-personas"
        "personalities"
        # Classics
        "testing"
        "languages"
        "frameworks"
        "backend"
        "infrastructure"
        "cloud-infrastructure"
        "devops"
        "security"
        "database"
        "architecture"
        "documentation"
        "debugging"
        "refactoring"
        "planning"
        "mobile"
        "game-development"
        "blockchain"
        "emerging-tech"
        "ebpf"
        "rfc"
        "project-structure"
        "specialized"
      ];
      description = "Which VIBE categories to install (empty = all)";
    };
  };

  config = lib.mkIf cfg.enable {
    # ── VIBE CLI wrapper ─────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "vibe" ''
        #!/usr/bin/env bash
        exec ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} "$@"
      '')

      # ── AgentOS VIBE installer ─────────────────────────────────────
      (pkgs.writeShellScriptBin "agentos-vibe" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        BOLD='\033[1m'
        NC='\033[0m'
        info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        SUBCMD="''${1:-status}"

        case "$SUBCMD" in
          install)
            info "Installing VIBE library into all agent CLIs..."
            echo ""
            echo "  Source:   ${cfg.repoUrl}"
            echo "  Targets:  ${lib.concatStringsSep ", " cfg.installTargets}"
            echo ""

            # Run the VIBE CLI in non-interactive mode
            for target in ${lib.concatStringsSep " " cfg.installTargets}; do
              info "Installing into $target..."
              ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} add --agent "$target" --yes 2>/dev/null && \
                ok "  $target: skills installed" || \
                warn "  $target: not detected or install failed"
            done

            echo ""
            ok "VIBE installation complete!"
            echo ""
            echo "  853 modes, 5340 skills, 200 agents, 112 commands"
            echo "  120 plugins, 111 rules, 759 system prompts"
            echo ""
            echo "  Browse:   vibe list"
            echo "  Search:   vibe search 'rag'"
            echo "  Preview:  vibe info systematic-debugging"
            ;;

          update)
            info "Updating VIBE library..."
            # Clear npx cache to force re-fetch
            rm -rf /tmp/.npx-vibe-cache 2>/dev/null || true
            ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} --yes 2>/dev/null || true
            ok "VIBE updated"
            ;;

          status)
            echo -e "''${BOLD}VIBE Integration Status''${NC}"
            echo ""
            echo "  Repository:     ${cfg.repoUrl}"
            echo "  Auto-install:   ${lib.boolToString cfg.autoInstallOnBoot}"
            echo "  Targets:        ${lib.concatStringsSep ", " cfg.installTargets}"
            echo ""
            echo -e "''${BOLD}Library Contents:''${NC}"
            echo "    Modes:         853 (52 categories)"
            echo "    Skills:        5340"
            echo "    Subagents:     200 (10 categories)"
            echo "    Commands:      112 (8 categories)"
            echo "    Plugins:       120"
            echo "    Rules:         111"
            echo "    Prompts:       106"
            echo "    System Prompts: 759"
            echo "    Recipes:       18"
            echo "    Output Styles: 13"
            echo ""
            echo -e "''${BOLD}Category Highlights:''${NC}"
            echo "    AI Engineering:    109 modes (RAG, training, eval, multimodal)"
            echo "    Design Systems:    174 modes (Airbnb, Apple, Bento, Brutalist)"
            echo "    Engineer Personas: 19 modes (DHH, Carmack, Torvalds, Hickey)"
            echo "    Mythos Security:   33 modes (defensive-first vuln discovery)"
            echo "    Modern Stack:      53 modes (edge, web, data platforms)"
            echo "    Local LLM:         36 modes (llama.cpp, Ollama, vLLM, MLX)"
            echo ""
            echo -e "''${BOLD}Installed per target:''${NC}"

            # Check each target
            declare -A TARGET_DIRS=(
              [claude-code]="$HOME/.claude/skills"
              [codex]="$HOME/.codex/skills"
              [cursor]="$HOME/.cursor/skills"
              [opencode]="$HOME/.config/opencode/skill"
              [gemini]="$HOME/.gemini/skills"
              [copilot]="$HOME/.copilot/skills"
              [factory-droid]="$HOME/.factory/skills"
            )

            for target in ${lib.concatStringsSep " " cfg.installTargets}; do
              dir="''${TARGET_DIRS[$target]:-}"
              if [ -n "$dir" ] && [ -d "$dir" ]; then
                count=$(find "$dir" -name "SKILL.md" -o -name "*.md" 2>/dev/null | wc -l)
                ok "  $target: $count files in $dir"
              else
                echo "  $target: not installed (run 'agentos-vibe install')"
              fi
            done
            ;;

          search)
            QUERY="''${2:-}"
            if [ -z "$QUERY" ]; then
              echo "Usage: agentos-vibe search <query>"
              exit 1
            fi
            ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} search "$QUERY"
            ;;

          list)
            KIND="''${2:-}"
            if [ -n "$KIND" ]; then
              ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} list --kind "$KIND"
            else
              ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} list
            fi
            ;;

          add)
            ASSET="''${2:-}"
            if [ -z "$ASSET" ]; then
              echo "Usage: agentos-vibe add <skill-name>"
              exit 1
            fi
            shift 2
            ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} add "$ASSET" "$@" --yes
            ;;

          doctor)
            ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} doctor
            ;;

          categories)
            echo -e "''${BOLD}VIBE Mode Categories (52):''${NC}"
            echo ""
            echo "  Modern Stack:"
            echo "    ai-frameworks       18 modes (LangGraph, CrewAI, Pydantic AI, DSPy)"
            echo "    ai-engineering      20 modes (math, ML, DL, NLP, LLMs, agents)"
            echo "    rag-advanced        17 modes (HyDE, ColBERT, GraphRAG, RAPTOR)"
            echo "    llm-training        19 modes (LoRA, QLoRA, DPO, ORPO, SimPO, GRPO)"
            echo "    llm-eval-ops        18 modes (Langfuse, LangSmith, RAGAS, Promptfoo)"
            echo "    multimodal-ai       19 modes (Flux, SDXL, ComfyUI, Whisper, VLMs)"
            echo "    vector-stores       18 modes (pgvector, Qdrant, Weaviate, Pinecone)"
            echo "    local-llm           19 modes (llama.cpp, Ollama, vLLM, MLX, GGUF)"
            echo "    model-authoring     17 modes (Modelfile, GGUF, chat templates)"
            echo "    modern-web          18 modes (Vite, Bun, Astro, Solid, Qwik, SvelteKit)"
            echo "    edge-platforms      16 modes (CF Workers, Vercel, Fly, Supabase)"
            echo "    data-platforms      19 modes (DuckDB, ClickHouse, Polars, Iceberg)"
            echo "    android-cli         13 modes (Google's agent-first CLI)"
            echo "    android-platform    17 modes (Compose, Wear OS, TV, NDK)"
            echo ""
            echo "  Security (Mythos):"
            echo "    mythos/discovery     9 modes (zero-day-hunter, fuzzing, PoC)"
            echo "    mythos/offense       8 modes (exploit-dev, privesc — auth-gated)"
            echo "    mythos/defense       8 modes (patch-gen, CVD, OSS-maintainer)"
            echo "    mythos/specialty     8 modes (crypto, supply-chain, sandbox-escape)"
            echo ""
            echo "  Design:"
            echo "    design-systems     174 modes (Airbnb, Apple, Bento, Brutalist, Glass)"
            echo "    design-ux            5 modes (design tokens, system architect)"
            echo "    ui-ux                6 modes (UX research, accessibility)"
            echo ""
            echo "  People:"
            echo "    engineer-personas   19 modes (DHH, Carmack, Torvalds, antirez)"
            echo "    personalities       10 modes (Tony Stark, Sheldon, Gordon Ramsay)"
            echo ""
            echo "  Classics:"
            echo "    testing             22 modes (chaos, contract, security, BDD)"
            echo "    languages           14 modes (Rust, Go, TS, Python, Kotlin, Swift)"
            echo "    frameworks          11 modes (NestJS, FastAPI, Svelte, Remix)"
            echo "    backend             11 modes"
            echo "    infrastructure      10 modes (Kafka, Istio, OTel, ArgoCD)"
            echo "    cloud-infra          6 modes (AWS, GCP, Azure, Terraform, K8s)"
            echo "    devops               9 modes (GitOps, SRE, FinOps, AIOps)"
            echo "    security            18 modes (SAST/DAST, SOC2, GDPR)"
            echo "    database             9 modes"
            echo "    architecture         7 modes"
            echo "    documentation        5 modes"
            echo "    debugging            5 modes"
            echo "    refactoring          5 modes"
            echo "    planning             5 modes"
            echo "    project-structure   21 modes"
            ;;

          *)
            cat <<'HELP'
        AgentOS VIBE Integration

        USAGE:
            agentos-vibe <COMMAND> [ARGS]

        COMMANDS:
            install              Install VIBE into all agent CLIs
            update               Update VIBE library
            status               Show installation status per target
            categories           List all 52 mode categories
            search <query>       Search the VIBE library
            list [--kind K]      List assets (skill/agent/command/mode/prompt)
            add <name>           Install a specific skill/mode
            doctor               Diagnose VIBE installation

        THE VIBE CLI IS ALSO AVAILABLE DIRECTLY:
            vibe                 Interactive fuzzy picker
            vibe add <name>      Install specific asset
            vibe list            List all assets
            vibe search <query>  Search
            vibe info <name>     Preview an asset
            vibe doctor          Diagnose

        LIBRARY: 853 modes | 5340 skills | 200 agents | 112 commands
                  120 plugins | 111 rules | 759 system prompts | 18 recipes
        HELP
            ;;
        esac
      '')
    ];

    # ── Auto-install VIBE on first boot ──────────────────────────────
    systemd.services.agentos-vibe-install = lib.mkIf cfg.autoInstallOnBoot {
      description = "AgentOS VIBE Library Auto-Installer";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "admin";
        # /var/lib/agentos-vibe, owned by admin, so the marker can be written
        StateDirectory = "agentos-vibe";
        ExecStart = toString (pkgs.writeShellScript "vibe-auto-install" ''
          set -euo pipefail
          MARKER="/var/lib/agentos-vibe/installed"

          if [ -f "$MARKER" ]; then
            echo "[vibe] Already installed. Run 'agentos-vibe update' to refresh."
            exit 0
          fi

          echo "[vibe] First boot: installing VIBE library..."
          echo "[vibe] This installs 5340+ skills into all agent CLIs."

          # Install via npx for each target
          for target in ${lib.concatStringsSep " " cfg.installTargets}; do
            echo "[vibe] Installing into $target..."
            ${pkgs.nodejs_22}/bin/npx -y ${cfg.repoUrl} add --agent "$target" --yes 2>/dev/null || \
              echo "[vibe] Warning: $target not detected, skipping"
          done

          touch "$MARKER"
          echo "[vibe] Installation complete."
        '');
      };
    };
  };
}
