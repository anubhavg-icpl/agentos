# Four skills built from Andrej Karpathy's public talks and posts: the coding
# loop (plan, small diffs, verify), context engineering, task routing (how
# much autonomy, which tool or model) and verification of AI output.
# Markdown only.
#
# Upstream's install.sh also copies KARPATHY.md into ~/.claude and appends
# an `@KARPATHY.md` import to ~/.claude/CLAUDE.md, so the routing is always
# loaded. That edits a user's own file, so it is not done here: the skills
# load on their own when their descriptions match the task.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "karpathy-claude-skills";
  version = "0-unstable-2026-10-05";
  src = sources.karpathy-claude-skills;
  skills = {
    karpathy-coding-loop = "skills/karpathy-coding-loop";
    karpathy-context-engineering = "skills/karpathy-context-engineering";
    karpathy-task-routing = "skills/karpathy-task-routing";
    karpathy-verification = "skills/karpathy-verification";
  };
  description = "Karpathy's working methods as skills: coding loop, context engineering, task routing, verification";
  homepage = "https://github.com/benfngu/karpathy-claude-skills";
  license = "MIT";
  collections = [ "dev-workflow" ];
  notes = "Overlaps karpathy-guidelines (upstream treats that skill as superseded by this set); enable one or both.";
}
