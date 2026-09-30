# AgentOS system modules — all submodules
{ lib, ... }:
{
  # The Rust service daemons (agent daemon, MCP gateway, model gateway,
  # budget controller, circuit breaker, orchestrator, scheduler, notifier,
  # provisioner, memory manager, MCP registry) have no source code yet;
  # nixos/packages/*.nix only holds build stubs. Their systemd units are
  # therefore gated behind this switch. Enabling it before the daemons
  # exist makes the system fail to build.
  options.agentos.daemons.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Run the AgentOS service daemons (not implemented yet).";
  };

  imports = [
    # Core infrastructure
    ./runtime
    ./security
    ./observability
    ./storage
    ./networking

    # Agent intelligence
    ./context
    ./orchestration

    # Tool ecosystem
    ./mcp-registry
    ./mcp-servers

    # Safety & control
    ./budget-controller
    ./circuit-breaker
    ./secrets-manager

    # Developer experience
    ./git-automation
    ./provisioning
    ./editors

    # Automation
    ./scheduler
    ./notifications

    # Pre-installed toolchains
    ./language-toolchains
    ./databases
    ./dev-tools
    ./security-tools
    ./browser-tools
    ./networking-tools
    ./cloud-tools
    ./package-managers

    # AI/ML
    ./ai-ml

    # VIBE integration (853 modes, 5340 skills)
    ./vibe-integration
  ];
}
