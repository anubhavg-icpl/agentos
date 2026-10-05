# Nestlo agentgateway module
#
# agentgateway (https://github.com/agentgateway/agentgateway, Apache-2.0, a
# Linux Foundation project) is an agent-aware proxy for MCP, A2A and LLM
# traffic. Here it is the enforcement point in front of Nestlo's MCP servers:
#
#   - ONE MCP endpoint (http://127.0.0.1:<mcpPort>/mcp, streamable HTTP; /sse
#     for old clients) multiplexes every server in the Nestlo MCP registries
#     (/etc/nestlo/mcp-servers.json and mcp-tools.json, read at evaluation
#     time) plus `mcp.extraServers`. Tools appear as `<server>_<tool>`.
#   - every agent has its own API key (hashed in the config, the key itself in
#     a file) and its own allow-list: which server's tools it may call.
#     Anything not allowed is refused (and filtered out of tools/list).
#     MCP servers run as stdio children of the gateway with a cleared
#     environment, so no gateway secret reaches them.
#   - an LLM endpoint (http://127.0.0.1:<llmPort>/v1/...) that forwards ONLY to
#     the Nestlo model gateway, as gateway agent `llm.agentId`, so the
#     budgets, DLP, loop detection and audit trail apply and provider keys
#     never reach agentgateway.
#   - OTLP traces to the Nestlo observability collector when it is enabled.
#
# agentgateway has no configuration reload hook that Nestlo needs: the unit is
# restarted when the generated configuration changes.
#
# See docs/agentgateway.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.agentgateway;
  net = config.nestlo.networking;
  obs = config.nestlo.observability;

  stateDir = "/var/lib/nestlo-agentgateway";
  keyDir = "${stateDir}/keys";
  envFile = "${stateDir}/env";
  adminSocket = config.nestlo.services.settings.gateway.admin_socket;
  workspaceRoot = lib.attrByPath [ "nestlo" "runtime" "workspaceRoot" ] "/var/lib/nestlo/workspaces" config;

  # ── The MCP servers Nestlo knows about ─────────────────────────────────
  # Both registries are JSON in /etc; evaluating their text here (rather than
  # reading the files at runtime) keeps the generated config a pure function
  # of the system configuration.
  etc = config.environment.etc;
  readRegistry = file: key:
    # The text may mention store paths (nestlo-mcp-bus, an absolute npx); fromJSON refuses
    # strings with context when import-from-derivation is off. The same paths are
    # referenced by the registry's own /etc file, so they stay in the system closure.
    if etc ? ${file} then (builtins.fromJSON (builtins.unsafeDiscardStringContext etc.${file}.text)).${key} or [ ] else [ ];
  registry = lib.listToAttrs (map (s: lib.nameValuePair s.name s)
    (readRegistry "nestlo/mcp-tools.json" "tools" ++ readRegistry "nestlo/mcp-servers.json" "servers"));
  registryEnabled = lib.filterAttrs
    (n: s: (s.enabled or true) && (s.command or "") != "" && !(lib.elem n cfg.mcp.excludeServers))
    registry;
  selected = if cfg.mcp.servers == null then registryEnabled
    else lib.filterAttrs (n: s: lib.elem n cfg.mcp.servers && (s.command or "") != "") registry;

  # agentgateway expands $VAR / ${VAR} in the whole file (shellexpand) and
  # fails on unset variables. Registry entries use ${VAR} for secrets that the
  # operator provides in `environmentFile`; default them to empty so a server
  # whose key is missing fails on its own instead of keeping the gateway down.
  defaultEmpty = v: if lib.hasInfix "\${" v then builtins.replaceStrings [ "}" ] [ ":-}" ] v else v;

  baseEnv = {
    PATH = lib.makeBinPath cfg.mcp.path;
    HOME = "${stateDir}/home";
    SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
    NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-bundle.crt";
  };

  stdioTarget = name: s: {
    inherit name;
    stdio = {
      cmd = s.command;
      args = map defaultEmpty (s.args or [ ]);
      env = baseEnv // lib.mapAttrs (_: defaultEmpty) (s.env or { });
      # the gateway's own environment holds the model gateway token and the
      # key hashes; MCP servers get only what is listed above
      clear_env = true;
    };
  };
  remoteTarget = name: s: {
    inherit name;
    mcp = { inherit (s) host port path; };
  };
  # ToolHive-isolated servers are plain streamable-HTTP servers on loopback
  toolhiveServers =
    if config.nestlo ? toolhive && config.nestlo.toolhive.enable
    then config.nestlo.toolhive.servers else { };

  targets =
    lib.mapAttrsToList stdioTarget (lib.filterAttrs (n: _: !(toolhiveServers ? ${n})) selected)
    ++ lib.mapAttrsToList (n: s: remoteTarget n { host = "127.0.0.1"; port = s.port; path = "/mcp"; })
      (lib.filterAttrs (n: _: toolhiveServers ? ${n} && toolhiveServers.${n}.registerWithGateway) toolhiveServers)
    ++ lib.mapAttrsToList (n: s:
      if s.host != null
      then remoteTarget n s
      else stdioTarget n s)
      cfg.mcp.extraServers;

  targetNames = map (t: t.name) targets;

  # ── Per-agent keys and authorization ───────────────────────────────────
  agentIds = lib.attrNames cfg.mcp.agents;
  indexed = lib.imap0 (i: id: { inherit i id; }) agentIds;

  q = builtins.toJSON; # a JSON string literal is a valid CEL string literal

  agentRules = id: a:
    lib.mapAttrsToList
      (server: tools:
        let
          who = "apiKey.agent == ${q id} && has(mcp.tool) && mcp.tool.target == ${q server}";
        in
        if tools == [ "*" ]
        then { allow = who; }
        else { allow = "${who} && mcp.tool.name in ${q tools}"; })
      a.tools
    ++ lib.optional a.allowPromptsAndResources
      { allow = "apiKey.agent == ${q id} && (has(mcp.prompt) || has(mcp.resource))"; };

  apiKeyPolicy = {
    mode = "strict";
    keys = map (x: {
      keyHash = "sha256:\${AG_KEYHASH_${toString x.i}}";
      metadata.agent = x.id;
    }) indexed;
  };

  # ── LLM: always through the Nestlo model gateway ───────────────────────
  gwBase = "http://127.0.0.1:${toString net.modelGatewayPort}/agent/${cfg.llm.agentId}:\${NESTLO_GW_TOKEN}";
  llmModel = name: m: {
    inherit name;
    provider = if m.provider == "anthropic" then "anthropic" else "openAI";
    params = {
      model = m.model;
      baseUrl = if m.provider == "anthropic" then "${gwBase}/anthropic/v1" else "${gwBase}/${m.provider}/v1";
      # the model gateway swaps in the real provider key
      apiKey = "nestlo-managed";
    };
  };

  # ── The whole config ───────────────────────────────────────────────────
  gatewayConfig = {
    config = {
      adminAddr = "127.0.0.1:${toString cfg.adminPort}";
      statsAddr = "127.0.0.1:${toString cfg.metricsPort}";
      readinessAddr = "127.0.0.1:${toString cfg.readinessPort}";
      logging.format = "json";
    };
    gateways = {
      mcp = { port = cfg.mcpPort; bindAddress = cfg.listenAddress; };
    } // lib.optionalAttrs cfg.llm.enable {
      llm = { port = cfg.llmPort; bindAddress = cfg.listenAddress; };
    };
    mcp = {
      gateways = "mcp";
      prefixMode = "always";
      statefulMode = "stateful";
      # one server failing to start must not take the others away
      failureMode = "failOpen";
      inherit targets;
      policies = {
        apiKey = apiKeyPolicy;
        mcpAuthorization.rules = lib.concatLists (lib.mapAttrsToList agentRules cfg.mcp.agents);
      };
    };
  }
  // lib.optionalAttrs cfg.llm.enable {
    llm = {
      gateways = "llm";
      policies.apiKey = apiKeyPolicy;
      models = lib.mapAttrsToList llmModel cfg.llm.models;
    };
  }
  // lib.optionalAttrs cfg.tracing.enable {
    frontendPolicies.tracing = {
      host = cfg.tracing.endpoint;
      protocol = "grpc";
      randomSampling = cfg.tracing.sampling;
    };
  }
  // cfg.extraConfig;

  configFile = pkgs.writeText "nestlo-agentgateway.yaml" (builtins.toJSON gatewayConfig);

  # Environment the config is validated with (placeholders only)
  placeholderEnv = lib.concatStringsSep " " (
    [ "NESTLO_GW_TOKEN=placeholder" ]
    ++ map (x: "AG_KEYHASH_${toString x.i}=${lib.fixedWidthString 64 "0" ""}") indexed
  );

  # Root-only setup: gateway agent + budget, per-agent keys, the env file
  setupScript = pkgs.writeShellApplication {
    name = "nestlo-agentgateway-setup";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 077
      mkdir -p ${stateDir}/home
      install -d -m 0750 -o root -g ${cfg.keyGroup} ${keyDir}
      : > ${envFile}.new

      ${lib.optionalString cfg.llm.enable ''
        tok=${stateDir}/gateway-token
        [ -s "$tok" ] || od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$tok"
        admin() {
          curl -fsS -m 10 --unix-socket ${adminSocket} -X "$1" -H 'Content-Type: application/json' \
            "''${@:3}" "http://x/_nestlo/$2"
        }
        for _ in $(seq 1 60); do admin GET health >/dev/null 2>&1 && break; sleep 1; done
        hash=$(sha256sum < "$tok" | cut -d' ' -f1)
        admin PUT agents/${cfg.llm.agentId} -d "$(jq -cn --arg h "$hash" '{token_sha256: $h}')" >/dev/null
        admin PUT budget/${cfg.llm.agentId} -d '{"daily_usd": ${toString cfg.llm.budgetUsd}}' >/dev/null
        echo "NESTLO_GW_TOKEN=$(cat "$tok")" >> ${envFile}.new
      ''}

      ${lib.concatMapStrings (x: ''
        key=${keyDir}/${x.id}
        [ -s "$key" ] || { printf 'agw_' > "$key"; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >> "$key"; }
        chown root:${cfg.keyGroup} "$key"; chmod 0640 "$key"
        echo "AG_KEYHASH_${toString x.i}=$(tr -d '\n' < "$key" | sha256sum | cut -d' ' -f1)" >> ${envFile}.new
      '') indexed}

      mv ${envFile}.new ${envFile}
    '';
  };

  # What an agent's MCP client needs: the endpoint and its key
  mcpConfigCli = pkgs.writeShellApplication {
    name = "nestlo-agentgateway-mcp-config";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    text = ''
      if [ $# -ne 1 ]; then
        echo "usage: nestlo-agentgateway-mcp-config <agent>" >&2
        echo "prints an MCP client configuration ({mcpServers}) for that agent; needs read access to ${keyDir}" >&2
        exit 2
      fi
      key=$(cat "${keyDir}/$1")
      jq -n --arg url "http://${cfg.listenAddress}:${toString cfg.mcpPort}/mcp" --arg key "$key" \
        '{mcpServers: {nestlo: {type: "http", url: $url, headers: {Authorization: ("Bearer " + $key)}}}}'
    '';
  };

  agentType = lib.types.submodule {
    options = {
      tools = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = { git = [ "*" ]; fetch = [ "fetch" ]; };
        description = ''
          Which tools this agent may call: MCP server name -> tool names
          (as the server calls them, without the `<server>_` prefix), or
          `[ "*" ]` for all tools of that server. A server that is not
          listed is invisible and uncallable for this agent.
        '';
      };
      allowPromptsAndResources = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Also allow this agent to use MCP prompts and resources of every
          server. The tool allow-list does not cover them, and without this
          they are refused.
        '';
      };
    };
  };

  loopback = a: lib.hasPrefix "127." a || a == "::1";
