# Nestlo AI/ML Tools Module
# Local model inference and ML tooling
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.nestlo.ai-ml;
in
{
  options.nestlo.ai-ml = {
    enable = lib.mkEnableOption "Nestlo AI/ML tools";
    enableOllama = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Ollama for local LLM inference";
    };
    ollamaModels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "llama3.2" "qwen2.5-coder" ];
      description = ''
        Models to pull when Ollama starts. Empty by default: models are
        several GB each and are downloaded from Ollama's registry/CDN, which
        the default egress allowlist does not include. Pull on demand with
        `ollama pull <model>` after allowing those hosts.
      '';
    };
    enableLlamaCpp = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable llama.cpp";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ollama = lib.mkIf cfg.enableOllama {
      enable = true;
      loadModels = cfg.ollamaModels;
    };

    environment.systemPackages = avail (with pkgs; [
      # A Python with the ML stack importable (`python3 -c "import torch"`)
      (lib.lowPrio (python3.withPackages (ps: with ps; [
        torch
        transformers
        tokenizers
        accelerate
        datasets
        jupyter
        jupyterlab
      ])))
      whisper-cpp
      cmake  # for building models from source
    ] ++ lib.optional cfg.enableLlamaCpp llama-cpp);
  };
}
