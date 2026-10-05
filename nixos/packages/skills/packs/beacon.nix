# Agent Beacon: the Agent Skills of its memory loop. They recall reviewed
# project memory before a task (MCP get_memory_context, or `beacon memory
# list`), turn selected sessions into approved memory with the user's
# confirmation, promote an approved memory to a project skill that every
# harness loads, and write dashboard lenses. The beacon CLI, the capture and
# the MCP server come from nestlo.beacon, not from this pack; nestlo.beacon
# turns the pack on by default.
{ mkSkillPack, sources }:

mkSkillPack {
  pack = "beacon";
  version = "0.1.0";
  src = sources.beacon;
  skills = {
    beacon-lens-create = "agent-skills/skills/beacon-lens-create";
    beacon-memory-distill = "agent-skills/skills/beacon-memory-distill";
    beacon-memory-promote = "agent-skills/skills/beacon-memory-promote";
    beacon-memory-recall = "agent-skills/skills/beacon-memory-recall";
  };
  description = "Recall, distill and promote cross-harness project memory from Beacon traces, and create Beacon dashboard lenses";
  homepage = "https://github.com/Asymptote-Labs/agent-beacon";
  license = "MIT";
  collections = [ "dev-workflow" ];
  notes = "Needs the beacon CLI (nestlo.beacon.enable installs it and captures the sessions). Only beacon-memory-distill can reach the network, and only when a person runs the Jev evaluator: see nestlo.beacon.evaluator.";
}
