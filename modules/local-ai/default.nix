# Nestlo local inference module
#
# A local model server (Ollama or llama.cpp) and an optional Open WebUI, all
# bound to loopback, registered with the model gateway as the provider
# `local` so agents reach it at /agent/<id>:<token>/local/v1 and every
# request still goes through budgets, rate limits, loop detection and
# recording. See docs/local-ai.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.localAI;
  gpuCfg = config.nestlo.gpu;

  # "auto" follows the GPU driver selection of this machine
  autoAccel =
    if gpuCfg.enable && gpuCfg.vendor == "nvidia" then "cuda"
    else if gpuCfg.enable && gpuCfg.vendor == "amd" then "rocm"
    else if builtins.elem "nvidia" config.services.xserver.videoDrivers then "cuda"
    else if builtins.elem "amdgpu" config.services.xserver.videoDrivers then "rocm"
    else "cpu";
  accel = if cfg.acceleration == "auto" then autoAccel else cfg.acceleration;

  ollama = cfg.backend == "ollama";
  loopback = "127.0.0.1";
  backendUrl = "http://${loopback}:${toString cfg.port}";

  ollamaPackage = {
    cuda = pkgs.ollama-cuda;
    rocm = pkgs.ollama-rocm;
    cpu = pkgs.ollama-cpu;
  }.${accel};
  llamaPackage = pkgs.llama-cpp.override ({
    cuda = { cudaSupport = true; };
    rocm = { rocmSupport = true; };
    cpu = { };
  }.${accel});

  gpuEnv = lib.optionalAttrs (cfg.gpuDevices != null) {
    CUDA_VISIBLE_DEVICES = cfg.gpuDevices;
    HIP_VISIBLE_DEVICES = cfg.gpuDevices;
    ROCR_VISIBLE_DEVICES = cfg.gpuDevices;
  };
in
{
  options.nestlo.localAI = {
    enable = lib.mkEnableOption "local model inference (Ollama or llama.cpp) behind the model gateway";

    backend = lib.mkOption {
      type = lib.types.enum [ "ollama" "llama-cpp" ];
      default = "ollama";
      description = "Inference server. Ollama manages models itself; llama.cpp serves one GGUF file.";
    };

    acceleration = lib.mkOption {
      type = lib.types.enum [ "auto" "cuda" "rocm" "cpu" ];
      default = "auto";
      description = ''
        Compute backend. `auto` follows `nestlo.gpu.vendor` (nvidia gives
        cuda, amd gives rocm) or `services.xserver.videoDrivers`, and falls
        back to cpu. The package is chosen with `mkOverride 900` so it wins
        over the defaults of nestlo.gpu and nestlo.ai-ml.
      '';
    };

    resolvedAcceleration = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = accel;
      description = "The acceleration `auto` resolved to.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = if ollama then 11434 else 8081;
      defaultText = "11434 for ollama, 8081 for llama-cpp (8080 is the model gateway)";
      description = "Loopback port of the inference server.";
    };

    models = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "qwen2.5-coder:7b" ];
      description = ''
        Ollama models to pull after the server starts (`ollama pull`). The
        pull runs in a oneshot unit that logs and succeeds when the registry
        is unreachable, so an offline machine still boots; pull later with
        `systemctl restart nestlo-local-ai-pull`. Ignored by llama-cpp.
      '';
    };

    modelFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/var/lib/models/qwen2.5-coder-7b-q4_k_m.gguf";
      description = "GGUF file served by llama-cpp (required for that backend).";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "-c" "8192" "-ngl" "99" ];
      description = "Extra llama-server flags (llama-cpp backend).";
    };

    gpuDevices = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "0";
      description = ''
        Restrict the server to these GPU indices (CUDA_/HIP_/ROCR_VISIBLE_DEVICES).
        The server is not an agent and takes no lock from `nestlo gpu`, so
        this is how to keep other GPUs free for `nestlo spawn --gpu`.
      '';
    };

    keepAlive = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "30s";
      description = ''
        Ollama OLLAMA_KEEP_ALIVE: how long an idle model stays in GPU memory
        (Ollama's default is 5m). A short value returns VRAM sooner to
        agents that run with --gpu.
      '';
    };

    webui = {
      enable = lib.mkEnableOption "Open WebUI on loopback, pointed at the local backend";
      port = lib.mkOption {
        type = lib.types.port;
        default = 8180;
        description = "Loopback port of Open WebUI.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = cfg.backend != "llama-cpp" || cfg.modelFile != null;
          message = "nestlo.localAI: backend llama-cpp needs nestlo.localAI.modelFile";
        }
        {
          assertion = config.nestlo.networking.enable;
          message = "nestlo.localAI registers a gateway provider; enable nestlo.networking";
        }
      ];

      # An OpenAI-compatible upstream without a key, priced at zero by the
      # gateway so cost routing can prefer it (docs/local-ai.md).
      nestlo.networking.providers.local = {
        baseUrl = backendUrl;
        api = lib.mkDefault "openai-compatible";
        zeroCost = lib.mkDefault true;
        keyFile = null;
      };
    }

    (lib.mkIf ollama {
      services.ollama = {
        enable = true;
        host = loopback;
        port = cfg.port;
        package = lib.mkOverride 900 ollamaPackage;
        environmentVariables = gpuEnv
          // lib.optionalAttrs (cfg.keepAlive != null) { OLLAMA_KEEP_ALIVE = cfg.keepAlive; };
      };

      systemd.services.nestlo-local-ai-pull = lib.mkIf (cfg.models != [ ]) {
        description = "Pull local AI models (tolerates being offline)";
        wantedBy = [ "multi-user.target" ];
        wants = [ "ollama.service" "network-online.target" ];
        after = [ "ollama.service" "network-online.target" ];
        environment.OLLAMA_HOST = "${loopback}:${toString cfg.port}";
        path = [ config.services.ollama.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          DynamicUser = true;
          TimeoutStartSec = "6h";
        };
        script = ''
          for _ in $(seq 60); do ollama list >/dev/null 2>&1 && break; sleep 1; done
          for m in ${lib.escapeShellArgs cfg.models}; do
            ollama pull "$m" || echo "could not pull $m (offline?); retry with: systemctl restart nestlo-local-ai-pull"
          done
          exit 0
        '';
      };
    })

    (lib.mkIf (!ollama) {
      services.llama-cpp = {
        enable = true;
        host = loopback;
        port = cfg.port;
        package = lib.mkOverride 900 llamaPackage;
        model = cfg.modelFile;
        extraFlags = cfg.extraFlags;
      };
      systemd.services.llama-cpp.environment = gpuEnv;
    })

    (lib.mkIf cfg.webui.enable {
      services.open-webui = {
        enable = true;
        host = loopback;
        port = cfg.webui.port;
        environment = {
          ANONYMIZED_TELEMETRY = "False";
          DO_NOT_TRACK = "True";
          SCARF_NO_ANALYTICS = "True";
        } // (if ollama then {
          OLLAMA_BASE_URL = backendUrl;
        } else {
          ENABLE_OLLAMA_API = "False";
          OPENAI_API_BASE_URL = "${backendUrl}/v1";
          OPENAI_API_KEY = "none";
        });
      };
    })
  ]);
}
