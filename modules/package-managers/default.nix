# AgentOS Package Managers Module
# Every package manager pre-installed so agents can install deps for any project
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.agentos.package-managers;
in
{
  options.agentos.package-managers = {
    enable = lib.mkEnableOption "AgentOS package managers";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = avail (with pkgs; [
      # Python
      python3Packages.pip
      pipx
      poetry
      uv
      conda
      rye
      # Node
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
      phpPackages.composer
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
    ]);
  };
}
