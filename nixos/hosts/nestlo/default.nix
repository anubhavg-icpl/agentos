# ═══════════════════════════════════════════════════════════════════════
# Nestlo — Default Host Configuration
# ═══════════════════════════════════════════════════════════════════════
# This is the system that boots on bare metal or a VM.
# ALL coding agents are pre-installed by default.
{ config, pkgs, lib, inputs, ... }:

{
  # Disk layout (disko.nix) and hardware.nix are added per target in
  # flake.nix, so the same host config can also be built as a VM image.

  # ── Bootloader ─────────────────────────────────────────────────────
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.kernelParams = [
    "quiet"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  # ── Kernel modules ─────────────────────────────────────────────────
  boot.kernelModules = [ "btrfs" "overlay" "bridge" "veth" ]
    # KVM modules exist on x86 only (arm64 KVM is built in)
    ++ lib.optionals pkgs.stdenv.hostPlatform.isx86_64 [ "kvm-intel" "kvm-amd" ];

  # ── Hostname ───────────────────────────────────────────────────────
  networking.hostName = "nestlo";
  networking.networkmanager.enable = true;

  # ── Time zone & locale ─────────────────────────────────────────────
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── SSH for admin access ───────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # ── Admin user ────────────────────────────────────────────────────
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "containerd" "nestlo" ];
    # nestlo-install writes the key given at install time to
    # ~/.ssh/authorized_keys; keys can also be pinned here.
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA..."
    ];
  };

  # admin has no password (SSH key login only), so sudo can't prompt for one
  security.sudo.wheelNeedsPassword = false;

  # ── Nix settings ──────────────────────────────────────────────────
  nix = {
    package = pkgs.nixVersions.stable;
    extraOptions = ''
      experimental-features = nix-command flakes
      max-jobs = auto
      auto-optimise-store = true
      keep-outputs = true
      keep-derivations = true
    '';
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # ════════════════════════════════════════════════════════════════════
  # NESTLO MODULES
  # ════════════════════════════════════════════════════════════════════
  nestlo = {
    runtime = {
      enable = true;
      containerRuntime = "containerd";
      maxAgents = 8;
    };
    security = {
      enable = true;
      defaultEgress = "deny";
    };
    observability.enable = true;
    storage = {
      enable = true;
      filesystem = "btrfs";
    };
    networking.enable = true;

    # New feature modules
    context = {
      enable = true;
      vectorStore = "qdrant";
      enableSharedKnowledge = true;
    };
    orchestration = {
      enable = true;
      maxWorkers = 4;
    };
    mcp-registry = {
      enable = true;
      enableBuiltinTools = true;
    };
    budget-controller = {
      enable = true;
      defaultDailyBudgetUSD = 50.0;
      globalDailyBudgetUSD = 500.0;
      autoShutdown = true;
    };
    git-automation = {
      enable = true;
      autoBranch = true;
      autoCommit = true;
      autoPR = true;
    };
    provisioning = {
      enable = true;
      enableCache = true;
    };
    notifications = {
      enable = true;
      notifyOn = [ "task-completed" "budget-threshold" "agent-error" ];
      # Point at a sops secret to receive them, e.g.:
      # slackWebhookFile = "/run/secrets/SLACK_WEBHOOK";
    };
    circuit-breaker = {
      enable = true;
      maxApiCallsPerMinute = 60;
      maxConsecutiveFailures = 5;
    };
    secrets-manager = {
      enable = true;
      backend = "sops";
    };
    scheduler = {
      enable = true;
    };
    # Pre-installed toolchains (20+ languages, databases, dev tools)
    language-toolchains = {
      enable = true;
      enableAll = true;
    };
    databases = {
      enable = true;
      enablePostgres = true;
      enableRedis = true;
      enableDuckDB = true;
    };
    dev-tools.enable = true;
    security-tools.enable = true;
    browser-tools.enable = true;

    # VIBE integration (853 modes, 5340 skills, 200 agents)
    vibe-integration = {
      enable = true;
      autoInstallOnBoot = true;
    };

    # Skill packs (docs/skills.md), linked into every agent CLI's skills directory
    skills.enable = true;

    # MCP server registry (50+ preconfigured servers)
    mcp-servers = {
      enable = true;
      enableCore = true;
      enableDatabases = true;
      enableBrowser = true;
      enableAI = true;
      enableDevOps = true;
      enableData = true;
    };

    # Remaining modules
    networking-tools.enable = true;
    cloud-tools.enable = true;
    package-managers.enable = true;
    editors.enable = true;
    ai-ml.enable = true;
  };

  # ════════════════════════════════════════════════════════════════════
  # PRE-INSTALLED PACKAGES
  # ════════════════════════════════════════════════════════════════════

  environment.systemPackages = with pkgs; [
    # ── ALL coding agents (pre-installed) ────────────────────────────
    nestlo.all-agents

    # ── Nestlo internal tools ───────────────────────────────────────
    nestlo.cli

    # ── Language runtimes ────────────────────────────────────────────
    python3
    nodejs_22
    go
    rustc
    cargo
    gcc
    gnumake
    cmake

    # ── Dev tools ────────────────────────────────────────────────────
    git
    gh
    ripgrep
    fd
    jq
    fzf
    bat
    eza
    tree
    tmux
    htop
    btop
    vim
    neovim

    # ── Container / VM tools ─────────────────────────────────────────
    nerdctl
    kubectl

    # ── System tools ─────────────────────────────────────────────────
    curl
    wget
    unzip
    gzip
    xz
    sqlite
    openssl
  ];

  # ── Fonts (for agent-generated diagrams) ──────────────────────────
  fonts.fontconfig.enable = true;

  # ── Headless by default (nestlo.desktop.enable turns this on) ───
  services.xserver.enable = lib.mkDefault false;
  services.displayManager.enable = lib.mkDefault false;

  # ── Console ───────────────────────────────────────────────────────
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # ── MOTD (welcome message on login) ───────────────────────────────
  programs.bash.loginShellInit = ''
    if [ -t 1 ] && [ "$USER" = "admin" ]; then
      cat <<'BANNER'
    ╔══════════════════════════════════════════════╗
    ║                                              ║
    ║          A G E N t O S                       ║
    ║          An OS for coding agents             ║
    ║                                              ║
    ╚══════════════════════════════════════════════╝

    Agents: claude codex aider agy gemini qwen amp goose opencode crush
            cursor-agent copilot kilocode vibe kiro-cli codebuff pi grok
            droid cline cn interpreter

    Quick start:
      nestlo workspace create demo            Shared workspace
      nestlo spawn claude --workspace demo    Sandboxed, metered agent
      nestlo list                             Agents and spend today
      nestlo budget status                    Budgets
      nestlo help                             Everything else

    BANNER
    fi
  '';

  # ── Automatic updates (security) ──────────────────────────────────
  # Defaults only: nestlo.upgrade (modules/upgrade) overrides them and adds
  # the post-upgrade health gate with automatic rollback.
  system.autoUpgrade = {
    enable = true;
    allowReboot = lib.mkDefault false;
    dates = lib.mkDefault "04:00";
    flake = lib.mkDefault "github:anubhavg-icpl/nestlo";
  };

  system.stateVersion = "24.11";
}
