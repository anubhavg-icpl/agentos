# agentos-skills: inspect the skill packs installed by agentos.skills.
#
#   agentos-skills list [--all]    packs, skills, tools, MCP servers, licenses
#                                  (long skill lists are cut at 40; --all shows every name)
#   agentos-skills list --collections   enabled packs grouped by collection
#   agentos-skills doctor          per user and target: links present or broken
#   agentos-skills path <skill>    store path of a skill
#
# Reads /etc/agentos/skills.json (written by the module; override with
# AGENTOS_SKILLS_CONFIG): { bundle, users = [ { name, home } ], targets = { name = dir; } }.
{ writeShellApplication, jq, coreutils }:

writeShellApplication {
  name = "agentos-skills";
  runtimeInputs = [ jq coreutils ];
  text = ''
    conf="''${AGENTOS_SKILLS_CONFIG:-/etc/agentos/skills.json}"
    if [ ! -r "$conf" ]; then
      echo "agentos-skills: $conf not found; set agentos.skills.enable = true" >&2
      exit 2
    fi
    bundle=$(jq -r .bundle "$conf")

    cmd_list() {
      all=false
      collections=false
      for a in "$@"; do
        case "$a" in
          --all) all=true ;;
          --collections) collections=true ;;
          *) echo "usage: agentos-skills list [--all] [--collections]" >&2; exit 2 ;;
        esac
      done
      if [ "$collections" = true ]; then
        jq -r '
          [ .packs[] | . as $p | ((.collections // []) | if length == 0 then ["(none)"] else . end)[]
            | { c: ., pack: $p.pack, n: ($p.skills | length) } ]
          | group_by(.c)[]
          | "\(.[0].c)  (\(map(.n) | add) skills)",
            (.[] | "  \(.pack) (\(.n))"),
            ""
        ' "$bundle/manifest.json"
        return
      fi
      jq -r --argjson all "$all" '
        .packs[] |
        (.skills | length) as $n |
        "\(.pack) \(.version)  [\(.license)]",
        "  \(.description)",
        (if (.collections // []) | length > 0 then "  collections: \(.collections | join(", "))" else empty end),
        "  skills (\($n)): \(if $n > 40 and ($all | not) then (.skills[:40] | join(", ")) + ", ... (+\($n - 40) more; agentos-skills list --all)" else .skills | join(", ") end)",
        "  tools:  \(if (.tools | length) > 0 then .tools | join(", ") else "-" end)",
        "  mcp:    \(if (.mcp | length) > 0 then .mcp | keys | join(", ") else "-" end)",
        (if .notes != "" then "  notes:  \(.notes | rtrimstr("\n") | gsub("\n"; "\n          "))" else empty end),
        ""
      ' "$bundle/manifest.json"
    }

    cmd_path() {
      if [ $# -ne 1 ]; then
        echo "usage: agentos-skills path <skill>" >&2
        exit 2
      fi
      if [ ! -e "$bundle/skills/$1" ]; then
        echo "agentos-skills: no skill named $1" >&2
        exit 1
      fi
      readlink -f "$bundle/skills/$1"
    }

    cmd_doctor() {
      bad=0
      nskills=$(find "$bundle/skills" -mindepth 1 -maxdepth 1 | wc -l)
      echo "bundle: $bundle ($nskills skills)"
      while IFS=$'\t' read -r user home; do
        while IFS=$'\t' read -r target dir; do
          ok=0 missing=0 broken=0 other=0
          for entry in "$bundle"/skills/*; do
            [ -L "$entry" ] || continue
            skill=$(basename "$entry")
            link="$home/$dir/$skill"
            if [ -L "$link" ]; then
              if [ ! -e "$link" ]; then
                broken=$((broken + 1)); echo "  broken:  $link"
              elif [ "$(readlink "$link")" = "$bundle/skills/$skill" ]; then
                ok=$((ok + 1))
              else
                other=$((other + 1)); echo "  not ours or outdated: $link -> $(readlink "$link")"
              fi
            elif [ -e "$link" ]; then
              other=$((other + 1)); echo "  user-created, left alone: $link"
            else
              missing=$((missing + 1)); echo "  missing: $link"
            fi
          done
          echo "$user $target ($home/$dir): $ok ok, $missing missing, $broken broken, $other other"
          if [ "$missing" -gt 0 ] || [ "$broken" -gt 0 ]; then bad=1; fi
        done < <(jq -r '.targets | to_entries[] | [.key, .value] | @tsv' "$conf")
      done < <(jq -r '.users[] | [.name, .home] | @tsv' "$conf")
      if [ "$bad" -ne 0 ]; then
        echo "some links are missing or broken; try: systemctl restart 'agentos-skills-link-*'" >&2
      fi
      exit "$bad"
    }

    case "''${1:-list}" in
      list) shift; cmd_list "$@" ;;
      doctor) cmd_doctor ;;
      path) shift; cmd_path "$@" ;;
      *)
        echo "usage: agentos-skills <list [--all] [--collections]|doctor|path <skill>>" >&2
        exit 2
        ;;
    esac
  '';
}
