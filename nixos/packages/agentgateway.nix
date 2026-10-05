# agentgateway: Linux Foundation agent-aware proxy (Apache-2.0,
# https://github.com/agentgateway/agentgateway) for MCP, A2A and LLM traffic.
#
# Not in nixpkgs (checked pkgs.agentgateway and pkgs.unstable.agentgateway),
# so it is built from the v1.6.0 tag: the `agentgateway` binary of the
# `agentgateway-app` crate with its default features (jemalloc, mimalloc,
# aws-lc crypto).
#
# The embedded web UI (the `ui` cargo feature) needs a pnpm build of ./ui that
# is not part of the Rust build, so it is left out; the config file and the
# admin API (config.adminAddr) are the interface. Protobufs are compiled with
# protox, so no protoc is needed.
#
# `src.hash` and `cargoHash` are verified (the vendored crates, including the
# git dependencies patched in by the workspace, were fetched and hashed).
{ lib
, runtimeShell
, rustPlatform
, fetchFromGitHub
, pkg-config
, cmake
, perl
, clang
, openssl
}:

let
  version = "1.6.0";
in
rustPlatform.buildRustPackage {
  pname = "agentgateway";
  inherit version;

  src = fetchFromGitHub {
    owner = "agentgateway";
    repo = "agentgateway";
    rev = "v${version}"; # ea5608642b9d5c94c5baf5fd9f2f9849b808e963
    hash = "sha256-rxRDONkTVFbav+cVO+aYtIzjcFu9JfnD/DTwumXgEYA=";
  };

  # The workspace patches schemars, http-serde, wiremock, async-openai and
  # yaml-serde-edit from git; fetchCargoVendor handles those.
  cargoHash = "sha256-PCE/wyslj4UPHocBKNp24QaqeKIGXRig9KZovBqdcHo=";

  # Only the proxy binary; the workspace also has xtask and test helpers
  cargoBuildFlags = [ "-p" "agentgateway-app" ];

  nativeBuildInputs = [ pkg-config cmake perl clang ];
  buildInputs = [ openssl ];

  # The test suite binds sockets and spawns MCP servers via npx/uvx
  doCheck = false;

  # Reported by `agentgateway --version` (the workspace version is 0.0.0)
  env.VERSION = version;

  # crates/core/build.rs takes the build version and git revision from
  # tools/report_build_info.sh, which needs git and the checkout; without
  # them the env!() lookups in crates/core/src/version.rs fail to compile
  postPatch = ''
    cat > tools/report_build_info.sh <<EOF
    #!${runtimeShell}
    echo "agentgateway.dev.buildVersion=${version}"
    echo "agentgateway.dev.buildGitRevision=ea5608642b9d5c94c5baf5fd9f2f9849b808e963"
    echo "agentgateway.dev.buildStatus=Clean"
    echo "agentgateway.dev.buildTag=v${version}"
    EOF
    chmod +x tools/report_build_info.sh
  '';

  meta = {
    description = "Agent-aware proxy and gateway for MCP, A2A and LLM traffic";
    homepage = "https://github.com/agentgateway/agentgateway";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "agentgateway";
  };
}
