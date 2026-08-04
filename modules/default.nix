# AgentOS system modules - imports all submodules
{ ... }:
{
  imports = [
    ./runtime
    ./security
    ./observability
    ./storage
    ./networking
    ./context
    ./orchestration
    ./mcp-registry
    ./budget-controller
    ./git-automation
    ./provisioning
    ./notifications
    ./circuit-breaker
    ./secrets-manager
    ./scheduler
  ];
}
