# mkSkillBundle: every skill of the given packs flattened into one store
# directory, so nestlo.skills can link <skill> -> bundle/skills/<skill> into
# each CLI's skills directory.
#
#   $out/skills/<skill>     symlink to the pack's skill directory
#   $out/manifest.json      { packs = [ <pack.json of each pack> ]; }
#
# The build fails when two packs ship a skill with the same name.
{ lib, runCommand, jq }:

packs:

runCommand "nestlo-skills-bundle" { nativeBuildInputs = [ jq ]; } ''
  mkdir -p $out/skills owners
  : > pack-files
  for pack in ${lib.concatMapStringsSep " " (p: "${p}") packs}; do
    for meta in "$pack"/share/nestlo/skills/*/pack.json; do
      [ -e "$meta" ] || continue
      root=$(dirname "$meta")
      name=$(basename "$root")
      echo "$meta" >> pack-files
      for dir in "$root"/*/; do
        skill=$(basename "$dir")
        if [ -e "owners/$skill" ]; then
          echo "skill name collision: '$skill' is provided by the packs '$(cat "owners/$skill")' and '$name'" >&2
          echo "disable one of them (nestlo.skills.packs.<name>.enable = false)" >&2
          exit 1
        fi
        echo "$name" > "owners/$skill"
        ln -s "$root/$skill" "$out/skills/$skill"
      done
    done
  done
  xargs -r cat < pack-files | jq -s '{ packs: . }' > $out/manifest.json
''
