"""Check (and normalise) one skill directory against the Agent Skills spec.

Usage: validate.py <pack> <skill dir>...

- SKILL.md starts with YAML front matter holding `name` and `description`.
- name: 1-64 chars of a-z, 0-9 and single hyphens, no leading or trailing
  hyphen, equal to the directory name. When a pack installs a skill under a
  different directory name (to avoid a clash), the `name:` line is rewritten
  to that name, so the installed skill still satisfies the spec.
- description: non-empty, at most 1024 characters.
A body over 500 lines is reported but allowed (the spec recommends less).
Exits non-zero with a message on any violation.
"""
import re
import sys

import yaml

NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def fail(where, msg):
    print("skill %s: %s" % (where, msg), file=sys.stderr)
    sys.exit(1)


def check(pack, skill_dir):
    want = skill_dir.rstrip("/").rsplit("/", 1)[-1]
    where = "%s/%s" % (pack, want)
    path = skill_dir + "/SKILL.md"
    text = open(path, encoding="utf-8").read()

    m = re.match(r"^---\r?\n(.*?)\r?\n---\r?\n?", text, re.S)
    if not m:
        fail(where, "SKILL.md has no YAML front matter")
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as exc:
        fail(where, "front matter is not valid YAML: %s" % exc)
    if not isinstance(meta, dict):
        fail(where, "front matter is not a mapping")

    if not NAME_RE.match(want) or len(want) > 64:
        fail(where, "directory name %r is not a valid skill name (a-z, 0-9, single hyphens, max 64)" % want)

    name = meta.get("name")
    if not isinstance(name, str) or not name.strip():
        fail(where, "front matter has no name")
    body_lines = text[m.end():].count("\n")
    if name != want:
        # Rewrite the top-level name key, including indented continuation
        # lines of a multi-line value, then parse the result again
        head, n = re.subn(r"(?m)^name:.*(?:\r?\n[ \t]+.*)*$", "name: " + want, m.group(1), count=1)
        if n != 1:
            fail(where, "cannot rewrite name %r to %r" % (name, want))
        try:
            again = yaml.safe_load(head) or {}
        except yaml.YAMLError as exc:
            fail(where, "rewritten front matter is not valid YAML: %s" % exc)
        if not isinstance(again, dict) or again.get("name") != want or \
                {k: v for k, v in again.items() if k != "name"} != {k: v for k, v in meta.items() if k != "name"}:
            fail(where, "rewriting name %r to %r changed the front matter" % (name, want))
        text = text[:m.start(1)] + head + text[m.end(1):]
        open(path, "w", encoding="utf-8").write(text)
        print("skill %s: name %r installed as %r" % (where, name, want))

    desc = meta.get("description")
    if not isinstance(desc, str) or not desc.strip():
        fail(where, "front matter has no description")
    if len(desc) > 1024:
        fail(where, "description is %d characters (max 1024)" % len(desc))

    if body_lines > 500:
        print("skill %s: note: body is %d lines (spec recommends under 500)" % (where, body_lines))


for d in sys.argv[2:]:
    check(sys.argv[1], d)
