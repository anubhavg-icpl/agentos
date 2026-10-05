# ComposioHQ/awesome-claude-skills, composio-skills/: about 830 app-automation
# skills (one per SaaS product: "Automate <app> tasks via Rube MCP"). Each is a
# short SKILL.md that tells the agent to discover tools through Composio's Rube
# MCP server and run them against a connected account.
#
# They do nothing without that service, and ~830 descriptions cost a lot of
# context, so the pack is opt-in and in no collection but `automation`.
#
# Names: two upstream directories start with a hyphen (`-21risk-automation`,
# `-2chat-automation`), which is not a valid skill name; they are installed
# without it (`21risk-automation`, `2chat-automation`). Only the directory and
# the `name:` line change. 26 directories with underscores
# (`google_maps-automation`) are skipped: each is an older, generic copy of the
# skill that also exists with hyphens (`google-maps-automation`, the proper
# one), and underscores are not valid in skill names.
{ lib, mkSkillPack, sources, discover }:

let
  src = sources.composio-awesome-claude-skills;
in
mkSkillPack {
  pack = "composio-automation";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ "composio-skills" ];
    normalize = true;
    filter = dir: _text: !(lib.hasInfix "_" dir);
  };
  description = "App-automation skills for ~830 SaaS products through Composio's Rube MCP server";
  homepage = "https://github.com/ComposioHQ/awesome-claude-skills";
  license = "Apache-2.0";
  collections = [ "automation" ];
  defaultEnable = false;
  notes = ''
    Needs a Composio account: every skill drives the Rube MCP server (https://rube.app/mcp, hosted by Composio), which you add to your agent's MCP configuration, and then a login or API key for each app you automate. Without it the skills do nothing. All calls go to Composio's service.
    About 830 skills: enabling the pack adds roughly 80k tokens of skill descriptions to every session. Enable it only where you use Composio.
    The repository has no LICENSE file; its README says Apache-2.0.
    Not packaged: the Rube MCP server itself.
  '';
}
