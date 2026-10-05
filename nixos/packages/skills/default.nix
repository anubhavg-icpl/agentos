# AgentOS skill packs: one attribute per pack, each built with mkSkillPack
# (lib.nix) from a pinned source (sources.nix). See docs/skills.md.
{ pkgs }:

let
  mkSkillPack = pkgs.callPackage ./lib.nix { };
  sources = pkgs.callPackage ./sources.nix { };
  callPack = file: pkgs.callPackage file { inherit mkSkillPack sources; };
in
{
  fwc-swiftui-skills = callPack ./packs/fwc-swiftui-skills.nix;
  karpathy-guidelines = callPack ./packs/karpathy-guidelines.nix;
  karpathy-claude-skills = callPack ./packs/karpathy-claude-skills.nix;
  chisle = callPack ./packs/chisle.nix;
  anti-slop = callPack ./packs/anti-slop.nix;
  img2threejs = callPack ./packs/img2threejs.nix;
  ui-skills = callPack ./packs/ui-skills.nix;
}
