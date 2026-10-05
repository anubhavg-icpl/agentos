# ComposioHQ/awesome-claude-skills: the curated skills at the top level of the
# repository (changelog generator, file organizer, invoice organizer, lead
# research, meeting insights, ...). Markdown, a few helper scripts.
#
# Licence: the repository has no LICENSE file; its README states "licensed
# under the Apache License 2.0" and that individual skills may differ. None of
# the skills kept here carries a licence of its own that says otherwise.
#
# Left out:
#   - composio-skills/ is the composio-automation pack
#   - document-skills/ (docx, pdf, pptx, xlsx): Anthropic, "All rights reserved"
#   - template-skill: a template; connect-apps-plugin: a plugin, no SKILL.md
#   - older copies of skills that the anthropic-skills pack ships from their
#     upstream (artifacts-builder is the former name of web-artifacts-builder)
{ mkSkillPack, sources, discover }:

let
  src = sources.composio-awesome-claude-skills;
in
mkSkillPack {
  pack = "composio-awesome-claude-skills";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ "" ];
    exclude = [
      "template-skill"
      "artifacts-builder"
      "brand-guidelines"
      "canvas-design"
      "internal-comms"
      "mcp-builder"
      "skill-creator"
      "slack-gif-creator"
      "theme-factory"
      "webapp-testing"
    ];
  };
  description = "Curated everyday skills: changelogs, file and invoice organising, lead research, meeting insights, resumes, domain names";
  homepage = "https://github.com/ComposioHQ/awesome-claude-skills";
  license = "Apache-2.0";
  collections = [ "community" "productivity" ];
  defaultEnable = false;
  notes = ''
    The repository has no LICENSE file; its README says Apache-2.0 (individual skills may differ, none kept here says so).
    `connect` and `connect-apps` send actions through Composio's hosted Rube MCP server and need a Composio account; `langsmith-fetch` needs a LangSmith API key; `video-downloader` runs a Python script (scripts/download_video.py) that needs yt-dlp and the network.
    Copies of Anthropic's own skills are in anthropic-skills instead; Anthropic's docx, pdf, pptx and xlsx are not shipped (all rights reserved).
  '';
}
