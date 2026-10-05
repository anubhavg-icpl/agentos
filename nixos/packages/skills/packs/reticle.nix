# Reticle: stops an agent from calling an app finished when it is not. It
# opens the app in a browser, uses it, marks each check worked / did not work /
# not enough information, and explains the failures. 19 skills plus the
# `reticle` CLI and its MCP server (`reticle mcp`).
#
# The CLI is built from the pinned source: only the @reticlehq/server package
# and the workspace packages it depends on are fetched and compiled. Nothing is
# downloaded at run time. Reticle drives the Chromium given by
# RETICLE_CHROMIUM_PATH, which the wrapper points at nixpkgs' chromium, so
# Playwright never tries to install a browser.
#
# server/src/features/ee is under the Reticle Enterprise License (production use
# needs a subscription). Nothing imports it, so it is removed before the build
# and is not part of the output.
{ lib
, stdenv
, mkSkillPack
, sources
, nodejs_22
, pnpm_10
, fetchPnpmDeps
, pnpmConfigHook
, makeWrapper
, chromium
}:

let
  version = "3.5.0";
  src = sources.reticle;

  reticle = stdenv.mkDerivation (finalAttrs: {
    pname = "reticle";
    inherit version src;

    nativeBuildInputs = [ nodejs_22 pnpm_10 pnpmConfigHook makeWrapper ];

    pnpmWorkspaces = [ "@reticlehq/server..." ];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src pnpmWorkspaces;
      pnpm = pnpm_10;
      fetcherVersion = 3;
      # Fetch through the configured proxy even for registry.npmjs.org (the
      # build host lists it in NO_PROXY and has no direct route from the sandbox).
      prePnpmInstall = ''
        export NO_PROXY= no_proxy=
      '';
      hash = "sha256-oVcBNMXhGOjW0uPKzOKnKeMeYUpCHR9G92e54TI5YB8=";
    };

    postPatch = ''
      # Enterprise-licensed, unused by the CLI: do not build or ship it.
      rm -rf server/src/features/ee
    '';

    buildPhase = ''
      runHook preBuild
      pnpm --filter '@reticlehq/server...' build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      # Production dependencies only: the workspace's dev tooling is several
      # hundred MB that the CLI never loads.
      CI=true pnpm install --offline --prod --frozen-lockfile --ignore-scripts \
        --filter '@reticlehq/server...'
      mkdir -p $out/lib/reticle/adapters/realm
      cp -r node_modules $out/lib/reticle/
      for d in server core engine init open-verification; do
        cp -r $d $out/lib/reticle/
      done
      cp -r adapters/realm/browser $out/lib/reticle/adapters/realm/
      rm -rf $out/lib/reticle/*/src $out/lib/reticle/adapters/realm/browser/src
      makeWrapper ${nodejs_22}/bin/node $out/bin/reticle \
        --add-flags $out/lib/reticle/server/bin/reticle.js \
        --set-default RETICLE_CHROMIUM_PATH ${chromium}/bin/chromium \
        --set-default PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD 1 \
        --set-default RETICLE_TELEMETRY 0
      runHook postInstall
    '';

    meta = {
      description = "Reticle CLI and MCP server";
      homepage = "https://github.com/reticlehq/reticle";
      license = lib.licenses.fsl11Asl20;
      mainProgram = "reticle";
    };
  });
in
mkSkillPack {
  pack = "reticle";
  inherit version src;
  skills = {
    reticle = "plugin";
    agentic-tdd = "skills/agentic-tdd";
    audit-my-app = "skills/audit-my-app";
    debug-broken-ui = "skills/debug-broken-ui";
    design-system-compliance = "skills/design-system-compliance";
    drive-desktop-app = "skills/drive-desktop-app";
    false-green-tests = "skills/false-green-tests";
    fix-what-i-pointed-at = "skills/fix-what-i-pointed-at";
    install-and-verify = "skills/install-and-verify";
    replay-user-flows = "skills/replay-user-flows";
    test-error-states = "skills/test-error-states";
    verify-cli-run = "skills/verify-cli-run";
    verify-form-validation = "skills/verify-form-validation";
    verify-keyboard-access = "skills/verify-keyboard-access";
    verify-login-logout = "skills/verify-login-logout";
    verify-optimistic-update = "skills/verify-optimistic-update";
    verify-pagination = "skills/verify-pagination";
    verify-ui-change = "skills/verify-ui-change";
    verify-unattended = "skills/verify-unattended";
  };
  tools = [ reticle ];
  mcp.reticle = {
    command = "reticle";
    args = [ "mcp" ];
  };
  description = "Reticle: opens the app in a browser, uses it, and marks each check worked / did not work / not enough information, so an agent cannot call unfinished work done";
  homepage = "https://www.reticle.sh";
  license = "FSL-1.1-ALv2";
  notes = ''
    Skills are Apache-2.0. The reticle CLI and MCP server (@reticlehq/server,
    @reticlehq/init) are FSL-1.1-ALv2: free for internal use, development and
    evaluation; the one restriction is offering Reticle as a competing product
    or service, and each version converts to Apache-2.0 two years after release.
    The core, engine, browser and open-verification packages it bundles are
    Apache-2.0. server/src/features/ee is under the Reticle Enterprise License
    and is removed from the build, so no enterprise code ships here.
    The CLI is built from source (no network at run time) and uses nixpkgs
    chromium via RETICLE_CHROMIUM_PATH. Telemetry is disabled by the wrapper.
  '';
}
