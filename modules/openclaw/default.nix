# ═══════════════════════════════════════════════════════════════════════
# Nestlo OpenClaw Module
# ═══════════════════════════════════════════════════════════════════════
#
# Runs the OpenClaw gateway (https://github.com/openclaw/openclaw): a Node
# daemon that connects chat channels (Telegram, Slack) to an LLM agent. Here
# it is wired into Nestlo like this:
#
#   chat user ──▶ channel (allowlisted DMs only) ──▶ openclaw.service (user openclaw)
#                                                        │ LLM calls
#                                                        ▼
#                       model gateway  http://127.0.0.1:8080/agent/openclaw:<token>/anthropic
#                       (real API key injected there, daily budget for agent id "openclaw")
#
#                openclaw ──exec: nestlo-task-chat──▶ bridge ──▶ orchestrator ──▶ sandboxed agents
#
# - nixpkgs has no module for it, only the package (marked insecure upstream
#   because of prompt injection, hence `acceptPromptInjectionRisk`).
# - The config file is generated here and copied into place on every start:
#   OpenClaw rewrites its config with atomic renames, so a symlink into the
#   Nix store would be replaced. Secrets never enter the store; the config only
#   holds ${VAR} references that the start script fills from files.
# - See docs/openclaw.md for the security model.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.openclaw;
  rt = config.nestlo.runtime;
  orch = config.nestlo.orchestration;

  stateDir = "/var/lib/openclaw";
  homeDir = stateDir;
  openclawDir = "${homeDir}/.openclaw";
  workspaceDir = "${stateDir}/workspace";
  gatewayAddr = "http://127.0.0.1:${toString config.nestlo.networking.modelGatewayPort}";
  adminSocket = config.nestlo.services.settings.gateway.admin_socket;
  agentId = "openclaw";
  providerId = "nestlo";

  bridgeEnabled = cfg.workspaces != [ ];
  chat = import ./task-chat.nix {
    inherit pkgs lib;
    inherit (cfg) workspaces;
    agents = cfg.agents;
    taskBudgetUsd = cfg.taskBudgetUsd;
    taskTimeoutSec = cfg.taskTimeoutSec;
    maxActiveTasks = cfg.maxActiveTasks;
  };
  wrapperPath = "${chat.wrapper}/bin/nestlo-task-chat";

  tg = cfg.channels.telegram;
  sl = cfg.channels.slack;

  # ── openclaw.json ──────────────────────────────────────────────────
  # Every key below was checked against the schema shipped in the package
  # (dist/zod-schema*.js and the telegram/slack plugin manifests). The schema
  # is strict: an unknown key stops the gateway from starting.
  settings = {
    gateway = {
      mode = "local";
      port = cfg.port;
      bind = "loopback";
      auth = {
        mode = "token";
        token = "\${OPENCLAW_GATEWAY_TOKEN}";
      };
      tailscale.mode = "off";
    };
    discovery.mdns.mode = "off";
    update = {
      checkOnStart = false;
      auto.enabled = false;
    };

    # LLM access only through the Nestlo model gateway. The token in the URL
    # is the agent token registered for id "openclaw"; the key is a
    # placeholder, the gateway injects the real one (`nestlo-managed`).
    models = {
      mode = "merge";
      pricing.enabled = false;
      providers.${providerId} = {
        baseUrl = "${gatewayAddr}/agent/${agentId}:\${NESTLO_OPENCLAW_TOKEN}/anthropic";
        apiKey = "nestlo-managed";
        api = "anthropic-messages";
        models = [{
          id = cfg.model;
          name = cfg.model;
          reasoning = false;
          input = [ "text" ];
          contextWindow = 200000;
          maxTokens = 8192;
        }];
      };
    };

    agents.defaults = {
      workspace = workspaceDir;
      model.primary = "${providerId}/${cfg.model}";
      # only the vendored Nestlo skill; no bundled or installed skills
      skills = lib.optional bridgeEnabled "nestlo";
      # no periodic background LLM calls
      heartbeat.every = "0m";
    };

    # Messaging plus the minimum for the Nestlo skill: read (the skill file,
    # confined to the workspace) and exec (restricted to one command below).
    # No file writes, web, browser, canvas, nodes, cron or gateway control.
    tools = {
      profile = "messaging";
      alsoAllow = [ "read" ] ++ lib.optional bridgeEnabled "exec";
      deny = [ "write" "edit" "apply_patch" "group:ui" "group:web" "group:nodes" "group:automation" "sessions_spawn" ];
      fs.workspaceOnly = true;
      elevated.enabled = false;
      exec = {
        host = "gateway";
        security = if bridgeEnabled then "allowlist" else "deny";
        ask = "off";
        safeBins = [ ];
        strictInlineEval = true;
      };
    };

    # No chat-driven config, plugin or shell changes
    commands = {
      bash = false;
      config = false;
      mcp = false;
      plugins = false;
      debug = false;
      restart = false;
    };
    session.dmScope = "per-channel-peer";

    channels =
      lib.optionalAttrs tg.enable {
        telegram = {
          enabled = true;
          dmPolicy = "allowlist";
          groupPolicy = "disabled";
          allowFrom = tg.allowFrom;
          configWrites = false;
        };
      }
      // lib.optionalAttrs sl.enable {
        slack = {
          enabled = true;
          mode = "socket";
          dmPolicy = "allowlist";
          groupPolicy = "disabled";
          allowFrom = sl.allowFrom;
          configWrites = false;
        };
      };
  };

  configFile = pkgs.writeText "openclaw.json" (builtins.toJSON settings);

  # Host exec approvals (~/.openclaw/exec-approvals.json): the one allowlisted
  # executable. Anything else is denied (askFallback), nothing is ever prompted.
  execApprovals = pkgs.writeText "openclaw-exec-approvals.json" (builtins.toJSON {
    version = 1;
    defaults = {
      security = "deny";
      ask = "off";
      askFallback = "deny";
      autoAllowSkills = false;
    };
    agents.main = {
      security = if bridgeEnabled then "allowlist" else "deny";
      ask = "off";
      askFallback = "deny";
      autoAllowSkills = false;
      allowlist = lib.optional bridgeEnabled {
        id = "5f0c3a52-7a3e-4c53-9d0e-0a6c0e5a11c1";
        pattern = wrapperPath;
      };
    };
  });

  # Environment shared by the service and `nestlo-openclaw`
  commonEnv = {
    HOME = homeDir;
    OPENCLAW_STATE_DIR = openclawDir;
    OPENCLAW_CONFIG_PATH = "${openclawDir}/openclaw.json";
    # no self-installs or self-updates; ClawHub and npm are never contacted
    OPENCLAW_NIX_MODE = "1";
    OPENCLAW_NO_AUTO_UPDATE = "1";
    OPENCLAW_DISABLE_BONJOUR = "1";
    CLAWHUB_DISABLE_TELEMETRY = "1";
  };

  # root: tokens, gateway registration, budget, vendored skill
  prepare = pkgs.writeShellApplication {
    name = "openclaw-prepare";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 077
      install -d -m 0700 -o openclaw -g openclaw ${stateDir} ${openclawDir} ${workspaceDir}

      newtoken() { od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; }
      for name in gateway-token nestlo-token; do
        if [ ! -s ${stateDir}/$name ]; then
          newtoken > ${stateDir}/$name
        fi
        chown openclaw:openclaw ${stateDir}/$name
        chmod 0400 ${stateDir}/$name
      done

      # admin METHOD PATH [curl args]: the admin socket appears when the model gateway is up
      admin() {
        curl -fsS -m 10 --unix-socket ${adminSocket} -X "$1" -H 'Content-Type: application/json' \
          "''${@:3}" "http://x/_nestlo/$2"
      }
      for _ in $(seq 1 60); do
        if admin GET health >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      admin GET health >/dev/null || { echo "model gateway admin socket ${adminSocket} not available" >&2; exit 1; }

      hash=$(sha256sum < ${stateDir}/nestlo-token | cut -d' ' -f1)
      admin PUT agents/${agentId} -d "$(jq -cn --arg h "$hash" '{token_sha256: $h}')" >/dev/null
      admin PUT budget/${agentId} -d '{"daily_usd": ${toString cfg.budgetUsd}}' >/dev/null

      ${lib.optionalString bridgeEnabled ''
        # The skill is root-owned: OpenClaw can read it, not change it
        install -d -m 0755 -o root -g root ${workspaceDir}/skills ${workspaceDir}/skills/nestlo
        install -m 0444 -o root -g root ${chat.skill}/nestlo/SKILL.md ${workspaceDir}/skills/nestlo/SKILL.md
      ''}
    '';
  };

  # openclaw user: the config and approvals, copied (not linked) because
  # OpenClaw replaces its config file by atomic rename
  install-config = pkgs.writeShellApplication {
    name = "openclaw-install-config";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      umask 077
      install -m 0600 ${configFile} ${openclawDir}/openclaw.json
      install -m 0600 ${execApprovals} ${openclawDir}/exec-approvals.json
    '';
  };

  # Fill the environment from the secret files, then run the gateway
  start = pkgs.writeShellApplication {
    name = "openclaw-start";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      OPENCLAW_GATEWAY_TOKEN=$(cat ${stateDir}/gateway-token)
      NESTLO_OPENCLAW_TOKEN=$(cat ${stateDir}/nestlo-token)
      export OPENCLAW_GATEWAY_TOKEN NESTLO_OPENCLAW_TOKEN
      ${lib.optionalString tg.enable ''
        TELEGRAM_BOT_TOKEN=$(cat "''${CREDENTIALS_DIRECTORY}"/telegram-token)
        export TELEGRAM_BOT_TOKEN
      ''}
      ${lib.optionalString sl.enable ''
        SLACK_BOT_TOKEN=$(cat "''${CREDENTIALS_DIRECTORY}"/slack-bot-token)
        SLACK_APP_TOKEN=$(cat "''${CREDENTIALS_DIRECTORY}"/slack-app-token)
        export SLACK_BOT_TOKEN SLACK_APP_TOKEN
      ''}
      exec ${cfg.package}/bin/openclaw gateway run
    '';
  };

  # For operators: run the openclaw CLI as the service user with the
  # service's environment (config validate, doctor, channels status ...)
  adminCli = pkgs.writeShellApplication {
    name = "nestlo-openclaw";
    runtimeInputs = [ pkgs.coreutils pkgs.util-linux ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "nestlo-openclaw: run as root (sudo nestlo-openclaw ...)" >&2
        exit 1
      fi
      OPENCLAW_GATEWAY_TOKEN=$(cat ${stateDir}/gateway-token)
      NESTLO_OPENCLAW_TOKEN=$(cat ${stateDir}/nestlo-token)
      exec runuser -u openclaw -- env \
        ${lib.concatStringsSep " \\\n        " (lib.mapAttrsToList (k: v: "${k}=${v}") commonEnv)} \
        OPENCLAW_GATEWAY_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
        NESTLO_OPENCLAW_TOKEN="$NESTLO_OPENCLAW_TOKEN" \
        ${cfg.package}/bin/openclaw "$@"
    '';
  };

  channelOptions = name: extra: {
    enable = lib.mkEnableOption "the ${name} channel";
    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/${name}-bot-token";
      description = ''
        File holding the ${name} bot token. It is read by systemd
        (LoadCredential) and handed to OpenClaw in the environment; it never
        enters the Nix store. Use a path outside the store (sops-nix,
        agenix, a root-owned file).
      '';
    };
    allowFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = extra.example;
      description = ''
        ${extra.what} that may talk to the bot. This is an allowlist: direct
        messages from anyone else are ignored, there is no pairing flow and
        group chats are disabled. Must not be empty when the channel is enabled.
      '';
    };
  };