in
{
  options.nestlo.agentgateway = {
    enable = lib.mkEnableOption "agentgateway as the enforcement point in front of Nestlo's MCP servers and LLM calls";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.agentgateway;
      defaultText = lib.literalExpression "pkgs.nestlo.agentgateway";
      description = "agentgateway build (not in nixpkgs; nixos/packages/agentgateway.nix).";
    };

    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address of the MCP and LLM listeners. Keep it on loopback: agents
        authenticate with API keys, which is not a substitute for network
        isolation. A non-loopback address is refused unless
        `allowNonLoopback` is set.
      '';
    };
    allowNonLoopback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Permit a non-loopback listenAddress (for example an agent bridge address).";
    };

    mcpPort = lib.mkOption { type = lib.types.port; default = 9961; description = "MCP endpoint port (/mcp, /sse)."; };
    llmPort = lib.mkOption { type = lib.types.port; default = 9962; description = "LLM endpoint port (/v1/chat/completions, /v1/messages, ...)."; };
    adminPort = lib.mkOption { type = lib.types.port; default = 9963; description = "Admin API port (always 127.0.0.1)."; };
    metricsPort = lib.mkOption { type = lib.types.port; default = 9964; description = "Prometheus metrics port (always 127.0.0.1)."; };
    readinessPort = lib.mkOption { type = lib.types.port; default = 9965; description = "Readiness probe port (always 127.0.0.1)."; };

    keyGroup = lib.mkOption {
      type = lib.types.str;
      default = "nestlo";
      description = ''
        Group that may read the per-agent API keys in ${keyDir}. Whoever can
        read a key can act as that agent towards the MCP and LLM endpoints.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/agentgateway-env";
      description = ''
        File with `NAME=value` lines (root-only) for the MCP servers: the
        registries reference secrets as `''${GITHUB_TOKEN}`, `''${BRAVE_API_KEY}`
        and so on, and agentgateway expands them from its environment. A
        variable that is not set expands to the empty string.
      '';
    };

    mcp = {
      servers = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        example = [ "git" "fetch" "memory" ];
        description = ''
          Registry servers to expose. `null` exposes every enabled server of
          /etc/nestlo/mcp-tools.json and mcp-servers.json (those whose
          registry module is enabled), minus `excludeServers`.
        '';
      };
      excludeServers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "nestlo-bus" "agentgateway" ];
        description = ''
          Registry servers that are not exposed. `nestlo-bus` identifies the
          calling agent from the environment `nestlo spawn` sets, which does
          not exist in a gateway-owned child process; `agentgateway` is this
          module's own registry entry.
        '';
      };
      extraServers = lib.mkOption {
        default = { };
        description = "Additional MCP servers, as stdio commands or remote streamable-HTTP URLs.";
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            command = lib.mkOption { type = lib.types.str; default = ""; description = "Command of a stdio server."; };
            args = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Arguments of the stdio command."; };
            env = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; description = "Environment of the stdio command."; };
            host = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "127.0.0.1";
              description = "Host of a remote streamable-HTTP MCP server (used instead of command).";
            };
            port = lib.mkOption { type = lib.types.port; default = 80; description = "Port of the remote server."; };
            path = lib.mkOption { type = lib.types.str; default = "/mcp"; description = "Path of the remote server's MCP endpoint."; };
          };
        });
      };
      path = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ pkgs.nodejs pkgs.uv pkgs.git pkgs.coreutils pkgs.bash ];
        defaultText = lib.literalExpression "[ pkgs.nodejs pkgs.uv pkgs.git pkgs.coreutils pkgs.bash ]";
        description = "PATH of the stdio MCP servers (the registries start most with npx and uvx).";
      };
      agents = lib.mkOption {
        type = lib.types.attrsOf agentType;
        default = { };
        example = lib.literalExpression ''
          {
            claude-code.tools = { git = [ "*" ]; fetch = [ "fetch" ]; };
            reviewer.tools.git = [ "git_status" "git_diff" "git_log" ];
          }
        '';
        description = ''
          Agents that may use the MCP endpoint, by id (lower case letters,
          digits, `-`, `_`). Each gets an API key in ${keyDir}/<id> and the
          tool allow-list given here. Print a client configuration with
          `nestlo-agentgateway-mcp-config <id>`.
        '';
      };
    };

    llm = {
      enable = lib.mkEnableOption "the LLM endpoint, which forwards to the Nestlo model gateway";
      agentId = lib.mkOption {
        type = lib.types.str;
        default = "agentgateway";
        description = "Model gateway agent id that every call through this endpoint is made as (budget, logs, audit).";
      };
      budgetUsd = lib.mkOption {
        type = lib.types.numbers.positive;
        default = 10;
        description = "Daily budget of that gateway agent in USD.";
      };
      models = lib.mkOption {
        default = { };
        example = lib.literalExpression ''{ sonnet = { provider = "anthropic"; model = "claude-sonnet-4-5"; }; }'';
        description = ''
          Models offered on the LLM endpoint: the name clients request ->
          the Nestlo gateway provider and the upstream model name.
        '';
        type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
          options = {
            provider = lib.mkOption {
              type = lib.types.enum [ "anthropic" "openai" ];
              description = "Gateway provider path: `anthropic` (Messages API) or `openai` (Chat Completions, also OpenAI-compatible providers).";
            };
            model = lib.mkOption {
              type = lib.types.str;
              default = name;
              description = "Model name sent to the provider.";
            };
          };
        }));
      };
    };

    tracing = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = obs.enable;
        defaultText = lib.literalExpression "config.nestlo.observability.enable";
        description = "Export OTLP traces (one span per MCP and LLM request) to the Nestlo observability collector.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:${toString obs.otelCollectorPort}";
        defaultText = lib.literalExpression ''"127.0.0.1:''${toString config.nestlo.observability.otelCollectorPort}"'';
        description = "OTLP gRPC endpoint.";
      };
      sampling = lib.mkOption {
        type = lib.types.str;
        default = "true";
        description = "CEL expression deciding whether a request is traced; \"true\" traces everything.";
      };
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Top-level agentgateway configuration merged over the generated one (shallow). Do not put `$` in values: agentgateway expands environment variables in the file.";
    };

    registerInRegistry = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Add an `agentgateway` entry to `nestlo.mcp-registry.extraToolServers`
        (an `npx mcp-remote` bridge to the endpoint using the key in the
        environment variable NESTLO_AGENTGATEWAY_KEY).
      '';
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = configFile;
      description = "The generated agentgateway configuration (YAML-compatible JSON), for tests and inspection.";
    };
    validateEnv = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = placeholderEnv;
      description = "Placeholder environment under which `agentgateway --validate-only -f <configFile>` succeeds.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = loopback cfg.listenAddress || cfg.allowNonLoopback;
        message = "nestlo.agentgateway.listenAddress must be a loopback address (or set allowNonLoopback)";
      }
      {
        assertion = config.users.groups ? ${cfg.keyGroup};
        message = "nestlo.agentgateway.keyGroup (${cfg.keyGroup}) is not a defined group; enable nestlo.runtime or set keyGroup";
      }
      {
        assertion = cfg.mcp.agents != { };
        message = "nestlo.agentgateway.mcp.agents is empty: no agent could authenticate to the MCP endpoint";
      }
      {
        assertion = lib.all (id: builtins.match "[a-z0-9][a-z0-9_-]*" id != null) agentIds;
        message = "nestlo.agentgateway.mcp.agents: ids must match [a-z0-9][a-z0-9_-]*";
      }
      {
        assertion = lib.all (n: !(lib.hasInfix "_" n)) targetNames;
        message = "nestlo.agentgateway: MCP server names must not contain '_' (it separates the server from the tool in tools/list); offending: ${toString (lib.filter (lib.hasInfix "_") targetNames)}";
      }
      {
        assertion = cfg.mcp.servers == null || lib.all (n: registry ? ${n}) cfg.mcp.servers;
        message = "nestlo.agentgateway.mcp.servers names servers missing from the MCP registries: ${toString (lib.filter (n: !(registry ? ${n})) (cfg.mcp.servers or [ ]))}";
      }
      {
        assertion = lib.all (a: lib.all (s: lib.elem s targetNames) (lib.attrNames a.tools)) (lib.attrValues cfg.mcp.agents);
        message = "nestlo.agentgateway.mcp.agents.*.tools names a server that is not exposed (exposed: ${toString targetNames})";
      }
      {
        assertion = lib.all (s: s.host != null || s.command != "") (lib.attrValues cfg.mcp.extraServers);
        message = "nestlo.agentgateway.mcp.extraServers: each server needs a command or a host";
      }
      {
        assertion = !cfg.llm.enable || (net.enable && cfg.llm.models != { });
        message = "nestlo.agentgateway.llm needs nestlo.networking.enable (the model gateway) and at least one model";
      }
    ];

    environment.systemPackages = [ cfg.package mcpConfigCli ];

    # Entry for clients that read the registry: one server instead of many
    nestlo.mcp-registry.extraToolServers = lib.mkIf cfg.registerInRegistry {
      agentgateway = {
        command = "npx";
        args = [
          "-y" "mcp-remote" "http://${cfg.listenAddress}:${toString cfg.mcpPort}/mcp"
          "--header" "Authorization:\${AUTH_HEADER}"
        ];
        env.AUTH_HEADER = "Bearer \${NESTLO_AGENTGATEWAY_KEY}";
        description = "All Nestlo MCP servers through agentgateway (per-agent tool authorization, tracing)";
      };
    };

    users.users.nestlo-agentgateway = {
      isSystemUser = true;
      group = "nestlo-agentgateway";
      home = "${stateDir}/home";
      # shared workspaces for the filesystem and git servers
      extraGroups = lib.optional (config.users.groups ? nestlo-agent) "nestlo-agent";
      description = "agentgateway (MCP/LLM enforcement point)";
    };
    users.groups.nestlo-agentgateway = { };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0711 root root -"
      # HOME and working directory of the service (and its MCP servers); the setup unit runs as root
      "d ${stateDir}/home 0700 nestlo-agentgateway nestlo-agentgateway -"
    ];

    systemd.services.nestlo-agentgateway-setup = {
      description = "agentgateway: per-agent keys and model gateway registration";
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-agentgateway.service" ];
      after = lib.optional cfg.llm.enable "nestlo-model-gateway.service";
      wants = lib.optional cfg.llm.enable "nestlo-model-gateway.service";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe setupScript;
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadWritePaths = [ stateDir ];
        ProtectSystem = "strict";
      };
    };

    systemd.services.nestlo-agentgateway = {
      description = "agentgateway: MCP and LLM enforcement point";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "nestlo-agentgateway-setup.service" ];
      requires = [ "nestlo-agentgateway-setup.service" ];
      restartTriggers = [ configFile ];
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} -f ${configFile}";
        EnvironmentFile = [ envFile ] ++ lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        User = "nestlo-agentgateway";
        Group = "nestlo-agentgateway";
        WorkingDirectory = "${stateDir}/home";
        Restart = "on-failure";
        RestartSec = 5;

        # The MCP servers are children of this unit and inherit the sandbox
        ProtectSystem = "strict";
        ReadWritePaths = [ "${stateDir}/home" workspaceRoot ];
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        UMask = "0077";
        # MemoryDenyWriteExecute stays off: the Node-based MCP servers need V8's JIT
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      };
    };
  };
}
