# sway (Wayland, i3-compatible) session. The config is /etc/sway/config,
# used when the user has no ~/.config/sway/config.
{ config, pkgs, lib, ... }:

let
  c = import ./common.nix { inherit config pkgs lib; };
  inherit (c) cfg p;
  enabled = cfg.enable && cfg.windowManager == "sway";

  fuzzelCmd = "${lib.getExe pkgs.fuzzel} --config ${c.fuzzelConfig}";
  volume = "${pkgs.wireplumber}/bin/wpctl";
  lock = "${lib.getExe pkgs.swaylock} --daemonize --color ${c.hex p.bg}";
  wsBinds = lib.concatMapStrings
    (n: ''
      bindsym $mod+${c.wsKey n} workspace number ${n}
      bindsym $mod+Shift+${c.wsKey n} move container to workspace number ${n}
    '')
    c.workspaces;

  swayConfig = pkgs.writeText "sway-config" ''
    # AgentOS sway configuration (generated; copy to ~/.config/sway/config to customise)
    set $mod Mod4
    set $term ${c.terminal}

    font pango:${p.monoFont} 10
    floating_modifier $mod normal

    # ── Look ────────────────────────────────────────────────────────
    default_border pixel 2
    default_floating_border pixel 2
    hide_edge_borders smart
    smart_borders on
    gaps inner ${toString cfg.gaps.inner}
    gaps outer ${toString cfg.gaps.outer}
    smart_gaps on
    focus_follows_mouse no
    workspace_auto_back_and_forth yes

    client.focused          ${p.blue}   ${p.bg}     ${p.fgBright} ${p.blue}  ${p.blue}
    client.focused_inactive ${p.bgHighlight} ${p.bgAlt} ${p.fg}  ${p.bgHighlight} ${p.bgHighlight}
    client.unfocused        ${p.bgAlt}  ${p.bgAlt}  ${p.muted}  ${p.bgAlt}  ${p.bgAlt}
    client.urgent           ${p.red}    ${p.red}    ${p.bg}     ${p.red}    ${p.red}

    output * bg ${cfg.wallpaper} fill
    input type:keyboard xkb_layout us
    input type:touchpad {
      tap enabled
      natural_scroll enabled
      dwt enabled
    }

    # ── Programs ────────────────────────────────────────────────────
    bindsym $mod+Return exec $term
    bindsym $mod+d exec ${fuzzelCmd}
    bindsym $mod+Shift+b exec ${if cfg.browser == "chromium" then "chromium" else "firefox"}
    ${lib.optionalString cfg.vscode.enable "bindsym $mod+Shift+v exec code --ozone-platform-hint=auto"}
    ${lib.optionalString cfg.zed.enable "bindsym $mod+Shift+z exec zeditor"}
    bindsym $mod+c exec sh -c '${pkgs.cliphist}/bin/cliphist list | ${fuzzelCmd} --dmenu | ${pkgs.cliphist}/bin/cliphist decode | ${pkgs.wl-clipboard}/bin/wl-copy'
    bindsym $mod+Ctrl+l exec ${lock}
    bindsym Print exec sh -c '${lib.getExe pkgs.grim} -g "$(${lib.getExe pkgs.slurp})" - | ${lib.getExe pkgs.swappy} -f -'
    bindsym $mod+Shift+s exec sh -c '${lib.getExe pkgs.grim} -g "$(${lib.getExe pkgs.slurp})" - | ${lib.getExe pkgs.swappy} -f -'

    # Dashboard: `agentos status` lives in a hidden terminal (scratchpad)
    for_window [app_id="^agentos-dash$"] floating enable, resize set 1100 640, move position center, move scratchpad
    bindsym $mod+grave scratchpad show
    bindsym $mod+Shift+minus move scratchpad
    bindsym $mod+minus scratchpad show

    bindsym --locked XF86AudioRaiseVolume exec ${volume} set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
    bindsym --locked XF86AudioLowerVolume exec ${volume} set-volume @DEFAULT_AUDIO_SINK@ 5%-
    bindsym --locked XF86AudioMute exec ${volume} set-mute @DEFAULT_AUDIO_SINK@ toggle
    bindsym --locked XF86AudioMicMute exec ${volume} set-mute @DEFAULT_AUDIO_SOURCE@ toggle
    bindsym --locked XF86AudioPlay exec ${lib.getExe pkgs.playerctl} play-pause
    bindsym --locked XF86AudioNext exec ${lib.getExe pkgs.playerctl} next
    bindsym --locked XF86AudioPrev exec ${lib.getExe pkgs.playerctl} previous
    bindsym --locked XF86MonBrightnessUp exec ${lib.getExe pkgs.brightnessctl} set 5%+
    bindsym --locked XF86MonBrightnessDown exec ${lib.getExe pkgs.brightnessctl} set 5%-

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

    bindsym $mod+b splith
    bindsym $mod+v splitv
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
    bindsym $mod+Shift+e exec swaynag -t warning -m 'Exit sway?' -B 'Yes, exit' 'swaymsg exit'

    mode "resize" {
      bindsym h resize shrink width 10px
      bindsym j resize grow height 10px
      bindsym k resize shrink height 10px
      bindsym l resize grow width 10px
      bindsym Left resize shrink width 10px
      bindsym Down resize grow height 10px
      bindsym Up resize shrink height 10px
      bindsym Right resize grow width 10px
      bindsym Return mode "default"
      bindsym Escape mode "default"
    }
    bindsym $mod+r mode "resize"

    # ── Bar ─────────────────────────────────────────────────────────
    bar {
      swaybar_command ${lib.getExe pkgs.waybar} --config ${c.waybarConfig "sway"} --style ${c.waybarStyle}
    }

    # ── Autostart ───────────────────────────────────────────────────
    exec ${c.seed}/bin/agentos-desktop-seed
    exec ${lib.getExe pkgs.mako} --config ${c.makoConfig}
    exec ${c.polkitAgent}
    exec ${pkgs.networkmanagerapplet}/bin/nm-applet --indicator
    exec ${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.cliphist}/bin/cliphist store
    ${lib.optionalString cfg.bluetooth "exec ${pkgs.blueman}/bin/blueman-applet"}
    exec ${lib.getExe pkgs.swayidle} -w \
      timeout 600 '${lock}' \
      timeout 900 'swaymsg "output * power off"' resume 'swaymsg "output * power on"' \
      before-sleep '${lock}'
    exec ${c.terminal} --class agentos-dash --title "AgentOS" -e ${c.dashboard}/bin/agentos-dashboard

    include /etc/sway/config.d/*
  '';
in
{
  config = lib.mkIf enabled {
    programs.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
      # foot/dmenu/swaylock defaults are replaced by the config above
      extraPackages = [ ];
    };
    security.pam.services.swaylock = { };

    environment.etc."sway/config".source = swayConfig;

    environment.systemPackages = with pkgs; [
      waybar
      fuzzel
      mako
      swaylock
      swayidle
      grim
      slurp
      swappy
      wl-clipboard
      cliphist
      wlr-randr
    ];
  };
}
