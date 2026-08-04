# AgentOS provisioner - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ stdenv, rustPlatform, baseTools }:

rustPlatform.buildRustPackage {
  pname = "agentos-provisioner";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-provisioner";
}
