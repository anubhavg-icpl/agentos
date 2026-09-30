# AgentOS installer - used by the live ISO to install to disk
#
# Partitions the target disk with the layout in nixos/hosts/agentos/disko.nix
# (via disko-install), installs the `agentos` configuration, and installs an
# SSH public key for the `admin` user (the installed system only allows
# key-based SSH login).
#
# With --desktop it installs the `agentos-desktop` configuration (window
# manager, IDEs, browser) and also asks for a local login password for admin.
{ writeShellApplication, disko, coreutils, whois }:

writeShellApplication {
  name = "agentos-install";
  runtimeInputs = [ disko coreutils whois ];
  text = ''
    usage() {
      cat <<'USAGE'
    Usage: agentos-install <disk> [--desktop] [--ssh-key <public key>] [--flake <ref>]

      <disk>        Target disk, e.g. /dev/sda or /dev/nvme0n1 (will be ERASED)
      --desktop     Install the desktop edition (flake attr agentos-desktop)
                    and set a local login password for admin.
      --ssh-key     Public key for the admin user. Defaults to the live
                    user's ~/.ssh/authorized_keys if present.
      --flake       Flake to install from
                    (default: github:anubhavg-icpl/agentos)
    USAGE
    }

    DISK=""
    SSH_KEY=""
    FLAKE="github:anubhavg-icpl/agentos"
    HOST="agentos"
    DESKTOP=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --ssh-key) SSH_KEY="''${2:-}"; shift 2 ;;
        --flake)   FLAKE="''${2:-}"; shift 2 ;;
        --desktop) DESKTOP=1; HOST="agentos-desktop"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         DISK="$1"; shift ;;
      esac
    done

    # The aarch64 configurations carry an -aarch64 suffix
    case "$(uname -m)" in
      aarch64|arm64) HOST="$HOST-aarch64" ;;
    esac

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
    echo "Flake:       $FLAKE#$HOST"
    read -rp "This will ERASE $DISK. Continue? [y/N] " confirm
    case "$confirm" in
      y|Y) ;;
      *) echo "Aborted."; exit 1 ;;
    esac

    keyfile="$(mktemp)"
    pwfile="$(mktemp)"
    trap 'rm -f "$keyfile" "$pwfile"' EXIT
    printf '%s\n' "$SSH_KEY" > "$keyfile"

    # The desktop has a local login: hash a password for admin. The system
    # reads the hash from /etc/agentos/admin-password (hashedPasswordFile).
    extra_pw=()
    if [ "$DESKTOP" -eq 1 ]; then
      while :; do
        read -rsp "Password for admin (local desktop login): " pw1; echo
        read -rsp "Repeat password: " pw2; echo
        [ -n "$pw1" ] && [ "$pw1" = "$pw2" ] && break
        echo "Passwords are empty or do not match, try again."
      done
      printf '%s\n' "$pw1" | mkpasswd -m yescrypt -s > "$pwfile"
      unset pw1 pw2
      extra_pw=(--extra-files "$pwfile" /etc/agentos/admin-password)
    fi

    disko-install \
      --flake "$FLAKE#$HOST" \
      --disk main "$DISK" \
      --write-efi-boot-entries \
      --extra-files "$keyfile" /home/admin/.ssh/authorized_keys \
      "''${extra_pw[@]}"

    if [ "$DESKTOP" -eq 1 ]; then
      echo "Done. Reboot to the login screen, or: ssh admin@<ip>"
    else
      echo "Done. Reboot, then: ssh admin@<ip>"
    fi
  '';
}
