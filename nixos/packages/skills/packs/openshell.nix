# OpenShell: the skills from NVIDIA's sandboxed runtime for AI agents. They
# teach an agent to use the openshell CLI, write sandbox policies and debug
# gateways and inference. The openshell binary and the gateway come from
# nestlo.openshell, not from this pack.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "openshell";
  version = "unstable-2026-10-05";
  src = sources.openshell;
  skills = {
    debug-inference = "skills/debug-inference";
    debug-openshell-cluster = "skills/debug-openshell-cluster";
    generate-sandbox-policy = "skills/generate-sandbox-policy";
    openshell-cli = "skills/openshell-cli";
  };
  description = "Use the openshell CLI, write sandbox policies, and debug OpenShell gateways and inference";
  homepage = "https://github.com/NVIDIA/OpenShell";
  license = "Apache-2.0";
  collections = [ "dev-workflow" ];
  notes = "Needs the openshell CLI (nestlo.openshell.enable installs it).";
}
