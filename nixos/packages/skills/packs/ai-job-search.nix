# MadsLorentzen/ai-job-search: a job-application framework built on Claude
# Code: evaluate job postings, tailor a CV, write cover letters, prepare for
# interviews, find postings through portal-search skills, and plan upskilling.
#
# The skills are in two places upstream: .claude/skills (job-application-
# assistant, job-scraper, upskill) and .agents/skills (portal searches with
# TypeScript scripts). Left out, because the build rejects them: jobbank-search,
# jobdanmark-search, jobindex-search and jobnet-search have descriptions of
# 1122 to 1241 characters (the Agent Skills spec allows 1024).
{ mkSkillPack, sources, discover }:

let
  src = sources.ai-job-search;
in
mkSkillPack {
  pack = "ai-job-search";
  version = "0-unstable-2026-10-05";
  inherit src;
  skills = discover.findSkills {
    inherit src;
    roots = [ ".claude/skills" ".agents/skills" ];
    exclude = [ "jobbank-search" "jobdanmark-search" "jobindex-search" "jobnet-search" ];
  };
  description = "Job search workflow: evaluate postings, tailor CVs and cover letters, interview prep, portal searches, skill-gap plans";
  homepage = "https://github.com/MadsLorentzen/ai-job-search";
  license = "MIT";
  collections = [ "community" "productivity" ];
  defaultEnable = false;
  notes = ''
    Upstream is a repository you fork and fill in (profile, CV, company research, tracked postings); the skills read and write those project files, so they are useful inside such a checkout, not as a global skill set. The job-scraper skill's `name:` is `scrape` upstream (the /scrape command); it is installed as job-scraper, the directory name, because gstack has a skill called scrape.
    freehire-search and linkedin-search run a bundled TypeScript CLI with `bun run .agents/skills/<skill>/cli/src/cli.ts` (relative to a project that holds the skill; needs Bun) and fetch job listings from the network, so the commands only resolve inside a checkout that has the skills at that path.
    Not shipped (descriptions over 1024 characters): jobbank-search, jobdanmark-search, jobindex-search, jobnet-search (Danish job boards).
  '';
}
