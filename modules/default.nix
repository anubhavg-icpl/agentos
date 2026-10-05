# Nestlo system modules — all submodules
{ lib, ... }:
{
  # The planned services (MCP gateway, MCP registry service, provisioner,
  # memory manager) were stubs with no source and are removed; they come
  # back when implemented (docs/ROADMAP.md).
  imports = [
    (lib.mkRemovedOptionModule [ "nestlo" "plannedServices" "enable" ]
      "The planned (unimplemented) services were removed; see docs/ROADMAP.md.")

    # Core infrastructure
    ./runtime
    ./security
    ./audit
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
    ./factory
    ./policy
    ./openclaw

    # Tool ecosystem
    ./mcp-registry
    ./skills
    ./mcp-servers
    ./pullrun
    ./orca
    ./agent-security
    ./llm-observability
    ./agent-identity
    ./openbao
    ./openshell

    # Safety & control
    ./budget-controller
    ./circuit-breaker
    ./secrets-manager
    ./backup
    ./upgrade

    # Developer experience
    ./git-automation
    ./provenance
    ./provisioning
    ./editors
    ./desktop
    ./herdr
    ./cloud

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
