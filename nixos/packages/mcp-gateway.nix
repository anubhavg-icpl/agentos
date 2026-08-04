# MCP Gateway - routes MCP tool calls between agents and tool providers
# Implements the Model Context Protocol server side.
{ stdenv, rustPlatform, baseTools }:

rustPlatform.buildRustPackage {
  pname = "agentos-mcp-gateway";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-mcp-gateway";
}
