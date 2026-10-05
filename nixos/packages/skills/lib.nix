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
#                The skill name is the directory name the CLIs see. The value
#                may also be an absolute store path (discover.renameSkills).
#   tools        list of derivations whose bin/ is merged into $out/bin
#   mcp          attrset of MCP servers the pack provides:
#                { <name> = { command = "..."; args = [ ... ]; env = { }; }; }
#   description, homepage, license (an SPDX id string), notes (free text,
#                e.g. license caveats or what needs the network)
#   defaultEnable  false makes the pack opt-in under agentos.skills (for packs
#                that change agent behaviour or cost many context tokens)
#   licenseSrc   where to copy LICENSE/NOTICE files from (default src); they land in
#                $out/share/doc/agentos-skills/<pack>/ so the licence text travels
#                with the skills. Set it when `src` is a derived tree
#   collections  names of the collections the pack belongs to; listing one in
#                agentos.skills.collections (or setting agentos.skills.enableAll)
#                enables the pack unless packs.<name>.enable is set explicitly
#
# Every skill is checked against the Agent Skills spec (validate.py): front
# matter with a valid `name` equal to the directory name and a description
# of at most 1024 characters. The build fails on a violation.
{ lib, stdenvNoCC, jq, python3 }:

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
, collections ? [ ]
, licenseSrc ? src
}:

assert lib.assertMsg (builtins.match "[a-z0-9-]+" pack != null) "skill pack name ${pack} must be [a-z0-9-]+";
let
  # `skills` is only forced when the pack is built or its skill names are read,
  # so evaluating a configuration with the pack disabled never enumerates its
  # source (packs that discover their skills with discover.nix read the source)
  skills' = if skills == { } then throw "skill pack ${pack} has no skills" else skills;

  meta = {
    inherit pack version description homepage license notes defaultEnable collections;
    skills = lib.attrNames skills';
    mcp = mcp;
    # The command each tool provides (what agentos-skills list shows)
    tools = map (t: t.meta.mainProgram or t.pname or t.name) tools;
  };
  # `dir` is relative to src, or an absolute store path (a skill that
  # discover.renameSkills built under a new name). The list goes through a file
  # (passAsFile): a pack with hundreds of skills would overflow the builder's
  # environment if it were spelled out in the install script.
  skillList = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: dir: "${name}\t${if lib.hasPrefix "/" dir then dir else "${src}/${dir}"}")
    skills') + "\n";
in
stdenvNoCC.mkDerivation {
  pname = "agentos-skills-${pack}";
  inherit version skillList;
  metaJson = builtins.toJSON meta;
  passAsFile = [ "skillList" "metaJson" ];
  dontUnpack = true;
  nativeBuildInputs = [ jq (python3.withPackages (ps: [ ps.pyyaml ])) ];

  installPhase = ''
    runHook preInstall
    root=$out/share/agentos/skills/${pack}
    mkdir -p "$root"
    dirs=()
    while IFS=$'\t' read -r name from; do
      if [ ! -f "$from/SKILL.md" ]; then
        echo "skill pack ${pack}: $name: $from/SKILL.md not found" >&2
        exit 1
      fi
      mkdir -p "$root/$name"
      cp -r --no-preserve=mode "$from"/. "$root/$name/"
      dirs+=("$root/$name")
    done < "$skillListPath"
    if [ "''${#dirs[@]}" -ne ${toString (lib.length (lib.attrNames skills'))} ]; then
      echo "skill pack ${pack}: installed ''${#dirs[@]} skills, expected ${toString (lib.length (lib.attrNames skills'))}" >&2
      exit 1
    fi
    python3 ${./validate.py} ${lib.escapeShellArg pack} "''${dirs[@]}"
    jq . "$metaJsonPath" > "$root/pack.json"
    doc=$out/share/doc/agentos-skills/${pack}
    mkdir -p "$doc"
    for f in ${licenseSrc}/LICENSE* ${licenseSrc}/LICENCE* ${licenseSrc}/COPYING* ${licenseSrc}/NOTICE*; do
      if [ -f "$f" ]; then cp --no-preserve=mode "$f" "$doc/"; fi
    done
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
    inherit pack mcp tools defaultEnable collections src;
    packMeta = meta;
    # skill name -> directory in src (used by nixos/packages/skills/collisions.py)
    skillDirs = skills';
    skillNames = lib.attrNames skills';
  };

  meta = {
    inherit description homepage;
    platforms = lib.platforms.all;
  };
}
