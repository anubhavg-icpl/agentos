# AgentOS - Live ISO configuration
# Builds a bootable ISO that boots into a minimal agent-ready environment.
{ config, pkgs, lib, ... }:

{
  # ── ISO identity ───────────────────────────────────────────────────
  isoImage = {
    isoName = lib.mkForce "agentos-${config.system.nixos.version}.iso";
    volumeID = lib.mkForce "AGENTOS";
    makeEfiBootable = true;
    makeUsbBootable = true;
    squashfsCompression = "zstd -Xcompression-level 19";
  };

  # ── Kernel ────────────────────────────────────────────────────────
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelParams = [
    "quiet"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  # ── Hostname ──────────────────────────────────────────────────────
  networking.hostName = "agentos-live";
  networking.networkmanager.enable = true;
  networking.useDHCP = true;

  # ── SSH enabled on the ISO (for remote install) ───────────────────
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = lib.mkForce true;
  };

  # ── Live user (no password) ───────────────────────────────────────
  users.users.agentos-live = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "agentos";
  };
  security.sudo.wheelNeedsPassword = false;

  # ── Minimal agent tools on the ISO ────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Install tool
    agentos.installer

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

    To install:        agentos-install /dev/sda
    To start agent:    agentos spawn claude-code
    List agents:       agentos list

    SSH: ssh agentos-live@<ip>   (password: agentos)
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
  services.xserver.enable = false;

  system.stateVersion = "24.11";
}
