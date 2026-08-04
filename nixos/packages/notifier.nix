# AgentOS notifier - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ stdenv, rustPlatform, baseTools }:

rustPlatform.buildRustPackage {
  pname = "agentos-notifier";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-notifier";
}
