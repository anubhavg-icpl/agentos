# AgentOS installer - used by the live ISO to install to disk
#
# Partitions the target disk with the layout in nixos/hosts/agentos/disko.nix
# (via disko-install), installs the `agentos` configuration, and installs an
# SSH public key for the `admin` user (the installed system only allows
# key-based SSH login).
#
# With --desktop it installs the `agentos-desktop` configuration (window
# manager, IDEs, browser) and also asks for a local login password for admin.
#
# With --encrypt the root partition is a LUKS2 container (passphrase asked at
# install and at every boot). TPM2 auto-unlock is a follow-up, see
# nixos/hosts/agentos/disko.nix.
{ writeShellApplication, disko, coreutils, whois, openssh, util-linux, gnugrep }:

writeShellApplication {
  name = "agentos-install";
  runtimeInputs = [ disko coreutils whois openssh util-linux gnugrep ];
  text = ''
    usage() {
      cat <<'USAGE'
    Usage: agentos-install <disk> [--desktop] [--encrypt] [--ssh-key <public key>] [--flake <ref>]

      <disk>        Target disk, e.g. /dev/sda or /dev/nvme0n1 (will be ERASED)
      --desktop     Install the desktop edition (flake attr agentos-desktop)
                    and set a local login password for admin.
      --encrypt     Encrypt the root partition with LUKS2. You are asked for
                    a passphrase, needed at every boot.
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
    ENCRYPT=0

    while [ $# -gt 0 ]; do
      case "$1" in
        --ssh-key) SSH_KEY="''${2:-}"; shift 2 ;;
        --flake)   FLAKE="''${2:-}"; shift 2 ;;
        --encrypt) ENCRYPT=1; shift ;;
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

    # Every non-empty line must be a public key ssh-keygen can parse. A
    # private key is rejected explicitly: ssh-keygen would accept it too.
    keyfile="$(mktemp)"
    pwfile="$(mktemp)"
    lukspw="$(mktemp)"
    trap 'rm -f "$keyfile" "$pwfile" "$lukspw"' EXIT
    printf '%s\n' "$SSH_KEY" | grep -v '^[[:space:]]*$' > "$keyfile" || true
    if grep -q 'PRIVATE KEY' "$keyfile"; then
      echo "That is a private key. Give the PUBLIC key (the .pub file)." >&2
      exit 1
    fi
    if [ ! -s "$keyfile" ]; then
      echo "SSH key is empty." >&2
      exit 1
    fi
    while IFS= read -r line; do
      if ! printf '%s\n' "$line" | grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( .*)?$'; then
        echo "Not a valid SSH public key: ''${line:0:40}..." >&2
        echo "Expected e.g. 'ssh-ed25519 AAAA... comment'." >&2
        exit 1
      fi
      if ! printf '%s\n' "$line" | ssh-keygen -l -f - >/dev/null 2>&1; then
        echo "ssh-keygen cannot parse this key (truncated?): ''${line:0:40}..." >&2
        exit 1
      fi
    done < "$keyfile"

    echo "Target disk: $DISK"
    lsblk -o NAME,SIZE,TYPE,MODEL,FSTYPE,MOUNTPOINTS "$DISK" || true
    echo "Flake:       $FLAKE#$HOST"
    if [ "$ENCRYPT" -eq 1 ]; then
      echo "Encryption:  LUKS2 on the root partition"
    fi
    echo "This will ERASE everything on $DISK."
    read -rp "Type the device path ($DISK) to confirm: " confirm
    if [ "$confirm" != "$DISK" ]; then
      echo "Aborted: the typed path does not match."
      exit 1
    fi

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

    # LUKS2: the passphrase goes to a 0600 temp file that disko reads while
    # formatting (it is not stored on the installed system).
    extra_luks=()
    if [ "$ENCRYPT" -eq 1 ]; then
      while :; do
        read -rsp "Disk encryption passphrase: " lp1; echo
        read -rsp "Repeat passphrase: " lp2; echo
        if [ "''${#lp1}" -lt 8 ]; then
          echo "Use at least 8 characters."
        elif [ "$lp1" != "$lp2" ]; then
          echo "Passphrases do not match, try again."
        else
          break
        fi
      done
      printf '%s' "$lp1" > "$lukspw"
      unset lp1 lp2
      extra_luks=(--system-config "{\"agentos\":{\"disk\":{\"encrypt\":true,\"luksPasswordFile\":\"$lukspw\"}}}")
    fi

    disko-install \
      --flake "$FLAKE#$HOST" \
      --disk main "$DISK" \
      --write-efi-boot-entries \
      --extra-files "$keyfile" /home/admin/.ssh/authorized_keys \
      "''${extra_pw[@]}" \
      "''${extra_luks[@]}"

    if [ "$DESKTOP" -eq 1 ]; then
      echo "Done. Reboot to the login screen, or: ssh admin@<ip>"
    else
      echo "Done. Reboot, then: ssh admin@<ip>"
    fi
  '';
}
