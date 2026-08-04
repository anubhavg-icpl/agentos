# AgentOS system modules - imports all submodules
{ ... }:
{
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

    # Automation
    ./scheduler
    ./notifications

    # Pre-installed toolchains
    ./language-toolchains
    ./databases
    ./dev-tools
    ./security-tools
    ./browser-tools

    # VIBE integration (853 modes, 5340 skills)
    ./vibe-integration
  ];
}
