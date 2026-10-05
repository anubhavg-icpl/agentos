"""Scope guard for factory builder tasks (agentos-factory-scope).

Used as the task's verify command:

    agentos-factory-scope --allow 'src/**' --allow 'tests/**' [--base REF] -- <the line's verify argv>

It lists the files the branch changed since its merge-base with REF (default:
origin/HEAD, main or master; committed, modified and untracked files) and, when
any is outside the allowed globs, prints one `SCOPE-VIOLATION: <path>` line per
file and exits 3 without running the rest. Otherwise it runs the remaining
argv (exit status passed through) or exits 0 when there is none. The factory
reads the SCOPE-VIOLATION lines from the verify output.
"""

import argparse
import os
import subprocess
import sys

from .factory import scope_violations


def _git(*args):
    res = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    return res.returncode, res.stdout


def changed_files(base=None):
    candidates = [base] if base else ["origin/HEAD", "main", "master"]
    point = None
    for ref in candidates:
        rc, out = _git("merge-base", "HEAD", ref)
        if rc == 0 and out.strip():
            point = out.strip()
            break
    if point is None:
        raise RuntimeError("cannot find a base to diff against (tried %s)" % ", ".join(candidates))
    names = set()
    for args in (["diff", "--name-only", point], ["ls-files", "--others", "--exclude-standard"]):
        rc, out = _git(*args)
        if rc != 0:
            raise RuntimeError("git %s failed" % args[0])
        names.update(n for n in out.splitlines() if n)
    return sorted(names)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    rest = []
    if "--" in argv:
        i = argv.index("--")
        argv, rest = argv[:i], argv[i + 1:]
    parser = argparse.ArgumentParser(description="fail when a branch changed files outside the allowed scope")
    parser.add_argument("--allow", action="append", default=[])
    parser.add_argument("--base", default=None)
    args = parser.parse_args(argv)
    try:
        bad = scope_violations(changed_files(args.base), args.allow)
    except RuntimeError as exc:
        print("scope check error: %s" % exc)
        return 2
    if bad:
        for path in bad:
            print("SCOPE-VIOLATION: %s" % path)
        return 3
    if rest:
        os.execvp(rest[0], rest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
