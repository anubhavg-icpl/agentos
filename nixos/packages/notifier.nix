# Nestlo notifier - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nestlo-notifier";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "nestlo-notifier";
}
