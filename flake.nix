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

      # One nixpkgs instance per system, shared by the packages, the checks
      # and every NixOS configuration: evaluating each configuration with its
      # own nixpkgs makes `nix flake check` need several GB per host.
      pkgsBySystem = forEachSystem (system:
        import nixpkgs {
          inherit system;
          overlays = [ agentOverlay ];
          config.allowUnfree = true;
        });
      pkgsFor = system: pkgsBySystem.${system};

      # Shared module applied to every host
      sharedModules = [
        disko.nixosModules.disko
        sops-nix.nixosModules.sops
        ./modules
      ];

      mkHost = system: modules: nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        # pkgs already carries the overlay and allowUnfree
        modules = sharedModules ++ modules ++ [{ nixpkgs.pkgs = pkgsFor system; }];
      };

      # The host flavours. Every flavour is built for each system: the
      # x86_64 names are plain (agentos, agentos-vm, ...), the aarch64 ones
      # carry an -aarch64 suffix (agentos-aarch64, agentos-vm-aarch64, ...).
      installerIso = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";
      hostFlavours = {
        # The default AgentOS host (bare metal, installed by agentos-install)
        agentos = [
          ./nixos/hosts/agentos
          ./nixos/hosts/agentos/hardware.nix
          ./nixos/hosts/agentos/disko.nix
        ];
        # The same host as a QEMU/KVM guest (see packages.vm-image)
        agentos-vm = [ ./nixos/hosts/agentos ./nixos/hosts/vm.nix ];
        # Live ISO for installation
        agentos-iso = [ installerIso ./nixos/hosts/iso.nix ];

        # The desktop edition: the same host with a graphical session
        agentos-desktop = [
          ./nixos/hosts/agentos
          ./nixos/hosts/agentos/hardware.nix
          ./nixos/hosts/agentos/disko.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-host.nix
        ];
        agentos-desktop-vm = [
          ./nixos/hosts/agentos
          ./nixos/hosts/vm.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-host.nix
          ./nixos/hosts/desktop-vm.nix
        ];
        # Live ISO with the desktop, to try AgentOS or install from
        agentos-desktop-iso = [
          installerIso
          ./nixos/hosts/iso.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-iso.nix
        ];
      };
      hostSuffix = system: lib.optionalString (system == "aarch64-linux") "-aarch64";
      # The desktop VM and live ISO are x86_64 only: every configuration costs
      # evaluation memory in `nix flake check`, and CI runners have 16 GB.
      x86Only = [ "agentos-desktop-vm" "agentos-desktop-iso" ];
      hostsFor = system: lib.mapAttrs'
        (name: modules: lib.nameValuePair (name + hostSuffix system) (mkHost system modules))
        (if system == "x86_64-linux" then hostFlavours else removeAttrs hostFlavours x86Only);
      hostFor = system: flavour: self.nixosConfigurations.${flavour + hostSuffix system};
    in
    {
      # ── NixOS configurations ──────────────────────────────────────────
      nixosConfigurations = lib.foldl' (acc: system: acc // hostsFor system) { } systems;

      # ── Packages (each coding agent as an installable package) ─────────
      packages = forEachSystem (system:
        let pkgs = pkgsFor system; in
        (import ./agents/default.nix { inherit pkgs lib; })
        // {
          default = self.packages.${system}.cli;
        }
        # Installable OS images. The desktop-* images are separate outputs
        # (large): the minimal images stay headless.
        // {
          iso-image = (hostFor system "agentos-iso").config.system.build.isoImage;
          vm-image = (hostFor system "agentos-vm").config.system.build.image;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          desktop-iso-image = self.nixosConfigurations.agentos-desktop-iso.config.system.build.isoImage;
          desktop-vm-image = self.nixosConfigurations.agentos-desktop-vm.config.system.build.image;
        });

      # ── Checks (nix flake check) ──────────────────────────────────────
      checks = forEachSystem (system:
        let
          pkgs = pkgsFor system;
          agentosModules = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules ];
        in
        {
          services = self.packages.${system}.services;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Boots a VM with the AgentOS service stack and drives an agent
          # through spawn -> model gateway -> budget cap -> kill.
          e2e = import ./tests/e2e.nix { inherit pkgs agentosModules; };
          # Loop detection, cost routing, record/replay and the message bus.
          gateway-features = import ./tests/gateway-features.nix { inherit pkgs agentosModules; };
          # Task queue, orchestrator plans and cron-style schedules.
          orchestration = import ./tests/orchestration.nix { inherit pkgs agentosModules; };
          # Container-isolated agents in their own network namespace.
          container = import ./tests/container.nix { inherit pkgs agentosModules; };
          # Web dashboard, fleet registry and marketplace.
          platform = import ./tests/platform.nix { inherit pkgs agentosModules; };
          # Boots the i3 desktop, opens a terminal, screenshots it.
          desktop = import ./tests/desktop.nix { inherit pkgs agentosModules; };
          # Local inference backend registered as a gateway provider.
          local-ai = import ./tests/local-ai.nix { inherit pkgs agentosModules; };
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
