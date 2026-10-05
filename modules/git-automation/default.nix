# ═══════════════════════════════════════════════════════════════════════
# AgentOS Git Automation Module
# ═══════════════════════════════════════════════════════════════════════
#
# Makes agents git-native:
#   - Auto-create branches per agent session
#   - Auto-commit after each meaningful change
#   - Auto-generate commit messages from diffs
#   - Create PRs when agent work is complete: tasks of the orchestrator are
#     published (branch pushed, PR opened through the GitHub REST API) by the
#     root task runner, see `publish` below and docs/triggers.md
#   - Merge conflict detection and notification
#   - Git hooks for quality gates (tests must pass before commit)
#   - Diff visualization for human review
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.git-automation;
in
{
  options.agentos.git-automation = {
    enable = lib.mkEnableOption "AgentOS git automation";

    autoBranch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically create a new branch per agent session";
    };

    branchPrefix = lib.mkOption {
      type = lib.types.str;
      default = "agent/";
      description = "Prefix for agent-created branches";
    };

    autoCommit = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Automatically commit changes after each agent action";
    };

    autoPR = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Open a pull request for every orchestrator task that succeeds in a
        workspace listed under `publish.repos` and leaves changes on its
        `agent/<task-id>` branch. Without `publish.repos` it does nothing.
        Tasks can also ask for a PR one by one (`agentos.triggers` rules with
        `publish = true`), whatever this is set to.
      '';
    };

    publish = {
      repos = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Push URL (default: https://github.com/<owner>/<name>.git); https or a local path";
            };
            base = lib.mkOption {
              type = lib.types.str;
              default = "main";
              description = "Branch the pull request targets; it is never pushed to";
            };
            workspaces = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Workspaces whose tasks belong to this repository (for autoPR)";
            };
            allowAutoMerge = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Let a task's `publish.merge` request merge its pull request into
                `base` once every check run is green, the combined status is
                success and the head is still the pushed commit. Off by default;
                a request for a repository that does not set this is recorded as
                skipped and the PR stays open. Never merges into any other branch.
              '';
            };
          };
        });
        default = { };
        example = lib.literalExpression ''{ "acme/widgets" = { workspaces = [ "widgets" ]; }; }'';
        description = ''
          Repositories (owner/name) the root task runner may publish to. Only
          `agent/<task-id>` branches are pushed, never a protected branch and
          never with force. Needs `tokenFile`.
        '';
      };

      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/agentos-github-token";
        description = ''
          GitHub token with contents:write and pull_requests:write on the
          repositories above and nothing else (a fine-grained token). Passed
          to the root task runner as a systemd credential; keep the file
          root-only (0400). The agent sandbox never sees it.
        '';
      };

      apiUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://api.github.com";
        description = "GitHub REST API base URL (GitHub Enterprise: https://host/api/v3)";
      };

      protectedBranches = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "main" "master" "develop" "dev" "trunk" "release/*" "production" "prod" "stable" ];
        description = "Branch name patterns that are never pushed (in addition to each repository's base)";
      };

      draft = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Open pull requests as drafts";
      };

      mergeWaitSec = lib.mkOption {
        type = lib.types.ints.between 0 86400;
        default = 1800;
        description = ''
          How long the root task runner polls a pull request's checks before it
          gives up on an auto-merge (see `repos.<repo>.allowAutoMerge`). The
          runner unit has no start timeout, so this is the only bound.
        '';
      };

      commitUncommitted = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Commit what the agent left uncommitted on its branch before pushing";
      };
    };

    requireTestsPass = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Require tests to pass before allowing commits";
    };

    commitMessageStyle = lib.mkOption {
      type = lib.types.enum [ "conventional" "descriptive" "emoji" ];
      default = "conventional";
      description = "Style for auto-generated commit messages";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.publish.repos == { } || cfg.publish.tokenFile != null;
        message = "agentos.git-automation.publish.repos needs agentos.git-automation.publish.tokenFile";
      }
      {
        assertion = cfg.publish.repos == { } || config.agentos.orchestration.enable;
        message = "agentos.git-automation.publish publishes orchestrator tasks; set agentos.orchestration.enable = true";
      }
    ];

    # Read by the root task runner (services/agentos_services/publish.py)
    agentos.services.settings.publish = {
      auto = cfg.autoPR;
      api_url = cfg.publish.apiUrl;
      protected_branches = cfg.publish.protectedBranches;
      draft = cfg.publish.draft;
      commit_uncommitted = cfg.publish.commitUncommitted;
      merge_wait_sec = cfg.publish.mergeWaitSec;
      repos = lib.mapAttrs
        (_: r: { base = r.base; workspaces = r.workspaces; allow_auto_merge = r.allowAutoMerge; } // lib.optionalAttrs (r.url != null) { inherit (r) url; })
        cfg.publish.repos;
    };

    # The token goes to the root helper only, as a credential
    systemd.services."agentos-task-runner@" = lib.mkIf (cfg.publish.tokenFile != null) {
      serviceConfig.LoadCredential = [ "github-token:${toString cfg.publish.tokenFile}" ];
      environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    };

    # ─ Global git config for agents ──────────────────────────────────
    programs.git = {
      enable = true;
      config = {
        user = {
          name = "AgentOS";
          email = "agent@agentos.local";
        };
        init = {
          defaultBranch = "main";
        };
        pull = {
          rebase = true;
        };
        push = {
          autoSetupRemote = true;
        };
        commit = {
          gpgsign = false;
        };
      };
    };

    # ─ Git hooks installer ───────────────────────────────────────────
    environment.etc."agentos/git-hooks/pre-commit".source = pkgs.writeShellScript "pre-commit" ''
      #!/usr/bin/env bash
      set -euo pipefail

      # AgentOS pre-commit hook
      # Runs quality checks before allowing commits

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      NC='\033[0m'

      # Check if tests exist and run them
      if [ -f Makefile ] && grep -q "^test:" Makefile 2>/dev/null; then
        echo "[agentos] Running tests..."
        if ! make test 2>&1; then
          echo -e "''${RED}[agentos] Tests failed. Commit blocked.''${NC}"
          exit 1
        fi
      fi

      # Check for common issues
      # Block secrets from being committed
      if git diff --cached | grep -iE '(api_key|secret|password|token)\s*=\s*["\x27]' 2>/dev/null; then
        echo -e "''${RED}[agentos] Possible secret detected. Commit blocked.''${NC}"
        echo "If this is a false positive, commit with --no-verify"
        exit 1
      fi

      # Block large files
      MAX_SIZE=$((10 * 1024 * 1024))  # 10MB
      for file in $(git diff --cached --name-only); do
        if [ -f "$file" ]; then
          size=$(stat -c%s "$file" 2>/dev/null || echo 0)
          if [ "$size" -gt "$MAX_SIZE" ]; then
            echo -e "''${RED}[agentos] File too large: $file ($((size / 1024 / 1024))MB). Commit blocked.''${NC}"
            exit 1
          fi
        fi
      done

      echo -e "''${GREEN}[agentos] Pre-commit checks passed.''${NC}"
    '';

    environment.etc."agentos/git-hooks/prepare-commit-msg".source = pkgs.writeShellScript "prepare-commit-msg" ''
      #!/usr/bin/env bash
      # Auto-generate commit message if none provided
      COMMIT_MSG_FILE="$1"
      COMMIT_SOURCE="$2"

      # Only auto-generate for agent commits (not merges/amends)
      if [ -n "$COMMIT_SOURCE" ]; then
        exit 0
      fi

      # Check if message is already set
      if [ -s "$COMMIT_MSG_FILE" ]; then
        exit 0
      fi

      # Generate from diff
      DIFF=$(git diff --cached --stat 2>/dev/null)
      if [ -z "$DIFF" ]; then
        exit 0
      fi

      FILES=$(echo "$DIFF" | wc -l)
      INSERTIONS=$(git diff --cached --shortstat 2>/dev/null | grep -oP '\d+(?= insertion)')
      DELETIONS=$(git diff --cached --shortstat 2>/dev/null | grep -oP '\d+(?= deletion)')

      cat > "$COMMIT_MSG_FILE" <<EOF
      feat(agent): automated change

      Files changed: $FILES
      Insertions: ''${INSERTIONS:-0}
      Deletions: ''${DELETIONS:-0}

      Generated by AgentOS
      EOF
    '';

    # ─ Git automation CLI ────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-git" ''
        #!/usr/bin/env bash
        set -euo pipefail

        GREEN='\033[0;32m'
        BLUE='\033[0;34m'
        YELLOW='\033[1;33m'
        NC='\033[0m'
        info()  { echo -e "''${BLUE}[INFO]''${NC} $*"; }
        ok()    { echo -e "''${GREEN}[OK]''${NC} $*"; }
        warn()  { echo -e "''${YELLOW}[WARN]''${NC} $*"; }

        PREFIX="${cfg.branchPrefix}"

        case "''${1:-help}" in
          init)
            # Initialize a workspace with agent git hooks
            if [ ! -d .git ]; then
              git init --quiet
              ok "Initialized git repo"
            fi
            # Install hooks
            mkdir -p .git/hooks
            cp /etc/agentos/git-hooks/pre-commit .git/hooks/pre-commit 2>/dev/null || true
            cp /etc/agentos/git-hooks/prepare-commit-msg .git/hooks/prepare-commit-msg 2>/dev/null || true
            chmod +x .git/hooks/*
            ok "Agent git hooks installed"
            ;;

          branch)
            # Create an agent branch
            AGENT="''${2:-agent}"
            BRANCH="$PREFIX$AGENT-$(date +%Y%m%d-%H%M%S)"
            git checkout -b "$BRANCH"
            ok "Created branch: $BRANCH"
            echo "$BRANCH"
            ;;

          commit)
            # Auto-commit changes
            MSG="''${2:-}"
            git add -A
            if git diff --cached --quiet; then
              warn "No changes to commit"
              exit 0
            fi
            if [ -z "$MSG" ]; then
              # Generate commit message
              FILES=$(git diff --cached --stat | tail -1)
              MSG="feat(agent): $FILES"
            fi
            git commit -m "$MSG" --quiet
            ok "Committed: $MSG"
            ;;

          pr)
            # Manual PR from a shell (requires GitHub CLI and your own login).
            # Orchestrator tasks are published by the task runner instead.
            TITLE="''${2:-Agent: automated changes}"
            BODY="## Summary
            Automated changes by AgentOS agent.

            ## Changes
            $(git log main..HEAD --oneline 2>/dev/null || git log master..HEAD --oneline 2>/dev/null)

            ## Diff
            $(git diff main..HEAD --stat 2>/dev/null || git diff master..HEAD --stat 2>/dev/null)
            ---
            _Generated by AgentOS_"

            if command -v gh &>/dev/null; then
              gh pr create --title "$TITLE" --body "$BODY" --fill 2>/dev/null || \
                gh pr create --title "$TITLE" --body "$BODY"
              ok "PR created"
            else
              warn "GitHub CLI not available. Push branch manually:"
              echo "  git push -u origin HEAD"
            fi
            ;;

          snapshot)
            # Create a quick checkpoint commit
            git add -A
            git commit --allow-empty -m "checkpoint(agent): snapshot at $(date -Iseconds)" --quiet 2>/dev/null || true
            ok "Snapshot committed"
            ;;

          undo)
            # Undo last commit but keep changes
            git reset --soft HEAD~1
            ok "Undid last commit (changes preserved)"
            ;;

          diffstat)
            # Show diff from main
            BASE=$(git rev-parse --verify main 2>/dev/null && echo main || echo master)
            git diff "$BASE"..HEAD --stat
            ;;

          hooks)
            # Install hooks in current repo
            mkdir -p .git/hooks
            cp /etc/agentos/git-hooks/* .git/hooks/ 2>/dev/null || warn "No hooks found"
            chmod +x .git/hooks/*
            ok "Hooks installed"
            ;;

          help|*)
            cat <<'HELP'
        AgentOS Git Automation

        USAGE:
            agentos-git <COMMAND> [ARGS]

        COMMANDS:
            init                 Initialize workspace with agent hooks
            branch [agent-name]  Create an agent branch
            commit [message]     Auto-commit changes
            pr [title]           Create a pull request
            snapshot             Create a checkpoint commit
            undo                 Undo last commit (keep changes)
            diffstat             Show diff from main
            hooks                Install git hooks in current repo

        CONFIG:
            Auto-branch:    ${lib.boolToString cfg.autoBranch}
            Auto-commit:    ${lib.boolToString cfg.autoCommit}
            Auto-PR:        ${lib.boolToString cfg.autoPR}
            Require tests:  ${lib.boolToString cfg.requireTestsPass}
            Branch prefix:  ${cfg.branchPrefix}

        HELP
            ;;
        esac
      '')
    ];
  };
}
