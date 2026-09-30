# ═══════════════════════════════════════════════════════════════════════
# AgentOS — Default Host Configuration
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
  boot.kernelModules = [ "kvm-intel" "btrfs" "overlay" "bridge" "veth" ];

  # ── Hostname ───────────────────────────────────────────────────────
  networking.hostName = "agentos";
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
    extraGroups = [ "wheel" "containerd" "agentos" ];
    # agentos-install writes the key given at install time to
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
  # AGENTOS MODULES
  # ════════════════════════════════════════════════════════════════════
  agentos = {
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
      mode = "planner-worker";
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
      enableWebhook = true;
      notifyOn = [ "task-completed" "approval-needed" "budget-threshold" "agent-error" "pr-created" ];
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
      maxConcurrent = 4;
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
    agentos.all-agents

    # ── AgentOS internal tools ───────────────────────────────────────
    agentos.cli

    # ── Language runtimes ────────────────────────────────────────────
    python311
    python311Packages.pip
    nodejs_22
    go_1_23
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

  # ── NO desktop environment (headless) ─────────────────────────────
  services.xserver.enable = false;
  services.displayManager.enable = false;

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

    Pre-installed agents:
      claude         Anthropic Claude Code
      codex          OpenAI Codex CLI
      droid          Factory Droid
      aider          AI pair programmer
      gemini         Google Gemini CLI
      qwen-code      Alibaba Qwen Code
      amp            Sourcegraph Amp
      goose          Block Goose
      opencode       OpenCode (SST)
      crush          Charm Crush
      cursor         Cursor CLI
      cline          Cline agent
      continue       Continue Dev
      copilot        GitHub Copilot CLI
      devin          Devin CLI (Cognition)
      roo            Roo Code
      interpreter    Open Interpreter
      sweagent       SWE-Agent (Princeton)
      gpt-engineer   GPT-Engineer
      devika         Devika
      autogpt        AutoGPT
      smol-developer smol-developer

    Quick start:
      agentos list                 See running agents
      agentos spawn claude-code    Start an agent
      agentos budget               Check token spend
      agentos install <pkg>        Install additional tools

    BANNER
    fi
  '';

  # ── Automatic updates (security) ──────────────────────────────────
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
    dates = "04:00";
    flake = "github:anubhavg-icpl/agentos";
  };

  system.stateVersion = "24.11";
}
