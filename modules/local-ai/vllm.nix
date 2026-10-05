# Nestlo vLLM backend
#
# vLLM (Apache-2.0, https://github.com/vllm-project/vllm): a high-throughput
# GPU inference server with an OpenAI-compatible API. One process serves one
# model, so `models` declares one hardened unit per model
# (nestlo-vllm-<name>.service). Each listens on loopback and is registered
# with the model gateway as a keyless-for-agents, zero-cost provider of api
# `openai-compatible` (default name `vllm-<name>`), so agents use it at
# /agent/<id>:<token>/vllm-<name>/v1 with budgets, rate limits, DLP and the
# audit log in front of it.
#
# GPU scheduling (modules/gpu): `nestlo spawn --gpu` hands GPUs to agents by
# a lock file per index (<lockDir>/<index>) that the daemon's reaper frees
# when the holder is not a running agent, so a server cannot hold a lock.
# Instead each model names its GPUs (`gpus`); the unit gets exactly those
# device nodes (DeviceAllow) and CUDA_VISIBLE_DEVICES, the same mechanism
# `nestlo spawn --gpu` uses for agents. Keep the indices vLLM uses out of
# agents' reach by running agents with explicit `--gpu N` of other GPUs.
#
# Needs a GPU for the CUDA/ROCm builds; the CPU build of vLLM works but is
# slow. Nothing here runs without `nestlo.localAI.vllm.models`.
# See docs/local-ai-backends.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.localAI.vllm;
  loopback = "127.0.0.1";
  keyDir = "/var/lib/nestlo-vllm";
  keyFile = "${keyDir}/api-key";

  accel = cfg.acceleration;
  # Built with CUDA/ROCm through nixpkgs' pkgsCuda/pkgsRocm package sets
  # (unfree for CUDA: nixpkgs.config.allowUnfree)
  # `pkgs.unstable` (flake overlay): the stable pin carries vLLM 0.16.0, which
  # nixpkgs marks insecure (15 known CVEs); unstable has 0.24.0
  upstream = pkgs.unstable or pkgs;
  autoPackage =
    if accel == "cuda" then upstream.pkgsCuda.vllm
    else if accel == "rocm" then upstream.pkgsRocm.vllm
    else upstream.vllm;

  names = lib.attrNames cfg.models;
  portOf = name:
    let m = cfg.models.${name};
    in if m.port != null then m.port
    else cfg.basePort + (lib.lists.findFirstIndex (n: n == name) 0 names);
  providerOf = name: cfg.models.${name}.providerName;
  unitOf = name: "nestlo-vllm-${name}";

  nvidiaNodes = gpus:
    (map (i: "/dev/nvidia${toString i} rw") gpus)
    ++ [ "/dev/nvidiactl rw" "/dev/nvidia-uvm rw" "/dev/nvidia-uvm-tools rw" "/dev/nvidia-modeset rw" ];
  deviceAllow = m:
    if accel == "cuda" then nvidiaNodes m.gpus
    else if accel == "rocm" then [ "/dev/kfd rw" "char-drm rw" ]
    else [ ];

  start = name: m: pkgs.writeShellScript "${unitOf name}-start" ''
    ${lib.optionalString cfg.apiKey.enable ''
      VLLM_API_KEY="$(cat "$CREDENTIALS_DIRECTORY/api-key")"
      export VLLM_API_KEY
    ''}
    exec ${lib.escapeShellArgs ([
      "${cfg.package}/bin/vllm" "serve" m.model
      "--host" loopback
      "--port" (toString (portOf name))
      "--served-model-name" m.servedModelName
      "--dtype" m.dtype
      "--gpu-memory-utilization" (toString m.gpuMemoryUtilization)
    ]
    ++ lib.optionals (m.maxModelLen != null) [ "--max-model-len" (toString m.maxModelLen) ]
    ++ lib.optionals (m.quantization != null) [ "--quantization" m.quantization ]
    ++ lib.optionals (accel != "cpu" && lib.length m.gpus > 1) [ "--tensor-parallel-size" (toString (lib.length m.gpus)) ]
    ++ m.extraArgs)}
  '';

  modelOptions = { name, config, ... }: {
    options = {
      model = lib.mkOption {
        type = lib.types.str;
        example = "Qwen/Qwen2.5-Coder-7B-Instruct";
        description = ''
          Hugging Face repository id, or an absolute path to a model
          directory. With `offline = true` (the default) a repository id
          must already be in the cache (${cfg.cacheDir}), so prefer a path
          that is provisioned declaratively.
        '';
      };
      servedModelName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Model name clients send (`--served-model-name`).";
      };
      providerName = lib.mkOption {
        type = lib.types.str;
        default = "vllm-${name}";
        description = "Name of the provider registered in nestlo.networking.providers.";
      };
      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Loopback port. Null: `basePort` plus the model's position in alphabetical order.";
      };
      gpus = lib.mkOption {
        type = lib.types.listOf lib.types.ints.unsigned;
        default = [ 0 ];
        example = [ 0 1 ];
        description = ''
          GPU indices this server uses (CUDA_VISIBLE_DEVICES, and the device
          nodes it may open). More than one sets `--tensor-parallel-size`.
          Ignored for the CPU build.
        '';
      };
      maxModelLen = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Context length (`--max-model-len`); null: the model's own.";
      };
      gpuMemoryUtilization = lib.mkOption {
        type = lib.types.numbers.between 0.1 1.0;
        default = 0.85;
        description = "Fraction of GPU memory vLLM may take (`--gpu-memory-utilization`). Leave room for agents' own GPU use.";
      };
      dtype = lib.mkOption {
        type = lib.types.str;
        default = "auto";
        description = "Weight data type (`--dtype`).";
      };
      quantization = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "awq";
        description = "`--quantization` method.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "--enable-auto-tool-choice" "--tool-call-parser" "hermes" ];
        description = "Extra `vllm serve` flags.";
      };
    };
  };
