# obra/superpowers: a software-development workflow as skills (brainstorming,
# writing plans, subagent-driven development, test-driven development,
# systematic debugging, code review, verification, git worktrees, ...).
#
# Upstream is a Claude Code / Codex / Gemini plugin whose SessionStart hook
# injects `using-superpowers` into every session. The hook (hooks/) is not
# packaged; the skills load on their own when their descriptions match.
{ mkSkillPack, sources, discover }:

let
  src = sources.superpowers;
in
mkSkillPack {
  pack = "superpowers";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills { inherit src; };
  description = "Software-development workflow: brainstorm, plan, subagent-driven development, TDD, debugging, review, verification";
  homepage = "https://github.com/obra/superpowers";
  license = "MIT";
  collections = [ "community" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    Skills are Markdown plus a few helpers: brainstorming ships a small Node visual-companion server (node), subagent-driven-development ships shell helpers (review-package, sdd-workspace, task-brief), writing-skills ships render-graphs.js (needs Graphviz). Nothing needs the network or a key.
    Not packaged: the plugin's SessionStart hook, which injects using-superpowers into every session. Without it the skills are chosen by their descriptions, which is less insistent than upstream intends.
    Several skills assume the agent can spawn subagents (Claude Code, Codex).
  '';
}
