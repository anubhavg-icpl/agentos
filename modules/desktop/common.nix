# Pieces shared by the i3, sway and hyprland sessions: the palette, helper
# scripts, and generated config files for the terminal, launcher,
# notification daemon, compositor and bars.
{ config, pkgs, lib }:

let
  cfg = config.agentos.desktop;
  p = import ./theme.nix;
  hex = lib.removePrefix "#";
  toml = pkgs.formats.toml { };
  json = pkgs.formats.json { };
  # Nerd Font glyph from its code point (keeps the source ASCII)
  g = code: builtins.fromJSON ''"\u${code}"'';
in
rec {
  inherit cfg p hex;

  # ── Wallpaper: a dark vertical gradient, no binary asset in the repo ──
  wallpaper = pkgs.runCommand "agentos-wallpaper.png"
    { nativeBuildInputs = [ pkgs.imagemagick ]; }
    ''magick -size 3840x2160 gradient:'${p.bg}-${p.bgAlt}' $out'';

  # ── Helper scripts ────────────────────────────────────────────────
  # Live view of the agent fleet; started hidden (scratchpad) at login.
  dashboard = pkgs.writeShellScriptBin "agentos-dashboard" ''
    while true; do
      clear
      printf '  AgentOS  %s\n\n' "$(date '+%a %d %b  %H:%M:%S')"
      if command -v agentos >/dev/null 2>&1; then
        agentos status 2>&1
        echo
        agentos list 2>&1
      else
        echo "  the agentos CLI is not installed on this system"
      fi
      sleep 10
    done
  '';

  # Copies the default editor settings into $HOME on first login. The files
  # are copied (not linked) so the editors can write to them afterwards.
  vscodeSettings = json.generate "vscode-settings.json" {
    "workbench.colorTheme" = "One Dark Pro";
    "editor.fontFamily" = "'${p.monoFont}', monospace";
    "editor.fontLigatures" = true;
    "terminal.integrated.fontFamily" = p.monoFont;
    "nix.enableLanguageServer" = true;
    "nix.serverPath" = "nixd";
    "telemetry.telemetryLevel" = "off";
    "update.mode" = "none";
    "extensions.autoUpdate" = false;
    "extensions.autoCheckUpdates" = false;
    "window.titleBarStyle" = "custom";
    "files.autoSave" = "afterDelay";
  };
  zedSettings = json.generate "zed-settings.json" {
    theme = "One Dark";
    buffer_font_family = p.monoFont;
    buffer_font_size = 14;
    ui_font_size = 16;
    telemetry = { diagnostics = false; metrics = false; };
    auto_update = false;
  };
  seed = pkgs.writeShellScriptBin "agentos-desktop-seed" ''
    cfg="''${XDG_CONFIG_HOME:-$HOME/.config}"
    seed() {
      [ -e "$2" ] && return 0
      mkdir -p "$(dirname "$2")"
      cp --no-preserve=mode "$1" "$2"
    }
    ${lib.optionalString cfg.vscode.enable ''seed ${vscodeSettings} "$cfg/Code/User/settings.json"''}
    ${lib.optionalString cfg.zed.enable ''seed ${zedSettings} "$cfg/zed/settings.json"''}
  '';

  # ── Terminal (alacritty on every session; works on X11 and Wayland) ──
  terminal = lib.getExe pkgs.alacritty;
  alacrittyConfig = toml.generate "alacritty.toml" {
    window = {
      padding = { x = 8; y = 8; };
      opacity = 0.96;
    };
    font = {
      normal.family = p.monoFont;
      size = 11;
    };
    colors = {
      primary = { background = p.bg; foreground = p.fg; };
      cursor = { text = p.bg; cursor = p.blue; };
      selection = { text = p.fgBright; background = p.bgHighlight; };
      normal = {
        black = p.bg; red = p.red; green = p.green; yellow = p.yellow;
        blue = p.blue; magenta = p.magenta; cyan = p.cyan; white = p.fg;
      };
      bright = {
        black = p.muted; red = p.red; green = p.green; yellow = p.yellow;
        blue = p.blue; magenta = p.magenta; cyan = p.cyan; white = p.fgBright;
      };
    };
  };

  # ── Launcher (rofi on X11, fuzzel on Wayland) ─────────────────────
  rofiTheme = pkgs.writeText "agentos.rasi" ''
    * {
      bg: ${p.bg}; bg-alt: ${p.bgAlt}; hl: ${p.bgHighlight};
      fg: ${p.fg}; fg-bright: ${p.fgBright}; accent: ${p.blue};
      background-color: transparent;
      text-color: @fg;
    }
    configuration {
      font: "${p.monoFont} 11";
      show-icons: true;
      icon-theme: "${p.iconTheme}";
    }
    window {
      width: 40%;
      background-color: @bg;
      border: 2px;
      border-color: @accent;
      border-radius: 8px;
    }
    mainbox { padding: 8px; }
    inputbar {
      background-color: @bg-alt;
      border-radius: 6px;
      padding: 8px;
      spacing: 8px;
      children: [ prompt, entry ];
    }
    prompt { text-color: @accent; }
    listview { lines: 10; margin: 8px 0 0 0; scrollbar: false; }
    element { padding: 6px; border-radius: 6px; spacing: 8px; }
    element selected.normal { background-color: @hl; text-color: @fg-bright; }
    element-text { highlight: bold ${p.blue}; }
  '';
  fuzzelConfig = pkgs.writeText "fuzzel.ini" ''
    [main]
    font=${p.monoFont}:size=11
    terminal=${terminal} -e
    prompt="> "
    icon-theme=${p.iconTheme}
    width=40
    lines=10

    [colors]
    background=${hex p.bg}f2
    text=${hex p.fg}ff
    match=${hex p.blue}ff
    selection=${hex p.bgHighlight}ff
    selection-text=${hex p.fgBright}ff
    border=${hex p.blue}ff

    [border]
    width=2
    radius=8
  '';

  # ── Notifications (dunst on X11, mako on Wayland) ─────────────────
  dunstrc = pkgs.writeText "dunstrc" ''
    [global]
      font = ${p.monoFont} 10
      width = 340
      origin = top-right
      offset = 16x16
      frame_width = 2
      frame_color = "${p.blue}"
      corner_radius = 8
      gap_size = 6
      padding = 10
      horizontal_padding = 12
      icon_theme = ${p.iconTheme}
      enable_recursive_icon_lookup = true
      mouse_left_click = close_current
      mouse_right_click = close_all

    [urgency_low]
      background = "${p.bg}"
      foreground = "${p.muted}"
      timeout = 4

    [urgency_normal]
      background = "${p.bg}"
      foreground = "${p.fg}"
      timeout = 8

    [urgency_critical]
      background = "${p.bg}"
      foreground = "${p.fgBright}"
      frame_color = "${p.red}"
      timeout = 0
  '';
  makoConfig = pkgs.writeText "mako-config" ''
    font=${p.monoFont} 10
    background-color=${p.bg}
    text-color=${p.fg}
    border-color=${p.blue}
    border-size=2
    border-radius=8
    padding=10
    margin=12
    width=340
    default-timeout=8000

    [urgency=critical]
    border-color=${p.red}
    default-timeout=0
  '';

  # ── X11 compositor ────────────────────────────────────────────────
  picomConfig = pkgs.writeText "picom.conf" ''
    backend = "glx";
    vsync = true;
    corner-radius = 8;
    rounded-corners-exclude = [ "window_type = 'dock'" ];
    shadow = true;
    shadow-radius = 14;
    shadow-opacity = 0.45;
    shadow-exclude = [ "window_type = 'dock'", "_GTK_FRAME_EXTENTS@" ];
    fading = true;
    fade-in-step = 0.04;
    fade-out-step = 0.04;
    inactive-opacity = 1.0;
    detect-client-opacity = true;
    use-damage = true;
  '';

  # ── i3 status bar ─────────────────────────────────────────────────
  i3statusConfig = toml.generate "i3status-rust.toml" {
    theme = {
      theme = "plain";
      overrides = {
        idle_bg = p.bg; idle_fg = p.fg;
        info_bg = p.bg; info_fg = p.blue;
        good_bg = p.bg; good_fg = p.green;
        warning_bg = p.bg; warning_fg = p.yellow;
        critical_bg = p.bg; critical_fg = p.red;
        separator = " ";
        separator_bg = p.bg; separator_fg = p.muted;
      };
    };
    icons.icons = "awesome6";
    block = [
      { block = "disk_space"; path = "/"; info_type = "available"; interval = 60; warning = 20.0; alert = 10.0; }
      { block = "memory"; }
      { block = "cpu"; }
      { block = "net"; }
      { block = "sound"; }
      { block = "battery"; missing_format = ""; }
      { block = "time"; interval = 30; format = " $icon $timestamp.datetime(f:'%a %d %b  %R') "; }
    ];
  };

  # ── Wayland bar (sway and hyprland) ───────────────────────────────
  waybarConfig = wm: json.generate "waybar.json" {
    layer = "top";
    position = "top";
    height = 30;
    modules-left = [ "${wm}/workspaces" ] ++ lib.optional (wm == "sway") "sway/mode";
    modules-center = [ "${wm}/window" ];
    modules-right = [ "pulseaudio" "network" "cpu" "memory" "battery" "clock" "tray" ];
    "${wm}/window" = { max-length = 60; };
    "${wm}/workspaces" = { disable-scroll = true; };
    clock = { format = "{:%a %d %b  %H:%M}"; tooltip = false; };
    cpu = { format = "${g "f2db"} {usage}%"; interval = 5; };
    memory = { format = "${g "f538"} {percentage}%"; interval = 5; };
    battery = { format = "{icon} {capacity}%"; format-icons = map g [ "f244" "f243" "f242" "f241" "f240" ]; };
    network = {
      format-wifi = "${g "f1eb"} {essid}";
      format-ethernet = "${g "f6ff"} {ipaddr}";
      format-disconnected = "${g "f071"} offline";
    };
    pulseaudio = {
      format = "{icon} {volume}%";
      format-muted = "${g "f6a9"} muted";
      format-icons.default = map g [ "f026" "f027" "f028" ];
      on-click = "${lib.getExe pkgs.pavucontrol}";
    };
    tray.spacing = 8;
  };
  waybarStyle = pkgs.writeText "waybar.css" ''
    * { font-family: "${p.monoFont}"; font-size: 13px; border: none; border-radius: 0; min-height: 0; }
    window#waybar { background: ${p.bg}; color: ${p.fg}; border-bottom: 2px solid ${p.bgHighlight}; }
    #workspaces button { padding: 0 8px; color: ${p.muted}; background: transparent; }
    #workspaces button.active, #workspaces button.focused { color: ${p.blue}; border-bottom: 2px solid ${p.blue}; }
    #workspaces button.urgent { color: ${p.red}; }
    #clock, #cpu, #memory, #network, #pulseaudio, #battery, #tray, #mode { padding: 0 10px; }
    #battery.warning { color: ${p.yellow}; }
    #battery.critical { color: ${p.red}; }
    #network.disconnected { color: ${p.red}; }
    #mode { color: ${p.yellow}; }
  '';

  # ── Session pieces used by all three window managers ──────────────
  polkitAgent = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
  codeBin = if cfg.vscode.enable then "code" else "";
  workspaces = map toString (lib.range 1 9) ++ [ "10" ];
  wsKey = n: if n == "10" then "0" else n;
}