in
{
  options.nestlo.localAI.vllm = {
    enable = lib.mkEnableOption "vLLM servers behind the model gateway";

    acceleration = lib.mkOption {
      type = lib.types.enum [ "cuda" "rocm" "cpu" ];
      default = config.nestlo.localAI.resolvedAcceleration;
      defaultText = lib.literalExpression "config.nestlo.localAI.resolvedAcceleration";
      description = ''
        Build and device access. Defaults to what `nestlo.gpu.vendor`
        resolves to (nvidia: cuda, amd: rocm), else cpu.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = autoPackage;
      defaultText = lib.literalExpression "pkgs.unstable.pkgsCuda.vllm, pkgs.unstable.pkgsRocm.vllm or pkgs.unstable.vllm by acceleration";
      description = ''
        vLLM package (the one with `bin/vllm`). CUDA needs
        `nixpkgs.config.allowUnfree`. Building vLLM from source takes hours:
        use a binary cache that carries it.
      '';
    };

    models = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule modelOptions);
      default = { };
      example = lib.literalExpression ''
        {
          coder = {
            model = "/var/lib/models/Qwen2.5-Coder-7B-Instruct";
            gpus = [ 0 ];
            maxModelLen = 32768;
          };
        }
      '';
      description = "Models to serve, one `nestlo-vllm-<name>.service` each.";
    };

    basePort = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "First loopback port for models without an explicit `port`.";
    };

    cacheDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/nestlo-vllm";
      description = "Hugging Face and vLLM cache (HF_HOME). Shared by the model units and mounted read-only into them: pre-populate it as root (weights are not secret, so it is world-readable).";
    };

    offline = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        HF_HUB_OFFLINE and TRANSFORMERS_OFFLINE: never contact Hugging Face.
        The model must be a local path or already in `cacheDir`. When false
        the units may also reach the network to download weights.
      '';
    };

    apiKey.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Require an API key (VLLM_API_KEY). Loopback is reachable by every
        local user, including the agent user, so without a key an agent could
        call vLLM directly and skip the gateway's budgets, DLP and audit log.
        The key is generated on first boot into ${keyFile} (root:nestlo, mode
        0640), registered as each provider's `keyFile` (the gateway injects
        it; agents only see "nestlo-managed") and given to the units as a
        systemd credential.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.nestlo.networking.enable;
        message = "nestlo.localAI.vllm registers gateway providers; enable nestlo.networking";
      }
      {
        assertion = cfg.models != { };
        message = "nestlo.localAI.vllm.enable needs at least one entry in nestlo.localAI.vllm.models";
      }
      {
        assertion = !cfg.apiKey.enable || config.users.groups ? nestlo;
        message = "nestlo.localAI.vllm.apiKey needs the group nestlo (nestlo.runtime.enable) so the gateway can read the key";
      }
      {
        assertion = let ports = map portOf names; in lib.length (lib.unique ports) == lib.length ports;
        message = "nestlo.localAI.vllm: two models use the same port";
      }
      {
        assertion = !(lib.elem config.nestlo.networking.modelGatewayPort (map portOf names))
          && !(config.nestlo.localAI.enable && lib.elem config.nestlo.localAI.port (map portOf names))
          && !(config.nestlo.localAI.localai.enable && lib.elem config.nestlo.localAI.localai.port (map portOf names));
        message = "nestlo.localAI.vllm: a model port clashes with the gateway, nestlo.localAI or nestlo.localAI.localai";
      }
      {
        assertion = let ps = map providerOf names; in lib.length (lib.unique ps) == lib.length ps;
        message = "nestlo.localAI.vllm: two models register the same provider name";
      }
    ] ++ map
      (n: {
        assertion = cfg.models.${n}.gpus != [ ] || accel == "cpu";
        message = "nestlo.localAI.vllm.models.${n}.gpus must name at least one GPU";
      })
      names;

    nestlo.networking.providers = lib.listToAttrs (map
      (n: lib.nameValuePair (providerOf n) {
        baseUrl = "http://${loopback}:${toString (portOf n)}";
        api = lib.mkDefault "openai-compatible";
        zeroCost = lib.mkDefault true;
        keyFile = if cfg.apiKey.enable then keyFile else null;
      })
      names);

    systemd.tmpfiles.rules = [ "d ${cfg.cacheDir} 0755 root root -" ]
      ++ lib.optional cfg.apiKey.enable "d ${keyDir} 0750 root nestlo -";

    systemd.services = {
      nestlo-vllm-key = lib.mkIf cfg.apiKey.enable {
        description = "Create the vLLM API key";
        wantedBy = [ "multi-user.target" ];
        before = map (n: "${unitOf n}.service") names;
        unitConfig.ConditionPathExists = "!${keyFile}";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          StateDirectory = "nestlo-vllm";
          StateDirectoryMode = "0750";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
        script = ''
          ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/od -An -tx1 | ${pkgs.coreutils}/bin/tr -d ' \n' > ${keyFile}
          ${pkgs.coreutils}/bin/chgrp nestlo ${keyDir} ${keyFile}
          ${pkgs.coreutils}/bin/chmod 0640 ${keyFile}
        '';
      };
    } // lib.mapAttrs'
      (name: m: lib.nameValuePair (unitOf name) {
        description = "vLLM server for ${name} (${m.model})";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ] ++ lib.optional cfg.apiKey.enable "nestlo-vllm-key.service";
        requires = lib.optional cfg.apiKey.enable "nestlo-vllm-key.service";
        environment = {
          HF_HOME = cfg.cacheDir;
          HF_HUB_CACHE = "${cfg.cacheDir}/hub";
          # a DynamicUser has no writable home: caches (Triton, torch inductor,
          # vLLM config and assets) go to the unit's cache directory
          HOME = "%C/${unitOf name}";
          XDG_CACHE_HOME = "%C/${unitOf name}";
          VLLM_CACHE_ROOT = "%C/${unitOf name}";
          # No usage statistics to vLLM's servers
          VLLM_NO_USAGE_STATS = "1";
          DO_NOT_TRACK = "1";
        } // lib.optionalAttrs cfg.offline {
          HF_HUB_OFFLINE = "1";
          TRANSFORMERS_OFFLINE = "1";
        } // lib.optionalAttrs (accel == "cuda") {
          CUDA_VISIBLE_DEVICES = lib.concatMapStringsSep "," toString m.gpus;
        } // lib.optionalAttrs (accel == "rocm") {
          HIP_VISIBLE_DEVICES = lib.concatMapStringsSep "," toString m.gpus;
        };

        serviceConfig = {
          ExecStart = start name m;
          DynamicUser = true;
          LoadCredential = lib.optional cfg.apiKey.enable "api-key:${keyFile}";
          CacheDirectory = unitOf name;
          CacheDirectoryMode = "0700";
          # Weights and model-local caches are read from here
          BindReadOnlyPaths = lib.optional (lib.hasPrefix "/" m.model) m.model
            ++ [ cfg.cacheDir ];
          # model loading takes minutes
          TimeoutStartSec = "30min";
          Restart = "on-failure";
          RestartSec = 10;

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
          # vLLM uses unix and loopback TCP sockets (ZMQ, torch distributed)
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          # PyTorch, Triton and CUDA JIT map executable memory
          MemoryDenyWriteExecute = false;
          # Python bytecode and JIT caches live in the cache directory only
          PrivateDevices = accel == "cpu";
        } // lib.optionalAttrs cfg.offline {
          IPAddressAllow = [ "localhost" ];
          IPAddressDeny = "any";
        } // lib.optionalAttrs (accel != "cpu") {
          DevicePolicy = "closed";
          DeviceAllow = deviceAllow m;
        };
      })
      cfg.models;
  };
}
