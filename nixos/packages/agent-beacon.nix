# Agent Beacon (Asymptote-Labs/agent-beacon, MIT): cross-harness session
# capture for AI coding agents. Hooks, plugins and OTLP feed a local JSONL
# runtime log; the CLI replays and searches it, distils reviewed project
# memory and serves it to agents over MCP.
#
# Builds, from source and without network access beyond the pinned fetches:
#
#   beacon          the CLI (cli/beacon): endpoint, traces, memory, mcp serve,
#                   scan, lenses, ... The hook adapter is embedded in it the
#                   way upstream's release does (cli/beacon/Makefile, the
#                   goreleaser pre-hook): beacon-hooks is built first and
#                   copied to internal/embedded/hooks.bin, from where the
#                   CLI writes it out when it installs hooks.
#   beacon-hooks    the hook adapter (cli/beacon-hooks) that harness hooks and
#                   plugins call; also installed on its own
#   beacon-otelcol  the OpenTelemetry collector (collector-builder). Upstream
#                   generates it with the OpenTelemetry Collector Builder from
#                   collector-builder/builder.yaml; the generated main package
#                   is reproduced in ./agent-beacon/otelcol (go.mod and go.sum
#                   are the output of `go mod tidy`) and reduced to what a
#                   local endpoint uses: OTLP receiver, batch and
#                   memory_limiter processors, health_check and the beaconjson
#                   exporter. The Splunk HEC and Falcon LogScale exporters
#                   and the http(s) config providers are not compiled in, so
#                   this collector has no way to send events off the machine.
#
# Not built: beacon-sandbox (upstream's own verification harness; it launches
# real Claude Code sessions in cloud sandboxes and costs money), the browser
# extension and the JS SDK. The plugins for OpenCode, Cline, pi, Oh My Pi and
# OpenClaw are committed pre-built under cli/beacon/internal/endpoint/hooks/
# assets and compiled into the CLI.
{ lib
, buildGoModule
, fetchFromGitHub
, symlinkJoin
}:

let
  version = "1.3.22-unstable-2026-10-05";
  rev = "82a6fba58e5d51f55fadc12ccdde8ce7b286eaa4";

  src = fetchFromGitHub {
    owner = "Asymptote-Labs";
    repo = "agent-beacon";
    inherit rev;
    hash = "sha256-PtEObrdWZ9qCH04X8xEKp8hIIKKR9azODSW37tZUUMs=";
  };

  meta = {
    description = "Cross-harness session capture, replay and reviewed memory for AI coding agents";
    homepage = "https://github.com/Asymptote-Labs/agent-beacon";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };

  mod = "github.com/asymptote-labs/agent-beacon";
  shortRev = builtins.substring 0 7 rev;

  hooks = buildGoModule {
    pname = "beacon-hooks";
    inherit version src;
    modRoot = "cli/beacon-hooks";
    vendorHash = "sha256-Vs45UXbaI6EHrkyhrilNNAe6/DvrgTqoRogBB/qQOQU=";
    # Static, like the release build: the adapter is embedded in another
    # binary and copied to hosts, and it pulls in net (cgo resolver) otherwise
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" "-X ${mod}/cli/beacon-hooks/internal/version.Version=${version}" ];
    doCheck = false;
    meta = meta // { mainProgram = "beacon-hooks"; };
  };

  cli = buildGoModule {
    pname = "beacon";
    inherit version src;
    modRoot = "cli/beacon";
    # the module also holds two dev helpers (e2eserver, gen) that are not installed
    subPackages = [ "." ];
    vendorHash = "sha256-9WB29tSpAWOCfasJLSH5GDlJS6XlRDyjJhFpCtedM8I=";
    env.CGO_ENABLED = 0;
    ldflags = [
      "-s"
      "-w"
      "-X ${mod}/cli/beacon/internal/version.Version=${version}"
      "-X ${mod}/cli/beacon/internal/version.GitCommit=${shortRev}"
      "-X ${mod}/cli/beacon/internal/version.BuildDate=2026-10-05"
    ];
    # internal/embedded/embed.go: //go:embed hooks.bin (gitignored upstream)
    preBuild = ''
      cp ${hooks}/bin/beacon-hooks internal/embedded/hooks.bin
      chmod u+w internal/embedded/hooks.bin
    '';
    # `go mod vendor` only needs the file to exist
    overrideModAttrs = _: {
      preBuild = ''
        echo PLACEHOLDER > internal/embedded/hooks.bin
      '';
    };
    doCheck = false;
    meta = meta // { mainProgram = "beacon"; };
  };

  otelcol = buildGoModule {
    pname = "beacon-otelcol";
    inherit version src;
    modRoot = "collector-builder/nestlo-otelcol";
    vendorHash = "sha256-c9acobtqUy3XbK6bfg0x70PP1cWWBw/F5IfABrKFv88=";
    # The module lives in the upstream tree so its replace directives
    # (../exporter/beaconjsonexporter, ../../pkg/asymptoteobserve) resolve
    postPatch = ''
      mkdir -p collector-builder/nestlo-otelcol
      cp ${./agent-beacon/otelcol}/{go.mod,go.sum,main.go,components.go} collector-builder/nestlo-otelcol/
      chmod -R u+w collector-builder/nestlo-otelcol
    '';
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" "-X main.version=${version}" ];
    doCheck = false;
    meta = meta // { mainProgram = "beacon-otelcol"; };
  };
in
symlinkJoin {
  name = "agent-beacon-${version}";
  paths = [ cli hooks otelcol ];
  passthru = { inherit cli hooks otelcol version src; };
  meta = meta // {
    mainProgram = "beacon";
    description = "Agent Beacon: session capture, replay and reviewed memory for AI coding agents (CLI, hook adapter, local collector)";
  };
}
