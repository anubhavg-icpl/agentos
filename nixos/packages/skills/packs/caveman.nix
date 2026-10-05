# JuliusBrussee/caveman: terse output modes (caveman, ultracave, megacave),
# compressed commit messages and reviews, memory-file compression, a read-only
# repository explorer, and a set of narrow engineering-discipline skills
# (surgical-patch, safe-refactor, lean-build, migration, investigate-first,
# verify-and-stop).
#
# Licence: Apache-2.0 since 3.0.0 (LICENSING.md); the MIT text for earlier
# contributions travels in the upstream repository.
#
# Left out: the six skills that work only with Caveman Cloud (the hosted,
# commercial gateway, "separate commercial software" per LICENSING.md) or its
# CLI reports: caveman-setup, caveman-discover, caveman-evidence-review,
# caveman-manage, caveman-optimize, caveman-learn. The plugins/ copy of the
# skills, hooks and the CLI are not used.
{ mkSkillPack, sources, discover }:

let
  src = sources.caveman;
in
mkSkillPack {
  pack = "caveman";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    exclude = [
      "caveman-setup"
      "caveman-discover"
      "caveman-evidence-review"
      "caveman-manage"
      "caveman-optimize"
      "caveman-learn"
    ];
  };
  description = "Terse output modes (caveman, ultracave, megacave), compressed commits and reviews, memory-file compression, narrow engineering skills";
  homepage = "https://github.com/JuliusBrussee/caveman";
  license = "Apache-2.0";
  collections = [ "community" "writing" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    caveman-compress runs a Python script (scripts/compress.py) that sends the file to Claude through the Anthropic API or the claude CLI, so it needs a key or login and the network; caveman-explore ships a Node package (no dependencies installed). caveman-stats reads local Claude Code usage data.
    Not shipped: the six Caveman Cloud skills (hosted commercial service), the CLI, hooks and the cavecrew subagent definitions that the cavecrew skill delegates to (the skill still works inline).
    The caveman modes change how every answer reads while they are on; they switch on only when asked ("caveman mode", /caveman).
  '';
}
