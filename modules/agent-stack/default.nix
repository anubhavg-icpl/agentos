# AgentOS agent-stack module
#
# Runs the apps of github.com/anubhavg-icpl/agent-fleet on the AgentOS host
# instead of as Hugging Face Docker Spaces: n8n, Open WebUI + Ollama,
# Flowise, Langflow, AnythingLLM, LobeChat and OpenMuse. See docs/agent-stack.md.
#
#   native    n8n (services.n8n), local chat (agentos.localAI: Ollama + Open WebUI)
#   podman    Flowise, Langflow, AnythingLLM, LobeChat, OpenMuse
#             (virtualisation.oci-containers; OpenMuse needs an image you build)
#
# - Every published port is on 127.0.0.1. Reach the apps with an SSH tunnel.
# - Secrets (basic-auth passwords, access codes, the n8n key, gateway tokens)
#   are generated at first boot by a root oneshot into
#   /var/lib/agentos-stack/secrets (0600) and handed over as env files or
#   systemd credentials. They never enter the Nix store.
# - LLM calls go through the AgentOS model gateway with one agent id per app
#   (`stack-<app>`), its own token and daily budget. The apps never see a real
#   provider key: they get the placeholder `agentos-managed`.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.agentStack;
  net = config.agentos.networking;

  stateRoot = "/var/lib/agentos-stack";
  secretsDir = "${stateRoot}/secrets";
  adminSocket = config.agentos.services.settings.gateway.admin_socket;
  gwPort = toString net.modelGatewayPort;
  loopback = "127.0.0.1";
  podmanUnit = app: "podman-agentos-stack-${app}.service";
  secretsUnit = "agentos-stack-secrets.service";
  gwUnit = app: "agentos-stack-gw-${app}.service";
  agentId = app: "stack-${app}";

  # name (dir/agent id) -> option set of the app
  apps = {
    n8n = cfg.n8n;
    local-chat = cfg.localChat;
    flowise = cfg.flowise;
    langflow = cfg.langflow;
    anythingllm = cfg.anythingllm;
    lobechat = cfg.lobechat;
    openmuse = cfg.openmuse;
  };
  enabledApps = lib.filterAttrs (_: a: cfg.enable && a.enable) apps;
  isOn = app: enabledApps ? ${app};
  containerApps = lib.filterAttrs (n: _: builtins.elem n [ "flowise" "langflow" "anythingllm" "lobechat" "openmuse" ]) enabledApps;
  anyContainer = containerApps != { };

  # ── per-app container specs ────────────────────────────────────────────
  # port: port inside the container; volume: where the persistent directory is
  # mounted; owner: uid:gid that owns the host directory (the user the image
  # runs as); env: static environment; llmEnv: the file with gateway settings
  # is passed to the container (apps that read the LLM endpoint from env).
  specs = {
    flowise = {
      port = 3000;
      volume = "/root/.flowise";
      owner = "0:0";
      env = {
        PORT = "3000";
        FLOWISE_FILE_SIZE_LIMIT = "50MB";
        DISABLE_FLOWISE_TELEMETRY = "true";
      };
      llmEnv = false;
    };
    langflow = {
      port = 7860;
      volume = "/app/langflow";
      owner = "1000:0";
      env = {
        LANGFLOW_HOST = "0.0.0.0";
        LANGFLOW_PORT = "7860";
        LANGFLOW_AUTO_LOGIN = "false";
        LANGFLOW_CONFIG_DIR = "/app/langflow";
        LANGFLOW_DATABASE_URL = "sqlite:////app/langflow/langflow.db";
        LANGFLOW_DO_NOT_TRACK = "true";
        DO_NOT_TRACK = "true";
      };
      llmEnv = true;
    };
    anythingllm = {
      port = 3001;
      volume = "/app/server/storage";
      owner = "1000:1000";
      env = {
        STORAGE_DIR = "/app/server/storage";
        SERVER_PORT = "3001";
        DISABLE_TELEMETRY = "true";
      };
      llmEnv = true;
    };
    lobechat = {
      port = 3210;
      volume = "/data";
      owner = "0:0";
      env = { PORT = "3210"; };
      llmEnv = true;
    };
    openmuse = {
      port = 7860;
      volume = "/data";
      owner = "0:0";
      env = {
        WORKSPACE_MODE = "live";
        AGENT_BACKEND = "model";
        MODEL = cfg.openmuse.model;
        DATA_DIR = "/data/openmuse";
        WORKSPACE_DIR = "/data/openmuse";
        TASK_WORKER_ENABLED = "true";
        PUBLIC_API_URL = "http://${loopback}:${toString cfg.openmuse.port}";
        ALLOWED_ORIGINS = "http://${loopback}:${toString cfg.openmuse.port}";
      };
      llmEnv = true;
    };
  };

  # ── shell snippets ─────────────────────────────────────────────────────
  # Per-app secret files, created only when absent (rotate = delete + restart)
  secretsText = ''
    umask 077
    install -d -m 0700 -o root -g root ${stateRoot} ${secretsDir}

    hex() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }
    alnum() { head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
    # once FILE CONTENT: a 0600 file with CONTENT, unless it exists and is not empty
    once() {
      if [ ! -s "$1" ]; then
        printf '%s' "$2" > "$1.tmp"
        mv "$1.tmp" "$1"
      fi
      chmod 0600 "$1"
    }
    # envfile FILE KEY=VALUE...: same, one line per argument
    envfile() {
      local f="$1"
      shift
      if [ ! -s "$f" ]; then
        printf '%s\n' "$@" > "$f.tmp"
        mv "$f.tmp" "$f"
      fi
      chmod 0600 "$f"
    }

    ${lib.optionalString (isOn "n8n") ''
      once ${secretsDir}/n8n-encryption-key "$(hex 32)"
    ''}
    ${lib.optionalString (isOn "local-chat") ''
      envfile ${secretsDir}/local-chat.env "WEBUI_SECRET_KEY=$(hex 32)"
    ''}
    ${lib.optionalString (isOn "flowise") ''
      envfile ${secretsDir}/flowise.env "FLOWISE_USERNAME=fleet-admin" "FLOWISE_PASSWORD=$(alnum 20)"
    ''}
    ${lib.optionalString (isOn "langflow") ''
      envfile ${secretsDir}/langflow.env "LANGFLOW_SUPERUSER=langflow" "LANGFLOW_SUPERUSER_PASSWORD=$(alnum 20)"
    ''}
    ${lib.optionalString (isOn "lobechat") ''
      envfile ${secretsDir}/lobechat.env "ACCESS_CODE=$(alnum 16)"
    ''}
    ${lib.optionalString (isOn "anythingllm") ''
      envfile ${secretsDir}/anythingllm.env "AUTH_TOKEN=$(alnum 20)" "JWT_SECRET=$(hex 32)"
    ''}
    ${lib.optionalString (isOn "openmuse") ''
      envfile ${secretsDir}/openmuse.env "OPENMUSE_ACCESS_KEY=$(alnum 28)" \
        "TOKEN_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64 -w0)" "WORKER_TOKEN=$(alnum 36)"
    ''}
  '';

  secretsScript = pkgs.writeShellApplication {
    name = "agentos-stack-secrets";
    runtimeInputs = [ pkgs.coreutils ];
    text = secretsText;
  };

  # Lines of <app>.llm.env, written by the gateway registration. $oa is the
  # OpenAI-compatible base URL (with the agent token), $an the Anthropic one.
  llmLines = {
    n8n = ''
      # n8n has no env switch: create an OpenAI/Anthropic credential in the UI
      OPENAI_BASE_URL=$oa
      ANTHROPIC_BASE_URL=$an
      OPENAI_API_KEY=agentos-managed
    '';
    local-chat = ''
      OPENAI_API_BASE_URL=$oa
      OPENAI_API_KEY=agentos-managed
    '';
    flowise = ''
      # Flowise has no env switch: set BasePath and the key in the UI credentials
      OPENAI_BASE_URL=$oa
      ANTHROPIC_BASE_URL=$an
      OPENAI_API_KEY=agentos-managed
    '';
    langflow = ''
      OPENAI_API_KEY=agentos-managed
      OPENAI_BASE_URL=$oa
      OPENAI_API_BASE=$oa
      ANTHROPIC_API_KEY=agentos-managed
      ANTHROPIC_BASE_URL=$an
      LANGFLOW_VARIABLES_TO_GET_FROM_ENVIRONMENT=OPENAI_API_KEY,ANTHROPIC_API_KEY
    '';
    anythingllm = ''
      LLM_PROVIDER=generic-openai
      GENERIC_OPEN_AI_BASE_PATH=$oa
      GENERIC_OPEN_AI_API_KEY=agentos-managed
      GENERIC_OPEN_AI_MODEL_PREF=${cfg.anythingllm.model}
      GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT=8192
    '';
    lobechat = ''
      OPENAI_API_KEY=agentos-managed
      OPENAI_PROXY_URL=$oa
      ANTHROPIC_API_KEY=agentos-managed
      ANTHROPIC_PROXY_URL=$an
    '';
    openmuse = ''
      OPENAI_API_KEY=agentos-managed
      OPENAI_BASE_URL=$oa
    '';
  };

  # Token + registration with the gateway admin socket + the app's LLM env file
  gwScript = app: host: pkgs.writeShellApplication {
    name = "agentos-stack-gw-${app}";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 077
      tok=${secretsDir}/${app}.gateway-token
      if [ ! -s "$tok" ]; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$tok"
      fi

      admin() {
        curl -fsS -m 10 --unix-socket ${adminSocket} -X "$1" -H 'Content-Type: application/json' \
          "''${@:3}" "http://x/_agentos/$2"
      }
      for _ in $(seq 1 60); do
        if admin GET health >/dev/null 2>&1; then
          break
        fi
        sleep 1
      done
      admin GET health >/dev/null || { echo "model gateway admin socket ${adminSocket} not available" >&2; exit 1; }

      hash=$(sha256sum < "$tok" | cut -d' ' -f1)
      admin PUT agents/${agentId app} -d "$(jq -cn --arg h "$hash" '{token_sha256: $h}')" >/dev/null
      admin PUT budget/${agentId app} -d '{"daily_usd": ${toString apps.${app}.budgetUsd}}' >/dev/null

      token=$(cat "$tok")
      base="http://${host}:${gwPort}/agent/${agentId app}:$token"
      oa="$base/${cfg.gateway.openaiProvider}/v1"
      an="$base/${cfg.gateway.anthropicProvider}"
      # the env file below uses whichever of the two the app needs
      : "$oa" "$an"
      cat > ${secretsDir}/${app}.llm.env.tmp <<EOF
      ${llmLines.${app}}EOF
      chmod 0600 ${secretsDir}/${app}.llm.env.tmp
      mv ${secretsDir}/${app}.llm.env.tmp ${secretsDir}/${app}.llm.env
    '';
  };

  hostFor = app: if builtins.elem app (builtins.attrNames containerApps) then cfg.network.gatewayAddress else loopback;

  gwService = app: _: {
    name = "agentos-stack-gw-${app}";
    value = {
      description = "Register ${agentId app} with the AgentOS model gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "agentos-model-gateway.service" ];
      requires = [ secretsUnit ];
      after = [ "agentos-model-gateway.service" secretsUnit ];
      restartTriggers = [ (gwScript app (hostFor app)) ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 120;
        ExecStart = "${gwScript app (hostFor app)}/bin/agentos-stack-gw-${app}";
      };
    };
  };

  # ── option helpers ─────────────────────────────────────────────────────
  commonOptions = name: { port, memoryMax }: {
    enable = lib.mkEnableOption "${name} of the agent stack";
    port = lib.mkOption {
      type = lib.types.port;
      default = port;
      description = "Loopback port of ${name} on the host (127.0.0.1 only).";
    };
    budgetUsd = lib.mkOption {
      type = lib.types.numbers.nonnegative;
      default = 2;
      description = ''
        Daily budget in USD of the gateway agent `stack-<app>` for ${name}. The
        gateway answers 402 once it is spent; local models cost 0.
      '';
    };
    memoryMax = lib.mkOption {
      type = lib.types.str;
      default = memoryMax;
      example = "4G";
      description = "Memory limit of ${name} (systemd MemoryMax or podman --memory; no swap).";
    };
  };

  containerOptions = name: { image, extraEnv ? { } }: {
    image = lib.mkOption {
      type = lib.types.str;
      default = image;
      description = ''
        Container image of ${name}. The default is pinned by tag and digest
        (`name:tag@sha256:...`; podman checks the digest). To update, resolve a
        new digest with `skopeo inspect docker://<name>:<tag> | jq -r .Digest`
        (or the `Docker-Content-Digest` header of a registry manifest HEAD)
        and keep tag and digest together.
      '';
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra, non-secret environment of the ${name} container.";
    };
    capabilities = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.bool);
      default = { };
      example = { SYS_ADMIN = true; };
      description = ''
        Capabilities of the ${name} container on top of `--cap-drop=ALL`
        (true adds one back). None are added by default.
      '';
    };
    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra `podman run` flags of the ${name} container.";
    };
  };

  mkContainer = app:
    let
      a = apps.${app};
      s = specs.${app};
    in
    {
      name = "agentos-stack-${app}";
      value = {
        image = if a.image == null then "" else a.image;
        autoStart = true;
        pull = "missing";
        ports = [ "${loopback}:${toString a.port}:${toString s.port}" ];
        volumes = [ "${stateRoot}/${app}:${s.volume}" ];
        environment = s.env // a.environment;
        environmentFiles =
          [ "${secretsDir}/${app}.env" ]
          ++ lib.optional s.llmEnv "${secretsDir}/${app}.llm.env";
        networks = [ cfg.network.podmanNetwork ];
        privileged = false;
        capabilities = { ALL = false; } // a.capabilities;
        extraOptions = [
          "--security-opt=no-new-privileges"
          "--memory=${a.memoryMax}"
          "--memory-swap=${a.memoryMax}"
          "--pids-limit=2048"
        ] ++ a.extraOptions;
      };
    };

  mkContainerUnit = app: _: {
    name = "podman-agentos-stack-${app}";
    value = {
      requires = [ secretsUnit (gwUnit app) ];
      after = [ secretsUnit (gwUnit app) ];
    };
  };

  # host side of the persistent volumes, owned by the user the image runs as
  hostVolumeRules = lib.mapAttrsToList
    (app: _: "d ${stateRoot}/${app} 0750 ${builtins.head (lib.splitString ":" specs.${app}.owner)} ${builtins.elemAt (lib.splitString ":" specs.${app}.owner) 1} -")
    containerApps;
