# Panniantong/Agent-Reach: one skill, `agent-reach`, that routes internet
# research and reading to per-platform backends (web, search, Twitter/X,
# Reddit, YouTube, Bilibili, Xiaohongshu, LinkedIn and job boards, GitHub,
# podcasts, RSS, stock quotes, ...). The skill is the Markdown router plus
# per-category reference notes; it is the agent_reach/skill directory of the
# Python package.
#
# The `agent-reach` Python package (CLI and `doctor` command) and the
# platform CLIs it drives are not packaged.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "agent-reach";
  version = "0-unstable-2026-10-05";
  src = sources.agent-reach;
  skills.agent-reach = "agent_reach/skill";
  description = "Internet research and reading across web, social, video, code and job platforms through per-platform backends";
  homepage = "https://github.com/Panniantong/Agent-Reach";
  license = "MIT";
  collections = [ "community" "research" ];
  defaultEnable = false;
  notes = ''
    The skill is a router: it needs upstream's `agent-reach` CLI (Python 3.10 or newer, pip) and the platform tools it selects (OpenCLI, yt-dlp, per-platform CLIs), none of which the pack installs, and it runs `agent-reach doctor --json` to see what is available. Everything it does goes to the open internet.
    Several channels need accounts or cookies (Twitter/X: exported browser cookies; Boss Zhipin: a logged-in browser reached through the Chrome DevTools protocol; others as `agent-reach doctor` reports) and some backends need API keys. Six channels work without configuration. The skill text is mostly Chinese with English trigger phrases.
  '';
}
