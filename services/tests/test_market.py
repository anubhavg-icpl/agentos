import copy
import json
import os
import re
import shlex
import stat
import sys

import pytest

from nestlo_services import market

REPO_INDEX = os.path.join(os.path.dirname(__file__), "..", "..", "marketplace", "index.json")

VALID = {
    "name": "kilo", "description": "Kilo", "homepage": "https://example.org/kilo", "license": "MIT",
    "kind": "npm", "package": "@kilocode/cli", "version": "7.8.1", "bin": "kilo",
    "commands": ["kilo", "kilocode"], "maintainers": ["someone"],
}


def entry(**changes):
    e = copy.deepcopy(VALID)
    e.update(changes)
    return e


def errors(*entries):
    return market.validate_index({"agents": list(entries)})


def test_valid_entry():
    assert errors(VALID) == []


@pytest.mark.parametrize("changes,fragment", [
    ({"name": "Bad_Name"}, "name must match"),
    ({"name": "1abc"}, "name must match"),
    ({"name": "claude"}, "built-in"),
    ({"name": "cursor-agent"}, "built-in"),
    ({"commands": ["kilo", "codex"]}, "built-in"),
    ({"kind": "cargo"}, "kind must be one of"),
    ({"version": "latest"}, "pinned"),
    ({"version": "^1.2.3"}, "pinned"),
    ({"version": "1.2"}, "pinned"),
    ({"homepage": "http://example.org"}, "https"),
    ({"package": "Bad Package"}, "invalid npm package"),
    ({"package": "x;rm -rf"}, "invalid npm package"),
    ({"bin": "-oops"}, "invalid bin"),
    ({"commands": ["kilocode"]}, "must include bin"),
    ({"commands": []}, "non-empty list"),
    ({"maintainers": []}, "maintainers"),
    ({"description": "x" * 201}, "200 characters"),
    ({"description": ""}, "non-empty"),
    ({"surprise": 1}, "unknown field"),
])
def test_invalid_entries(changes, fragment):
    found = errors(entry(**changes))
    assert any(fragment in e for e in found), found


def test_missing_field():
    e = entry()
    del e["license"]
    assert any("missing 'license'" in x for x in errors(e))


def test_duplicates_and_command_clashes():
    assert any("duplicate" in e for e in errors(VALID, entry()))
    other = entry(name="other", commands=["other", "kilocode"], bin="other")
    assert any("already used" in e for e in errors(VALID, other))
    # an entry's own name may equal one of its commands
    assert errors(entry(name="mini", commands=["mini"], bin="mini")) == []


def test_pypi_and_nixpkgs_packages():
    assert errors(entry(kind="pypi", package="mini-swe-agent")) == []
    assert errors(entry(kind="nixpkgs", package="mistral-vibe")) == []
    assert errors(entry(kind="pypi", package="@scoped/pkg"))


def test_bad_top_level():
    assert market.validate_index([]) 
    assert market.validate_index({"agents": {}})


@pytest.mark.skipif(not os.path.exists(REPO_INDEX), reason="repository index not available (package build)")
def test_repository_index_is_valid():
    with open(REPO_INDEX) as f:
        index = json.load(f)
    assert market.validate_index(index) == []
    kinds = {e["kind"] for e in index["agents"]}
    assert kinds <= set(market.KINDS) and len(index["agents"]) >= 5
    # matches the JSON schema's structure
    schema_path = os.path.join(os.path.dirname(REPO_INDEX), "index.schema.json")
    with open(schema_path) as f:
        schema = json.load(f)
    agent = schema["definitions"]["agent"]
    assert set(agent["required"]) == set(market.FIELDS_REQUIRED)
    assert set(agent["properties"]) == set(market.FIELDS_REQUIRED) | set(market.FIELDS_OPTIONAL)
    assert re.match(agent["properties"]["version"]["pattern"], "1.2.3")
    for e in index["agents"]:
        for key, spec in agent["properties"].items():
            if "pattern" in spec and key in e:
                assert re.search(spec["pattern"], e[key]), (e["name"], key)


def test_render_flake_npm_and_pypi():
    npm = market.render_flake(entry(), system="x86_64-linux")
    assert 'packages.${system}."kilo"' in npm
    assert "--package=@kilocode/cli@7.8.1 -- kilo" in npm and "-- kilocode" in npm
    assert "${pkgs.nodejs_22}/bin/npx" in npm
    py = market.render_flake(entry(kind="pypi", package="code-puppy", name="code-puppy", bin="code-puppy",
                                   commands=["code-puppy", "pup"], version="0.0.884"), system="aarch64-linux")
    assert "--from code-puppy==0.0.884 pup" in py and "${pkgs.uv}/bin/uvx" in py
    assert 'system = "aarch64-linux"' in py
    with pytest.raises(market.MarketError):
        market.render_flake(entry(kind="nixpkgs"))


# ── install / list / remove with a fake nix ───────────────────────────────
FAKE_NIX = r"""
import json, os, sys
args = [a for a in sys.argv[1:] if a not in ("--extra-experimental-features", "nix-command flakes")]
with open(os.environ["FAKE_NIX_LOG"], "a") as f:
    f.write(json.dumps(args) + "\n")
if args[:1] == ["build"]:
    print(os.environ["FAKE_NIX_OUT"])
"""


