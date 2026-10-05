# Nestlo (formerly AgentOS) - an operating system for coding agents
# Top-level flake that ties together host configs, agent packages, and modules
{
  description = "Nestlo - the open-source home for AI coding agents (NixOS)";

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
          # Eval-only: runtime agent map, agent packages and the host's
          # systemPackages agree (see tests/agent-inclusion.nix).
          agent-inclusion = import ./tests/agent-inclusion.nix {
            inherit pkgs;
            host = hostFor system "agentos";
            agentPkgs = self.packages.${system};
          };
          # Eval-only: agentos.policy assertions fire on an invalid policy
          # and a valid one compiles; rbac defaults (tests/policy-eval.nix).
          policy-eval = import ./tests/policy-eval.nix {
            inherit pkgs;
            host = hostFor system "agentos";
          };
          # Every skill pack and the combined bundle build, skills have front
          # matter, no name collisions, pack.json is valid (no VM).
          skills-eval = import ./tests/skills-eval.nix {
            inherit pkgs;
            packs = lib.filterAttrs (n: _: lib.hasPrefix "skills-" n) self.packages.${system};
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Boots a VM with the AgentOS service stack and drives an agent
          # through spawn -> model gateway -> budget cap -> kill.
          e2e = import ./tests/e2e.nix { inherit pkgs agentosModules; };
          # Loop detection, cost routing, record/replay and the message bus.
          gateway-features = import ./tests/gateway-features.nix { inherit pkgs agentosModules; };
          # Tamper-evident audit log, signed checkpoints, gateway DLP.
          audit = import ./tests/audit.nix { inherit pkgs agentosModules; };
          # Task queue, orchestrator plans and cron-style schedules.
          orchestration = import ./tests/orchestration.nix { inherit pkgs agentosModules; };
          # GitHub webhooks -> tasks -> pushed branch and pull request.
          triggers = import ./tests/triggers.nix { inherit pkgs agentosModules; };
          # Software factory: fake roles take an item to a pull request with evidence.
          factory = import ./tests/factory.nix { inherit pkgs agentosModules; };
          # AgentOS Cloud: VMs over SSH, the private HTTPS proxy, /exec, integrations.
          cloud = import ./tests/cloud.nix { inherit pkgs agentosModules; };
          # Container-isolated agents in their own network namespace.
          container = import ./tests/container.nix { inherit pkgs agentosModules; };
          # Pullrun daemon: operators-only socket, agents in Pullrun containers.
          pullrun = import ./tests/pullrun.nix { inherit pkgs agentosModules; };
          # Skill packs linked into the agent user's CLI skills directories.
          skills = import ./tests/skills.nix { inherit pkgs agentosModules; };
          # Web dashboard, fleet registry and marketplace.
          platform = import ./tests/platform.nix { inherit pkgs agentosModules; };
          # agent-fleet chat and hub: static server on loopback, wasm/COOP/COEP.
          agent-fleet-web = import ./tests/agent-fleet-web.nix { inherit pkgs agentosModules; };
          # OpenClaw chat gateway wired to the model gateway and orchestrator.
          openclaw = import ./tests/openclaw.nix { inherit pkgs agentosModules; };
          # herdr: agent-user server, status bridge and metrics, AgentOS and
          # declared plugins linked.
          herdr = import ./tests/herdr.nix { inherit pkgs agentosModules; };
          # Boots the i3 desktop, opens a terminal, screenshots it.
          desktop = import ./tests/desktop.nix { inherit pkgs agentosModules; };
          # Local inference backend registered as a gateway provider.
          local-ai = import ./tests/local-ai.nix { inherit pkgs agentosModules; };
          # n8n native, Flowise as a container, secrets and gateway routing.
          agent-stack = import ./tests/agent-stack.nix { inherit pkgs agentosModules; };
          # Backs up to a local restic repository, destroys the state, restores it.
          backup = import ./tests/backup.nix { inherit pkgs agentosModules; };
          # Eval-only: key-only sshd on the live ISO, no fixed VM password.
          hardening = import ./tests/hardening.nix { inherit pkgs self; };
        });

      # ── Apps ──────────────────────────────────────────────────────────
      # nix run .#sbom [-- <installable>]: a CycloneDX SBOM of the closure
      apps = forEachSystem (system:
        let pkgs = pkgsFor system; in
        lib.optionalAttrs (pkgs ? sbomnix) {
          sbom = {
            type = "app";
            meta.description = "Write a CycloneDX SBOM (sbom.cdx.json) of the AgentOS system closure";
            program = lib.getExe (pkgs.writeShellApplication {
              name = "agentos-sbom";
              runtimeInputs = [ pkgs.sbomnix pkgs.nix ];
              text = ''
                # Usage: nix run .#sbom [-- <installable>]   (OUT=file to rename the output)
                target="''${1:-${self}#nixosConfigurations.agentos.config.system.build.toplevel}"
                out="''${OUT:-sbom.cdx.json}"
                path=$(nix build --no-link --print-out-paths "$target")
                sbomnix "$path" --cdx "$out"
                echo "wrote $out (CycloneDX) for $path"
              '';
            });
          };
        });

      # ── Dev shell for working on AgentOS itself ───────────────────────
      devShells = forEachSystem (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixpkgs-fmt
              nil
              (python3.withPackages (ps: [ ps.pytest ps.redis ps.fakeredis ps.cryptography ]))
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
