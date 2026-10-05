# The anti-slop oxlint plugin, built from the pinned source, and an
# `anti-slop` command that runs nixpkgs oxlint with it on the current project.
#
# The plugin is TypeScript that oxlint loads directly (jsPlugins), so there is
# nothing to compile: the build installs the plugin's one runtime dependency
# (@oxlint/plugins) pinned by the pnpm lockfile and ships src/ beside it.
{ lib
, stdenvNoCC
, nodejs
, fetchurl
, oxlint
, makeWrapper
, writeText
, sources
}:

let
  src = sources.anti-slop;
  version = "0.1.2";

  # The plugin's only runtime dependency is @oxlint/plugins (no transitive
  # deps; the rest of pnpm-lock.yaml is dev tooling for upstream's own tests).
  # Fetch that one tarball pinned by the integrity hash recorded in
  # pnpm-lock.yaml instead of running a full pnpm install in a fixed-output
  # derivation.
  oxlintPlugins = fetchurl {
    url = "https://registry.npmjs.org/@oxlint/plugins/-/plugins-1.78.0.tgz";
    hash = "sha512-Ypt8KeRYw+4jUtlPirfcHWMrn5ms12VrrFPD+Mds477/7tJxG1Kcz2Yrg2nVcTQEUx/GdlhS+BUg1kmxNm04Ug==";
  };

  plugin = stdenvNoCC.mkDerivation {
    pname = "oxlint-plugin-anti-slop";
    inherit version src;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      d=$out/lib/anti-slop
      mkdir -p $d/node_modules/@oxlint/plugins
      cp -r src package.json $d/
      tar -xzf ${oxlintPlugins} --strip-components=1 -C $d/node_modules/@oxlint/plugins
      runHook postInstall
    '';
  };

  # Every generic rule at "error", plus the oxlint-native companion the
  # upstream install skill pairs with no-reduce-accumulator-copy.
  rules = lib.genAttrs
    (map (r: "anti-slop/${r}") [
      "no-array-filter-map"
      "no-reduce-accumulator-copy"
      "no-chained-type-assertions"
      "no-conditional-empty-object-spread"
      "no-known-value-widening"
      "no-module-mocking"
      "no-object-parameters"
      "no-reflect-apply"
      "no-reflect-get"
      "no-runtime-typeof"
      "no-shape-in-symbol-names"
      "no-unknown-parameters"
      "no-unknown-returns"
      "no-unknown-type-aliases"
      "no-unsafe-dictionary-type"
      "no-widen-then-assert"
      "require-readable-spacing"
      "require-safety-comment-for-type-assertion"
    ])
    (_: "error")
  // { "oxc/no-accumulating-spread" = "error"; };

  config = writeText "anti-slop-oxlintrc.json" (builtins.toJSON {
    jsPlugins = [{ name = "anti-slop"; specifier = "${plugin}/lib/anti-slop/src/index.ts"; }];
    inherit rules;
    ignorePatterns = [ "node_modules/**" "dist/**" "build/**" ".claude/**" ".agents/**" ".codex/**" ".opencode/**" ];
  });
in
stdenvNoCC.mkDerivation {
  pname = "anti-slop";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/anti-slop
    ln -s ${config} $out/share/anti-slop/oxlintrc.json
    # `anti-slop [oxlint args]`: lints the current directory with every
    # anti-slop rule. Pass -c <file> to use your own oxlint config instead.
    makeWrapper ${oxlint}/bin/oxlint $out/bin/anti-slop \
      --prefix PATH : ${lib.makeBinPath [ nodejs ]} \
      --run 'case " $* " in *" -c "*|*" --config"*) ;; *) set -- -c ${config} "$@" ;; esac'
    runHook postInstall
  '';

  passthru = { inherit plugin config; };

  meta = {
    description = "Run oxlint with the anti-slop rules on the current project";
    license = lib.licenses.mit;
    mainProgram = "anti-slop";
  };
}
