# Shelley: the mobile-friendly web coding agent of exe.dev (Apache-2.0,
# https://github.com/boldsoftware/shelley). Packaged from its pinned static
# release binary (Go, UI embedded). AgentOS Cloud VMs run it on port 9999;
# it finds the VM's LLM integration through the metadata service and the
# reflection integration, as on exe.dev (docs/cloud.md).
{ lib, stdenvNoCC, fetchurl }:

let
  version = "0.1312.970113066";
  assets = {
    x86_64-linux = { arch = "amd64"; sha256 = "0pkd1qn00q0rij0l6xx91wfg4anhnkixbahvw93rfl6sfic8fjpz"; };
    aarch64-linux = { arch = "arm64"; sha256 = "0l6hkq6hmrc5vagx5dijarpfgk1s9ya7x0gn0z56g1cphmlqgmb7"; };
  };
  asset = assets.${stdenvNoCC.hostPlatform.system} or (throw "shelley: unsupported system");
in
stdenvNoCC.mkDerivation {
  pname = "shelley";
  inherit version;
  src = fetchurl {
    url = "https://github.com/boldsoftware/shelley/releases/download/v${version}/shelley_linux_${asset.arch}";
    inherit (asset) sha256;
  };
  dontUnpack = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/shelley
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/shelley version | grep -q '"'
  '';
  meta = {
    description = "Web-based, multi-model coding agent (exe.dev's Shelley)";
    homepage = "https://github.com/boldsoftware/shelley";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames assets;
    mainProgram = "shelley";
  };
}
