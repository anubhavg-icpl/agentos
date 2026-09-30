# AgentOS daemon - manages agent lifecycle
# Responsibilities:
#   - Spawn/supervise agent containers
#   - Track running agents (PID, workspace, budget, status)
#   - Enforce maxAgents limit
#   - Route tool calls via the MCP gateway
#   - Report metrics on :9950/metrics (Prometheus)
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "agentos-daemon";
  version = "0.1.0";
  src = ./.;

  cargoHash = ""; # placeholder

  meta = {
    description = "AgentOS agent lifecycle daemon";
    mainProgram = "agentos-daemon";
  };
}
