# AgentOS memory manager - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ stdenv, rustPlatform, baseTools }:

rustPlatform.buildRustPackage {
  pname = "agentos-memory-manager";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-memory-manager";
}
