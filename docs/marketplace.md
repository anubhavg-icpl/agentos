# Agent marketplace

A registry of community coding agents beyond the 15 built-ins, and `agentos-market` to install them.

```
agentos-market search kilo
agentos-market info mini-swe-agent
agentos-market install kilo
agentos spawn kilo --workspace api
agentos-market list-installed
agentos-market remove kilo
```

Enable it with `agentos.marketplace.enable = true;`. The registry is [`marketplace/index.json`](../marketplace/index.json), installed as `/etc/agentos/marketplace.json`.

## Entry format

Described by [`marketplace/index.schema.json`](../marketplace/index.schema.json) and enforced by `agentos-market validate` (which also runs in the unit tests and the platform VM test).

| Field | Meaning |
|:---|:---|
| `name` | Lower-case name for `install` and `spawn`. Must not collide with a built-in agent or another entry |
| `description`, `homepage` (https), `license`, `maintainers` | Metadata |
| `kind` | `nixpkgs`, `npm` or `pypi` |
| `package` | nixpkgs attribute, npm package or PyPI project |
| `version` | Pinned `x.y.z`. No ranges, tags or `latest`. For `nixpkgs` it is informational: the system's nixpkgs decides |
| `bin` | Main executable |
| `commands` | Optional. Executables the package provides (default `[bin]`, must include `bin`); each becomes a spawn name |

To add an agent, check that the package exists at the pinned version, that it is a coding-agent CLI, and run `agentos-market validate --index marketplace/index.json`.

## How installing works

- `nixpkgs`: `nix profile install nixpkgs#<package>`.
- `npm` / `pypi`: a small flake with a pinned launcher (`npx --package=pkg@version`, or `uvx --from pkg==version`), like the built-in launchers, is written to `~/.local/share/agentos/market/<name>/` and installed with `nix profile install`. The code itself is fetched from npm or PyPI on first run, outside Nix's reproducibility guarantees.
- `--dry-run` prints the flake and the command without changing anything.

## Making installed agents spawnable

`agentos spawn` reads agents from `/etc/agentos/runtime.json`. Marketplace installs add an operator-writable extension: one file per package in `/var/lib/agentos/agents.d/` (created by the module, `root:agentos`, mode 2775, so operators can write and the sandboxed `agentos-agent` user cannot).

```json
{
  "agents": {
    "kilo": "/nix/store/...-kilo-7.8.1/bin/kilo",
    "kilocode": "/nix/store/...-kilo-7.8.1/bin/kilocode"
  },
  "marketplace": { "name": "kilo", "kind": "npm", "package": "@kilocode/cli",
                   "version": "7.8.1", "profile_element": "kilo" }
}
```

`agents` maps a spawn name to an absolute command path. Only paths under `/nix/store` or `/run/current-system` may be used. `marketplace` is metadata for `list-installed` and `remove`; hand-written files can omit it.

### Change needed in `agentos spawn`

`cmd_spawn` in `nixos/packages/cli.nix` must consult `agents.d` when the name is not in `runtime.json`:

```bash
AGENTS_D=/var/lib/agentos/agents.d
extension_agent() {
  local f path
  for f in "$AGENTS_D"/*.json; do
    [ -e "$f" ] || continue
    path=$(jq -r --arg a "$1" '.agents[$a] // empty' "$f" 2>/dev/null) || continue
    if [[ "$path" =~ ^(/nix/store|/run/current-system)/[^[:space:]]+$ && "$path" != *..* && -x "$path" ]]; then
      echo "$path"
      return
    fi
  done
}
```

and in `cmd_spawn`, replace

```bash
command=$(jq -r --arg a "$agent" '.agents[$a] // empty' "$RUNTIME")
[ -n "$command" ] || die "Unknown agent: $agent (see: agentos agents)"
cmd_path=$(command -v "$command") || die "$command is not installed"
```

with

```bash
command=$(jq -r --arg a "$agent" '.agents[$a] // empty' "$RUNTIME")
if [ -n "$command" ]; then
  cmd_path=$(command -v "$command") || die "$command is not installed"
else
  cmd_path=$(extension_agent "$agent")
  [ -n "$cmd_path" ] || die "Unknown agent: $agent (see: agentos agents)"
  command="$cmd_path"
fi
```

`cmd_agents` can list the extension files the same way.
