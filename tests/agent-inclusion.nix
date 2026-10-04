# Evaluation-only check: the agent packages, the runtime agent map and the
# agentos host's system packages cannot drift apart.
#
#   - every package in agents/commands.nix is part of `all-agents`, and
#     every package in `all-agents` is listed in agents/commands.nix
#   - `all-agents` (and the AgentOS CLIs) are in the host's systemPackages
#   - every command in the runtime map (`agentos spawn <name>`) is a
#     command of some agent package
#   - every agent package's primary command has a runtime map entry
#   - a package's primary command is its meta.mainProgram, where it has one
#
# Nothing is built: a violation makes evaluation fail with the list below.
{ pkgs, host, agentPkgs }:

let
  inherit (pkgs) lib;
  commands = import ../agents/commands.nix;
  cfg = host.config;
  map' = cfg.agentos.runtime.agents;
  sysPkgs = cfg.environment.systemPackages;
  inSystem = p: lib.any (s: s.drvPath == p.drvPath) sysPkgs;

  allAgents = agentPkgs.all-agents;
  allAgentDrvs = map (p: p.drvPath) allAgents.paths;
  declared = lib.attrNames commands;
  allCommands = lib.concatLists (lib.attrValues commands);
  primary = n: lib.head commands.${n};

  problems =
    lib.optional (!inSystem allAgents) "all-agents is not in the agentos host's systemPackages"
    ++ lib.concatMap
      (n: lib.optional (!(agentPkgs ? ${n})) "commands.nix lists ${n}, which agents/default.nix does not define"
        ++ lib.optional (agentPkgs ? ${n} && !(lib.elem agentPkgs.${n}.drvPath allAgentDrvs))
        "${n} is not part of all-agents (so not installed on the host)"
        ++ lib.optional (agentPkgs ? ${n} && (agentPkgs.${n}.meta.mainProgram or null) != null
          && agentPkgs.${n}.meta.mainProgram != primary n)
        "${n}: primary command ${primary n} differs from meta.mainProgram ${agentPkgs.${n}.meta.mainProgram}"
        ++ lib.optional (!(lib.elem (primary n) (lib.attrValues map')))
        "${n}: no runtime agent map entry runs ${primary n}")
      declared
    ++ lib.concatMap
      (d: lib.optional (!(lib.any (n: agentPkgs ? ${n} && agentPkgs.${n}.drvPath == d) declared))
        "all-agents contains a package ${d} that agents/commands.nix does not list")
      allAgentDrvs
    ++ lib.mapAttrsToList
      (name: bin: "runtime map: ${name} -> ${bin}, but no agent package provides ${bin}")
      (lib.filterAttrs (_: bin: !(lib.elem bin allCommands)) map');
in
if problems == [ ] then
  pkgs.runCommand "agent-inclusion" { } "touch $out"
else
  throw "agent-inclusion check failed:\n  ${lib.concatStringsSep "\n  " problems}"
