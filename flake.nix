# Nestlo - an operating system for coding agents
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
          nestlo = self.packages.${system};
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
      # x86_64 names are plain (nestlo, nestlo-vm, ...), the aarch64 ones
      # carry an -aarch64 suffix (nestlo-aarch64, nestlo-vm-aarch64, ...).
      installerIso = "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";
      hostFlavours = {
        # The default Nestlo host (bare metal, installed by nestlo-install)
        nestlo = [
          ./nixos/hosts/nestlo
          ./nixos/hosts/nestlo/hardware.nix
          ./nixos/hosts/nestlo/disko.nix
        ];
        # The same host as a QEMU/KVM guest (see packages.vm-image)
        nestlo-vm = [ ./nixos/hosts/nestlo ./nixos/hosts/vm.nix ];
        # Live ISO for installation
        nestlo-iso = [ installerIso ./nixos/hosts/iso.nix ];

        # The desktop edition: the same host with a graphical session
        nestlo-desktop = [
          ./nixos/hosts/nestlo
          ./nixos/hosts/nestlo/hardware.nix
          ./nixos/hosts/nestlo/disko.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-host.nix
        ];
        nestlo-desktop-vm = [
          ./nixos/hosts/nestlo
          ./nixos/hosts/vm.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-host.nix
          ./nixos/hosts/desktop-vm.nix
        ];
        # Live ISO with the desktop, to try Nestlo or install from
        nestlo-desktop-iso = [
          installerIso
          ./nixos/hosts/iso.nix
          ./nixos/hosts/desktop.nix
          ./nixos/hosts/desktop-iso.nix
        ];
      };
      hostSuffix = system: lib.optionalString (system == "aarch64-linux") "-aarch64";
      # The desktop VM and live ISO are x86_64 only: every configuration costs
      # evaluation memory in `nix flake check`, and CI runners have 16 GB.
      x86Only = [ "nestlo-desktop-vm" "nestlo-desktop-iso" ];
      hostsFor = system: lib.mapAttrs'
        (name: modules: lib.nameValuePair (name + hostSuffix system) (mkHost system modules))
        (if system == "x86_64-linux" then hostFlavours else removeAttrs hostFlavours x86Only);
      hostFor = system: flavour: self.nixosConfigurations.${flavour + hostSuffix system};
    in
    {
      # ── NixOS configurations ──────────────────────────────────────────
      nixosConfigurations = lib.foldl' (acc: system: acc // hostsFor system) { } systems
        # Temporary: .github/workflows/ci.yml still builds the pre-rename name.
        # Remove once the workflow says nestlo (see CHANGELOG, "Renamed from AgentOS").
        // { agentos = self.nixosConfigurations.nestlo; };

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
          iso-image = (hostFor system "nestlo-iso").config.system.build.isoImage;
          vm-image = (hostFor system "nestlo-vm").config.system.build.image;
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          desktop-iso-image = self.nixosConfigurations.nestlo-desktop-iso.config.system.build.isoImage;
          desktop-vm-image = self.nixosConfigurations.nestlo-desktop-vm.config.system.build.image;
        });

      # ── Checks (nix flake check) ──────────────────────────────────────
      checks = forEachSystem (system:
        let
          pkgs = pkgsFor system;
          nestloModules = [ disko.nixosModules.disko sops-nix.nixosModules.sops ./modules ];
        in
        {
          services = self.packages.${system}.services;
          # Eval-only: runtime agent map, agent packages and the host's
          # systemPackages agree (see tests/agent-inclusion.nix).
          agent-inclusion = import ./tests/agent-inclusion.nix {
            inherit pkgs;
            host = hostFor system "nestlo";
            agentPkgs = self.packages.${system};
          };
          # Eval-only: nestlo.policy assertions fire on an invalid policy
          # and a valid one compiles; rbac defaults (tests/policy-eval.nix).
          policy-eval = import ./tests/policy-eval.nix {
            inherit pkgs;
            host = hostFor system "nestlo";
          };
          # Every skill pack and the combined bundle build, skills have front
          # matter, no name collisions, pack.json is valid (no VM).
          skills-eval = import ./tests/skills-eval.nix {
            inherit pkgs;
            packs = lib.filterAttrs (n: _: lib.hasPrefix "skills-" n) self.packages.${system};
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          # Boots a VM with the Nestlo service stack and drives an agent
          # through spawn -> model gateway -> budget cap -> kill.
          e2e = import ./tests/e2e.nix { inherit pkgs nestloModules; };
          # Loop detection, cost routing, record/replay and the message bus.
          gateway-features = import ./tests/gateway-features.nix { inherit pkgs nestloModules; };
          # Tamper-evident audit log, signed checkpoints, gateway DLP.
          audit = import ./tests/audit.nix { inherit pkgs nestloModules; };
          # Task queue, orchestrator plans and cron-style schedules.
          orchestration = import ./tests/orchestration.nix { inherit pkgs nestloModules; };
          # GitHub webhooks -> tasks -> pushed branch and pull request.
          triggers = import ./tests/triggers.nix { inherit pkgs nestloModules; };
          # Software factory: fake roles take an item to a pull request with evidence.
          factory = import ./tests/factory.nix { inherit pkgs nestloModules; };
          # Nestlo Cloud: VMs over SSH, the private HTTPS proxy, /exec, integrations.
          cloud = import ./tests/cloud.nix { inherit pkgs nestloModules; };
          # Container-isolated agents in their own network namespace.
          container = import ./tests/container.nix { inherit pkgs nestloModules; };
          # Pullrun daemon: operators-only socket, agents in Pullrun containers.
          pullrun = import ./tests/pullrun.nix { inherit pkgs nestloModules; };
          # Skill packs linked into the agent user's CLI skills directories.
          skills = import ./tests/skills.nix { inherit pkgs nestloModules; };
          # Web dashboard, fleet registry and marketplace.
          platform = import ./tests/platform.nix { inherit pkgs nestloModules; };
          # agent-fleet chat and hub: static server on loopback, wasm/COOP/COEP.
          agent-fleet-web = import ./tests/agent-fleet-web.nix { inherit pkgs nestloModules; };
          # OpenClaw chat gateway wired to the model gateway and orchestrator.
          openclaw = import ./tests/openclaw.nix { inherit pkgs nestloModules; };
          # herdr: agent-user server, status bridge and metrics, Nestlo and
          # declared plugins linked.
          herdr = import ./tests/herdr.nix { inherit pkgs nestloModules; };
          # TUIOS: per-user daemons, layouts, bridge (audit, metrics, notifications), SSH and web access.
          tuios = import ./tests/tuios.nix { inherit pkgs nestloModules; };
          # OpenShell gateway (mTLS, podman driver), CLI, declared policies, Nestlo
          # model gateway agent for sandbox inference.
          openshell = import ./tests/openshell.nix { inherit pkgs nestloModules; };
          # agentgateway as the MCP enforcement point: per-agent keys, tool
          # authorization, a cleared environment for stdio servers.
          agentgateway = import ./tests/agentgateway.nix { inherit pkgs nestloModules; };
          # Agent Orca: k3s, chart, ModelProviders through the gateway, UI
          orca = import ./tests/orca.nix { inherit pkgs nestloModules; };
          # promptfoo red-team, MCP/skill admission scan, PR-Agent, through the gateway
          agent-security = import ./tests/agent-security.nix { inherit pkgs nestloModules; };
          # OTel GenAI spans from the gateway to an OTLP sink; Langfuse/OpenLIT stacks
          llm-observability = import ./tests/llm-observability.nix { inherit pkgs nestloModules; };
          # SPIRE identities (X.509/JWT SVIDs), Cedar authorization
          agent-identity = import ./tests/agent-identity.nix { inherit pkgs nestloModules; };
          # OpenBao: init/unseal, KV, JWT login by SPIRE identity, /run/secrets sync
          openbao = import ./tests/openbao.nix { inherit pkgs nestloModules; };
          # LocalAI (container/package) and vLLM backends: keys, units, gateway providers
          local-ai-backends = import ./tests/local-ai-backends.nix { inherit pkgs nestloModules; };
          # Tetragon policies for agents: a decoy secret read raises an alert
          agent-runtime-security = import ./tests/agent-runtime-security.nix { inherit pkgs nestloModules; };
          # A2A server: agent card, auth, message/send creates an orchestrator task
          a2a = import ./tests/a2a.nix { inherit pkgs nestloModules; };
          # Agent Beacon: collector, per-user capture, relay, retention, memory, MCP, skills.
          beacon = import ./tests/beacon.nix { inherit pkgs nestloModules; };
          # Boots the i3 desktop, opens a terminal, screenshots it.
          desktop = import ./tests/desktop.nix { inherit pkgs nestloModules; };
          # Local inference backend registered as a gateway provider.
          local-ai = import ./tests/local-ai.nix { inherit pkgs nestloModules; };
          # n8n native, Flowise as a container, secrets and gateway routing.
          agent-stack = import ./tests/agent-stack.nix { inherit pkgs nestloModules; };
          # Backs up to a local restic repository, destroys the state, restores it.
          backup = import ./tests/backup.nix { inherit pkgs nestloModules; };
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
            meta.description = "Write a CycloneDX SBOM (sbom.cdx.json) of the Nestlo system closure";
            program = lib.getExe (pkgs.writeShellApplication {
              name = "nestlo-sbom";
              runtimeInputs = [ pkgs.sbomnix pkgs.nix ];
              text = ''
                # Usage: nix run .#sbom [-- <installable>]   (OUT=file to rename the output)
                target="''${1:-${self}#nixosConfigurations.nestlo.config.system.build.toplevel}"
                out="''${OUT:-sbom.cdx.json}"
                path=$(nix build --no-link --print-out-paths "$target")
                sbomnix "$path" --cdx "$out"
                echo "wrote $out (CycloneDX) for $path"
              '';
            });
          };
        });

      # ── Dev shell for working on Nestlo itself ───────────────────────
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
        nestlo-runtime = ./modules/runtime;
        nestlo-security = ./modules/security;
        nestlo-observability = ./modules/observability;
        nestlo-storage = ./modules/storage;
        nestlo-networking = ./modules/networking;
        default = ./modules;
      };

      # ── Templates (for agent workspace scaffolds) ─────────────────────
      templates = {
        default = {
          path = ./templates/agent-workspace;
          description = "A minimal Nestlo workspace for a new project";
        };
      };
    };
}
