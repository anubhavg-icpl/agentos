# ═══════════════════════════════════════════════════════════════════════
# AgentOS Developer Tools Module
# ═══════════════════════════════════════════════════════════════════════
#
# Essential tools that every agent needs for day-to-day work:
# build systems, container tools, CLI utilities, API testing,
# terminal multiplexers, modern Unix replacements, etc.
#
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.agentos.dev-tools;
in
{
  options.agentos.dev-tools = {
    enable = lib.mkEnableOption "AgentOS developer tools";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      # ════════════════════════════════════════════════════════════════
      # MODERN UNIX REPLACEMENTS
      # ════════════════════════════════════════════════════════════════
      eza             # ls replacement
      bat             # cat replacement
      fd              # find replacement
      ripgrep         # grep replacement
      zoxide          # cd replacement
      btop            # top/htop replacement
      delta           # git diff viewer
      dust            # du replacement
      duf             # df replacement
      procs           # ps replacement
      sd              # sed replacement
      choose          # awk replacement
      jq              # JSON processor
      yq              # YAML processor
      xq              # XML processor
      htmlq           # HTML processor
      grpcurl         # gRPC client
      dasel           # universal data selector

      # ════════════════════════════════════════════════════════════════
      # TERMINAL MULTIPLEXERS & EDITORS
      # ════════════════════════════════════════════════════════════════
      tmux
      zellij
      screen
      micro           # simple terminal editor
      helix           # modal editor (rust)
      vim             # classic
      neovim          # modern vim

      # ════════════════════════════════════════════════════════════════
      # NETWORK / API TESTING
      # ════════════════════════════════════════════════════════════════
      curl
      wget
      httpie           # human-friendly curl
      xh               # rust httpie
      websocat         # websocket client
      wuzz             # interactive HTTP client
      postman          # API testing (CLI via newman)

      # ════════════════════════════════════════════════════════════════
      # CONTAINER & ORCHESTRATION
      # ════════════════════════════════════════════════════════════════
      nerdctl          # containerd CLI
      podman           # daemonless containers
      buildah          # container image builder
      skopeo           # container image utility
      kubectl          # Kubernetes CLI
      k9s              # Kubernetes TUI
      kubectx          # K8s context switcher
      helm             # Kubernetes package manager
      tilt             # local K8s dev
      kompose          # docker-compose to K8s

      # ════════════════════════════════════════════════════════════════
      # INFRASTRUCTURE AS CODE
      # ════════════════════════════════════════════════════════════════
      terraform
      opentofu         # open-source Terraform fork
      ansible
      pulumi
      packer           # image builder
      nomad            # scheduler (Consul companion)

      # ════════════════════════════════════════════════════════════════
      # BUILD TOOLS
      # ════════════════════════════════════════════════════════════════
      gnumake
      cmake
      ninja
      bazel_7          # Google's build system
      buck2            # Meta's build system
      just             # modern Makefile alternative
      go-task          # task runner

      # ════════════════════════════════════════════════════════════════
      # VERSION CONTROL
      # ════════════════════════════════════════════════════════════════
      git
      git-lfs
      gh               # GitHub CLI
      glab             # GitLab CLI
      tea              # Gitea CLI
      lazygit          # git TUI
      tig              # git TUI (lightweight)
      gitui            # git TUI (rust)
      git-cliff        # changelog generator
      commitizen       # conventional commits

      # ════════════════════════════════════════════════════════════════
      # FILE MANAGERS & UTILITIES
      # ════════════════════════════════════════════════════════════════
      ranger           # file manager TUI
      yazi             # modern file manager (rust)
      mc               # midnight commander
      fzf              # fuzzy finder
      starship         # shell prompt
      zellij           # terminal workspace

      # ════════════════════════════════════════════════════════════════
      # SEARCH & NAVIGATION
      # ════════════════════════════════════════════════════════════════
      ast-grep         # structural search
      ast-grep         # AST-based search/replace
      sd               # sed alternative
      tealdeer         # tldr client
      cheat            # cheatsheets

      # ════════════════════════════════════════════════════════════════
      # MONITORING & PROFILING
      # ════════════════════════════════════════════════════════════════
      hyperfine        # benchmarking
      gping            # ping with graph
      speedtest-cli    # bandwidth test
      doggo            # dig replacement
      bandwhich        # network bandwidth monitor

      # ════════════════════════════════════════════════════════════════
      # ARCHIVE / COMPRESSION
      # ════════════════════════════════════════════════════════════════
      unzip
      zip
      p7zip
      xz
      gzip
      bzip2
      zstd
      brotli
      pigz             # parallel gzip
      dust             # disk usage visualizer

      # ════════════════════════════════════════════════════════════════
      # MISC UTILITIES
      # ════════════════════════════════════════════════════════════════
      watchexec        # file watcher
      entr             # file watcher (alt)
      direnv           # env loader
      envsubst         # env var substitution
      age              # encryption
      sops             # secrets ops
      gnupg            # GPG
      openssl          # TLS toolkit
      netcat-openbsd   # netcat
      socat            # socket relay
      time             # command timer
      parallel         # GNU parallel
      expect           # automation
      dialog           # TUI dialogs
    ]);

    # ── Shell enhancements ───────────────────────────────────────────
    programs = {
      bash.completion.enable = true;
      zsh.enable = true;
      fish.enable = true;
      starship.enable = true;
      tmux.enable = true;
      fzf = {
        fuzzyCompletion = true;
        keybindings = true;
      };
    };
  };
}
