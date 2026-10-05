# Nestlo LocalAI backend
#
# LocalAI (MIT, https://localai.io) as an additional local inference server
# next to Ollama / llama.cpp (modules/local-ai/default.nix). It serves the
# OpenAI API on loopback and is registered with the model gateway as the
# keyless-for-agents, zero-cost provider `localai`, so agents reach it at
# /agent/<id>:<token>/localai/v1 and every request still goes through
# budgets, rate limits, DLP, loop detection and the audit log.
#
# Two ways to run it (`deployment`):
#   container (default)  the upstream OCI image (CPU, CUDA 12 or ROCm
#                        variant, pinned by digest) under Podman, published
#                        on 127.0.0.1 only. Chosen as the default because
#   package              `pkgs.local-ai` is marked `broken = true` in the
#                        pinned nixpkgs (it does not build with the current
#                        Go: "cp: cannot stat 'bin/rpc-server'"), and nixpkgs
#                        has no `services.local-ai` (only a test-only module,
#                        pkgs/by-name/lo/local-ai/module.nix). The package
#                        unit below follows that module (same flags, runtime
#                        directory as working directory) and adds hardening;
#                        use it once the package builds again, or with your
#                        own `package`.
#
# A container is also the more isolated choice: LocalAI starts its model
# backends as gRPC servers on localhost TCP ports. In a container they sit in
# the container's network namespace and only the API port is published; in
# the package unit they are on the host's loopback, where any local user
# (including the agent user) can reach them without a key.
#
# Independent of nestlo.localAI.enable: both servers can run side by side.
# See docs/local-ai-backends.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.localAI.localai;
  loopback = "127.0.0.1";
  stateDir = "/var/lib/local-ai";
  isContainer = cfg.deployment == "container";

  accel = config.nestlo.localAI.resolvedAcceleration;
  usesGpu = accel == "cuda" || accel == "rocm";

  # Upstream images, v3.9.0, pinned by manifest-list digest (docker.io/localai/localai)
  images = {
    cpu = "localai/localai:v3.9.0@sha256:29c0965e27ac450cd79a13d2fa3e1679413283211de045ea01727ebe681a2dca";
    cuda = "localai/localai:v3.9.0-gpu-nvidia-cuda-12@sha256:94011182ea0eb5b3540b20d869294f5dbf6ab376c4a66b3c19dc52f558c5d296";
    rocm = "localai/localai:v3.9.0-gpu-hipblas@sha256:64c75858e03671abc6fb8f29aa9bce86c5235f67c50284d45a62b444bf7882b0";
  };

  # Model configs as the package's `lib.genModels` builds them (one YAML per
  # model; a derivation in parameters.model is linked next to it), written
  # here so it does not depend on the (broken) package
  modelFiles = name: conf:
    let
      weights = conf.parameters.model or null;
      isDrv = lib.isDerivation weights;
      conf' = lib.recursiveUpdate conf ({ inherit name; }
        // lib.optionalAttrs isDrv { parameters.model = weights.name; });
    in
    [{ name = "${name}.yaml"; path = pkgs.writers.writeYAML "${name}.yaml" conf'; }]
    ++ lib.optional isDrv { name = weights.name; path = weights; };
  generatedModels =
    if cfg.modelConfigs == { } then null
    else pkgs.linkFarm "local-ai-models"
      (lib.flatten (lib.mapAttrsToList modelFiles cfg.modelConfigs));

  # Where the server reads models from, on the host
  hostModels =
    if cfg.modelsPath != null then toString cfg.modelsPath
    else if generatedModels != null then toString generatedModels
    else "${stateDir}/models";

  keyDir = "/var/lib/nestlo-localai";
  keyFile = "${keyDir}/api-key";
  envFile = "${keyDir}/container.env";

  gpuEnv = lib.optionalAttrs (cfg.gpuDevices != null) {
    CUDA_VISIBLE_DEVICES = cfg.gpuDevices;
    HIP_VISIBLE_DEVICES = cfg.gpuDevices;
  };

  # package mode: the key comes from the unit's credential, not the unit file
  start = pkgs.writeShellScript "nestlo-localai-start" ''
    ${lib.optionalString cfg.apiKey.enable ''
      LOCALAI_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/api-key")"
      export LOCALAI_API_KEY
    ''}
    exec ${lib.escapeShellArgs ([
      "${cfg.package}/bin/local-ai"
      "--address=${loopback}:${toString cfg.port}"
      "--threads=${toString cfg.threads}"
      "--localai-config-dir=."
      "--models-path=${hostModels}"
      "--log-level=${cfg.logLevel}"
    ]
    ++ lib.optional (cfg.parallelRequests > 1) "--parallel-requests"
    ++ cfg.extraArgs)}
  '';
in
{
  options.nestlo.localAI.localai = {
    enable = lib.mkEnableOption "the LocalAI server behind the model gateway";

    deployment = lib.mkOption {
      type = lib.types.enum [ "container" "package" ];
      default = "container";
      description = ''
        container: the upstream image under Podman (works today).
        package: `pkgs.local-ai` as a hardened systemd unit. That package is
        marked broken in the pinned nixpkgs, so this needs a package that
        builds (set `package`, and `nixpkgs.config.allowBroken` if you
        patched it yourself).
      '';
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = images.${if accel == "cuda" || accel == "rocm" then accel else "cpu"};
      defaultText = lib.literalExpression "localai/localai v3.9.0 (cpu, cuda-12 or hipblas by nestlo.localAI.resolvedAcceleration), pinned by digest";
      description = "Container image (deployment = container). Keep the digest.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.local-ai;
      defaultText = lib.literalExpression "pkgs.local-ai";
      description = "LocalAI package (deployment = package). Marked broken in the pinned nixpkgs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Loopback port (8080 is the model gateway, 8081 llama.cpp, 11434 Ollama).";
    };

    modelConfigs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''
        {
          qwen-coder = {
            backend = "llama-cpp";
            parameters.model = pkgs.fetchurl { url = "..."; hash = "..."; };
            context_size = 8192;
          };
        }
      '';
      description = ''
        Models to serve, by model name. Each value is a LocalAI model config
        (<https://localai.io/advanced/>); a derivation in `parameters.model`
        (a fetched GGUF file) is linked next to the generated YAML. They are
        assembled into one read-only store directory. Empty: LocalAI starts
        without models (GET /v1/models answers an empty list).
      '';
    };

    modelsPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/models/localai";
      description = ''
        Use this directory instead of `modelConfigs` (for example weights
        that were copied to the machine); mounted read-only. Unset and no
        `modelConfigs`: ${stateDir}/models, empty at first. A directory
        outside ${stateDir} must be listed in `extraReadPaths` for the
        package unit.
      '';
    };

    extraReadPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Further read-only paths the package unit may see (BindReadOnlyPaths), such as a model directory on another disk.";
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "CPU threads per request.";
    };

    parallelRequests = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Concurrent requests per model (`--parallel-requests`, LLAMACPP_PARALLEL).";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "error" "warn" "info" "debug" "trace" ];
      default = "warn";
      description = "LocalAI log level.";
    };

    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "16G";
      description = "systemd MemoryMax of the server (a model that does not fit is killed instead of starving the agents).";
    };

    gpuDevices = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0";
      description = ''
        Restrict the server to these GPU indices (CUDA_/HIP_VISIBLE_DEVICES).
        Like Ollama here, LocalAI takes no lock from `nestlo gpu`; this keeps
        other GPUs free for `nestlo spawn --gpu`.
      '';
    };

    allowOutbound = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        package mode: let the unit open connections beyond loopback (model
        gallery, Hugging Face). Off by default. Not enforced for containers,
        whose backend downloads need the network; see docs/local-ai-backends.md.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--disable-webui" ];
      description = "Extra `local-ai` flags (package mode).";
    };

    apiKey.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require an API key on the server. Loopback is reachable by every
        local user, including the agent user, so without a key an agent could
        call the backend directly and skip the gateway's budgets, DLP and
        audit log. The key is generated on first boot into ${keyFile}
        (root:nestlo, mode 0640), registered as the provider's `keyFile`
        (the gateway injects it; agents only ever see "nestlo-managed") and
        handed to the server (a systemd credential, or an env file for the
        container).
      '';
    };

    providerName = lib.mkOption {
      type = lib.types.str;
      default = "localai";
      description = "Name of the provider registered in nestlo.networking.providers.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.nestlo.networking.enable;
          message = "nestlo.localAI.localai registers a gateway provider; enable nestlo.networking";
        }
        {
          assertion = !(config.nestlo.localAI.enable && config.nestlo.localAI.port == cfg.port);
          message = "nestlo.localAI.localai.port clashes with nestlo.localAI.port (${toString cfg.port})";
        }
        {
          assertion = !cfg.apiKey.enable || config.users.groups ? nestlo;
          message = "nestlo.localAI.localai.apiKey needs the group nestlo (nestlo.runtime.enable) so the gateway can read the key";
        }
        {
          assertion = cfg.port != config.nestlo.networking.modelGatewayPort;
          message = "nestlo.localAI.localai.port must differ from the model gateway port";
        }
        {
          assertion = !(cfg.modelsPath != null && cfg.modelConfigs != { });
          message = "nestlo.localAI.localai: set either modelsPath or modelConfigs, not both";
        }
      ];

      # Keyless-for-agents OpenAI-compatible upstream priced at $0 by the gateway
      nestlo.networking.providers.${cfg.providerName} = {
        baseUrl = "http://${loopback}:${toString cfg.port}";
        api = lib.mkDefault "openai-compatible";
        zeroCost = lib.mkDefault true;
        keyFile = if cfg.apiKey.enable then keyFile else null;
      };

      # Generates the key once; later boots keep it
      systemd.services.nestlo-localai-key = lib.mkIf cfg.apiKey.enable {
        description = "Create the LocalAI API key";
        wantedBy = [ "multi-user.target" ];
        before = [ (if isContainer then "podman-nestlo-localai.service" else "nestlo-localai.service") ];
        unitConfig.ConditionPathExists = "!${keyFile}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          StateDirectory = "nestlo-localai";
          StateDirectoryMode = "0750";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
        script = ''
          key=$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/od -An -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n')
          printf '%s' "$key" > ${keyFile}
          printf 'LOCALAI_API_KEY=%s\n' "$key" > ${envFile}
          ${pkgs.coreutils}/bin/chgrp nestlo ${keyDir} ${keyFile}
          ${pkgs.coreutils}/bin/chmod 0640 ${keyFile}
          ${pkgs.coreutils}/bin/chmod 0600 ${envFile}
        '';
      };
      systemd.tmpfiles.rules = lib.optional cfg.apiKey.enable "d ${keyDir} 0750 root nestlo -"
        ++ lib.optional (hostModels == "${stateDir}/models") "d ${stateDir}/models 0755 root root -";
    }

    # ── container ───────────────────────────────────────────────────────
    (lib.mkIf isContainer {
      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = lib.mkDefault "podman";
      virtualisation.oci-containers.containers.nestlo-localai = {
        image = cfg.image;
        # Only the API is published, and only on loopback. The gRPC model
        # backends LocalAI starts stay inside the container's namespace.
        ports = [ "${loopback}:${toString cfg.port}:8080" ];
        volumes = [
          "${hostModels}:/models:ro"
          "${stateDir}/backends:/backends"
        ];
        environment = {
          LOCALAI_MODELS_PATH = "/models";
          LOCALAI_BACKENDS_PATH = "/backends";
          LOCALAI_THREADS = toString cfg.threads;
          LOCALAI_LOG_LEVEL = cfg.logLevel;
          LLAMACPP_PARALLEL = toString cfg.parallelRequests;
          DO_NOT_TRACK = "1";
        } // lib.optionalAttrs (cfg.parallelRequests > 1) { LOCALAI_PARALLEL_REQUESTS = "true"; }
        // gpuEnv;
        environmentFiles = lib.optional cfg.apiKey.enable envFile;
        extraOptions = [
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
          "--pids-limit=4096"
        ] ++ lib.optional (accel == "cuda") "--device=nvidia.com/gpu=all"
        ++ lib.optionals (accel == "rocm") [ "--device=/dev/kfd" "--device=/dev/dri" ];
      };
      systemd.tmpfiles.rules = [ "d ${stateDir}/backends 0755 root root -" ];
      systemd.services.podman-nestlo-localai = {
        after = lib.optional cfg.apiKey.enable "nestlo-localai-key.service";
        requires = lib.optional cfg.apiKey.enable "nestlo-localai-key.service";
        serviceConfig = lib.optionalAttrs (cfg.memoryMax != null) { MemoryMax = cfg.memoryMax; };
      };
    })

    # ── package ─────────────────────────────────────────────────────────
    (lib.mkIf (!isContainer) {
      systemd.services.nestlo-localai = {
        description = "LocalAI (OpenAI-compatible, loopback only)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ lib.optional cfg.apiKey.enable "nestlo-localai-key.service";
        requires = lib.optional cfg.apiKey.enable "nestlo-localai-key.service";
        environment = {
          LLAMACPP_PARALLEL = toString cfg.parallelRequests;
          DO_NOT_TRACK = "1";
          HOME = "%t/local-ai";
        } // gpuEnv;

        serviceConfig = {
          ExecStart = start;
          DynamicUser = true;
          LoadCredential = lib.optional cfg.apiKey.enable "api-key:${keyFile}";
          # The backends are gRPC servers on localhost; the working directory
          # is where LocalAI unpacks them (as in the nixpkgs module)
          RuntimeDirectory = "local-ai";
          WorkingDirectory = "%t/local-ai";
          StateDirectory = "local-ai";
          StateDirectoryMode = "0750";
          Restart = "on-failure";
          RestartSec = 5;

          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          # other processes are hidden, but /proc/cpuinfo, /proc/meminfo and
          # /proc/driver/nvidia stay: psutil, torch and the GPU runtimes read them
          ProtectProc = "invisible";
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
          UMask = "0077";
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          # GPU runtimes and the Go/cgo backends map executable memory
          MemoryDenyWriteExecute = false;
          PrivateDevices = !usesGpu;
          BindReadOnlyPaths = map toString cfg.extraReadPaths;
        } // lib.optionalAttrs (cfg.memoryMax != null) { MemoryMax = cfg.memoryMax; }
        // lib.optionalAttrs (!cfg.allowOutbound) {
          IPAddressAllow = [ "localhost" ];
          IPAddressDeny = "any";
        } // lib.optionalAttrs usesGpu {
          DevicePolicy = "closed";
          DeviceAllow = [
            "char-nvidia-frontend rw"
            "char-nvidia-uvm rw"
            "char-nvidia-caps rw"
            "/dev/kfd rw"
            "char-drm rw"
          ];
        };
      };
    })
  ]);
}
