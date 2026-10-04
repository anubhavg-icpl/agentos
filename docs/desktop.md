# Desktop edition

AgentOS is headless by default. The desktop edition adds a graphical session
for people who want to sit in front of the machine: a tiling window manager,
one dark theme, audio, fonts, IDEs and a browser. The server host does not
change; everything below is opt-in.

## Getting it

| Output | What it is |
|---|---|
| `nixosConfigurations.agentos-desktop` | The `agentos` host plus the desktop (bare metal, installed with `agentos-install --desktop`) |
| `nixosConfigurations.agentos-desktop-vm` | The same as a QEMU/KVM guest |
| `nixosConfigurations.agentos-desktop-iso` | Live installer ISO with the desktop |
| `packages.<system>.desktop-vm-image` | Bootable qcow2 of the desktop VM (a random `admin` password is generated at first boot, shown on the console and in `/var/lib/agentos/first-boot-password`, and must be changed at first login) |
| `packages.<system>.desktop-iso-image` | The desktop live ISO (several GB larger than `iso-image`) |

```
nix build .#desktop-vm-image
nix build .#desktop-iso-image
sudo agentos-install /dev/nvme0n1 --desktop     # from a live ISO
```

`agentos-install --desktop` installs `agentos-desktop` (`agentos-desktop-aarch64`
on ARM) and asks for a password for `admin`. The server host only accepts SSH
keys, but a desktop needs a local login. The password hash is written to
`/etc/agentos/admin-password`, which `users.users.admin.hashedPasswordFile`
points at.

On a desktop host built without `agentos-install`, set
`agentos.desktop.initialHashedPassword` (from `mkpasswd -m yescrypt`) or create
`/etc/agentos/admin-password`; activation warns when neither exists.
`agentos-install --encrypt` puts the root filesystem on LUKS2 (passphrase at
boot; TPM2 unlock is on the roadmap).

## Enabling it on your own host

For sway or Hyprland, set `agentos.desktop.windowManager` in your host
configuration and rebuild. The flake does not ship separate host outputs for
them, which keeps `nix flake check` within CI memory.

```nix
agentos.desktop = {
  enable = true;
  windowManager = "i3";          # "i3" | "sway" | "hyprland"
  autologin.enable = false;      # off by default
};
```

Options: `gaps.inner` / `gaps.outer`, `compositor` (picom under i3),
`wallpaper`, `browser` (`firefox`, `chromium`, `none`), `bluetooth`,
`vscode.enable` / `vscode.fhs`, `zed.enable`, `jetbrains.enable` /
`jetbrains.ides`.

## What you get

- **Window managers.** i3 (X11, >= 4.22 for the built-in gaps), sway (Wayland,
  i3-compatible) and hyprland (Wayland). All share the same keybindings where
  the compositor allows it (`$mod` is Super).
- **Config without home-manager.** The i3 config is `/etc/xdg/i3/config`, the
  sway config `/etc/sway/config`; both apply to every user until they create
  `~/.config/i3/config` / `~/.config/sway/config`. Hyprland has no system-wide
  lookup path, so the greeter starts it with
  `--config /etc/agentos/desktop/hyprland.conf`; copy that file to
  `~/.config/hypr/hyprland.conf` and start Hyprland yourself to customise it.
- **Display manager.** i3 uses LightDM (best-supported X11 login manager,
  proper autologin). sway and hyprland use greetd with tuigreet, a text-mode
  greeter with no toolkit or GPU requirement. Starting X from greetd needs
  glue that NixOS does not test, so the two are not mixed.
- **Session pieces.** Status bar (i3status-rust under i3, waybar under
  sway/hyprland), rofi (i3) or fuzzel (Wayland) launcher, dunst / mako
  notifications, picom compositor (i3), feh / swaybg wallpaper, lock screen
  with idle locking (i3lock + xss-lock, swaylock + swayidle, hyprlock +
  hypridle), alacritty terminal, clipboard history (clipmenu / cliphist),
  screenshots (flameshot / grim + slurp + swappy), NetworkManager applet,
  polkit agent, gnome-keyring, PipeWire (with PulseAudio and ALSA
  compatibility), xdg portals, optional Bluetooth.
- **Dashboard.** `agentos status` and `agentos list` run in a hidden terminal
  that starts at login: `$mod+grave` shows or hides it (scratchpad on i3 and
  sway, special workspace on hyprland).
- **IDEs.** VS Code with extensions (Nix, Python + Pylance, Go, rust-analyzer,
  ESLint, Prettier, GitLens, TOML, YAML, direnv, Docker, One Dark Pro), Zed,
  and Firefox. JetBrains IDEs are off by default (large): set
  `agentos.desktop.jetbrains.enable = true`. neovim and helix come from the
  existing `editors` module.
- **Default editor settings** are copied to `~/.config/Code/User/settings.json`
  and `~/.config/zed/settings.json` on first login (only if missing).
- **Theme.** One Dark everywhere: alacritty, rofi/fuzzel, bars, notifications,
  lock screen, GTK (adw-gtk3-dark + Papirus-Dark), Qt (adwaita-dark), VS Code
  (One Dark Pro) and Zed (One Dark). The palette is
  `modules/desktop/theme.nix`.

### Keybindings

| Key | Action |
|---|---|
| `$mod+Return` | terminal |
| `$mod+d` | launcher |
| `$mod+Shift+q` | close window |
| `$mod+h/j/k/l` (or arrows) | focus; add `Shift` to move the window |
| `$mod+1..0` | workspace; add `Shift` to send the window there |
| `$mod+f` | fullscreen |
| `$mod+Shift+Space` | toggle floating |
| `$mod+r` | resize mode |
| `$mod+grave` | AgentOS dashboard |
| `$mod+c` | clipboard history |
| `$mod+Ctrl+l` | lock |
| `Print` / `$mod+Shift+s` | screenshot |
| `$mod+Shift+b` / `v` / `z` | browser / VS Code / Zed |
| `$mod+Shift+c` (i3, sway) | reload config |
| `$mod+Shift+e` | exit |

## Choices worth knowing

- **VS Code is `vscode` with `vscode-with-extensions`**, not `vscode-fhs`: the
  extension set is declarative and reproducible. The trade-off is that
  extensions installed at runtime from the marketplace cannot run unpatched
  binaries. Set `agentos.desktop.vscode.fhs = true` for `vscode-fhs` (no
  pre-installed extensions) if you prefer that.
- **Hyprland needs GPU acceleration.** It performs poorly or fails in VMs
  without 3D support. Use i3 or sway in VMs; the VM image and live ISO default
  to i3.
- **The VM image has no fixed password.** A random `admin` password is
  generated at first boot (see the artifacts table above) and must be changed
  at first login. SSH password login stays disabled.

## Testing

`tests/desktop.nix` boots the desktop module in a VM with i3 and LightDM
autologin, waits for the i3 IPC socket (version >= 4.22), validates the shipped
config with `i3 -C`, checks the bar, dunst and the dashboard terminal, opens a
terminal, takes screenshots, and checks that VS Code, Zed and Firefox are
installed:

```
nix build .#checks.x86_64-linux.desktop
```

It exercises the desktop module alone (not the full server host) to keep the VM
small. The sway and hyprland configs are not covered by a VM test; their
generated config files were validated with `sway -C` and
`Hyprland --verify-config`.
