# Check of the skill packs without a VM.
#
#   nix build .#checks.x86_64-linux.skills-eval
#
# Builds every pack in nixos/packages/skills and the combined bundle of all
# of them (which fails on a skill name provided by two packs), then checks:
#   - every skill directory has a SKILL.md with YAML front matter holding a
#     non-empty `name` and a `description`
#   - no two packs ship a skill of the same name
#   - each pack.json parses, names its pack, and lists exactly the skills
#     the pack ships; license and description are set
#   - the bundle has one link per skill and its manifest lists every pack
#   - tools named in pack.json exist in the pack's bin/
{ pkgs, packs }:

let
  inherit (pkgs) lib;
  list = lib.attrValues packs;
  bundle = pkgs.callPackage ../nixos/packages/skills/bundle.nix { } list;
in
pkgs.runCommand "agentos-skills-eval"
{
  nativeBuildInputs = [ pkgs.jq pkgs.gnugrep pkgs.gawk ];
  inherit bundle;
  packs = map (p: "${p}") list;
}
  ''
    fail() { echo "FAIL: $*" >&2; exit 1; }
    declare -A seen
    npacks=0
    nskills=0

    for pack in $packs; do
      for meta in "$pack"/share/agentos/skills/*/pack.json; do
        [ -e "$meta" ] || fail "$pack has no pack.json"
        root=$(dirname "$meta")
        pname=$(basename "$root")
        npacks=$((npacks + 1))

        jq -e --arg p "$pname" '
          .pack == $p
          and (.version | type == "string" and length > 0)
          and (.license | type == "string" and length > 0)
          and (.description | type == "string" and length > 0)
          and (.homepage | type == "string" and length > 0)
          and (.skills | type == "array" and length > 0)
          and (.tools | type == "array")
          and (.mcp | type == "object")
        ' "$meta" > /dev/null || fail "$pname: pack.json is invalid"

        want=$(jq -r '.skills | sort | .[]' "$meta")
        have=$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
        [ "$want" = "$have" ] || fail "$pname: pack.json lists [$want] but the pack ships [$have]"

        for t in $(jq -r '.tools[]' "$meta"); do
          [ -e "$pack/bin/$t" ] || fail "$pname: tool $t is not in $pack/bin"
        done

        for dir in "$root"/*/; do
          skill=$(basename "$dir")
          file="$dir/SKILL.md"
          [ -f "$file" ] || fail "$pname/$skill: no SKILL.md"
          if [ -n "''${seen[$skill]:-}" ]; then
            fail "skill name collision: $skill is in ''${seen[$skill]} and $pname"
          fi
          seen[$skill]=$pname

          [ "$(head -1 "$file")" = "---" ] || fail "$pname/$skill: SKILL.md has no front matter"
          front=$(awk 'NR > 1 && /^---[[:space:]]*$/ { exit } NR > 1 { print }' "$file")
          [ -n "$front" ] || fail "$pname/$skill: front matter is empty or not closed"
          name=$(printf '%s\n' "$front" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d "\"'")
          [ -n "$name" ] || fail "$pname/$skill: front matter has no name"
          printf '%s\n' "$front" | grep -q '^description:' || fail "$pname/$skill: front matter has no description"
          nskills=$((nskills + 1))
        done
      done
    done

    # bundle: one link per skill, manifest covers every pack
    [ "$(find "$bundle/skills" -mindepth 1 -maxdepth 1 -type l | wc -l)" -eq "$nskills" ] \
      || fail "bundle has a different number of skills than the packs ($nskills)"
    for l in "$bundle"/skills/*; do
      [ -f "$l/SKILL.md" ] || fail "bundle link $l does not reach a SKILL.md"
    done
    [ "$(jq '.packs | length' "$bundle/manifest.json")" -eq "$npacks" ] \
      || fail "bundle manifest does not list all $npacks packs"

    echo "$npacks packs, $nskills skills, no collisions"
    touch $out
  ''
