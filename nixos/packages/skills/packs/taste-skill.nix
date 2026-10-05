# Leonxlnx/taste-skill: anti-slop frontend design skills. A main skill
# (design-taste-frontend) and style variants (high-end-visual-design,
# industrial-brutalist-ui, minimalist-ui, stitch-design-taste, gpt-taste),
# redesign-existing-projects, full-output-enforcement, and image-direction /
# image-to-code skills (imagegen-frontend-web, imagegen-frontend-mobile,
# image-to-code, brandkit) that expect an image-generation tool.
#
# Upstream directories are named *-skill; the skills are installed under the
# `name:` in their own front matter, which is what upstream's installer uses
# (a rename map, since no skill refers to another by path).
# Left out: taste-skill-v1 (the superseded original, kept upstream only for
# projects that depend on its exact behaviour).
{ mkSkillPack, sources, discover }:

let
  src = sources.taste-skill;
in
mkSkillPack {
  pack = "taste-skill";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    exclude = [ "taste-skill-v1" ];
    rename = {
      taste-skill = "design-taste-frontend";
      soft-skill = "high-end-visual-design";
      brutalist-skill = "industrial-brutalist-ui";
      minimalist-skill = "minimalist-ui";
      redesign-skill = "redesign-existing-projects";
      stitch-skill = "stitch-design-taste";
      output-skill = "full-output-enforcement";
      image-to-code-skill = "image-to-code";
      gpt-tasteskill = "gpt-taste";
    };
  };
  description = "Anti-slop frontend design skills: taste, high-end, brutalist and minimalist styles, redesign, image-to-code";
  homepage = "https://github.com/Leonxlnx/taste-skill";
  license = "MIT";
  collections = [ "community" "design" ];
  defaultEnable = false;
  notes = ''
    Markdown only. imagegen-frontend-web, imagegen-frontend-mobile, brandkit and image-to-code tell the agent to generate design images first, so they need an agent with an image-generation tool (and its account or key); stitch-design-taste targets Google Stitch; gpt-taste is written for GPT / Codex models. The variants overlap in purpose; enabling all of them adds 12 descriptions to every session.
  '';
}
