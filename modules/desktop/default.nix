# ═══════════════════════════════════════════════════════════════════════
# AgentOS Desktop Module
# ═══════════════════════════════════════════════════════════════════════
#
# An optional graphical session for developers who want to sit in front of
# AgentOS: a tiling window manager (i3, sway or hyprland) with one dark
# theme, audio, fonts, IDEs and a browser. Off by default: the server host
# stays headless.
#
#   agentos.desktop = {
#     enable = true;
#     windowManager = "i3";   # or "sway" / "hyprland"
#   };
#
# Display manager: i3 is an X11 window manager, so it uses LightDM (the
# best-supported X11 login manager, with a proper autologin path). sway and
# hyprland are Wayland compositors and use greetd + tuigreet, a tiny
# text-mode greeter that needs no GPU and no toolkit. One DM cannot serve
# both cleanly: starting X from greetd needs extra glue that the NixOS
# tests do not cover.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.desktop;
  c = import ./common.nix { inherit config pkgs lib; };
  inherit (c) p;
  avail = import ../lib/available.nix { inherit pkgs lib; };

  wayland = cfg.windowManager != "i3";

  # VS Code with extensions from nixpkgs. Plain `vscode` (not vscode-fhs) is
  # used so the extensions can be pinned declaratively; set
  # vscode.fhs = true to get vscode-fhs instead, where extensions installed
  # from the marketplace at runtime can run unpatched binaries.
  vscodePackage =
    if cfg.vscode.fhs then pkgs.vscode-fhs
    else pkgs.vscode-with-extensions.override {
      vscodeExtensions = avail (with pkgs.vscode-extensions; [
        zhuangtongfa.material-theme # One Dark Pro
        jnoortheen.nix-ide
        ms-python.python
        ms-python.vscode-pylance
        ms-python.debugpy
        ms-python.black-formatter
        golang.go
        rust-lang.rust-analyzer
        dbaeumer.vscode-eslint
        esbenp.prettier-vscode
        eamodio.gitlens
        tamasfe.even-better-toml
        redhat.vscode-yaml
        mkhl.direnv
        ms-azuretools.vscode-docker
        editorconfig.editorconfig
        usernamehw.errorlens
      ]);
    };

  # Session command of the Wayland compositors, run by greetd
  sessionCmd =
    let env = "XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=${cfg.windowManager} XDG_SESSION_DESKTOP=${cfg.windowManager}"; in
    if cfg.windowManager == "sway" then
      "${pkgs.coreutils}/bin/env ${env} ${config.programs.sway.package}/bin/sway"
    else
      "${config.programs.hyprland.package}/bin/start-hyprland -- --config /etc/agentos/desktop/hyprland.conf";
