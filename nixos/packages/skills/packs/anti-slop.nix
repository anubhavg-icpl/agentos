# Anti-Slop: oxlint rules that reject specific low-evidence TypeScript and
# JavaScript patterns, plus the upstream skill for vendoring them into a repo.
# AgentOS also ships the plugin prebuilt: run `anti-slop` in any project.
{ pkgs, mkSkillPack, sources }:

let
  antiSlop = pkgs.callPackage ../tools/anti-slop.nix { inherit sources; };
in
mkSkillPack {
  pack = "anti-slop";
  version = "0.1.2";
  src = sources.anti-slop;
  skills.install-anti-slop = "skills/install-anti-slop";
  tools = [ antiSlop ];
  description = "Oxlint plugin that flags specific coding mistakes in JS/TS projects, with the `anti-slop` command";
  homepage = "https://github.com/dmmulroy/anti-slop";
  license = "MIT";
  collections = [ "dev-workflow" ];
  notes = ''
    The upstream install-anti-slop skill vendors the plugin into a repository and
    installs @oxlint/plugins and oxlint from npm. On AgentOS the `anti-slop`
    command already runs the same rules offline: it wraps oxlint from nixpkgs and
    loads the pinned plugin from the Nix store, enabling every generic rule at
    error. Pass `-c <file>` to use your own oxlint config. The plugin is pinned
    against oxlint 1.78.0 upstream; nixpkgs may ship an older oxlint.
  '';
}
