# DietrichGebert/ponytail: pushes the agent to the laziest solution that works
# (YAGNI, standard library first, one line before fifty). Skills: ponytail
# (with lite / full / ultra levels), ponytail-review, ponytail-audit,
# ponytail-debt, ponytail-gain, ponytail-help.
#
# Only skills/ is used. Left out: the .openclaw/ copies (a variant for another
# host), and upstream's hooks, slash commands, extensions and the ponytail-mcp
# server, which are not packaged.
{ mkSkillPack, sources, discover }:

let
  src = sources.ponytail;
in
mkSkillPack {
  pack = "ponytail";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills { inherit src; };
  description = "Lazy-solution discipline: ponytail rules with levels, review, audit, debt and gain reports";
  homepage = "https://github.com/DietrichGebert/ponytail";
  license = "MIT";
  collections = [ "community" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    Markdown only. The skills work from their descriptions; upstream's session hooks, slash commands and ponytail-mcp server (which make the mode persistent per session) are not packaged. ponytail-gain quotes benchmark averages from upstream and measures nothing locally.
  '';
}
