# AgentOS Package Managers Module
# Every package manager pre-installed so agents can install deps for any project
{ config, pkgs, lib, ... }:

let cfg = config.agentos.package-managers; in
{
  options.agentos.package-managers = {
    enable = lib.mkEnableOption "AgentOS package managers";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      # Python
      pip
      pipx
      poetry
      uv
      conda
      rye
      # Node
      npm
      pnpm
      yarn
      bun
      # Rust
      cargo
      # Go
      go
      # Ruby
      bundler
      gem
      # PHP
      composer
      # Java
      maven
      gradle
      # C/C++
      conan
      vcpkg
      meson
      # Generic
      nix
      flatpak
      appimage-run
    ];
  };
}
