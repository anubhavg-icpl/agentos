# AgentOS - Live ISO configuration
# Builds a bootable ISO that boots into a minimal agent-ready environment.
{ config, pkgs, lib, ... }:

{
  # ── ISO identity ───────────────────────────────────────────────────
  image.baseName = lib.mkForce "agentos-${config.system.nixos.version}";

  isoImage = {
    volumeID = lib.mkForce "AGENTOS";
    makeEfiBootable = true;
    makeUsbBootable = true;
    squashfsCompression = "zstd -Xcompression-level 19";
  };

  # ── Kernel ────────────────────────────────────────────────────────
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # ZFS usually lags the latest kernel; AgentOS installs to btrfs anyway
  boot.supportedFilesystems.zfs = lib.mkForce false;
  boot.kernelParams = [
    "quiet"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  # ── Hostname ──────────────────────────────────────────────────────
  networking.hostName = "agentos-live";
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  # ── SSH enabled on the ISO (for remote install) ───────────────────
  # There is no default password. To install over SSH, set one on the
  # console first with `passwd`, or add a key to
  # users.users.agentos-live.openssh.authorizedKeys.keys and rebuild.
  services.openssh.enable = true;

  # ── Live user ─────────────────────────────────────────────────────
  users.users.agentos-live = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialHashedPassword = "";
  };
  services.getty.autologinUser = lib.mkForce "agentos-live";
  security.sudo.wheelNeedsPassword = false;

  # ── Minimal agent tools on the ISO ────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Install tool
    agentos.installer

    # AgentOS CLIs (small: shell scripts and a pure-Python package). The
    # agents themselves are NOT on the ISO: all-agents is over 1 GB, see
    # docs/ISO-SIZE.md. They are installed with the system.
    agentos.cli
    agentos.services # agentos-fleet, agentos-market, agentos-gpu, ...
    agentos.task-cli
    agentos.schedule-cli

    # Essential
    git
    vim
    curl
    wget
    ripgrep
    fd
    jq
    btop
    tmux

    # Disk tools
    parted
    gptfdisk
    btrfs-progs

    # Nix
    nixVersions.stable
  ];

  # ── Nix flakes enabled on ISO ─────────────────────────────────────
  nix.extraOptions = ''
    experimental-features = nix-command flakes
  '';

  # ── Console welcome message ───────────────────────────────────────
  programs.bash.loginShellInit = ''
    cat <<'BANNER'
    ╔══════════════════════════════════════════╗
    ║          AgentOS Live ISO                 ║
    ║          An OS for coding agents          ║
    ╚══════════════════════════════════════════╝

    To install:        sudo agentos-install /dev/sda

    For SSH access, set a password first:  passwd
    BANNER
  '';

  # ── No AgentOS services on the ISO (just the installer) ───────────
  agentos = {
    runtime.enable = lib.mkForce false;
    security.enable = lib.mkForce false;
    observability.enable = lib.mkForce false;
    storage.enable = lib.mkForce false;
    networking.enable = lib.mkForce false;
  };

  # ── Disable GUI ───────────────────────────────────────────────────
  services.xserver.enable = lib.mkDefault false;

  system.stateVersion = "24.11";
}
