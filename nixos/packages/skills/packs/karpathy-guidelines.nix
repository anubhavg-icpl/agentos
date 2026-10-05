# Coding guidelines distilled from Andrej Karpathy's notes on how LLMs fail
# at coding: surface assumptions, keep changes surgical, avoid
# overcomplication, define verifiable success criteria. One skill, Markdown
# only. (The repository also ships CLAUDE.md and Cursor rules; the skill is
# the same text in the portable format.)
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "karpathy-guidelines";
  version = "0-unstable-2026-10-05";
  src = sources.karpathy-guidelines;
  skills = {
    karpathy-guidelines = "skills/karpathy-guidelines";
  };
  description = "Karpathy-inspired coding guidelines: assumptions, surgical changes, simplicity, verifiable goals";
  homepage = "https://github.com/multica-ai/andrej-karpathy-skills";
  license = "MIT";
}
