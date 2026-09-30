# AgentOS installer - used by the live ISO to install to disk
#
# Partitions the target disk with the layout in nixos/hosts/agentos/disko.nix
# (via disko-install), installs the `agentos` configuration, and installs an
# SSH public key for the `admin` user (the installed system only allows
# key-based SSH login).
{ writeShellApplication, disko, coreutils }:

writeShellApplication {
  name = "agentos-install";
  runtimeInputs = [ disko coreutils ];
  text = ''
    usage() {
      cat <<'USAGE'
    Usage: agentos-install <disk> [--ssh-key <public key>] [--flake <ref>]

      <disk>        Target disk, e.g. /dev/sda or /dev/nvme0n1 (will be ERASED)
      --ssh-key     Public key for the admin user. Defaults to the live
                    user's ~/.ssh/authorized_keys if present.
      --flake       Flake to install from
                    (default: github:anubhavg-icpl/agentos)
    USAGE
    }

    DISK=""
    SSH_KEY=""
    FLAKE="github:anubhavg-icpl/agentos"

    while [ $# -gt 0 ]; do
      case "$1" in
        --ssh-key) SSH_KEY="''${2:-}"; shift 2 ;;
        --flake)   FLAKE="''${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)         DISK="$1"; shift ;;
      esac
    done

    if [ -z "$DISK" ]; then
      usage
      exit 1
    fi
    if [ ! -b "$DISK" ]; then
      echo "Not a block device: $DISK" >&2
      exit 1
    fi
    if [ "$(id -u)" -ne 0 ]; then
      echo "Run as root (sudo agentos-install ...)" >&2
      exit 1
    fi

    if [ -z "$SSH_KEY" ] && [ -n "''${SUDO_USER:-}" ]; then
      live_keys="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
      if [ -s "$live_keys" ]; then
        SSH_KEY="$(cat "$live_keys")"
      fi
    fi
    if [ -z "$SSH_KEY" ]; then
      echo "The installed system only accepts SSH key logins for 'admin'."
      read -rp "Paste an SSH public key for admin: " SSH_KEY
    fi
    if [ -z "$SSH_KEY" ]; then
      echo "No SSH key given; refusing to install a system you cannot log into." >&2
      exit 1
    fi

    echo "Target disk: $DISK"
    echo "Flake:       $FLAKE#agentos"
    read -rp "This will ERASE $DISK. Continue? [y/N] " confirm
    case "$confirm" in
      y|Y) ;;
      *) echo "Aborted."; exit 1 ;;
    esac

    keyfile="$(mktemp)"
    trap 'rm -f "$keyfile"' EXIT
    printf '%s\n' "$SSH_KEY" > "$keyfile"

    disko-install \
      --flake "$FLAKE#agentos" \
      --disk main "$DISK" \
      --write-efi-boot-entries \
      --extra-files "$keyfile" /home/admin/.ssh/authorized_keys

    echo "Done. Reboot, then: ssh admin@<ip>"
  '';
}
