# mkSkillPack: turn an upstream repository into an AgentOS skill pack.
#
# A skill is a directory with a SKILL.md (YAML front matter with `name` and
# `description`, then instructions) plus any files it references. Claude
# Code, Codex, OpenCode, Gemini CLI, Copilot CLI, Cursor and others load
# skills from such directories; agentos.skills links every enabled pack's
# skills into each CLI's skills directory.
#
# Output layout:
#   $out/share/agentos/skills/<pack>/<skill>/SKILL.md   one dir per skill
#   $out/share/agentos/skills/<pack>/pack.json          metadata (below)
#   $out/bin/...                                        the pack's tools, if any
#
# Arguments:
#   pack         pack name (lower-case, [a-z0-9-])
#   src          pinned source (nixos/packages/skills/sources.nix)
#   skills       attrset { <skill name> = "<dir in src containing SKILL.md>"; }
#                The skill name is the directory name the CLIs see.
#   tools        list of derivations whose bin/ is merged into $out/bin
#   mcp          attrset of MCP servers the pack provides:
#                { <name> = { command = "..."; args = [ ... ]; env = { }; }; }
#   defaultEnable whether agentos.skills enables the pack by default (true)
#   description, homepage, license (an SPDX id string), notes (free text,
#                e.g. license caveats or what needs the network)
{ lib, stdenvNoCC, jq, symlinkJoin }:

{ pack
, version
, src
, skills
, tools ? [ ]
, mcp ? { }
, description
, homepage
, license
, notes ? ""
, defaultEnable ? true
}:

assert lib.assertMsg (builtins.match "[a-z0-9-]+" pack != null) "skill pack name ${pack} must be [a-z0-9-]+";
assert lib.assertMsg (skills != { }) "skill pack ${pack} has no skills";

let
  meta = {
    inherit pack version description homepage license notes;
    skills = lib.attrNames skills;
    mcp = mcp;
    tools = map (t: t.pname or t.name) tools;
  };
  copySkill = name: dir: ''
    if [ ! -f ${lib.escapeShellArg "${src}/${dir}"}/SKILL.md ]; then
      echo "skill pack ${pack}: ${dir}/SKILL.md not found" >&2
      exit 1
    fi
    mkdir -p "$root/${name}"
    cp -r --no-preserve=mode ${lib.escapeShellArg "${src}/${dir}"}/. "$root/${name}/"
    # Every skill needs front matter with a name and a description
    head -1 "$root/${name}/SKILL.md" | grep -qx -- '---' \
      || { echo "skill ${pack}/${name}: SKILL.md has no YAML front matter" >&2; exit 1; }
    sed -n '2,/^---$/p' "$root/${name}/SKILL.md" | grep -q '^description:' \
      || { echo "skill ${pack}/${name}: front matter has no description" >&2; exit 1; }
  '';
in
stdenvNoCC.mkDerivation {
  pname = "agentos-skills-${pack}";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ jq ];

  installPhase = ''
    runHook preInstall
    root=$out/share/agentos/skills/${pack}
    mkdir -p "$root"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList copySkill skills)}
    echo ${lib.escapeShellArg (builtins.toJSON meta)} | jq . > "$root/pack.json"
    ${lib.optionalString (tools != [ ]) ''
      mkdir -p $out/bin
      for t in ${lib.concatMapStringsSep " " (t: "${t}") tools}; do
        if [ -d "$t/bin" ]; then
          for b in "$t"/bin/*; do ln -s "$b" "$out/bin/$(basename "$b")"; done
        fi
      done
    ''}
    runHook postInstall
  '';

  passthru = {
    inherit pack mcp tools defaultEnable;
    packMeta = meta;
    skillNames = lib.attrNames skills;
  };

  meta = {
    inherit description homepage;
    platforms = lib.platforms.all;
  };
}