@pytest.fixture
def env(tmp_path, monkeypatch):
    out = tmp_path / "store" / "abc-kilo-7.8.1"
    (out / "bin").mkdir(parents=True)
    for cmd in ("kilo", "kilocode", "vibe"):
        p = out / "bin" / cmd
        p.write_text("#!/bin/sh\n")
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    script = tmp_path / "fake_nix.py"
    script.write_text(FAKE_NIX)
    index = tmp_path / "index.json"
    index.write_text(json.dumps({"agents": [
        VALID,
        entry(name="mistral-vibe", description="Vibe", kind="nixpkgs", package="mistral-vibe", bin="vibe", commands=["vibe"], version="2.25.0"),
    ]}))
    (tmp_path / "agents.d").mkdir()
    monkeypatch.setenv("NESTLO_MARKET_NIX", "%s %s" % (shlex.quote(sys.executable), shlex.quote(str(script))))
    monkeypatch.setenv("FAKE_NIX_LOG", str(tmp_path / "nix.log"))
    monkeypatch.setenv("FAKE_NIX_OUT", str(out))
    monkeypatch.setenv("NESTLO_MARKET_INDEX", str(index))
    monkeypatch.setenv("NESTLO_AGENTS_D", str(tmp_path / "agents.d"))
    monkeypatch.setenv("NESTLO_MARKET_HOME", str(tmp_path / "market"))
    # the fake output lives in tmp, not the Nix store
    monkeypatch.setattr(market, "STORE_PATH_RE", re.compile(r"^%s/.+" % re.escape(str(tmp_path))))
    return tmp_path, out


def nix_calls(tmp_path):
    return [json.loads(l) for l in (tmp_path / "nix.log").read_text().splitlines()]


def test_install_npm_registers_spawn_names(env, capsys):
    tmp, out = env
    assert market.main(["install", "kilo"]) == 0
    calls = nix_calls(tmp)
    ref = "path:%s#kilo" % (tmp / "market" / "kilo")
    assert ["build", "--no-link", "--print-out-paths", ref] in calls
    assert ["profile", "install", ref] in calls
    assert "packages.${system}" in (tmp / "market" / "kilo" / "flake.nix").read_text()
    doc = json.loads((tmp / "agents.d" / "kilo.json").read_text())
    assert doc["agents"] == {"kilo": str(out / "bin" / "kilo"), "kilocode": str(out / "bin" / "kilocode")}
    assert doc["marketplace"] == {"name": "kilo", "kind": "npm", "package": "@kilocode/cli",
                                  "version": "7.8.1", "profile_element": "kilo"}
    assert (tmp / "agents.d" / "kilo.json").stat().st_mode & 0o777 == 0o664
    assert "nestlo spawn kilo" in capsys.readouterr().out


def test_install_nixpkgs_uses_nixpkgs_ref(env):
    tmp, out = env
    assert market.main(["install", "vibe"]) == 0  # found through its command name
    assert ["profile", "install", "nixpkgs#mistral-vibe"] in nix_calls(tmp)
    doc = json.loads((tmp / "agents.d" / "mistral-vibe.json").read_text())
    assert doc["agents"]["mistral-vibe"].endswith("/bin/vibe")
    assert doc["marketplace"]["profile_element"] == "mistral-vibe"
    assert not (tmp / "market").exists()


def test_install_refuses_paths_outside_the_store(env, monkeypatch):
    tmp, _ = env
    monkeypatch.undo()  # drop the relaxed store pattern (and the env vars)
    monkeypatch.setenv("NESTLO_MARKET_INDEX", str(tmp / "index.json"))
    e = market.load_index()[0]
    with pytest.raises(market.MarketError, match="not under /nix/store"):
        market.registration(e, str(tmp / "store" / "x"))


def test_install_dry_run_touches_nothing(env, capsys):
    tmp, _ = env
    assert market.main(["install", "kilo", "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "mkDerivation" in out and "would run: nix profile install" in out
    assert not (tmp / "nix.log").exists() and not (tmp / "market").exists()
    assert list((tmp / "agents.d").iterdir()) == []


def test_install_fails_without_the_executable(env):
    tmp, out = env
    (out / "bin" / "kilo").unlink()
    assert market.main(["install", "kilo"]) == 2
    assert list((tmp / "agents.d").iterdir()) == []


def test_list_installed_and_remove(env, capsys):
    tmp, _ = env
    market.main(["install", "kilo"])
    market.main(["install", "vibe"])
    # files without marketplace metadata (hand-written entries) are not listed
    (tmp / "agents.d" / "manual.json").write_text(json.dumps({"agents": {"x": "/nix/store/x"}}))
    capsys.readouterr()
    assert market.main(["list-installed", "--json"]) == 0
    listed = json.loads(capsys.readouterr().out)
    assert sorted(d["name"] for d in listed) == ["kilo", "mistral-vibe"]

    assert market.main(["remove", "kilo"]) == 0
    assert ["profile", "remove", "kilo"] in nix_calls(tmp)
    assert not (tmp / "agents.d" / "kilo.json").exists()
    assert not (tmp / "market" / "kilo").exists()
    assert (tmp / "agents.d" / "manual.json").exists()
    assert market.main(["remove", "kilo"]) == 2
    assert market.main(["remove", "manual"]) == 2


def test_search_and_info(env, capsys):
    assert market.main(["search", "kilo"]) == 0
    out = capsys.readouterr().out
    assert "kilo" in out and "mistral" not in out
    assert market.main(["search", "--json"]) == 0
    assert len(json.loads(capsys.readouterr().out)) == 2
    assert market.main(["info", "kilocode"]) == 0
    assert "@kilocode/cli@7.8.1" in capsys.readouterr().out
    assert market.main(["info", "nope"]) == 2


def test_invalid_index_is_rejected(tmp_path, monkeypatch, capsys):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"agents": [entry(version="latest")]}))
    monkeypatch.setenv("NESTLO_MARKET_INDEX", str(bad))
    assert market.main(["search"]) == 2
    assert market.main(["validate"]) == 1
    assert "pinned" in capsys.readouterr().err
