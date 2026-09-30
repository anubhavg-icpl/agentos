# Hyprland (Wayland) session. Hyprland renders with OpenGL ES and needs a
# real GPU driver; it is slow or fails in VMs without 3D acceleration (use
# i3 or sway there). The config is /etc/agentos/desktop/hyprland.conf and is
# passed to Hyprland explicitly by the greeter, so it applies to every user.
{ config, pkgs, lib, ... }:

let
  c = import ./common.nix { inherit config pkgs lib; };
  inherit (c) cfg p;
  enabled = cfg.enable && cfg.windowManager == "hyprland";

  rgb = color: "rgb(${c.hex color})";
  fuzzelCmd = "${lib.getExe pkgs.fuzzel} --config ${c.fuzzelConfig}";
  volume = "${pkgs.wireplumber}/bin/wpctl";
  screenshot = "${lib.getExe pkgs.grim} -g \"$(${lib.getExe pkgs.slurp})\" - | ${lib.getExe pkgs.swappy} -f -";
  wsBinds = lib.concatMapStrings
    (n: ''
      bind = $mod, ${c.wsKey n}, workspace, ${n}
      bind = $mod SHIFT, ${c.wsKey n}, movetoworkspace, ${n}
    '')
    c.workspaces;

  hyprlockConf = pkgs.writeText "hyprlock.conf" ''
    general {
      hide_cursor = true
    }
    background {
      color = ${rgb p.bg}
    }
    label {
      text = $TIME
      color = ${rgb p.fgBright}
      font_size = 64
      font_family = ${p.monoFont}
      position = 0, 140
      halign = center
      valign = center
    }
    input-field {
      size = 320, 50
      outline_thickness = 2
      outer_color = ${rgb p.blue}
      inner_color = ${rgb p.bgAlt}
      font_color = ${rgb p.fg}
      font_family = ${p.monoFont}
      placeholder_text = password
      position = 0, -20
      halign = center
      valign = center
    }
  '';
  lockCmd = "${lib.getExe pkgs.hyprlock} --config ${hyprlockConf}";
  hypridleConf = pkgs.writeText "hypridle.conf" ''
    general {
      lock_cmd = pidof hyprlock || ${lockCmd}
      before_sleep_cmd = loginctl lock-session
      after_sleep_cmd = hyprctl dispatch dpms on
    }
    listener {
      timeout = 600
      on-timeout = loginctl lock-session
    }
    listener {
      timeout = 900
      on-timeout = hyprctl dispatch dpms off
      on-resume = hyprctl dispatch dpms on
    }
  '';

  hyprConf = pkgs.writeText "hyprland.conf" ''
    # AgentOS Hyprland configuration (generated)
    monitor = , preferred, auto, 1

    $mod = SUPER
    $terminal = ${c.terminal}

    general {
      gaps_in = ${toString cfg.gaps.inner}
      gaps_out = ${toString cfg.gaps.outer}
      border_size = 2
      col.active_border = ${rgb p.blue}
      col.inactive_border = ${rgb p.bgHighlight}
      layout = dwindle
    }

    decoration {
      rounding = 8
      shadow {
        enabled = false
      }
      blur {
        enabled = true
        size = 4
        passes = 2
      }
    }

    # Modest animations
    animations {
      enabled = true
      bezier = ease, 0.25, 0.1, 0.25, 1.0
      animation = windows, 1, 3, ease
      animation = fade, 1, 3, ease
      animation = workspaces, 1, 3, ease, slide
    }

    input {
      kb_layout = us
      follow_mouse = 1
      touchpad {
        natural_scroll = true
      }
    }

    dwindle {
      preserve_split = true
    }

    misc {
      disable_hyprland_logo = true
      disable_splash_rendering = true
      force_default_wallpaper = 0
    }

    # ── Programs ──────────────────────────────────────────────────
    bind = $mod, Return, exec, $terminal
    bind = $mod, D, exec, ${fuzzelCmd}
    bind = $mod SHIFT, B, exec, ${if cfg.browser == "chromium" then "chromium" else "firefox"}
    ${lib.optionalString cfg.vscode.enable "bind = $mod SHIFT, V, exec, code --ozone-platform-hint=auto"}
    ${lib.optionalString cfg.zed.enable "bind = $mod SHIFT, Z, exec, zeditor"}
    bind = $mod, C, exec, ${pkgs.cliphist}/bin/cliphist list | ${fuzzelCmd} --dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy
    bind = $mod CTRL, L, exec, loginctl lock-session
    bind = , Print, exec, ${screenshot}
    bind = $mod SHIFT, S, exec, ${screenshot}

    # Dashboard: `agentos status` lives in a hidden special workspace
    windowrule = float on, match:class ^(agentos-dash)$
    windowrule = size 1100 640, match:class ^(agentos-dash)$
    windowrule = center on, match:class ^(agentos-dash)$
    windowrule = workspace special:dash silent, match:class ^(agentos-dash)$
    bind = $mod, grave, togglespecialworkspace, dash
    bind = $mod, minus, togglespecialworkspace, dash

    bindel = , XF86AudioRaiseVolume, exec, ${volume} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
    bindel = , XF86AudioLowerVolume, exec, ${volume} set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bindl = , XF86AudioMute, exec, ${volume} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindl = , XF86AudioMicMute, exec, ${volume} set-mute @DEFAULT_AUDIO_SOURCE@ toggle
    bindl = , XF86AudioPlay, exec, ${lib.getExe pkgs.playerctl} play-pause
    bindl = , XF86AudioNext, exec, ${lib.getExe pkgs.playerctl} next
    bindl = , XF86AudioPrev, exec, ${lib.getExe pkgs.playerctl} previous
    bindel = , XF86MonBrightnessUp, exec, ${lib.getExe pkgs.brightnessctl} set 5%+
    bindel = , XF86MonBrightnessDown, exec, ${lib.getExe pkgs.brightnessctl} set 5%-

    # ── Windows ───────────────────────────────────────────────────
    bind = $mod SHIFT, Q, killactive
    bind = $mod, F, fullscreen
    bind = $mod SHIFT, SPACE, togglefloating
    bind = $mod, E, layoutmsg, togglesplit

    bind = $mod, H, movefocus, l
    bind = $mod, J, movefocus, d
    bind = $mod, K, movefocus, u
    bind = $mod, L, movefocus, r
    bind = $mod, left, movefocus, l
    bind = $mod, down, movefocus, d
    bind = $mod, up, movefocus, u
    bind = $mod, right, movefocus, r
    bind = $mod SHIFT, H, movewindow, l
    bind = $mod SHIFT, J, movewindow, d
    bind = $mod SHIFT, K, movewindow, u
    bind = $mod SHIFT, L, movewindow, r

    bindm = $mod, mouse:272, movewindow
    bindm = $mod, mouse:273, resizewindow

    # ── Workspaces ────────────────────────────────────────────────
    ${wsBinds}
    # ── Session ───────────────────────────────────────────────────
    bind = $mod SHIFT, E, exit

    bind = $mod, R, submap, resize
    submap = resize
    binde = , H, resizeactive, -20 0
    binde = , L, resizeactive, 20 0
    binde = , K, resizeactive, 0 -20
    binde = , J, resizeactive, 0 20
    bind = , Return, submap, reset
    bind = , Escape, submap, reset
    submap = reset

    # ── Autostart ─────────────────────────────────────────────────
    exec-once = ${c.seed}/bin/agentos-desktop-seed
    exec-once = ${lib.getExe pkgs.swaybg} --image ${cfg.wallpaper} --mode fill
    exec-once = ${lib.getExe pkgs.waybar} --config ${c.waybarConfig "hyprland"} --style ${c.waybarStyle}
    exec-once = ${lib.getExe pkgs.mako} --config ${c.makoConfig}
    exec-once = ${c.polkitAgent}
    exec-once = ${pkgs.networkmanagerapplet}/bin/nm-applet --indicator
    exec-once = ${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.cliphist}/bin/cliphist store
    ${lib.optionalString cfg.bluetooth "exec-once = ${pkgs.blueman}/bin/blueman-applet"}
    exec-once = ${lib.getExe pkgs.hypridle} --config ${hypridleConf}
    exec-once = ${c.terminal} --class agentos-dash --title "AgentOS" -e ${c.dashboard}/bin/agentos-dashboard
  '';
in
{
  config = lib.mkIf enabled {
    programs.hyprland.enable = true;
    # Provides the PAM service for hyprlock
    programs.hyprlock.enable = true;

    environment.etc."agentos/desktop/hyprland.conf".source = hyprConf;

    environment.systemPackages = with pkgs; [
      waybar
      fuzzel
      mako
      hypridle
      swaybg
      grim
      slurp
      swappy
      wl-clipboard
      cliphist
      wlr-randr
    ];
  };
}