in
{
  options.agentos.agentStack = {
    enable = lib.mkEnableOption ''
      the agent-fleet app stack (n8n, Open WebUI + Ollama, Flowise, Langflow,
      AnythingLLM, LobeChat, OpenMuse) on this host. This switch only allows
      the apps; each one has its own `enable`
    '';

    gateway = {
      openaiProvider = lib.mkOption {
        type = lib.types.str;
        default = "openai";
        example = "local";
        description = ''
          Gateway provider (agentos.networking.providers) behind the OpenAI-
          compatible base URL of the apps. Use `local` to keep every app on
          local models.
        '';
      };
      anthropicProvider = lib.mkOption {
        type = lib.types.str;
        default = "anthropic";
        description = "Gateway provider behind the Anthropic base URL of the apps.";
      };
    };

    network = {
      podmanNetwork = lib.mkOption {
        type = lib.types.str;
        default = "agentstack";
        description = "Name of the podman network of the stack containers (bridge agentstack0).";
      };
      subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.89.0.0/24";
        description = "Subnet of the stack containers; the bridge takes the .1 address.";
      };
      gatewayAddress = lib.mkOption {
        type = lib.types.str;
        default = "10.89.1.1";
        description = ''
          Host address the containers use to reach the model gateway. It is an
          address of the host (on lo) outside `subnet`, so it exists at boot
          and the gateway can bind to it before podman creates the bridge.
          The containers reach it through the bridge and may use only the
          gateway port there.
        '';
      };
    };

    n8n = commonOptions "n8n" { port = 5678; memoryMax = "2G"; } // {
      webhookUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://n8n.example.com/";
        description = "Public URL for webhooks (WEBHOOK_URL), when n8n is published behind your own proxy.";
      };
    };

    localChat = commonOptions "local chat (Open WebUI + Ollama)" { port = 8180; memoryMax = "4G"; } // {
      models = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "llama3.2:1b" "qwen2.5:0.5b" "nomic-embed-text" ];
        description = ''
          Ollama models to pull (the agent-fleet `local-chat` defaults). They
          are added to agentos.localAI.models.
        '';
      };
    };

    flowise = commonOptions "Flowise" { port = 3000; memoryMax = "2G"; }
      // containerOptions "Flowise" {
      image = "flowiseai/flowise:3.1.4@sha256:3922767afb52a5777759fd8b28a3c9eee864daea96018a791f2429eae2a76571";
    };

    langflow = commonOptions "Langflow" { port = 7860; memoryMax = "4G"; }
      // containerOptions "Langflow" {
      image = "langflowai/langflow:1.12.4@sha256:4304bd9e67db00e72ab20d7a853abbc46d107901215b50a8298f4c4f45127eae";
    };

    anythingllm = commonOptions "AnythingLLM" { port = 3001; memoryMax = "3G"; }
      // containerOptions "AnythingLLM" {
      # upstream publishes no version tags on Docker Hub, only latest/master/render-*
      image = "mintplexlabs/anythingllm:master@sha256:e4d5b7c15aae0d7666038145b75971a9471164a74b09efe86f39933e073e331c";
    } // {
      model = lib.mkOption {
        type = lib.types.str;
        default = "gpt-4o-mini";
        description = "Model id AnythingLLM requests through the gateway (GENERIC_OPEN_AI_MODEL_PREF).";
      };
    };

    lobechat = commonOptions "LobeChat" { port = 3210; memoryMax = "1G"; }
      // containerOptions "LobeChat" {
      image = "lobehub/lobe-chat:1.143.3@sha256:b2d2454525523d9f0a19c79661f83ec45f13363dbadd5c1180887e77af35d872";
    };

    openmuse = commonOptions "OpenMuse" { port = 7861; memoryMax = "4G"; }
      // containerOptions "OpenMuse" { image = ""; } // {
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "localhost/openmuse:local";
        description = ''
          OpenMuse has no upstream image: agent-fleet builds it from a clone
          of CopilotKit/openmuse (nginx + API + worker + Playwright). Build
          it yourself from spaces/openmuse/Dockerfile of agent-fleet with
          `--build-arg PUBLIC_URL=http://127.0.0.1:<port>`, load it with
          `podman load`, and set it here (pin by digest). Enabling OpenMuse
          without an image is refused.
        '';
      };
      model = lib.mkOption {
        type = lib.types.str;
        default = "openai/gpt-5";
        description = "MODEL of OpenMuse.";
      };
      cpkKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/cpk-intelligence-key";
        description = ''
          File with `CPK_INTELLIGENCE_API_KEY=...` (a CopilotKit project key,
          required by the API to boot). Passed as an env file; it must live
          outside the Nix store. This is not a model provider key.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList
        (n: a: {
          assertion = !a.enable || cfg.enable;
          message = "agentos.agentStack: ${n} is enabled but agentos.agentStack.enable is false";
        })
        apps;
    }

    (lib.mkIf (cfg.enable && enabledApps != { }) {
      assertions = [
        {
          assertion = net.enable && config.agentos.runtime.enable;
          message = "agentos.agentStack routes LLM calls through the model gateway: enable agentos.runtime and agentos.networking";
        }
        {
          assertion = !isOn "openmuse" || (cfg.openmuse.image != null && cfg.openmuse.cpkKeyFile != null);
          message = ''
            agentos.agentStack.openmuse: there is no upstream OpenMuse image. Build one from agent-fleet's
            spaces/openmuse/Dockerfile and set agentos.agentStack.openmuse.image, and set .cpkKeyFile
            (see docs/agent-stack.md).
          '';
        }
        {
          assertion = !isOn "local-chat" || config.agentos.localAI.backend == "ollama";
          message = "agentos.agentStack.localChat needs agentos.localAI.backend = \"ollama\"";
        }
      ];

      # Secrets: one root oneshot, files 0600 in a 0700 directory
      systemd.services.agentos-stack-secrets = {
        description = "Generate the agent-stack secrets (first boot only)";
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ secretsScript ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${secretsScript}/bin/agentos-stack-secrets";
          UMask = "0077";
        };
      };
    })

    # Gateway agent ids, tokens and budgets for every enabled app
    (lib.mkIf (cfg.enable && enabledApps != { }) {
      systemd.services = lib.listToAttrs (lib.mapAttrsToList gwService enabledApps);
    })

    # ── n8n (native) ───────────────────────────────────────────────────
    (lib.mkIf (isOn "n8n") {
      services.n8n = {
        enable = true;
        environment = {
          N8N_LISTEN_ADDRESS = loopback;
          N8N_PORT = cfg.n8n.port;
          # read through a systemd credential; the key file is root-only
          N8N_ENCRYPTION_KEY_FILE = "${secretsDir}/n8n-encryption-key";
          N8N_PERSONALIZATION_ENABLED = false;
          N8N_TEMPLATES_ENABLED = false;
        } // lib.optionalAttrs (cfg.n8n.webhookUrl != null) { WEBHOOK_URL = cfg.n8n.webhookUrl; };
      };
      systemd.services.n8n = {
        requires = [ secretsUnit ];
        after = [ secretsUnit ];
        serviceConfig.MemoryMax = cfg.n8n.memoryMax;
      };
    })

    # ── local chat: agentos.localAI with the agent-fleet defaults ─────────
    (lib.mkIf (isOn "local-chat") {
      agentos.localAI = {
        enable = lib.mkDefault true;
        backend = lib.mkDefault "ollama";
        models = cfg.localChat.models;
        webui = {
          enable = lib.mkDefault true;
          port = lib.mkDefault cfg.localChat.port;
        };
      };
      systemd.services.open-webui = {
        requires = [ secretsUnit (gwUnit "local-chat") ];
        after = [ secretsUnit (gwUnit "local-chat") ];
        environment.WEBUI_AUTH = "True";
        serviceConfig = {
          EnvironmentFile = [
            "${secretsDir}/local-chat.env"
            "${secretsDir}/local-chat.llm.env"
          ];
          MemoryMax = cfg.localChat.memoryMax;
        };
      };
    })

    # ── containers ─────────────────────────────────────────────────────
    (lib.mkIf anyContainer {
      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = lib.mkDefault "podman";
      virtualisation.oci-containers.containers =
        lib.listToAttrs (map mkContainer (builtins.attrNames containerApps));

      systemd.services = lib.mapAttrs' mkContainerUnit containerApps // {
        agentos-model-gateway = {
          after = [ "network-addresses-lo.service" ];
          wants = [ "network-addresses-lo.service" ];
        };
      };

      systemd.tmpfiles.rules = hostVolumeRules;

      # A dedicated netavark network on bridge agentstack0
      environment.etc."containers/networks/${cfg.network.podmanNetwork}.json".text = builtins.toJSON {
        name = cfg.network.podmanNetwork;
        id = builtins.hashString "sha256" "agentos-stack-${cfg.network.podmanNetwork}";
        driver = "bridge";
        network_interface = "agentstack0";
        subnets = [{
          subnet = cfg.network.subnet;
          gateway = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." (lib.head (lib.splitString "/" cfg.network.subnet))) ++ [ "1" ]);
        }];
        ipv6_enabled = false;
        internal = false;
        dns_enabled = false;
        ipam_options.driver = "host-local";
      };

      # The gateway listens on this host address too (a list that merges with
      # the loopback and agentos0 entries)
      networking.interfaces.lo.ipv4.addresses = [{
        address = cfg.network.gatewayAddress;
        prefixLength = 32;
      }];
      agentos.services.settings.gateway.listen = [ cfg.network.gatewayAddress ];

      # From the stack bridge the host offers the gateway port and nothing else
      networking.firewall.extraCommands = ''
        iptables -D INPUT -i agentstack0 -j agentstack-in 2>/dev/null || true
        iptables -F agentstack-in 2>/dev/null || iptables -N agentstack-in
        iptables -I INPUT 1 -i agentstack0 -j agentstack-in
        iptables -A agentstack-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A agentstack-in -d ${cfg.network.gatewayAddress} -p tcp --dport ${gwPort} -j ACCEPT
        iptables -A agentstack-in -j REJECT
      '';
      networking.firewall.extraStopCommands = ''
        iptables -D INPUT -i agentstack0 -j agentstack-in 2>/dev/null || true
        iptables -F agentstack-in 2>/dev/null || true
        iptables -X agentstack-in 2>/dev/null || true
      '';
    })

    # OpenMuse: the user's CopilotKit key is one more env file
    (lib.mkIf (isOn "openmuse") {
      virtualisation.oci-containers.containers.agentos-stack-openmuse = {
        image = lib.mkForce cfg.openmuse.image;
        environmentFiles = [ (toString cfg.openmuse.cpkKeyFile) ];
      };
    })
  ];
}
