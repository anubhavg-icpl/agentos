# agent-fleet web UIs (in-browser chat and fleet hub)
#
# Serves the static site of pkgs.agentos.agent-fleet-web on loopback with a
# small hardened Python server (server.py): correct content types for
# .wasm/.mjs/.webmanifest and, for the chat, the COOP/COEP headers wllama
# needs for multi-threaded inference. No authentication: it only serves
# public static files and binds to 127.0.0.1; reach it through an SSH tunnel.
#
#   ssh -L 8484:127.0.0.1:8484 admin@host     then open http://127.0.0.1:8484/chat/
#
# The chat runs the model in the visitor's browser; the GGUF weights are
# downloaded by the browser from huggingface.co. See docs/agent-fleet-web.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.dashboard.agentFleetWeb;
  web = pkgs.agentos.agent-fleet-web;
  site = "${web}/share/agent-fleet";
  url = "http://127.0.0.1:${toString cfg.port}";

  server = pkgs.writers.writePython3Bin "agent-fleet-web-serve"
    { flakeIgnore = [ "E501" ]; }
    (builtins.readFile ./server.py);
in
{
  options.agentos.dashboard.agentFleetWeb = {
    enable = lib.mkEnableOption "the agent-fleet chat and hub web UIs on loopback (in-browser llama.cpp chat; models download from huggingface.co)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8484;
      description = "Port on 127.0.0.1 serving /chat/ and /hub/.";
    };

    deployTool = lib.mkEnableOption ''
      the `agent-fleet-deploy` command in the system packages. It publishes
      the static Spaces (chat, agent-hub) to Hugging Face: it needs a write
      token and creates or updates Spaces on that account
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      systemd.services.agent-fleet-web = {
        description = "agent-fleet chat and hub (static, loopback)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "simple";
          ExecStart = lib.concatStringsSep " " [
            "${server}/bin/agent-fleet-web-serve"
            "--root ${site}"
            "--listen 127.0.0.1"
            "--port ${toString cfg.port}"
          ];
          Restart = "on-failure";
          RestartSec = 3;

          DynamicUser = true;
          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
          CapabilityBoundingSet = "";
          UMask = "0077";
        };
      };

      # Shown as a link in the AgentOS dashboard header (when it runs)
      agentos.services.settings.dashboard.links = [
        { name = "agent-fleet chat"; url = "${url}/chat/"; }
        { name = "agent-fleet hub"; url = "${url}/hub/"; }
      ];
    })

    # Launcher for the desktop edition
    (lib.mkIf (cfg.enable && config.agentos.desktop.enable) {
      environment.systemPackages = [
        (pkgs.makeDesktopItem {
          name = "agent-fleet-chat";
          desktopName = "agent-fleet Chat";
          comment = "Local AI chat that runs in the browser (llama.cpp WebAssembly)";
          exec = "${pkgs.xdg-utils}/bin/xdg-open ${url}/chat/";
          icon = "${site}/chat/icon.svg";
          terminal = false;
          categories = [ "Network" "Utility" ];
        })
      ];
    })

    (lib.mkIf cfg.deployTool {
      environment.systemPackages = [ pkgs.agentos.agent-fleet-deploy ];
    })
  ];
}
