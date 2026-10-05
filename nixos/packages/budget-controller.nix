# Nestlo budget controller - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nestlo-budget-controller";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "nestlo-budget-controller";
}
