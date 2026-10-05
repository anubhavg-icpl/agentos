# cursor/plugins: the skills of Cursor's plugin collection other than pstack
# (which is its own pack): cursor-team-kit (CI, PRs, merge conflicts, weekly
# review), thermos (code-quality review), advisor, orchestrate, ralph-loop,
# teaching, continual-learning, create-plugin, docs-canvas,
# pr-review-canvas, agent-compatibility, cli-for-agent, grok-voice, dyl-stack
# and the third_party Google Workspace / X plugins.
#
# Licence: the repository has no root licence. Only plugin directories that
# hold their own LICENSE starting "MIT License" are used; the plugin directories
# are found by that rule, not listed.
#
# Name clashes inside the repository:
#   - thermo-nuclear-code-quality-review is in cursor-team-kit and thermos, byte
#     for byte the same; only the cursor-team-kit copy is kept
#   - check-agent-compatibility (its description has an unquoted `: `, which
#     makes the front matter invalid YAML) and cursor-sdk (description of 1045
#     characters, over the 1024 the Agent Skills spec allows) are not shipped
#   - pr-review-canvas exists as a standalone plugin and, differently, in
#     cursor-team-kit; the standalone one is installed as
#     cursor-pr-review-canvas
{ lib, mkSkillPack, sources, discover }:

let
  src = sources.cursor-plugins;

  # plugin directories (under `base`) with an MIT LICENSE of their own and skills
  mitPlugins = base: skip:
    let
      dir = if base == "" then "${src}" else "${src}/${base}";
      entries = builtins.readDir dir;
      ok = d:
        entries.${d} == "directory"
        && !(builtins.elem d skip)
        && builtins.pathExists "${dir}/${d}/skills"
        && builtins.pathExists "${dir}/${d}/LICENSE"
        && lib.hasPrefix "MIT License" (builtins.readFile "${dir}/${d}/LICENSE");
    in
    map (d: if base == "" then "${d}/skills" else "${base}/${d}/skills")
      (lib.filter ok (lib.attrNames entries));
in
mkSkillPack {
  pack = "cursor-plugins";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = mitPlugins "" [ "pstack" "third_party" "schemas" "scripts" ] ++ mitPlugins "third_party" [ ];
    exclude = [
      "thermos/skills/thermo-nuclear-code-quality-review"
      "check-agent-compatibility"
      "cursor-sdk"
    ];
    rename."pr-review-canvas/skills/pr-review-canvas" = "cursor-pr-review-canvas";
  };
  description = "Cursor's plugin skills: team kit (CI, PRs, reviews), thermos, advisor, orchestrate, ralph-loop, teaching, Google Workspace and X guides";
  homepage = "https://github.com/cursor/plugins";
  license = "MIT";
  collections = [ "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    MIT, per plugin directory (the repository has no root licence; each plugin's own LICENSE is MIT, dyl-stack's names Dylan Gattey, the others Cursor).
    Skills are Markdown. Several assume Cursor features (canvases, the Cursor SDK, Cursor automations). grok-voice adds xAI Grok voice features to an app (an xAI API key); the third_party skills (google-docs, google-drive, google-sheets, google-slides, x, x-money) are guides for MCP servers or APIs that need their own accounts, and are of no use without them. fix-ci, loop-on-ci, make-pr-easy-to-review, pr-review-canvas and review-and-ship use the gh CLI and git.
    Not shipped because they fail the Agent Skills spec: check-agent-compatibility (invalid YAML front matter) and cursor-sdk (description over 1024 characters).
    Not packaged: each plugin's MCP configuration (mcp.json), rules, hooks and agents.
  '';
}
