# AgentOS mcp registry - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "agentos-mcp-registry";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-mcp-registry";
}
