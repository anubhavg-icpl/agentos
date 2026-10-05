"""nestlo-market: a registry of community coding agents beyond the built-in 15.

The registry is marketplace/index.json in the repository (installed to
/etc/nestlo/marketplace.json). Entry format: docs/marketplace.md and
marketplace/index.schema.json.

Installing an entry:
  npm / pypi   a small flake with a pinned launcher (npx / uvx, like the
               built-in launchers) is written to ~/.local/share/nestlo/market/
               <name>/ and installed into the operator's nix profile
  nixpkgs      `nix profile install nixpkgs#<package>`
Then the agent is made spawnable by writing /var/lib/nestlo/agents.d/<name>.json:

  {"agents": {"<spawn name>": "/nix/store/...-x/bin/<cmd>", ...},
   "marketplace": {"name": ..., "kind": ..., "version": ..., "package": ...,
                   "profile_element": ...}}

`nestlo spawn` looks a name up in /etc/nestlo/runtime.json first and in
agents.d second. Only absolute paths under /nix/store or /run/current-system
are honoured, and agents.d is not writable by the sandboxed agent user.
"""

import argparse
import json
import os
import platform
import re
import shlex
import subprocess
import sys

DEFAULT_INDEX = "/etc/nestlo/marketplace.json"
DEFAULT_AGENTS_D = "/var/lib/nestlo/agents.d"

KINDS = ("nixpkgs", "npm", "pypi")
FIELDS_REQUIRED = ("name", "description", "homepage", "license", "kind", "package", "version", "bin", "maintainers")
FIELDS_OPTIONAL = ("commands",)

# Names `nestlo spawn` already knows (modules/runtime/default.nix)
BUILTIN = frozenset("""
claude claude-code codex aider agy antigravity antigravity-cli gemini gemini-cli qwen qwen-code amp goose opencode crush
cursor cursor-agent copilot grok grok-cli interpreter open-interpreter droid factory-droid cline cn continue
""".split())

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,39}$")
CMD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+.][0-9A-Za-z][0-9A-Za-z.+-]*)?$")
PACKAGE_RE = {
    "npm": re.compile(r"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"),
    "pypi": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$"),
    "nixpkgs": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"),
}
URL_RE = re.compile(r"^https://[A-Za-z0-9][A-Za-z0-9.-]*(?::\d+)?(?:/[^\s]*)?$")
STORE_PATH_RE = re.compile(r"^(?:/nix/store|/run/current-system)/[^\s]+$")


class MarketError(Exception):
    pass


# ── index ─────────────────────────────────────────────────────────────────
def spawn_names(entry):
    return [entry["name"]] + [c for c in entry.get("commands", [entry["bin"]]) if c != entry["name"]]


def validate_index(index):
    """List of problems found in a parsed index (empty when valid)."""
    if not isinstance(index, dict) or not isinstance(index.get("agents"), list):
        return ['top level must be an object with an "agents" list']
    errors, seen = [], {}
    for pos, entry in enumerate(index["agents"]):
        label = "agents[%d]" % pos
        if not isinstance(entry, dict):
            errors.append("%s: must be an object" % label)
            continue
        label = "%s (%s)" % (label, entry.get("name"))
        for key in FIELDS_REQUIRED:
            if key not in entry:
                errors.append("%s: missing %r" % (label, key))
        for key in entry:
            if key not in FIELDS_REQUIRED + FIELDS_OPTIONAL:
                errors.append("%s: unknown field %r" % (label, key))
        if any(k not in entry for k in FIELDS_REQUIRED):
            continue
        for key in ("description", "homepage", "license", "package", "version", "bin", "name", "kind"):
            if not isinstance(entry[key], str) or not entry[key].strip():
                errors.append("%s: %r must be a non-empty string" % (label, key))
        if any(not isinstance(entry[k], str) for k in ("name", "kind", "package", "version", "bin", "homepage")):
            continue
        if not NAME_RE.match(entry["name"]):
            errors.append("%s: name must match %s" % (label, NAME_RE.pattern))
        if entry["kind"] not in KINDS:
            errors.append("%s: kind must be one of %s" % (label, ", ".join(KINDS)))
        elif not PACKAGE_RE[entry["kind"]].match(entry["package"]):
            errors.append("%s: invalid %s package name %r" % (label, entry["kind"], entry["package"]))
        if not VERSION_RE.match(entry["version"]):
            errors.append("%s: version %r is not a pinned x.y.z version (no ranges, tags or 'latest')" % (label, entry["version"]))
        if not URL_RE.match(entry["homepage"]):
            errors.append("%s: homepage must be an https URL" % label)
        if isinstance(entry["description"], str) and len(entry["description"]) > 200:
            errors.append("%s: description is longer than 200 characters" % label)
        if not CMD_RE.match(entry["bin"]):
            errors.append("%s: invalid bin %r" % (label, entry["bin"]))
        commands = entry.get("commands", [entry["bin"]])
        if not (isinstance(commands, list) and commands and all(isinstance(c, str) and CMD_RE.match(c) for c in commands)):
            errors.append('%s: "commands" must be a non-empty list of executable names' % label)
            continue
        if entry["bin"] not in commands:
            errors.append('%s: "commands" must include bin %r' % (label, entry["bin"]))
        m = entry["maintainers"]
        if not (isinstance(m, list) and m and all(isinstance(x, str) and x.strip() for x in m)):
            errors.append("%s: maintainers must be a non-empty list of strings" % label)
        for n in spawn_names(entry):
            if n in BUILTIN:
                errors.append("%s: %r collides with a built-in agent name" % (label, n))
            elif n in seen and seen[n] != entry["name"]:
                errors.append("%s: %r is already used by %r" % (label, n, seen[n]))
            elif n in seen and n == entry["name"]:
                errors.append("%s: duplicate name" % label)
            seen.setdefault(n, entry["name"])
    return errors


