# AgentOS system modules — all submodules
{ lib, ... }:
{
  # The planned services (MCP gateway, MCP registry service, provisioner,
  # memory manager) were stubs with no source and are removed; they come
  # back when implemented (docs/ROADMAP.md).
  imports = [
    (lib.mkRemovedOptionModule [ "agentos" "plannedServices" "enable" ]
      "The planned (unimplemented) services were removed; see docs/ROADMAP.md.")

    # Core infrastructure
    ./runtime
    ./security
    ./observability
    ./dashboard
    ./agent-fleet-web
    ./fleet
    ./marketplace
    ./storage
    ./networking

    # Agent intelligence
    ./context
    ./orchestration
    ./openclaw

    # Tool ecosystem
    ./mcp-registry
    ./mcp-servers
    ./pullrun

    # Safety & control
    ./budget-controller
    ./circuit-breaker
    ./secrets-manager

    # Developer experience
    ./git-automation
    ./provisioning
    ./editors
    ./desktop

    # Automation
    ./scheduler
    ./triggers
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
    ./gpu
    ./local-ai
    ./agent-stack

    # VIBE integration (853 modes, 5340 skills)
    ./vibe-integration
  ];
}
