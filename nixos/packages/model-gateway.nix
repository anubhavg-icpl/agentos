# Model Gateway - LLM API proxy with budget/rate limiting
{ rustPlatform }:

rustPlatform.buildRustPackage {
  pname = "nestlo-model-gateway";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "nestlo-model-gateway";
}
