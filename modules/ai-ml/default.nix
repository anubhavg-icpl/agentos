# AgentOS AI/ML Tools Module
# Local model inference and ML tooling
{ config, pkgs, lib, ... }:

let cfg = config.agentos.ai-ml; in
{
  options.agentos.ai-ml = {
    enable = lib.mkEnableOption "AgentOS AI/ML tools";
    enableOllama = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Ollama for local LLM inference";
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
      loadModels = [ "llama3.2" "qwen2.5-coder" ];
    };

    environment.systemPackages = with pkgs; [
      llama-cpp
      python311Packages.torch
      python311Packages.transformers
      python311Packages.tokenizers
      python311Packages.accelerate
      python311Packages.datasets
      python311Packages.jupyter
      python311Packages.jupyterlab
      whisper-cpp
      stable-diffusion-cpp
      cmake  # for building models from source
    ];
  };
}