def index_path(override=None):
    return override or os.environ.get("NESTLO_MARKET_INDEX", DEFAULT_INDEX)


def load_index(path=None):
    path = index_path(path)
    try:
        with open(path) as f:
            index = json.load(f)
    except (OSError, ValueError) as exc:
        raise MarketError("cannot read marketplace index %s: %s" % (path, exc))
    errors = validate_index(index)
    if errors:
        raise MarketError("invalid marketplace index %s:\n  %s" % (path, "\n  ".join(errors)))
    return index["agents"]


def find(entries, name):
    for e in entries:
        if e["name"] == name or name in e.get("commands", []):
            return e
    raise MarketError("no such agent %r (see: nestlo-market search)" % name)


# ── launcher flake ────────────────────────────────────────────────────────
NIX_SYSTEMS = {"x86_64": "x86_64-linux", "amd64": "x86_64-linux", "aarch64": "aarch64-linux", "arm64": "aarch64-linux"}

FLAKE = """\
# Generated by nestlo-market for {name} ({kind}: {package} {version}). Do not edit.
{{
  description = "Nestlo marketplace launcher: {name}";
  inputs.nixpkgs.url = "nixpkgs";
  outputs = {{ self, nixpkgs }}:
    let
      system = "{system}";
      pkgs = nixpkgs.legacyPackages.${{system}};
      tools = with pkgs; [ git ripgrep fd curl jq gnutar gzip unzip coreutils bash ];
    in
    {{
      packages.${{system}}."{name}" = pkgs.stdenvNoCC.mkDerivation {{
        pname = "{name}";
        version = "{version}";
        dontUnpack = true;
        nativeBuildInputs = [ pkgs.makeWrapper ];
        installPhase = ''
          mkdir -p $out/bin
{wrappers}
        '';
        meta.mainProgram = "{bin}";
      }};
    }};
}}
"""

NPM_WRAPPER = """\
          makeWrapper ${{pkgs.nodejs_22}}/bin/npx $out/bin/{cmd} \\
            --add-flags "--yes --package={package}@{version} -- {cmd}" \\
            --prefix PATH : ${{pkgs.lib.makeBinPath (tools ++ [ pkgs.nodejs_22 ])}}"""

PYPI_WRAPPER = """\
          makeWrapper ${{pkgs.uv}}/bin/uvx $out/bin/{cmd} \\
            --set UV_PYTHON_DOWNLOADS never \\
            --prefix LD_LIBRARY_PATH : ${{pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ]}} \\
            --add-flags "--python ${{pkgs.python312}}/bin/python3 --from {package}=={version} {cmd}" \\
            --prefix PATH : ${{pkgs.lib.makeBinPath tools}}"""


