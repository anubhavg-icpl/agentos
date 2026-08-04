# Model Gateway - LLM API proxy with budget/rate limiting
{ stdenv, rustPlatform, baseTools }:

rustPlatform.buildRustPackage {
  pname = "agentos-model-gateway";
  version = "0.1.0";
  src = ./.;
  cargoHash = "";
  meta.mainProgram = "agentos-model-gateway";
}