in
{
  imports = [ ./i3.nix ./sway.nix ./hyprland.nix ];

  options.agentos.desktop = {
    enable = lib.mkEnableOption "the AgentOS graphical desktop (window manager, IDEs, browser)";

    windowManager = lib.mkOption {
      type = lib.types.enum [ "i3" "sway" "hyprland" ];
      default = "i3";
      description = ''
        The window manager. i3 runs on X11 and works everywhere, including
        VMs. sway is its Wayland counterpart. hyprland is a Wayland
        compositor with animations that needs GPU acceleration; it performs
        poorly or not at all in VMs without 3D support.
      '';
    };

    autologin = {
      enable = lib.mkEnableOption "automatic login of `autologin.user` at boot (off by default; for VMs and live media)";
      user = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "User logged in automatically.";
      };
    };

    gaps = {
      inner = lib.mkOption {
        type = lib.types.ints.between 0 64;
        default = 8;
        description = "Gap between windows, in pixels.";
      };
      outer = lib.mkOption {
        type = lib.types.ints.between 0 64;
        default = 4;
        description = "Gap between windows and the screen edge, in pixels.";
      };
    };

    compositor = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run picom (shadows, rounded corners, fading) under i3. Wayland sessions always composite.";
    };

    wallpaper = lib.mkOption {
      type = lib.types.path;
      default = c.wallpaper;
      defaultText = lib.literalMD "a generated dark gradient";
      description = "Wallpaper image.";
    };

    browser = lib.mkOption {
      type = lib.types.enum [ "firefox" "chromium" "none" ];
      default = "firefox";
      description = "The desktop web browser.";
    };

    bluetooth = lib.mkEnableOption "Bluetooth (bluez and the blueman tray applet)";

    vscode = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install VS Code (unfree) with a set of language extensions.";
      };
      fhs = lib.mkEnableOption "vscode-fhs instead of a fixed extension set (lets marketplace extensions run unpatched binaries)";
    };

    zed.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install the Zed editor.";
    };

    jetbrains = {
      enable = lib.mkEnableOption "JetBrains IDEs (large downloads; the IDE list is in `jetbrains.ides`)";
      ides = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "idea-oss" ];
        example = [ "idea-oss" "pycharm-oss" "goland" ];
        description = "Attribute names in `pkgs.jetbrains` to install.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      hardware.graphics.enable = true;

      # ── Audio (PipeWire with PulseAudio and ALSA compatibility) ─────
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
      services.pulseaudio.enable = false;

      hardware.bluetooth.enable = cfg.bluetooth;
      services.blueman.enable = cfg.bluetooth;

      # ── Fonts ───────────────────────────────────────────────────────
      fonts = {
        enableDefaultPackages = true;
        packages = with pkgs; [
          nerd-fonts.jetbrains-mono
          noto-fonts
          noto-fonts-color-emoji
          font-awesome
          liberation_ttf
        ];
        fontconfig.defaultFonts = {
          monospace = [ p.monoFont ];
          sansSerif = [ p.uiFont ];
          serif = [ "Noto Serif" ];
          emoji = [ "Noto Color Emoji" ];
        };
      };

      # ── Desktop plumbing ────────────────────────────────────────────
      security.polkit.enable = true;
      services.gnome.gnome-keyring.enable = true;
      services.upower.enable = true;
      services.gvfs.enable = true;
      services.udev.packages = [ pkgs.brightnessctl ];
      services.libinput.enable = true;
      networking.networkmanager.enable = true;

      xdg.portal = {
        enable = true;
        extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
        config.common.default = lib.mkDefault [ "gtk" ];
      };

      # ── One dark theme for GTK, Qt and the terminal ────────────────
      programs.dconf = {
        enable = true;
        profiles.user.databases = [{
          settings."org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = p.gtkTheme;
            icon-theme = p.iconTheme;
            font-name = "${p.uiFont} 10";
            monospace-font-name = "${p.monoFont} 10";
          };
        }];
      };
      qt = {
        enable = true;
        platformTheme = "gnome";
        style = "adwaita-dark";
      };
      environment.etc =
        let
          gtkSettings = ''
            [Settings]
            gtk-theme-name=${p.gtkTheme}
            gtk-icon-theme-name=${p.iconTheme}
            gtk-font-name=${p.uiFont} 10
            gtk-application-prefer-dark-theme=1
          '';
        in
        {
          "xdg/gtk-3.0/settings.ini".text = gtkSettings;
          "xdg/gtk-4.0/settings.ini".text = gtkSettings;
          "alacritty/alacritty.toml".source = c.alacrittyConfig;
        };
      environment.sessionVariables = {
        XCURSOR_THEME = "Adwaita";
        XCURSOR_SIZE = "24";
      } // lib.optionalAttrs wayland {
        NIXOS_OZONE_WL = "1"; # Electron/Chromium apps use Wayland
      };

      # ── Applications ────────────────────────────────────────────────
      programs.firefox.enable = cfg.browser == "firefox";
      environment.systemPackages =
        (with pkgs; [
          alacritty
          adw-gtk3
          papirus-icon-theme
          adwaita-icon-theme
          networkmanagerapplet
          polkit_gnome
          pavucontrol
          playerctl
          brightnessctl
          libnotify
          xdg-utils
          pcmanfm
          c.seed
          c.dashboard
        ])
        ++ lib.optional (cfg.browser == "chromium") pkgs.chromium
        ++ lib.optional cfg.vscode.enable vscodePackage
        ++ lib.optional cfg.zed.enable pkgs.zed-editor
        ++ lib.optionals cfg.jetbrains.enable
          (map (name: pkgs.jetbrains.${name}) cfg.jetbrains.ides);
    }

    # ── X11: LightDM for i3 ───────────────────────────────────────────
    (lib.mkIf (!wayland) {
      services.xserver.displayManager.lightdm = {
        enable = true;
        background = cfg.wallpaper;
        greeters.gtk = {
          enable = true;
          theme = { package = pkgs.adw-gtk3; name = p.gtkTheme; };
          iconTheme = { package = pkgs.papirus-icon-theme; name = p.iconTheme; };
        };
      };
      services.displayManager.autoLogin = lib.mkIf cfg.autologin.enable {
        enable = true;
        user = cfg.autologin.user;
      };
      security.pam.services.lightdm.enableGnomeKeyring = true;
    })

    # ── Wayland: greetd + tuigreet for sway and hyprland ──────────────
    (lib.mkIf wayland {
      services.greetd = {
        enable = true;
        useTextGreeter = true;
        settings = {
          default_session.command =
            "${pkgs.tuigreet}/bin/tuigreet --time --remember --asterisks --cmd '${sessionCmd}'";
        } // lib.optionalAttrs cfg.autologin.enable {
          initial_session = { command = sessionCmd; user = cfg.autologin.user; };
        };
      };
      security.pam.services.greetd.enableGnomeKeyring = true;
    })
  ]);
}