def render_flake(entry, system=None):
    if entry["kind"] not in ("npm", "pypi"):
        raise MarketError("only npm and pypi entries use a generated flake")
    system = system or NIX_SYSTEMS.get(platform.machine().lower())
    if not system:
        raise MarketError("unsupported CPU architecture %s" % platform.machine())
    template = NPM_WRAPPER if entry["kind"] == "npm" else PYPI_WRAPPER
    commands = entry.get("commands", [entry["bin"]])
    wrappers = "\n".join(template.format(cmd=c, package=entry["package"], version=entry["version"]) for c in commands)
    return FLAKE.format(name=entry["name"], kind=entry["kind"], package=entry["package"],
                        version=entry["version"], bin=entry["bin"], system=system, wrappers=wrappers)


# ── install / remove ──────────────────────────────────────────────────────
def agents_d():
    return os.environ.get("NESTLO_AGENTS_D", DEFAULT_AGENTS_D)


def market_home():
    base = os.environ.get("NESTLO_MARKET_HOME")
    if base:
        return base
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(data, "nestlo", "market")


def nix(*args, capture=False):
    argv = shlex.split(os.environ.get("NESTLO_MARKET_NIX", "nix")) + ["--extra-experimental-features", "nix-command flakes"] + list(args)
    try:
        proc = subprocess.run(argv, text=True, stdout=subprocess.PIPE if capture else None)
    except OSError as exc:
        raise MarketError("cannot run nix: %s" % exc)
    if proc.returncode != 0:
        raise MarketError("`nix %s` failed (exit %d)" % (" ".join(args[:2]), proc.returncode))
    return proc.stdout


def profile_element(entry):
    return entry["package"] if entry["kind"] == "nixpkgs" else entry["name"]


def registration(entry, out_path):
    """The agents.d document for an installed entry."""
    agents = {}
    for cmd in entry.get("commands", [entry["bin"]]):
        agents[cmd] = os.path.join(out_path, "bin", cmd)
    agents[entry["name"]] = os.path.join(out_path, "bin", entry["bin"])
    for name, path in agents.items():
        if not STORE_PATH_RE.match(path):
            raise MarketError("refusing to register %s: %s is not under /nix/store" % (name, path))
    return {
        "agents": agents,
        "marketplace": {k: entry[k] for k in ("name", "kind", "package", "version")}
        | {"profile_element": profile_element(entry)},
    }


def write_registration(entry, doc):
    directory = agents_d()
    path = os.path.join(directory, entry["name"] + ".json")
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2, sort_keys=True)
            f.write("\n")
        os.chmod(tmp, 0o664)
        os.replace(tmp, path)
    except OSError as exc:
        raise MarketError("cannot write %s: %s (operators need the nestlo group)" % (path, exc))
    return path


def install(entry, dry_run=False):
    if entry["kind"] == "nixpkgs":
        flake_ref = "nixpkgs#" + entry["package"]
        flake_src = None
    else:
        flake_src = render_flake(entry)
        directory = os.path.join(market_home(), entry["name"])
        flake_ref = "path:%s#%s" % (directory, entry["name"])
    if dry_run:
        if flake_src:
            print(flake_src, end="")
        print("would run: nix profile install %s" % flake_ref)
        return
    if flake_src:
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "flake.nix"), "w") as f:
            f.write(flake_src)
    out = nix("build", "--no-link", "--print-out-paths", flake_ref, capture=True).split()
    if not out:
        raise MarketError("nix build produced no output for %s" % flake_ref)
    doc = registration(entry, out[0])
    binary = doc["agents"][entry["name"]]
    if not os.access(binary, os.X_OK):
        raise MarketError("%s does not provide an executable %s" % (entry["package"], binary))
    try:  # replace an earlier install of the same element
        nix("profile", "remove", profile_element(entry))
    except MarketError:
        pass
    nix("profile", "install", flake_ref)
    path = write_registration(entry, doc)
    print("installed %s %s" % (entry["name"], entry["version"]))
    print("spawn it with: nestlo spawn %s" % entry["name"])
    print("registered in %s" % path)


def installed():
    directory = agents_d()
    out = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return out
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(directory, n)) as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(doc, dict) and isinstance(doc.get("marketplace"), dict):
            out.append(doc)
    return out


def remove(name):
    docs = {d["marketplace"]["name"]: d for d in installed()}
    if name not in docs:
        raise MarketError("%s is not installed from the marketplace" % name)
    meta = docs[name]["marketplace"]
    element = meta.get("profile_element", name)
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", element):
        raise MarketError("invalid profile element %r in %s" % (element, name))
    try:
        nix("profile", "remove", element)
    except MarketError as exc:
        print("warning: %s (already removed?)" % exc, file=sys.stderr)
    path = os.path.join(agents_d(), name + ".json")
    try:
        os.unlink(path)
    except OSError as exc:
        raise MarketError("cannot remove %s: %s" % (path, exc))
    flake_dir = os.path.join(market_home(), name)
    for f in ("flake.nix", "flake.lock"):
        try:
            os.unlink(os.path.join(flake_dir, f))
        except OSError:
            pass
    try:
        os.rmdir(flake_dir)
    except OSError:
        pass
    print("removed %s" % name)


