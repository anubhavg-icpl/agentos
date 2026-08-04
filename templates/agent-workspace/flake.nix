# Agent workspace template
# Scaffold a new project with agent tools available.
# Usage: nix flake init -t github:yourorg/agentos
{
  description = "AgentOS workspace - a project scaffolded for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
      in
      {
        # Development shell with all agent tools
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Languages (add what your project needs)
            python311
            nodejs_22
            go
            rustc
            cargo

            # Tools every agent needs
            git
            ripgrep
            fd
            jq
            gh

            # Install specific agents as needed:
            # nix profile install github:yourorg/agentos#claude-code
            # nix profile install github:yourorg/agentos#aider
          ];

          shellHook = ''
            echo "AgentOS workspace active"
            echo "Git initialized: $(git rev-parse --is-inside-work-tree 2>/dev/null || echo 'no')"
          '';
        };
      });
}
