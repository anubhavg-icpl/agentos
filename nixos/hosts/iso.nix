# Nestlo - Live ISO configuration
# Builds a bootable ISO that boots into a minimal agent-ready environment.
{ config, pkgs, lib, ... }:

{
  # ── ISO identity ───────────────────────────────────────────────────
  image.baseName = lib.mkForce "nestlo-${config.system.nixos.version}";

  isoImage = {
    volumeID = lib.mkForce "NESTLO";
    makeEfiBootable = true;
    makeUsbBootable = true;
    squashfsCompression = "zstd -Xcompression-level 19";
  };

  # ── Kernel ────────────────────────────────────────────────────────
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # ZFS usually lags the latest kernel; Nestlo installs to btrfs anyway
  boot.supportedFilesystems.zfs = lib.mkForce false;
  boot.kernelParams = [
    "quiet"
    "systemd.show_status=false"
    "udev.log_level=3"
  ];

  # ── Hostname ──────────────────────────────────────────────────────
  networking.hostName = "nestlo-live";
  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  # ── SSH on the ISO (key-only) ──────────────────────────────────────
  # The live user and root have empty passwords for the console, so sshd
  # must never accept passwords: keys only. To install over SSH, add a
  # public key to ~/.ssh/authorized_keys of nestlo-live on the console
  # (nestlo-install also offers that key to the installed admin user).
  # An assertion below keeps this from regressing.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = lib.mkForce false;
      KbdInteractiveAuthentication = lib.mkForce false;
      PermitEmptyPasswords = lib.mkForce false;
      PermitRootLogin = lib.mkForce "prohibit-password";
    };
  };

  assertions = [{
    assertion =
      let s = config.services.openssh.settings;
      in !config.services.openssh.enable || (
        s.PasswordAuthentication == false
        && s.KbdInteractiveAuthentication == false
        && !(builtins.elem (s.PermitEmptyPasswords or false) [ true "yes" ])
        && s.PermitRootLogin != "yes"
      );
    message = ''
      The live ISO has empty-password accounts (nestlo-live, root). sshd
      must be disabled or key-only there: set PasswordAuthentication,
      KbdInteractiveAuthentication and PermitEmptyPasswords to false and do
      not allow PermitRootLogin = "yes".
    '';
  }];

  # ── Live user ─────────────────────────────────────────────────────
  users.users.nestlo-live = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
    initialHashedPassword = "";
  };
  services.getty.autologinUser = lib.mkForce "nestlo-live";
  security.sudo.wheelNeedsPassword = false;

  # ── Minimal agent tools on the ISO ────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Install tool
    nestlo.installer

    # Nestlo CLIs (small: shell scripts and a pure-Python package). The
    # agents themselves are NOT on the ISO: all-agents is over 1 GB, see
    # docs/ISO-SIZE.md. They are installed with the system.
    nestlo.cli
    nestlo.services # nestlo-fleet, nestlo-market, nestlo-gpu, ...
    nestlo.task-cli
    nestlo.schedule-cli

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
    ║          Nestlo Live ISO                 ║
    ║          An OS for coding agents          ║
    ╚══════════════════════════════════════════╝

    To install:        sudo nestlo-install /dev/sda

    For SSH access (keys only), add a public key:
      mkdir -p ~/.ssh && echo "ssh-ed25519 AAAA..." >> ~/.ssh/authorized_keys
    BANNER
  '';

  # ── No Nestlo services on the ISO (just the installer) ───────────
  nestlo = {
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
