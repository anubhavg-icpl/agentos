# AgentOS - An operating system for coding agents
# Top-level flake that ties together host configs, agent packages, and modules
{
  description = "AgentOS - a minimal NixOS for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Declarative disk partitioning
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, sops-nix, ... }@inputs:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = f: lib.genAttrs systems (sys: f sys);

      # Overlay that adds unstable packages and our agent tools
      agentOverlay = final: prev:
        let system = prev.stdenv.hostPlatform.system; in
        {
          unstable = import nixpkgs-unstable {
            inherit system;
            config.allowUnfree = true;
          };
          agentos = self.packages.${system};
        };

      pkgsFor = system:
        import nixpkgs {
          inherit system;
          overlays = [ agentOverlay ];
          config.allowUnfree = true;
        };

      # Shared module applied to every host
      sharedModules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./modules
        {
          nixpkgs.overlays = [ agentOverlay ];
          nixpkgs.config.allowUnfree = true;
        }
      ];

      mkHost = modules: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = sharedModules ++ modules;
      };
    in
    {
      # ── NixOS configurations ──────────────────────────────────────────
      nixosConfigurations = {
        # The default AgentOS host (bare metal, installed by agentos-install)
        agentos = mkHost [
          ./nixos/hosts/agentos
          ./nixos/hosts/agentos/hardware.nix
          ./nixos/hosts/agentos/disko.nix
        ];

        # The same host as a QEMU/KVM guest (see packages.vm-image)
        agentos-vm = mkHost [
          ./nixos/hosts/agentos
          ./nixos/hosts/vm.nix
        ];

        # Live ISO for installation
        agentos-iso = mkHost [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          ./nixos/hosts/iso.nix
        ];
      };

      # ── Packages (each coding agent as an installable package) ─────────
      packages = forEachSystem (system:
        let pkgs = pkgsFor system; in
        (import ./agents/default.nix { inherit pkgs lib; })
        // {
          default = self.packages.${system}.cli;
        }
        # The OS images target x86_64 (several pre-installed toolchains are
        # x86_64-only); agent packages are available on both systems.
        // lib.optionalAttrs (system == "x86_64-linux") {
          iso-image = self.nixosConfigurations.agentos-iso.config.system.build.isoImage;
          vm-image = self.nixosConfigurations.agentos-vm.config.system.build.image;
        });

      # ── Checks (nix flake check) ──────────────────────────────────────
      checks = forEachSystem (system:
        let pkgs = pkgsFor system; in
        {
          services = self.packages.${system}.services;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Boots a VM with the AgentOS service stack and drives an agent
          # through spawn -> model gateway -> budget cap -> kill.
          e2e = import ./tests/e2e.nix {
            inherit pkgs;
            agentosModules = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules ];
          };
        });

      # ── Dev shell for working on AgentOS itself ───────────────────────
      devShells = forEachSystem (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixpkgs-fmt
              nil
              (python3.withPackages (ps: [ ps.pytest ps.redis ps.fakeredis ]))
            ];
          };
        });

      # ── Overlays (re-usable by others) ────────────────────────────────
      overlays.default = agentOverlay;

      # ── NixOS modules (re-usable by others) ───────────────────────────
      nixosModules = {
        agentos-runtime = ./modules/runtime;
        agentos-security = ./modules/security;
        agentos-observability = ./modules/observability;
        agentos-storage = ./modules/storage;
        agentos-networking = ./modules/networking;
        default = ./modules;
      };

      # ── Templates (for agent workspace scaffolds) ─────────────────────
      templates = {
        default = {
          path = ./templates/agent-workspace;
          description = "A minimal AgentOS workspace for a new project";
        };
      };
    };
}
