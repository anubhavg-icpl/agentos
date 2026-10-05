# AgentOS skill packs: one attribute per pack, each built with mkSkillPack
# (lib.nix) from a pinned source (sources.nix). See docs/skills.md.
# useLocks = false makes discovery read the pinned sources at evaluation time
# (import from derivation); update-locks.sh does that to regenerate locks/.
{ pkgs, useLocks ? true }:

let
  mkSkillPack = pkgs.callPackage ./lib.nix { };
  sources = pkgs.callPackage ./sources.nix { };
  discoverFor = pack: import ./discover.nix {
    inherit (pkgs) lib runCommand;
    inherit pack useLocks;
  };
  # a pack declares only the helpers it uses
  # The pack name is the file name; discovery uses that pack's lock file
  callPack = file:
    let pack = pkgs.lib.removeSuffix ".nix" (baseNameOf (toString file));
    in pkgs.lib.callPackageWith (pkgs // { inherit mkSkillPack sources; discover = discoverFor pack; }) file { };
in
{
  fwc-swiftui-skills = callPack ./packs/fwc-swiftui-skills.nix;
  karpathy-guidelines = callPack ./packs/karpathy-guidelines.nix;
  karpathy-claude-skills = callPack ./packs/karpathy-claude-skills.nix;
  chisle = callPack ./packs/chisle.nix;
  anti-slop = callPack ./packs/anti-slop.nix;
  img2threejs = callPack ./packs/img2threejs.nix;
  ui-skills = callPack ./packs/ui-skills.nix;
  reticle = callPack ./packs/reticle.nix;
  caliper = callPack ./packs/caliper.nix;
  ouroboros = callPack ./packs/ouroboros.nix;

  # Community collections (docs/skills.md): all opt-in
  composio-awesome-claude-skills = callPack ./packs/composio-awesome-claude-skills.nix;
  composio-automation = callPack ./packs/composio-automation.nix;
  superpowers = callPack ./packs/superpowers.nix;
  anthropic-skills = callPack ./packs/anthropic-skills.nix;
  mattpocock-skills = callPack ./packs/mattpocock-skills.nix;
  gstack = callPack ./packs/gstack.nix;
  ui-ux-pro-max = callPack ./packs/ui-ux-pro-max.nix;
  everything-claude-code = callPack ./packs/everything-claude-code.nix;
  scientific-skills = callPack ./packs/scientific-skills.nix;
  caveman = callPack ./packs/caveman.nix;
  pstack = callPack ./packs/pstack.nix;
  cursor-plugins = callPack ./packs/cursor-plugins.nix;
  vibe-security = callPack ./packs/vibe-security.nix;
  no-ai-slop = callPack ./packs/no-ai-slop.nix;
  ponytail = callPack ./packs/ponytail.nix;
  hyperframes = callPack ./packs/hyperframes.nix;
  impeccable = callPack ./packs/impeccable.nix;
  taste-skill = callPack ./packs/taste-skill.nix;
  unlazy = callPack ./packs/unlazy.nix;
  ai-job-search = callPack ./packs/ai-job-search.nix;
  agent-reach = callPack ./packs/agent-reach.nix;
  open-design = callPack ./packs/open-design.nix;
}
