# garrytan/gstack: a software-factory workflow as skills (office-hours, plan
# reviews by CEO / engineering / design / DevEx, review, qa, ship,
# land-and-deploy, retro, investigate, design-consultation, ...).
#
# Each top-level directory with a SKILL.md is one skill. Left out:
#   - the root SKILL.md (`gstack`, a router): its directory is the whole
#     repository with the Bun-built tools (browse, bin/gstack-*)
#   - gstack-upgrade: upgrades an upstream checkout in ~/.claude/skills/gstack
#   - connect-chrome: a symlink to open-gstack-browser upstream
#   - browser-skills/, openclaw/ (variants for the OpenClaw host) and test/
#     fixtures
{ mkSkillPack, sources, discover }:

let
  src = sources.gstack;
in
mkSkillPack {
  pack = "gstack";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ "" ];
    exclude = [ "gstack-upgrade" ];
  };
  description = "Garry Tan's gstack workflow: office hours, plan reviews, review, QA, ship, deploy, retro, design review";
  homepage = "https://github.com/garrytan/gstack";
  license = "MIT";
  collections = [ "community" "dev-workflow" ];
  defaultEnable = false;
  notes = ''
    MIT. The skills call upstream's helper scripts at ~/.claude/skills/gstack/bin/ (config, learnings, decision log, ...) and the Bun-compiled `browse` tool that qa, design-review, canary, browse, scrape, open-gstack-browser, pair-agent and benchmark drive. None of that is packaged (CLIs are out of scope for the pack, and the router skill `gstack` that lives next to them is not shipped), so the skills' bookkeeping steps and all browser automation do not work until you install gstack itself (it needs Bun). Planning and review skills (office-hours, plan-*-review, review, investigate, retro, ship) are mostly prose and work as written.
    ios-* skills need macOS with Xcode; setup-gbrain and sync-gbrain need a gbrain / Supabase account; codex needs the Codex CLI; the skills use the gh CLI and git.
    Each skill starts by running ~/.claude/skills/gstack/bin/gstack-skill-start; when that script is absent it has a documented degraded mode (skip onboarding and telemetry, tell you to run ./setup, carry on with the task). Upstream telemetry is therefore not active unless you install gstack yourself.
    design-html ships a minified copy of the Pretext text-layout library (design-html/vendor/pretext.js, MIT upstream) that upstream's NOTICE.md does not list.
    No hooks, MCP servers or the extension are installed.
  '';
}
