# i3 (X11) session. Needs i3 >= 4.22 for the built-in gaps.
#
# The config is shipped as /etc/xdg/i3/config, which i3 reads when the user
# has no ~/.config/i3/config, so it applies to every user without
# home-manager and any user can still override it.
{ config, pkgs, lib, ... }:

let
  c = import ./common.nix { inherit config pkgs lib; };
  inherit (c) cfg p;
  enabled = cfg.enable && cfg.windowManager == "i3";

  rofiCmd = "${lib.getExe pkgs.rofi} -theme ${c.rofiTheme}";
  volume = "${pkgs.wireplumber}/bin/wpctl";
  wsBinds = lib.concatMapStrings
    (n: ''
      bindsym $mod+${c.wsKey n} workspace number ${n}
      bindsym $mod+Shift+${c.wsKey n} move container to workspace number ${n}
    '')
    c.workspaces;

  i3Config = pkgs.writeText "i3-config" ''
    # Nestlo i3 configuration (generated; copy to ~/.config/i3/config to customise)
    set $mod Mod4
    set $term ${c.terminal}

    font pango:${p.monoFont} 10
    floating_modifier $mod
    tiling_drag modifier titlebar

    # ── Look: gaps (built into i3 >= 4.22), borders, colors ─────────
    default_border pixel 2
    default_floating_border pixel 2
    hide_edge_borders smart   # smart borders: none for a lone window
    gaps inner ${toString cfg.gaps.inner}
    gaps outer ${toString cfg.gaps.outer}
    smart_gaps on
    focus_follows_mouse no
    workspace_auto_back_and_forth yes

    # class                 border      background  text        indicator   child_border
    client.focused          ${p.blue}   ${p.bg}     ${p.fgBright} ${p.blue}  ${p.blue}
    client.focused_inactive ${p.bgHighlight} ${p.bgAlt} ${p.fg}  ${p.bgHighlight} ${p.bgHighlight}
    client.unfocused        ${p.bgAlt}  ${p.bgAlt}  ${p.muted}  ${p.bgAlt}  ${p.bgAlt}
    client.urgent           ${p.red}    ${p.red}    ${p.bg}     ${p.red}    ${p.red}
    client.placeholder      ${p.bg}     ${p.bg}     ${p.fg}     ${p.bg}     ${p.bg}
    client.background       ${p.bg}

    # ── Programs ────────────────────────────────────────────────────
    bindsym $mod+Return exec $term
    bindsym $mod+d exec --no-startup-id ${rofiCmd} -show drun
    bindsym $mod+Shift+d exec --no-startup-id ${rofiCmd} -show run
    bindsym $mod+Tab exec --no-startup-id ${rofiCmd} -show window
    bindsym $mod+Shift+b exec ${if cfg.browser == "chromium" then "chromium" else "firefox"}
    ${lib.optionalString cfg.vscode.enable "bindsym $mod+Shift+v exec code"}
    ${lib.optionalString cfg.zed.enable "bindsym $mod+Shift+z exec zeditor"}
    bindsym $mod+c exec --no-startup-id env CM_LAUNCHER=rofi ${pkgs.clipmenu}/bin/clipmenu -theme ${c.rofiTheme}
    bindsym $mod+Ctrl+l exec --no-startup-id ${pkgs.systemd}/bin/loginctl lock-session
    bindsym Print exec --no-startup-id ${lib.getExe pkgs.flameshot} gui
    bindsym $mod+Shift+s exec --no-startup-id ${lib.getExe pkgs.flameshot} gui

    # Dashboard: `nestlo status` lives in a hidden terminal (scratchpad)
    for_window [class="^nestlo-dash$"] floating enable, resize set 1100 640, move position center, move scratchpad
    bindsym $mod+grave scratchpad show
    bindsym $mod+Shift+minus move scratchpad
    bindsym $mod+minus scratchpad show

    # Media, volume, brightness
    bindsym XF86AudioRaiseVolume exec --no-startup-id ${volume} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
    bindsym XF86AudioLowerVolume exec --no-startup-id ${volume} set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bindsym XF86AudioMute exec --no-startup-id ${volume} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindsym XF86AudioMicMute exec --no-startup-id ${volume} set-mute @DEFAULT_AUDIO_SOURCE@ toggle
    bindsym XF86AudioPlay exec --no-startup-id ${lib.getExe pkgs.playerctl} play-pause
    bindsym XF86AudioNext exec --no-startup-id ${lib.getExe pkgs.playerctl} next
    bindsym XF86AudioPrev exec --no-startup-id ${lib.getExe pkgs.playerctl} previous
    bindsym XF86MonBrightnessUp exec --no-startup-id ${lib.getExe pkgs.brightnessctl} set 5%+
    bindsym XF86MonBrightnessDown exec --no-startup-id ${lib.getExe pkgs.brightnessctl} set 5%-

    # ── Windows ─────────────────────────────────────────────────────
    bindsym $mod+Shift+q kill
    bindsym $mod+h focus left
    bindsym $mod+j focus down
    bindsym $mod+k focus up
    bindsym $mod+l focus right
    bindsym $mod+Left focus left
    bindsym $mod+Down focus down
    bindsym $mod+Up focus up
    bindsym $mod+Right focus right
    bindsym $mod+Shift+h move left
    bindsym $mod+Shift+j move down
    bindsym $mod+Shift+k move up
    bindsym $mod+Shift+l move right
    bindsym $mod+Shift+Left move left
    bindsym $mod+Shift+Down move down
    bindsym $mod+Shift+Up move up
    bindsym $mod+Shift+Right move right

    bindsym $mod+b split h
    bindsym $mod+v split v
    bindsym $mod+f fullscreen toggle
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+e layout toggle split
    bindsym $mod+Shift+space floating toggle
    bindsym $mod+space focus mode_toggle
    bindsym $mod+a focus parent

    # ── Workspaces ──────────────────────────────────────────────────
    ${wsBinds}
    # ── Session ─────────────────────────────────────────────────────
    bindsym $mod+Shift+c reload
    bindsym $mod+Shift+r restart
    bindsym $mod+Shift+e exec i3-nagbar -t warning -m 'Exit i3?' -B 'Yes, exit' 'i3-msg exit'

    mode "resize" {
      bindsym h resize shrink width 10 px or 10 ppt
      bindsym j resize grow height 10 px or 10 ppt
      bindsym k resize shrink height 10 px or 10 ppt
      bindsym l resize grow width 10 px or 10 ppt
      bindsym Left resize shrink width 10 px or 10 ppt
      bindsym Down resize grow height 10 px or 10 ppt
      bindsym Up resize shrink height 10 px or 10 ppt
      bindsym Right resize grow width 10 px or 10 ppt
      bindsym Return mode "default"
      bindsym Escape mode "default"
    }
    bindsym $mod+r mode "resize"

    # ── Bar ─────────────────────────────────────────────────────────
    bar {
      status_command ${lib.getExe pkgs.i3status-rust} ${c.i3statusConfig}
      position top
      tray_output primary
      font pango:${p.monoFont} 10
      colors {
        background ${p.bg}
        statusline ${p.fg}
        separator  ${p.muted}
        focused_workspace  ${p.blue} ${p.blue} ${p.bg}
        active_workspace   ${p.bgHighlight} ${p.bgHighlight} ${p.fgBright}
        inactive_workspace ${p.bg} ${p.bg} ${p.muted}
        urgent_workspace   ${p.red} ${p.red} ${p.bg}
      }
    }

    # ── Autostart ───────────────────────────────────────────────────
    exec_always --no-startup-id ${lib.getExe pkgs.feh} --no-fehbg --bg-fill ${cfg.wallpaper}
    exec --no-startup-id ${c.seed}/bin/nestlo-desktop-seed
    ${lib.optionalString cfg.compositor "exec --no-startup-id ${lib.getExe pkgs.picom} --config ${c.picomConfig}"}
    exec --no-startup-id ${lib.getExe pkgs.dunst}
    exec --no-startup-id ${c.polkitAgent}
    exec --no-startup-id ${pkgs.networkmanagerapplet}/bin/nm-applet
    exec --no-startup-id ${pkgs.clipmenu}/bin/clipmenud
    ${lib.optionalString cfg.bluetooth "exec --no-startup-id ${pkgs.blueman}/bin/blueman-applet"}
    exec --no-startup-id ${pkgs.xorg.xset}/bin/xset s 600 10
    exec --no-startup-id ${pkgs.xss-lock}/bin/xss-lock --transfer-sleep-lock -- ${pkgs.i3lock}/bin/i3lock --nofork --color ${c.hex p.bg}
    exec --no-startup-id ${c.terminal} --class nestlo-dash --title "Nestlo" -e ${c.dashboard}/bin/nestlo-dashboard
  '';
in
{
  config = lib.mkIf enabled {
    services.xserver = {
      enable = true;
      windowManager.i3 = {
        enable = true;
        # rofi, i3status-rust, i3lock and friends are referenced by store
        # path in the config; the default dmenu/i3status are not needed
        extraPackages = [ ];
      };
    };
    services.displayManager.defaultSession = lib.mkDefault "none+i3";

    environment.etc."xdg/i3/config".source = i3Config;
    environment.etc."xdg/dunst/dunstrc".source = c.dunstrc;

    programs.i3lock.enable = true;
    environment.systemPackages = with pkgs; [
      rofi
      dunst
      picom
      feh
      flameshot
      clipmenu
      xclip
      xdotool
      arandr
      i3status-rust
    ];
  };
}
