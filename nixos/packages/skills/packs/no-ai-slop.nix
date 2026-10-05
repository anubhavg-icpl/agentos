# petergyang/no-ai-slop: a writing skill that edits a draft into sharper, more
# human prose while keeping the writer's voice, or reports AI-slop patterns
# without rewriting. Markdown only. Upstream's plugin packaging
# (scripts/build_plugin.py, agents/openai.yaml) is not used.
{ mkSkillPack, sources, discover }:

let
  src = sources.no-ai-slop;
in
mkSkillPack {
  pack = "no-ai-slop";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills { inherit src; };
  description = "Writing skill: edit drafts into sharper, more human prose, or detect AI-slop patterns";
  homepage = "https://github.com/petergyang/no-ai-slop";
  license = "MIT";
  collections = [ "community" "writing" ];
  defaultEnable = false;
  notes = "Markdown only; no network, tools or keys.";
}