# ── commands ──────────────────────────────────────────────────────────────
def table(rows, header):
    rows = [[str(c) for c in r] for r in rows]
    widths = [max([len(header[i])] + [len(r[i]) for r in rows]) for i in range(len(header))]
    lines = ["  ".join(h.ljust(w) for h, w in zip(header, widths)).rstrip()]
    lines += ["  ".join(c.ljust(w) for c, w in zip(r, widths)).rstrip() for r in rows]
    return "\n".join(lines)


def cmd_search(args):
    q = " ".join(args.query).lower()
    hits = [e for e in load_index(args.index)
            if not q or q in " ".join([e["name"], e["description"], e["package"]] + e.get("commands", [])).lower()]
    if args.json:
        print(json.dumps(hits, indent=2))
    elif hits:
        print(table([[e["name"], e["kind"], e["version"], e["description"]] for e in hits],
                    ["NAME", "KIND", "VERSION", "DESCRIPTION"]))
    else:
        print("no agents match %r" % q)


def cmd_info(args):
    e = find(load_index(args.index), args.name)
    if args.json:
        print(json.dumps(e, indent=2))
        return
    print("%s - %s" % (e["name"], e["description"]))
    for label, value in (("kind", e["kind"]), ("package", "%s@%s" % (e["package"], e["version"])),
                         ("commands", ", ".join(e.get("commands", [e["bin"]]))), ("license", e["license"]),
                         ("homepage", e["homepage"]), ("maintainers", ", ".join(e["maintainers"]))):
        print("  %-12s %s" % (label, value))
    if e["kind"] != "nixpkgs":
        print("  note         fetched from %s on first run (not content-addressed)" % ("npm" if e["kind"] == "npm" else "PyPI"))


def cmd_install(args):
    install(find(load_index(args.index), args.name), args.dry_run)


def cmd_list_installed(args):
    docs = installed()
    if args.json:
        print(json.dumps([d["marketplace"] | {"agents": d["agents"]} for d in docs], indent=2))
    elif docs:
        print(table([[d["marketplace"]["name"], d["marketplace"]["kind"], d["marketplace"]["version"],
                      ", ".join(sorted(d["agents"]))] for d in docs], ["NAME", "KIND", "VERSION", "SPAWN NAMES"]))
    else:
        print("nothing installed from the marketplace")


def cmd_remove(args):
    remove(args.name)


def cmd_validate(args):
    path = index_path(args.index)
    try:
        with open(path) as f:
            errors = validate_index(json.load(f))
    except (OSError, ValueError) as exc:
        raise MarketError("cannot read %s: %s" % (path, exc))
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("%s: ok" % path)


def build_parser():
    p = argparse.ArgumentParser(prog="nestlo-market", description="Community coding agents for Nestlo")
    p.add_argument("--index", default=None, help="index file (default %s)" % DEFAULT_INDEX)
    sub = p.add_subparsers(dest="command", required=True)
    a = sub.add_parser("search", help="search the registry")
    a.add_argument("query", nargs="*")
    a.add_argument("--json", action="store_true")
    a.set_defaults(fn=cmd_search)
    a = sub.add_parser("info", help="show one entry")
    a.add_argument("name")
    a.add_argument("--json", action="store_true")
    a.set_defaults(fn=cmd_info)
    a = sub.add_parser("install", help="install an agent and make it spawnable")
    a.add_argument("name")
    a.add_argument("--dry-run", action="store_true", help="print what would be installed")
    a.set_defaults(fn=cmd_install)
    a = sub.add_parser("list-installed", aliases=["installed"], help="agents installed from the registry")
    a.add_argument("--json", action="store_true")
    a.set_defaults(fn=cmd_list_installed)
    a = sub.add_parser("remove", aliases=["rm"], help="uninstall an agent")
    a.add_argument("name")
    a.set_defaults(fn=cmd_remove)
    a = sub.add_parser("validate", help="check an index file")
    a.set_defaults(fn=cmd_validate)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.fn(args) or 0
    except MarketError as exc:
        print("nestlo-market: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
