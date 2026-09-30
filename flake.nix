# AgentOS - An operating system for coding agents
# Top-level flake that ties together host configs, agent packages, and modules
{
  description = "AgentOS - a minimal NixOS for coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Agent tooling sources
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-generators, disko, sops-nix, ... }@inputs:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forEachSystem = f: lib.genAttrs systems (sys: f sys);

      # Overlay that adds unstable packages and our agent tools
      agentOverlay = final: prev: {
        unstable = import nixpkgs-unstable {
          system = prev.system;
          config.allowUnfree = true;
        };
        agentos = self.packages.${prev.system};
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
    in
    {
      # ── NixOS configurations ──────────────────────────────────────────
      nixosConfigurations = {

        # The default AgentOS host (bare metal or VM)
        agentos = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = sharedModules ++ [
            ./nixos/hosts/agentos
            ./nixos/hosts/agentos/hardware.nix
            ./nixos/hosts/agentos/disko.nix
          ];
        };

        # Live ISO for installation
        agentos-iso = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs; };
          modules = sharedModules ++ [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
            ./nixos/hosts/iso.nix
          ];
        };
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
          # Build the ISO image
          iso-image = self.nixosConfigurations.agentos-iso.config.system.build.isoImage;

          # Build a QCOW2 VM image
          vm-image = nixos-generators.nixosGenerate {
            inherit system;
            specialArgs = { inherit inputs; };
            modules = sharedModules ++ [
              ./nixos/hosts/agentos
              ({ lib, ... }: {
                # The qcow image has a single ext4 root and boots with GRUB
                boot.loader.systemd-boot.enable = lib.mkForce false;
                boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
                agentos.storage.filesystem = lib.mkForce "ext4";
              })
            ];
            format = "qcow";
          };
        });

      # ── Dev shell for working on AgentOS itself ───────────────────────
      devShells = forEachSystem (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixpkgs-fmt
              nil
              nixos-generators.packages.${system}.nixos-generate
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
