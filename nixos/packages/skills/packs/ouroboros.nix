# Ouroboros: works through an app's details before building (interview,
# seed), asks about decisions that change behavior, then checks the finished
# app against the plan and sends problems back. Ships every upstream skill and
# the `ooo` / `ouroboros` / `ozo` CLI.
#
# Skill directories are prefixed `ouroboros-` so they cannot collide with other
# packs (evaluate, config, update, publish, cancel, ...). Upstream skills
# reach each other by relative path (`../setup/SKILL.md`), so the sources are
# rewritten to match: directory references and the front matter `name` follow
# the new directory name (several upstream skills already use `ouroboros-*`
# names: ouroboros-config, -help, -run, -status). The `ooo <skill>` commands
# and the CLI's own bundled skill copy are unaffected.
{ lib, runCommand, mkSkillPack, sources, callPackage }:

let
  names = [
    "auto" "brownfield" "cancel" "config" "evaluate" "evolve" "help"
    "interview" "maintain" "ooo" "pm" "publish" "qa" "ralph" "resume-session"
    "run" "seed" "setup" "status" "tutorial" "unstuck" "update" "welcome"
  ];

  prefixed = runCommand "ouroboros-skills-prefixed" { } ''
    mkdir -p $out
    for n in ${lib.concatStringsSep " " names}; do
      cp -r --no-preserve=mode ${sources.ouroboros}/skills/$n $out/ouroboros-$n
      sed -i \
        -e "0,/^name:.*/s//name: ouroboros-$n/" \
        ${lib.concatMapStringsSep " " (n: "-e 's|\\.\\./${n}/|../ouroboros-${n}/|g'") names} \
        $out/ouroboros-$n/SKILL.md
    done
  '';
in
mkSkillPack {
  pack = "ouroboros";
  version = "0.55.4";
  src = prefixed;
  skills = lib.listToAttrs (map (n: lib.nameValuePair "ouroboros-${n}" "ouroboros-${n}") names);
  tools = [ (callPackage ../tools/ouroboros.nix { inherit sources; }) ];
  mcp.ouroboros = {
    command = "ouroboros";
    args = [ "mcp" "serve" "--runtime" "claude-cli" "--llm-backend" "claude_code" ];
  };
  description = "Spec-first workflow: interview, seed, run, then evaluate the app against the plan";
  homepage = "https://github.com/Q00/ouroboros";
  license = "MIT";
  notes = "Telemetry is off by default (DO_NOT_TRACK=1, OUROBOROS_TELEMETRY=0 in the wrapper). Runs call the model through an agent CLI or API key. Uses gh/git when skills publish or star.";
}
