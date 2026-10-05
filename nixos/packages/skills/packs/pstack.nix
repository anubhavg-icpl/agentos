# cursor/plugins, pstack/ plugin: Lauren Tan's pstack, "write less, but higher
# quality code": rigorous agent workflows (poteto-mode, interrogate, arena,
# swarm, architect, unslop, show-me-your-work, technical-writing, TDD, ...) and
# a set of principle-* skills.
#
# Licence: pstack/LICENSE (MIT, Lauren Tan). The cursor/plugins repository has
# no root licence; every plugin directory carries its own, which is why the
# other plugins are in the separate cursor-plugins pack.
#
# Name clashes: pstack's `tdd` and `teach` share their names with
# mattpocock-skills (different skills), so they are installed as `pstack-tdd`
# and `pstack-teach`; the one place where a pstack skill points at `tdd`
# (poteto-mode's bug-fix playbook, "See the **tdd** skill") is changed to match.
#
# Left out: pstack/automations/ (Cursor automation setup for one bot, "benny"),
# pstack/agents/ (subagent definitions, not skills).
{ mkSkillPack, sources, discover }:

let
  src = sources.cursor-plugins;
in
mkSkillPack {
  pack = "pstack";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.renameSkills {
    pack = "pstack";
    inherit src;
    skills = discover.findSkills {
      inherit src;
      roots = [ "pstack/skills" ];
    };
    rename = {
      tdd = "pstack-tdd";
      teach = "pstack-teach";
      poteto-mode = "poteto-mode"; # copied to rewrite its reference to tdd
    };
    rewrite = [{ from = "**tdd** skill"; to = "**pstack-tdd** skill"; }];
  };
  description = "pstack: write less, higher-quality code; poteto-mode, interrogate, arena, swarm, unslop and engineering principles";
  homepage = "https://github.com/cursor/plugins/tree/main/pstack";
  license = "MIT";
  collections = [ "community" "dev-workflow" "writing" ];
  defaultEnable = false;
  notes = ''
    MIT (pstack/LICENSE). Markdown skills; two upstream skill names ("Make Bot UI", "Poteto Mode") are not valid skill names and are installed as make-bot-ui and poteto-mode.
    Not packaged: the plugin's two subagent definitions (agents/comment-sicko.md, agents/poteto-agent.md) and the benny automations. Skills refer to subagents and to Cursor features in places; they read fine in other agents but some steps assume Cursor.
  '';
}
