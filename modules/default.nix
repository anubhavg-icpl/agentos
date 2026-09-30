# AgentOS system modules — all submodules
{ lib, ... }:
{
  # Services that are designed but not implemented yet: orchestrator,
  # scheduler, MCP gateway, MCP registry service, provisioner and memory
  # manager (nixos/packages/*.nix holds build stubs with no source). Their
  # systemd units are gated behind this switch; enabling it before they
  # exist makes the system fail to build. The model gateway and the agent
  # daemon are implemented (services/) and are not affected by it.
  options.agentos.plannedServices.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Run the planned (not yet implemented) AgentOS services.";
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
