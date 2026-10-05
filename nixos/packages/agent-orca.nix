# Agent Orca: a Kubernetes operator for AI agents (heddles/agent-orca,
# Apache-2.0). Agents, model providers, tools, MCP servers, workflows,
# guardrails and knowledge bases are CRDs; runs are pods with a
# model-router sidecar.
#
# Builds every Go command from source, the React UI that ui-proxy embeds,
# and OCI images of the in-cluster components (loaded into k3s by
# nestlo.orca, so the cluster never pulls them from ghcr.io).
{ lib
, buildGoModule
, buildNpmPackage
, fetchFromGitHub
, dockerTools
, cacert
, symlinkJoin
}:

let
  version = "0.1.0-unstable-2026-10-04";

  src = fetchFromGitHub {
    owner = "heddles";
    repo = "agent-orca";
    rev = "f7aa8395ed7fdca198d22d3b7c339f95432cc804";
    hash = "sha256-1ShzBYShU7MfrdqDLyNYvPHFaDiT/39XvM04fJUPiQ4=";
  };

  meta = {
    description = "Kubernetes-native platform for deploying, managing and running AI agents";
    homepage = "https://github.com/heddles/agent-orca";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };

  ui = buildNpmPackage {
    pname = "agent-orca-ui";
    inherit version src meta;
    sourceRoot = "${src.name}/ui";
    npmDepsHash = "sha256-KkpglgrpAkRw54q90jA4fkQxyRuGtIYZ+1gPo5yuv2I=";
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };

  bin = buildGoModule {
    pname = "agent-orca";
    inherit version src;
    vendorHash = "sha256-9BPX9i9fn8I5XLVeWdidC4DFq/mBzQLXFiP9KJwa2N0=";
    subPackages = [ "cmd" "cmd/aoctl" "cmd/model-router" "cmd/mcp-ingester" "cmd/ui-proxy" ];
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" ];
    preBuild = ''
      rm -rf cmd/ui-proxy/dist
      cp -r ${ui} cmd/ui-proxy/dist
      chmod -R u+w cmd/ui-proxy/dist
    '';
    postInstall = ''
      mv $out/bin/cmd $out/bin/manager
    '';
    # The suites need envtest (a kube-apiserver and etcd) and network access.
    doCheck = false;
    meta = meta // { mainProgram = "aoctl"; };
  };

  # Distroless-like images: the binary, CA certificates, a non-root user.
  image = name: entry: user: dockerTools.buildLayeredImage {
    name = "nestlo.local/agent-orca/${name}";
    tag = version;
    contents = [ cacert ];
    fakeRootCommands = ''
      mkdir -p tmp && chmod 1777 tmp
    '';
    config = {
      Entrypoint = [ "${bin}/bin/${entry}" ];
      User = user;
      Env = [ "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt" ];
    };
  };
in
symlinkJoin {
  name = "agent-orca-${version}";
  paths = [ bin ];
  passthru = {
    inherit src ui bin version;
    chart = "${src}/charts/agent-orca";
    images = {
      operator = image "operator" "manager" "65532:65532";
      model-router = image "model-router" "model-router" "65532:65532";
      mcp-ingester = image "mcp-ingester" "mcp-ingester" "65532:65532";
      ui-proxy = image "ui-proxy" "ui-proxy" "65534:65534";
    };
  };
  meta = meta // { mainProgram = "aoctl"; };
}
