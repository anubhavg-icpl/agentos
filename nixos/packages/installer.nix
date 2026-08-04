# AgentOS installer - used by the ISO to install to disk
{ stdenv, writeShellScriptBin, coreutils, nix, git }:

writeShellScriptBin "agentos-install" ''
  #!${stdenv.shell}
  set -euo pipefail

  DISK="''${1:-}"
  if [ -z "$DISK" ]; then
    echo "Usage: agentos-install <disk> [e.g. /dev/sda or /dev/nvme0n1]"
    exit 1
  fi

  echo "╔══════════════════════════════════════════╗"
  echo "║   AgentOS Installer                       ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""
  echo "Target disk: $DISK"
  echo ""
  read -rp "This will ERASE $DISK. Continue? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 1
  fi

  # Partition
  echo "[1/5] Partitioning $DISK..."
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+1G -t 1:ef00 "$DISK"    # EFI
  sgdisk -n 2:0:0   -t 2:8300 "$DISK"    # Root

  # btrfs on root
  echo "[2/5] Creating btrfs filesystem..."
  mkfs.fat -F32 "''${DISK}1"
  mkfs.btrfs -f "''${DISK}2"

  # Mount
  echo "[3/5] Mounting..."
  mount -o compress=zstd "''${DISK}2" /mnt
  mkdir -p /mnt/boot
  mount "''${DISK}1" /mnt/boot

  # Install
  echo "[4/5] Installing NixOS (AgentOS config)..."
  nixos-install --flake github:yourorg/agentos#agentos --root /mnt

  echo "[5/5] Done. Reboot to start AgentOS."
''
