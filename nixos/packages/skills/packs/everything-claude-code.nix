# affaan-m/everything-claude-code ("ECC"): a large library of engineering
# skills: language and framework patterns (Python, Go, Rust, Kotlin, Swift,
# Django, Spring Boot, Laravel, Rails, React, Next.js, ...), testing and TDD,
# security review, API and database design, deployment, agent-loop patterns,
# research and content workflows, and domain packs (healthcare, logistics,
# network engineering, finance).
#
# Only skills/ is used: it is the curated set. Left out:
#   - docs/*/skills (ja-JP, zh-CN, tr, es, ... translations), pi/core/skills,
#     .agents/.kiro/.cursor skill copies: translations and per-agent copies
#   - the 19 skills whose description is about ECC itself or its operator
#     setup (they drive ECC's own commands, hooks, install plans or accounts and
#     do nothing without the ECC plugin): agent-sort, automation-audit-ops,
#     configure-ecc, cost-tracking, ecc-guide, ecc-recipes, ecc-tools-cost-audit,
#     email-ops, finance-billing-ops, frontend-design-direction, hermes-imports,
#     messages-ops, nanoclaw-repl, nasiko-control-plane, plan-orchestrate,
#     prompt-optimizer, research-ops, terminal-ops, unified-notifications-ops
#
# Name clashes: benchmark (gstack), design-system (ui-ux-pro-max) and
# exa-search (scientific-skills) are different skills with the same names, so
# this pack's are installed as everything-claude-code-benchmark, -design-system
# and -exa-search. Text elsewhere that mentions them by their old names is
# not rewritten.
#
# Licence: MIT (root LICENSE, Affaan Mustafa).
{ mkSkillPack, sources, discover }:

let
  src = sources.everything-claude-code;
in
mkSkillPack {
  pack = "everything-claude-code";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.renameSkills {
    pack = "everything-claude-code";
    inherit src;
    rename = {
      benchmark = "everything-claude-code-benchmark";
      design-system = "everything-claude-code-design-system";
      exa-search = "everything-claude-code-exa-search";
    };
    skills = discover.findSkills {
      inherit src;
      exclude = [
        "agent-sort"
        "automation-audit-ops"
        "configure-ecc"
        "cost-tracking"
        "ecc-guide"
        "ecc-recipes"
        "ecc-tools-cost-audit"
        "email-ops"
        "finance-billing-ops"
        "frontend-design-direction"
        "hermes-imports"
        "messages-ops"
        "nanoclaw-repl"
        "nasiko-control-plane"
        "plan-orchestrate"
        "prompt-optimizer"
        "research-ops"
        "terminal-ops"
        "unified-notifications-ops"
      ];
    };
  };
  description = "A large engineering skill library: language and framework patterns, testing, security, deployment, agent loops, domain packs";
  homepage = "https://github.com/affaan-m/everything-claude-code";
  license = "MIT";
  collections = [ "large" ];
  defaultEnable = false;
  notes = ''
    About 270 skills: enabling the pack adds roughly 27k tokens of skill descriptions to every session. Prefer enabling it only where you want the breadth; the language and framework skills are written to load when you work on matching files.
    Upstream is a Claude Code plugin; its agents, slash commands, hooks, rules and MCP configurations are not packaged. Some skills point at files in the upstream repository (rules/, hooks/, docs/) or at ECC commands, which are not present.
    Skills that call services need their own accounts or keys: x-api, exa-search, fal-ai-media, videodb, mailtrap-email-integration, google-workspace-ops, jira-integration, github-ops (gh), nutrient-document-processing and others. Some ship scripts (Python, Node, shell); no dependencies are installed.
  '';
}
