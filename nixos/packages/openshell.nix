# NVIDIA OpenShell: sandboxed runtimes for autonomous AI agents.
#
# Builds from source (Rust workspace, edition 2024):
#   openshell             CLI (gateway registration, sandboxes, providers, TUI)
#   openshell-gateway     control-plane server with the docker, podman and
#                         kubernetes compute drivers compiled in
#   openshell-supervisor  trusted per-sandbox supervisor (policy, credentials)
#   openshell-sandbox     in-sandbox process owner (Landlock, seccomp)
#   openshell-prover      standalone policy boundary checker (links libz3)
#
# The microVM compute driver (libkrun, needs prebuilt runtime blobs and KVM)
# is only a stub inside the gateway (its build script embeds placeholders). Tests need network, container
# runtimes and kernel features, so they are skipped.
{ lib
, rustPlatform
, fetchFromGitHub
, pkg-config
, cmake
, perl
, clang

, openssl
, z3
}:

let
  rev = "e7fdd6beef98f7f92d86271a169fdd4d3be44cf3";
  # The workspace version is the 0.0.0 placeholder; releases patch it at build
  # time. Report the pinned commit so `openshell --version` is not "0.0.0".
  version = "0.0.0-unstable-2026-10-05";

  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "OpenShell";
    inherit rev;
    hash = "sha256-GY3f0C7kfaeKXPVuzVcCyZ+BcfmhuBLj1caPOnv0wK8=";
  };
in
rustPlatform.buildRustPackage {
  pname = "openshell";
  inherit version src;

  cargoHash = "sha256-KZ4VfCRTuN1qZIZJ+Lp001wLPKIBufFZmWgMAsNzoJ8=";

  # Workspace crates -> binaries: openshell-cli -> openshell,
  # openshell-gateway -> openshell-gateway, openshell-supervisor,
  # openshell-sandbox, openshell-prover-cli -> openshell-prover.
  cargoBuildFlags = [
    "-p" "openshell-cli"
    "-p" "openshell-gateway"
    "-p" "openshell-supervisor"
    "-p" "openshell-sandbox"
    "-p" "openshell-prover-cli"
  ];

  nativeBuildInputs = [ pkg-config cmake perl clang ];
  buildInputs = [ openssl z3 ];

  # z3-sys bindgen
  LIBCLANG_PATH = "${lib.getLib clang.cc}/lib";
  Z3_SYS_Z3_HEADER = "${lib.getDev z3}/include/z3.h";

  doCheck = false;

  passthru = {
    inherit src rev;
    # Paths a NixOS module can use without reaching into the source tree.
    providers = "${src}/providers";
    skills = "${src}/skills";
    helmChart = "${src}/deploy/helm/openshell";
    gatewayDefaults = "${src}/deploy/rpm/gateway.toml.default";
    proto = "${src}/proto";
  };

  meta = {
    description = "Policy-enforced sandboxed runtimes for autonomous AI agents";
    homepage = "https://github.com/NVIDIA/OpenShell";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "openshell";
  };
}
