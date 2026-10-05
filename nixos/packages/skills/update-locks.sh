#!/usr/bin/env bash
# Regenerate nixos/packages/skills/locks/<pack>.json: what each pack's
# discover.findSkills call finds in its pinned source. Run it after changing a
# source in sources.nix or a pack's discovery arguments, and commit the locks.
# It reads the sources at evaluation time (import from derivation), so it
# fetches any that are not in the store yet.
#
#   nixos/packages/skills/update-locks.sh            # every pack that discovers
#   nixos/packages/skills/update-locks.sh gstack     # one pack
set -euo pipefail
cd "$(dirname "$0")/../../.."
exec python3 - "$@" <<'PY'
import json
import pathlib
import subprocess
import sys

root = pathlib.Path("nixos/packages/skills")
out = root / "locks"
out.mkdir(exist_ok=True)
packs = sys.argv[1:] or sorted(p.stem for p in (root / "packs").glob("*.nix")
                               if "findSkills" in p.read_text())

# The pack is evaluated with a mkSkillPack that only forces `skills`, and a
# findSkills that reports its unlocked result by aborting evaluation with it
# (the result before renameSkills or other changes made in the pack file).
EXPR = """
let
  # git+file copies only tracked files, so writing locks does not make new copies
  f = builtins.getFlake ("git+file://" + toString ./.);
  pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  lib = pkgs.lib;
  sources = pkgs.callPackage ./nixos/packages/skills/sources.nix { };
  d = import ./nixos/packages/skills/discover.nix { inherit (pkgs) lib runCommand; pack = "PACK"; useLocks = false; };
in
lib.callPackageWith (pkgs // {
  inherit sources;
  discover = d // { findSkills = args: throw ("NESTLO-LOCK:" + builtins.toJSON (d.findSkills args)); };
  mkSkillPack = a: builtins.seq a.skills null;
}) ./nixos/packages/skills/packs/PACK.nix { }
"""

for pack in packs:
    r = subprocess.run(["nix", "eval", "--option", "allow-import-from-derivation", "true",
                        "--impure", "--expr", EXPR.replace("PACK", pack)],
                       capture_output=True, text=True)
    i = r.stderr.find("NESTLO-LOCK:")
    if i < 0 and r.returncode == 0:
        print("%s: does not call findSkills, no lock needed" % pack)
        continue
    if i < 0:
        sys.exit("%s: no discovery result:\n%s" % (pack, r.stderr[-3000:]))
    data, _ = json.JSONDecoder().raw_decode(r.stderr[i + len("NESTLO-LOCK:"):])
    (out / ("%s.json" % pack)).write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    print("%s: %d skills" % (pack, len(data)))
PY
