# Nestlo circuit breaker - internal service binary
# (Placeholder: this will be a Rust binary in production)
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nestlo-circuit-breaker";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "nestlo-circuit-breaker";
}
