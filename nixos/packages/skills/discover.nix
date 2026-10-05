# discover: find the skills of an upstream source instead of listing them.
#
#   findSkills { src, roots ? [ "skills" ], exclude ? [ ], include ? [ ],
#                filter ? null, rename ? { }, prefix ? "", normalize ? false }
#
# returns the attrset mkSkillPack takes as `skills`
# ({ <installed name> = "<dir in src>"; }). For every directory directly under
# each of `roots` (paths relative to src) that holds a SKILL.md and is a real
# directory (symlinks are aliases and are skipped):
#   - dirs named in `exclude` are dropped (a name is the dir or "<root>/<dir>")
#   - `filter` (when set) is called with the dir name and the SKILL.md text and
#     must return true to keep the skill
#   - dirs named in `include` are kept whatever `filter` says (not `exclude`)
#   - the installed name is `rename.<root>/<dir>` or `rename.<dir>` if set, else `prefix` + dir;
#     with `normalize`, underscores become hyphens and leading or trailing
#     hyphens are dropped first (the spec allows only a-z, 0-9 and single
#     hyphens). `root = ""` means the top level of src.
# Two skills with the same installed name fail evaluation.
#
# The directory listing reads the pinned source at evaluation time, so a
# pack that uses this needs its source in the store when the pack's skills
# are needed (when it is built or enabled); mkSkillPack keeps that lazy.
#
# Locks: listing a source at evaluation time is import from derivation, which
# `nix flake check` refuses and which makes every evaluation fetch and read the
# sources. So the result of findSkills is committed per pack in
# locks/<pack>.json and read from there; nixos/packages/skills/update-locks.sh
# regenerates the locks (with useLocks = false) after a source is bumped. A
# pack whose lock is missing fails with a message saying so.
{ lib, runCommand, pack ? null, useLocks ? true }:

let
  lockFile = ./locks + "/${pack}.json";
  locked = pack != null && useLocks;
in

rec {
  # renameSkills { pack, src, skills, rename, rewrite ? [ ], prune ? [ ] }
  #
  # Installs some skills of a discovered set under other names, to resolve a
  # name clash with another pack (prefix with the pack name). `rename` maps an
  # installed name to its new name; an entry mapping a name to itself copies the
  # skill unchanged, which lets `rewrite` also fix references inside it.
  # `rewrite` is a list of { from; to; } fixed strings replaced in the *.md files
  # of the copied skills (for example "`/retro`" -> "`/pack-retro`"). The
  # copies come from a small derived tree; the result is an attrset for
  # mkSkillPack in which those skills point at it.
  # `prune` is a list of paths (shell globs, relative to the tree, so
  # "<new skill name>/dir/*.mp3") deleted from the copies: files whose licence
  # does not allow redistribution.
  renameSkills =
    { pack, src, skills, rename, rewrite ? [ ], prune ? [ ] }:
    let
      olds = lib.attrNames rename;
      tree = runCommand "${pack}-renamed-skills" { } ''
        mkdir -p $out
        ${lib.concatMapStringsSep "\n" (old: ''
          cp -r --no-preserve=mode ${lib.escapeShellArg "${src}/${skills.${old}}"} $out/${lib.escapeShellArg rename.${old}}
        '') olds}
        ${lib.concatMapStringsSep "\n" (g: "rm -f $out/${g}") prune}
        ${lib.concatMapStringsSep "\n" (r: ''
          grep -rlZ --include='*.md' -F ${lib.escapeShellArg r.from} $out | xargs -0 -r sed -i ${lib.escapeShellArg "s|${lib.escapeRegex r.from}|${r.to}|g"} || true
        '') rewrite}
      '';
    in
    (removeAttrs skills olds)
    // lib.listToAttrs (map (old: lib.nameValuePair rename.${old} "${tree}/${rename.${old}}") olds);

  findSkills = args:
    if locked then
      (if builtins.pathExists lockFile then lib.importJSON lockFile
       else throw "skill pack ${pack}: no lock file locks/${pack}.json; run nixos/packages/skills/update-locks.sh")
    else findSkillsUnlocked args;

  findSkillsUnlocked =
    { src
    , roots ? [ "skills" ]
    , exclude ? [ ]
    , include ? [ ]
    , filter ? null
    , rename ? { }
    , prefix ? ""
    , normalize ? false
    }:
    let
      normalized = n:
        let s = builtins.replaceStrings [ "_" ] [ "-" ] n;
        in if normalize then builtins.head (builtins.match "-*(.*[^-])-*" s) else n;
      found = lib.concatMap
        (root:
          let
            base = if root == "" then "${src}" else "${src}/${root}";
            entries = builtins.readDir base;
            isSkill = dir: entries.${dir} == "directory"
              && builtins.pathExists "${base}/${dir}/SKILL.md";
            keep = dir:
              !(builtins.elem dir exclude || builtins.elem "${root}/${dir}" exclude)
              && (filter == null
              || builtins.elem dir include
              || filter dir (builtins.readFile "${base}/${dir}/SKILL.md"));
          in
          map
            (dir: {
              name = rename."${root}/${dir}" or rename.${dir} or "${prefix}${normalized dir}";
              value = if root == "" then dir else "${root}/${dir}";
            })
            (lib.filter (dir: isSkill dir && keep dir) (lib.attrNames entries)))
        roots;
      dup = lib.filter (n: lib.length (lib.filter (s: s.name == n) found) > 1) (map (s: s.name) found);
    in
    if dup != [ ] then
      throw "skill discovery: duplicate skill name(s) ${lib.concatStringsSep ", " (lib.unique dup)}"
    else
      lib.listToAttrs found;
}
