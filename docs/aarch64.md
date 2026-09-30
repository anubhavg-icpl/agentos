# ARM64 (aarch64-linux)

Every host configuration is built for both `x86_64-linux` and `aarch64-linux`.
The x86_64 names are plain, the aarch64 ones carry a suffix:

| x86_64 | aarch64 |
|---|---|
| `agentos` | `agentos-aarch64` |
| `agentos-vm` | `agentos-vm-aarch64` |
| `agentos-iso` | `agentos-iso-aarch64` |
| `agentos-desktop` | `agentos-desktop-aarch64` |
| `agentos-desktop-vm` | `agentos-desktop-vm-aarch64` |
| `agentos-desktop-iso` | `agentos-desktop-iso-aarch64` |

`packages.aarch64-linux` has `iso-image`, `vm-image`, `desktop-iso-image` and
`desktop-vm-image`, next to the agent packages. `agentos-install` picks the
`-aarch64` configuration on its own when run on an ARM machine.

Building for ARM needs an aarch64 builder or `boot.binfmt.emulatedSystems`
on an x86_64 machine (slow); the flake checks only evaluate them.

## What differs from x86_64

- The tool modules (language-toolchains, dev-tools, security-tools,
  browser-tools, cloud-tools, ai-ml, editors, databases, networking-tools,
  package-managers) pass their package lists through
  `modules/lib/available.nix`, which drops packages whose `meta.platforms`
  exclude the host, using `lib.meta.availableOn`. New tool lists should do the
  same:

  ```nix
  let avail = import ../lib/available.nix { inherit pkgs lib; }; in
  environment.systemPackages = avail (with pkgs; [ ... ]);
  ```
- `kvm-intel` / `kvm-amd` and the CPU microcode updates are only enabled on
  x86. ARM KVM is built into the kernel.
- The bootloader stays systemd-boot on UEFI, which ARM servers and
  QEMU (`-machine virt` with UEFI firmware) provide.

## Packages excluded on aarch64

Only `kotlin-native` (Kotlin/Native has no aarch64-linux host build). The
filter is by `meta.platforms`, so a package that claims aarch64 support but
has no binary cache entry is built from source (long for Zed, Chromium,
Swift, Julia).