in
{
  options.nestlo.openclaw = {
    enable = lib.mkEnableOption "the OpenClaw chat gateway, wired to the Nestlo model gateway and orchestrator";

    acceptPromptInjectionRisk = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        nixpkgs marks OpenClaw as insecure ("uses LLMs to parse untrusted
        content, making it vulnerable to prompt injection, while having full
        access to the system by default"). Enabling the service requires
        acknowledging that. This module narrows the exposure (see
        docs/openclaw.md) but cannot remove it: anyone on the allowlists can
        steer the model, and so can any text the model reads.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      # The nixpkgs insecure flag is lifted only here, behind the option above
      default = pkgs.openclaw.overrideAttrs (old: {
        meta = old.meta // { knownVulnerabilities = [ ]; };
      });
      defaultText = lib.literalMD "`pkgs.openclaw` with its `knownVulnerabilities` cleared (needs `acceptPromptInjectionRisk`)";
      description = "The OpenClaw package. nixpkgs 2026.5.7 and later include the fix for CVE-2026-25253.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18789;
      description = "Port of the gateway and Control UI. Always bound to 127.0.0.1.";
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "claude-sonnet-5-5";
      description = "Anthropic model id used through the Nestlo gateway (must be in its pricing table to be metered).";
    };

    budgetUsd = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      default = 5;
      description = ''
        Daily budget (USD, UTC day) of the gateway agent id `openclaw`. The
        gateway refuses further requests once it is used up. It is set on
        every start of the service.
      '';
    };

    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "MemoryMax of the service";
    };

    channels = {
      telegram = channelOptions "telegram" {
        what = "Numeric Telegram user ids";
        example = [ "123456789" ];
      };
      slack = channelOptions "slack" {
        what = "Slack member ids";
        example = [ "U0123456789" ];
      } // {
        appTokenFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "File holding the Slack app-level token (xapp-..., Socket Mode). `tokenFile` holds the bot token (xoxb-...).";
        };
      };
    };

    agents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "claude" ];
      description = "Nestlo agents that OpenClaw may start tasks with. Each needs an entry in `nestlo.orchestration.taskCommands`.";
    };

    workspaces = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*");
      default = [ ];
      example = [ "main-project" ];
      description = ''
        Workspace names (under `nestlo.runtime.workspaceRoot`) that OpenClaw
        may start tasks in. Empty (the default) disables the task bridge, the
        `nestlo` skill and the exec tool altogether: OpenClaw then only chats.
      '';
    };

    taskBudgetUsd = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 2;
      description = "Daily budget of each task OpenClaw submits (the bridge sets it; OpenClaw cannot choose).";
    };

    taskTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Timeout of each task OpenClaw submits.";
    };

    maxActiveTasks = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "How many of OpenClaw's tasks may be queued or running at once.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.acceptPromptInjectionRisk;
        message = "nestlo.openclaw.enable: set nestlo.openclaw.acceptPromptInjectionRisk = true after reading docs/openclaw.md (nixpkgs marks openclaw insecure)";
      }
      {
        assertion = config.nestlo.networking.enable;
        message = "nestlo.openclaw routes its LLM calls through the Nestlo model gateway; enable nestlo.networking";
      }
      {
        assertion = tg.enable -> (tg.tokenFile != null && tg.allowFrom != [ ]);
        message = "nestlo.openclaw.channels.telegram needs tokenFile and a non-empty allowFrom";
      }
      {
        assertion = sl.enable -> (sl.tokenFile != null && sl.appTokenFile != null && sl.allowFrom != [ ]);
        message = "nestlo.openclaw.channels.slack needs tokenFile, appTokenFile and a non-empty allowFrom";
      }
      {
        assertion = !bridgeEnabled || orch.enable;
        message = "nestlo.openclaw.workspaces needs nestlo.orchestration.enable (OpenClaw submits tasks to the orchestrator)";
      }
      {
        assertion = !bridgeEnabled || (cfg.agents != [ ] && lib.all (a: orch.taskCommands ? ${a}) cfg.agents);
        message = "nestlo.openclaw.agents must be non-empty and each agent needs an entry in nestlo.orchestration.taskCommands";
      }
    ];

    users.users.openclaw = {
      isSystemUser = true;
      group = "openclaw";
      home = homeDir;
      description = "OpenClaw chat gateway";
    };
    users.groups.openclaw = { };

    environment.systemPackages = [ adminCli ] ++ lib.optional bridgeEnabled chat.wrapper;

    # ─ The gateway ──────────────────────────────────────────────────
    systemd.services.openclaw = {
      description = "OpenClaw chat gateway";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "nestlo-model-gateway.service" ]
        ++ lib.optional bridgeEnabled "nestlo-openclaw-bridge.service";
      wants = [ "network-online.target" ] ++ lib.optional bridgeEnabled "nestlo-openclaw-bridge.service";
      requires = [ "nestlo-model-gateway.service" ];
      restartTriggers = [ configFile execApprovals ] ++ lib.optional bridgeEnabled chat.skill;

      environment = commonEnv;
      path = [ pkgs.bash pkgs.coreutils ] ++ lib.optional bridgeEnabled chat.wrapper;

      serviceConfig = {
        Type = "simple";
        User = "openclaw";
        Group = "openclaw";
        StateDirectory = "openclaw";
        StateDirectoryMode = "0700";
        WorkingDirectory = workspaceDir;
        # root: tokens, gateway registration, budget, vendored skill
        ExecStartPre = [
          "+${prepare}/bin/openclaw-prepare"
          "${install-config}/bin/openclaw-install-config"
        ];
        ExecStart = "${start}/bin/openclaw-start";
        LoadCredential =
          lib.optional tg.enable "telegram-token:${toString tg.tokenFile}"
          ++ lib.optionals sl.enable [
            "slack-bot-token:${toString sl.tokenFile}"
            "slack-app-token:${toString sl.appTokenFile}"
          ];
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 120;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallFilter = [ "@system-service" ];
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
        # V8 reserves address space up front: no MemoryDenyWriteExecute
        MemoryMax = cfg.memoryMax;
        TasksMax = 512;
        UMask = "0077";
      };
    };

    # ─ Task bridge ──────────────────────────────────────────────────
    users.users.openclaw-bridge = lib.mkIf bridgeEnabled {
      isSystemUser = true;
      group = "openclaw";
      description = "OpenClaw to orchestrator bridge";
    };

    systemd.services.nestlo-openclaw-bridge = lib.mkIf bridgeEnabled {
      description = "Nestlo task bridge for OpenClaw";
      wantedBy = [ "multi-user.target" ];
      after = [ "nestlo-orchestrator.service" ];
      wants = [ "nestlo-orchestrator.service" ];
      serviceConfig = {
        Type = "simple";
        User = "openclaw-bridge";
        Group = "openclaw";
        # Reaches the orchestrator socket (group nestlo) and nothing else of
        # that group: the gateway admin socket and the Nestlo state are hidden
        SupplementaryGroups = [ "nestlo" ];
        InaccessiblePaths = [ "-/run/nestlo-gateway" "-/run/redis-nestlo" "-/run/pullrun" "-/var/lib/nestlo" ];
        ExecStart = "${chat.bridge}/bin/nestlo-openclaw-bridge ${chat.policy}";
        Restart = "on-failure";
        RestartSec = 3;
        RuntimeDirectory = "nestlo-openclaw";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallFilter = [ "@system-service" ];
        CapabilityBoundingSet = "";
        MemoryDenyWriteExecute = true;
        MemoryMax = "128M";
      };
    };
  };
}
