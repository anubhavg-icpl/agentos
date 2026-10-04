# Pullrun: one OCI image as a container or a Firecracker microVM.
#
# Builds the Rust runtime daemon (pullrun-runtime) and the Go CLI (pullrun,
# which also serves MCP via `pullrun mcp`). The prebuilt binaries committed
# under cli/pullrun/ upstream are not used.
{ lib
, rustPlatform
, buildGoModule
, fetchFromGitHub
, protobuf
, pkg-config
, symlinkJoin
}:

let
  version = "0.7.9";

  src = fetchFromGitHub {
    owner = "pullrun";
    repo = "pullrun";
    rev = "1800153e5f864a3852302ce0f035521ae0940c4c";
    hash = "sha256-0maFSchfeupXAwuoYLAl7y7q8RBGPPt5ARzicIZs7nk=";
  };

  meta = {
    description = "OCI runtime that runs one image as a container or Firecracker microVM";
    homepage = "https://github.com/pullrun/pullrun";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };

  runtime = rustPlatform.buildRustPackage {
    pname = "pullrun-runtime";
    inherit version src;
    cargoLock.lockFile = "${src}/Cargo.lock";
    cargoBuildFlags = [ "-p" "pullrun-runtime" ];
    nativeBuildInputs = [ protobuf pkg-config ];
    # The test suite needs /dev/kvm, runc and network access.
    doCheck = false;
    meta = meta // { mainProgram = "pullrun-runtime"; };
  };

  cli = buildGoModule {
    pname = "pullrun-cli";
    inherit version src;
    # go.mod has `replace pullrun/protoapi => ../../proto-go`, so the whole
    # source tree is the build root and only the module dir is entered.
    modRoot = "cli/pullrun";
    vendorHash = "sha256-Xx8mE5Q3mgYEQmi1sUXlFmnFy+8OlBaZS44/+PVLySM=";
    subPackages = [ "." ];
    ldflags = [ "-s" "-w" ];
    postInstall = ''
      mv $out/bin/cli $out/bin/pullrun
    '';
    doCheck = false;
    meta = meta // { mainProgram = "pullrun"; };
  };
in
symlinkJoin {
  name = "pullrun-${version}";
  paths = [ runtime cli ];
  passthru = { inherit runtime cli; };
  meta = meta // { mainProgram = "pullrun"; };
}
