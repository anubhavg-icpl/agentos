# nextlevelbuilder/ui-ux-pro-max-skill: UI/UX design intelligence (searchable
# styles, palettes, typography, UX guidelines and design-system generation)
# plus design, design-system, brand, banner-design, slides and ui-styling.
#
# The skills live in .claude/skills/ upstream (that is the source the
# project's own installer and CLI copy from; cli/assets/skills holds the
# same skills again and is not used). Licence: MIT (root LICENSE); ui-styling
# carries its own Apache-2.0 LICENSE.txt.
{ mkSkillPack, sources, discover }:

let
  src = sources.ui-ux-pro-max;
in
mkSkillPack {
  pack = "ui-ux-pro-max";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ ".claude/skills" ];
  };
  description = "UI/UX design intelligence: styles, palettes, typography and UX rules, design systems, brand, banners, slides, Tailwind and shadcn styling";
  homepage = "https://github.com/nextlevelbuilder/ui-ux-pro-max-skill";
  license = "MIT";
  collections = [ "community" "design" ];
  defaultEnable = false;
  notes = ''
    MIT; ui-styling is Apache-2.0 (its own LICENSE.txt).
    ui-ux-pro-max searches its CSV data with Python scripts (python3, no packages). SKILL.md invokes them as ''${CLAUDE_PLUGIN_ROOT}/.claude/skills/ui-ux-pro-max/scripts/search.py, a path that only exists when installed as upstream's plugin; installed as a plain skill the agent has to run scripts/search.py from the skill's own directory.
    design generates logos, icons and corporate-identity mockups through image APIs: it needs a Gemini, Atlas Cloud or MuAPI key and the network. brand, design-system and slides use Node scripts (no packages installed); ui-styling expects npm for shadcn/Tailwind projects.
    Not packaged: upstream's CLI (uipro-cli) and its other-agent templates.
  '';
}
