# anthropics/skills: Anthropic's example skills (frontend-design, canvas-design,
# algorithmic-art, mcp-builder, skill-creator, webapp-testing, theme-factory,
# web-artifacts-builder, internal-comms, brand-guidelines, slack-gif-creator,
# academy-guide, discernment-nudge).
#
# Licence: the repository has no root LICENSE. Each skill ships its own
# LICENSE.txt; those kept here are Apache-2.0.
#
# Left out:
#   - docx, pdf, pptx, xlsx: their LICENSE.txt is "© Anthropic, PBC. All rights
#     reserved" (source-available, not redistributable)
#   - template (template-skill): a template
#   - claude-api: its description is 1068 characters, over the 1024 the Agent
#     Skills spec allows (the build would fail)
#   - doc-coauthoring: no LICENSE.txt of its own and the README only says
#     "many skills in this repo are open source (Apache 2.0)", so its licence is
#     not clear
{ mkSkillPack, sources, discover }:

let
  src = sources.anthropic-skills;
in
mkSkillPack {
  pack = "anthropic-skills";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    exclude = [ "docx" "pdf" "pptx" "xlsx" "claude-api" "doc-coauthoring" ];
  };
  description = "Anthropic's open example skills: frontend design, canvas and algorithmic art, MCP builder, skill creator, webapp testing, themes";
  homepage = "https://github.com/anthropics/skills";
  license = "Apache-2.0";
  collections = [ "community" "design" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    Apache-2.0 per skill (each has its own LICENSE.txt; the repository has no root licence). Anthropic's docx, pdf, pptx and xlsx skills are all rights reserved and are not shipped.
    Not shipped because they fail the Agent Skills spec or have no clear licence: claude-api (description over 1024 characters), doc-coauthoring (no licence file).
    Scripts: Python helpers in mcp-builder, skill-creator, slack-gif-creator (Pillow, imageio, numpy), webapp-testing (Playwright), shell in web-artifacts-builder (needs Node and the network for npm), a Node script in algorithmic-art. None of the dependencies are provided.
  '';
}
