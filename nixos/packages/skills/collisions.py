#!/usr/bin/env python3
"""Collision analysis of the AgentOS skill packs.

    python3 nixos/packages/skills/collisions.py [--system x86_64-linux] [--flake .]

Evaluates every `skills-<pack>` package of the flake (skill name -> directory
in the pinned source; the sources must be in the store, no pack is built, only
small derived source trees are) and
reports:

  1. name collisions: a skill directory name installed by more than one pack.
     agentos.skills fails to evaluate when two enabled packs share a name, and
     `agentos.skills.enableAll` enables every pack, so this must be empty.
  2. duplicates: the same SKILL.md text installed under different names or by
     different packs (candidates to drop from the less canonical pack).
  3. per-pack skill counts, and the total.

Exit status 1 when there is a name collision.
"""
import argparse
import collections
import hashlib
import json
import os
import subprocess
import sys

APPLY = r"""
ps: builtins.listToAttrs (map
  (n: { name = builtins.substring 7 (-1) n; value = {
          skills = ps.${n}.skillDirs;
          src = "${ps.${n}.src}";
          drvs = builtins.attrNames (builtins.foldl' (a: d: a // builtins.getContext d) { }
                   (builtins.attrValues ps.${n}.skillDirs ++ [ "${ps.${n}.src}" ]));
          collections = ps.${n}.collections;
          enable = ps.${n}.defaultEnable; }; })
  (builtins.filter (n: builtins.substring 0 7 n == "skills-") (builtins.attrNames ps)))
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--system", default="x86_64-linux")
    ap.add_argument("--flake", default=".")
    args = ap.parse_args()

    run = subprocess.run(
        ["nix", "eval", "--json", "%s#packages.%s" % (args.flake, args.system), "--apply", APPLY],
        capture_output=True, text=True,
    )
    if run.returncode != 0:
        sys.stderr.write(run.stderr)
        return 2
    out = run.stdout
    packs = json.loads(out)

    owners = collections.defaultdict(list)       # skill name -> [pack]
    by_text = collections.defaultdict(list)      # sha256(SKILL.md) -> [(pack, skill)]
    counts = {}
    for pack, info in sorted(packs.items()):
        counts[pack] = len(info["skills"])
        realised = False
        for skill, d in info["skills"].items():
            owners[skill].append(pack)
            if not realised:
                # derived source trees (renamed skills, a prefixed copy): build them
                for drv in info["drvs"]:
                    subprocess.run(["nix-store", "--option", "sandbox", "true", "--realise", drv],
                                   check=True, capture_output=True)
                realised = True
            path = d if d.startswith("/") else os.path.join(info["src"], d)
            path = os.path.join(path, "SKILL.md")
            with open(path, "rb") as f:
                text = f.read()
            by_text[hashlib.sha256(text).hexdigest()].append((pack, skill))

    collisions = {s: p for s, p in owners.items() if len(p) > 1}
    dups = [v for v in by_text.values() if len(v) > 1]

    print("packs: %d, skills: %d" % (len(packs), sum(counts.values())))
    for pack in sorted(counts):
        info = packs[pack]
        print("  %-32s %4d  %s%s" % (
            pack, counts[pack], ",".join(info["collections"]) or "-", "" if info["enable"] else "  (opt-in)"))
    print()
    if collisions:
        print("NAME COLLISIONS (%d):" % len(collisions))
        for s, p in sorted(collisions.items()):
            print("  %s: %s" % (s, ", ".join(p)))
    else:
        print("name collisions: none (every pack can be enabled at once)")
    print()
    if dups:
        print("IDENTICAL SKILL.md installed more than once (%d groups):" % len(dups))
        for group in dups:
            print("  " + "; ".join("%s/%s" % g for g in group))
    else:
        print("identical SKILL.md under several names: none")
    return 1 if collisions else 0


if __name__ == "__main__":
    sys.exit(main())
