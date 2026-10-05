# img2threejs: turn a reference image of an object or character into a
# procedural, animation-ready Three.js model. One skill whose SKILL.md refers
# to the repository's forge/ (Python stages) and grimoire/ (reference notes),
# so the skill directory is the whole repository.
{ lib, stdenvNoCC, makeWrapper, nodejs, mkSkillPack, sources }:

let
  src = sources.img2threejs;

  # bin/img2threejs.mjs installs the skill into agent hosts by running
  # `npx img2 add`. AgentOS links the skill itself, so this is only useful
  # for `img2threejs doctor` and `version`.
  img2threejs-cli = stdenvNoCC.mkDerivation {
    pname = "img2threejs";
    version = "0.1.0";
    inherit src;
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    installPhase = ''
      install -Dm644 bin/img2threejs.mjs $out/lib/img2threejs/bin/img2threejs.mjs
      install -Dm644 package.json $out/lib/img2threejs/package.json
      makeWrapper ${lib.getExe nodejs} $out/bin/img2threejs \
        --add-flags "$out/lib/img2threejs/bin/img2threejs.mjs"
    '';
    meta.mainProgram = "img2threejs";
  };
in
mkSkillPack {
  pack = "img2threejs";
  version = "2.0.0";
  inherit src;
  skills.img2threejs = ".";
  tools = [ img2threejs-cli ];
  description = "img2threejs: rebuild an object or character reference image as a quality-gated procedural Three.js model";
  homepage = "https://github.com/img2threejs/img2threejs";
  license = "Apache-2.0";
  notes = ''
    Token-heavy: the skill runs a staged pipeline (intake, spec, build,
    review with an AI-vision self-correction loop) and reads many reference
    files, so a single model can use a large amount of context and many
    turns. Its forge/ scripts need Python, and the capture helpers need
    Playwright; neither is provided by this pack. The `img2threejs` CLI is
    the project's installer: `install` and `update` fetch with `npx` from the
    network and write into agent skill directories, which duplicates what
    agentos.skills already does; use `doctor` and `version` only.
  '';
}
