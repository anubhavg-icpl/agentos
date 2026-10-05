# Caliper: tests whether a skill (or MCP server, or other instructions) helps
# by running the agent with and without it and comparing. Ships the grill and
# evaluate skills plus the `caliper` CLI.
{ mkSkillPack, sources, callPackage }:

mkSkillPack {
  pack = "caliper";
  version = "0.17.0";
  src = sources.caliper;
  skills = {
    grill-skill = "skills/grill-skill";
    evaluate-skill = "skills/evaluate-skill";
  };
  tools = [ (callPackage ../tools/caliper.nix { inherit sources; }) ];
  description = "Test whether agent skills help: run the agent with and without a skill and compare";
  homepage = "https://github.com/edonadei/caliper";
  license = "MIT";
  notes = "caliper runs agent CLIs (claude, codex, ...) from PATH; evaluation runs call the model and need that agent logged in or keyed. git is needed only for specs with git skill sources.";
}
