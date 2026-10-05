# mattpocock/skills: Matt Pocock's engineering skills (grilling, spec and
# ticket flows, TDD, code review, domain modelling, triage, ...).
#
# Only the skills of the upstream Claude Code plugin (its plugin.json lists
# engineering/ and productivity/) are shipped. skills/misc and skills/in-progress
# are not part of the plugin (unfinished or personal) and are left out.
# Name clash: `retro` is also a gstack skill (a different one), so this pack's
# is installed as `mattpocock-skills-retro`; ask-matt, which recommends it, is
# changed to name it that way.
#
# `setup-matt-pocock-skills` configures a repository (issue tracker, labels,
# doc layout) and is meant to run once before the engineering skills.
{ mkSkillPack, sources, discover }:

let
  src = sources.mattpocock-skills;
in
mkSkillPack {
  pack = "mattpocock-skills";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.renameSkills {
    pack = "mattpocock-skills";
    inherit src;
    skills = discover.findSkills {
      inherit src;
      roots = [ "skills/engineering" "skills/productivity" ];
    };
    rename = {
      retro = "mattpocock-skills-retro";
      ask-matt = "ask-matt"; # copied to rewrite its reference to retro
    };
    rewrite = [{ from = "`/retro`"; to = "`/mattpocock-skills-retro`"; }];
  };
  description = "Matt Pocock's engineering skills: grilling, specs and tickets, TDD, code review, domain modelling, triage";
  homepage = "https://github.com/mattpocock/skills";
  license = "MIT";
  collections = [ "community" "dev-workflow" "writing" ];
  defaultEnable = false;
  notes = ''
    Markdown only. Run setup-matt-pocock-skills once per repository: it writes issue-tracker and label configuration into that repository. Some skills use the gh CLI and git.
    Not shipped: skills/misc and skills/in-progress (not part of upstream's plugin).
  '';
}
