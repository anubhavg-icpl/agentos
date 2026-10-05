# herdr: the skill that teaches an agent to drive herdr (workspaces, tabs,
# panes, other agents, waits, plugins) through its CLI. The herdr binary is
# installed by agentos.herdr, not by this pack. The skill only applies inside
# a herdr pane (HERDR_ENV=1), so it costs nothing elsewhere.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "herdr";
  version = "0.9.3";
  src = sources.herdr;
  skills = {
    herdr = "skills/herdr";
  };
  description = "Drive herdr panes, tabs, workspaces and other agents from an agent running inside herdr";
  homepage = "https://herdr.dev";
  license = "Apache-2.0";
  collections = [ "dev-workflow" ];
  notes = "Needs the herdr CLI (agentos.herdr.enable installs it) and only activates inside a herdr pane (HERDR_ENV=1).";
}
