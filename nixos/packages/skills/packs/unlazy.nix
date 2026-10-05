# Leonxlnx/unlazy: one skill that makes an agent write an explicit contract of
# observable gates (GATES.md with a CHECK/EXPECT per gate), build to it, and
# re-verify independently before it reports done; for larger work it plans a
# tree of leaves and dispatches them in waves. Ships zero-dependency Node
# scripts (gate-check, gate-lint, dispatch-check, an optional Stop hook
# installer).
#
# The skill is the root of the repository, so the pack copies only what
# SKILL.md refers to: SKILL.md, references/, scripts/ and templates/ (not the
# tests, research notes, agents/openai.yaml or package.json).
{ runCommand, mkSkillPack, sources }:

let
  skill = runCommand "unlazy-skill" { } ''
    mkdir -p $out/unlazy
    cp -r --no-preserve=mode ${sources.unlazy}/SKILL.md ${sources.unlazy}/references \
      ${sources.unlazy}/scripts ${sources.unlazy}/templates $out/unlazy/
  '';
in
mkSkillPack {
  pack = "unlazy";
  version = "0-unstable-2026-10-05";
  src = skill;
  licenseSrc = sources.unlazy;
  skills.unlazy = "unlazy";
  description = "Gate-checked work: write observable gates, build to them, verify independently before saying done";
  homepage = "https://github.com/Leonxlnx/unlazy";
  license = "MIT";
  collections = [ "community" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    Needs Node 16 or newer on the PATH for scripts/gate-check.mjs, gate-lint.mjs and dispatch-check.mjs (no packages, no network). scripts/install-hooks.mjs would write a Stop hook into the project's agent settings; it only runs if the agent is asked to, and the pack installs no hooks itself.
  '';
}
