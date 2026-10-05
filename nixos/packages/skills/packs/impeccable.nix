# pbakaus/impeccable: one skill, `impeccable`, with sub-commands for frontend
# design work (shape, critique, audit, polish, animate, colorize, typeset,
# layout, harden, optimize, ...), reference notes and helper scripts.
#
# The repository generates a copy of the skill for every agent (.claude/,
# .cursor/, .gemini/, ... directories, tests/ fixtures). plugin/skills is the
# one used here: the Claude Code plugin build, which has the full reference/
# and scripts/ directories. Licence: Apache-2.0 (root LICENSE; NOTICE.md lists
# MIT-licensed material it was derived from).
{ mkSkillPack, sources, discover }:

let
  src = sources.impeccable;
in
mkSkillPack {
  pack = "impeccable";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ "plugin/skills" ];
  };
  description = "Frontend design craft: shape, critique, audit, polish, animate, colorize, typeset, layout, harden";
  homepage = "https://github.com/pbakaus/impeccable";
  license = "Apache-2.0";
  collections = [ "community" "design" ];
  defaultEnable = false;
  notes = ''
    One skill with many sub-commands (argument-hint), so it costs a single description.
    The skill starts every session by running scripts/impeccable, a launcher for upstream's compiled engine binary. The binary is not in the pack: the launcher downloads it on first run into ~/.impeccable (network, an unreviewed prebuilt binary that may not run on NixOS unless it is statically linked), or uses IMPECCABLE_BIN / an `impeccable` on PATH. Without it the context, live-browser and pin commands fail. The `live` mode also needs a browser.
    scripts/modern-screenshot.umd.js is a bundled copy of the MIT-licensed modern-screenshot library that upstream's NOTICE.md does not list.
    Not packaged: the plugin's subagents (impeccable-asset-producer, -documenter, -finish-reviewer, -manual-edit-applier) and hooks, and the project's CLI.
  '';
}
