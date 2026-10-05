"""Verifiable AI-authored code: signed provenance for an agent's commit.

When the root task runner finishes a task it builds an in-toto Statement v1
whose subject is the agent branch commit (gitCommit digest, plus the pull
request once there is one) and whose predicate
(https://nestlo.dev/provenance/agent-run/v1) records who and what produced
it: the agent and its Nix store path, the system closure it ran on, models
and cost from the gateway's books, the sha256 of the prompt (the prompt
itself only with include_prompt), the task, its approvals, verify result and
judge winner, and the recording and the sha256 of its transcript.

The statement is wrapped in a DSSE envelope signed with an Ed25519 key. The
private key is a root-only file passed to the task runner as a systemd
credential (like the publish token); the agent sandbox never sees it, so an
agent cannot sign a statement for code it did not write through this host.
The envelope is stored as a git note (refs/notes/nestlo-provenance) on the
commit and in the task result; publish.py pushes the note ref with the branch.

`nestlo-provenance` verifies an envelope (signature against trusted public
keys, subject against the commit, closure path if local), pretty-prints it,
and checks a recording against it (replay-check).

Threat model, in short: a valid signature says "this host's task runner
attested these facts about exactly this commit". It does not say the code is
good, and a compromised root on the host can sign anything. See
docs/provenance.md.
"""

import argparse
import base64
import datetime
import hashlib
import json
import logging
import os
import re
import stat
import subprocess
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

from . import config as configmod

log = logging.getLogger("nestlo.provenance")

PREDICATE_TYPE = "https://nestlo.dev/provenance/agent-run/v1"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PAYLOAD_TYPE = "application/vnd.in-toto+json"
NOTES_REF = "refs/notes/nestlo-provenance"
STATUS_CONTEXT = "nestlo/provenance"
DEFAULT_PUBKEYS = ("/etc/nestlo/provenance.pub", "/var/lib/nestlo/provenance.pub")

DEFAULTS = {
    "provenance": {
        "enable": False,
        "credential_name": "provenance-key",
        "key_file": "",
        "include_prompt": False,
        "require_for_publish": False,
    },
}

_SHA = re.compile(r"^[0-9a-f]{40}([0-9a-f]{24})?$")


class ProvenanceError(Exception):
    pass


def settings(cfg):
    section = json.loads(json.dumps(DEFAULTS["provenance"]))
    return configmod._merge(section, cfg.get("provenance", {}))


# ── encoding ─────────────────────────────────────────────────────────────
def canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def sha256_hex(data):
    if isinstance(data, str):
        data = data.encode()
    return hashlib.sha256(data).hexdigest()


def pae(payload_type, payload):
    """DSSE pre-authentication encoding."""
    t = payload_type.encode()
    return b"DSSEv1 %d %s %d %s" % (len(t), t, len(payload), payload)


def utc_iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def raw_public(key):
    pub = key.public_key() if isinstance(key, Ed25519PrivateKey) else key
    return pub.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


def keyid_of(pub_raw):
    return sha256_hex(pub_raw)


def public_b64(key):
    return base64.b64encode(raw_public(key)).decode()


# ── keys ─────────────────────────────────────────────────────────────────
def _read_private_file(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as exc:
        raise ProvenanceError("cannot read the provenance key file: %s" % exc.strerror)
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(f.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077:
            raise ProvenanceError("the provenance key file must be a regular file readable only by its owner")
        return f.read()


def load_private_key(path):
    data = _read_private_file(path)
    try:
        key = serialization.load_pem_private_key(data, password=None)
    except (ValueError, TypeError):
        raise ProvenanceError("the provenance key file is not an unencrypted PEM private key")
    if not isinstance(key, Ed25519PrivateKey):
        raise ProvenanceError("the provenance key must be an Ed25519 key")
    return key


def key_path(opts, environ=None):
    environ = os.environ if environ is None else environ
    path = opts.get("key_file") or ""
    cred_dir = environ.get("CREDENTIALS_DIRECTORY")
    if cred_dir and opts.get("credential_name"):
        candidate = os.path.join(cred_dir, opts["credential_name"])
        if os.path.exists(candidate):
            path = candidate
    if not path:
        raise ProvenanceError("no provenance signing key is configured (nestlo.provenance.keyFile)")
    return path


class Signer:
    def __init__(self, key):
        self.key = key
        self.pub = raw_public(key)
        self.keyid = keyid_of(self.pub)

    @classmethod
    def load(cls, opts, environ=None):
        return cls(load_private_key(key_path(opts, environ)))

    def sign(self, statement):
        """Statement dict -> DSSE envelope dict."""
        payload = canonical(statement)
        sig = self.key.sign(pae(PAYLOAD_TYPE, payload))
        return {"payloadType": PAYLOAD_TYPE, "payload": base64.b64encode(payload).decode(),
                "signatures": [{"keyid": self.keyid, "sig": base64.b64encode(sig).decode()}]}


def generate_key(path, pub_path=None):
    """Create an Ed25519 key at `path` (0600, never overwritten). Returns (public b64, created)."""
    created = False
    if not os.path.lexists(path):
        key = Ed25519PrivateKey.generate()
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(pem)
        created = True
    key = load_private_key(path)
    pub = public_b64(key)
    if pub_path:
        with open(pub_path, "w") as f:
            f.write("%s\n" % pub)
        os.chmod(pub_path, 0o644)
    return pub, created


def parse_public_keys(text):
    """Lines of `<base64 raw ed25519 key>` with an optional leading name; # comments."""
    keys = {}
    for line in (text or "").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        b64 = line.split()[-1]
        try:
            raw = base64.b64decode(b64, validate=True)
            Ed25519PublicKey.from_public_bytes(raw)
        except (ValueError, TypeError):
            raise ProvenanceError("not an Ed25519 public key: %r" % b64[:20])
        keys[keyid_of(raw)] = raw
    return keys


def load_public_keys(paths):
    keys = {}
    for p in paths:
        try:
            with open(p) as f:
                keys.update(parse_public_keys(f.read()))
        except OSError:
            continue
    return keys


# ── statement ────────────────────────────────────────────────────────────
def build_statement(*, commit, tree=None, pr_url=None, repo=None, branch=None, agent, agent_binary=None,
                    agent_store_path=None, system_closure=None, task, prompt, include_prompt=False,
                    usage=None, verify=None, judge=None, approval=None, recording=None,
                    started_at=None, finished_at=None, exit_code=None, dirty=False):
    """The in-toto Statement v1 for one finished task. Only plain data goes in."""
    if not _SHA.match(commit or ""):
        raise ProvenanceError("not a git commit id: %r" % (commit,))
    subject = [{"name": "git+commit:%s" % (branch or commit), "digest": {"gitCommit": commit}}]
    if pr_url:
        subject.append({"name": pr_url, "digest": {"gitCommit": commit}})
    approvals = []
    if isinstance(approval, dict) and approval.get("decision") == "approved":
        approvals.append({"approver": approval.get("by"), "uid": approval.get("uid"),
                          "time": utc_iso(approval["at"]) if approval.get("at") else None,
                          "note": approval.get("note") or ""})
    predicate = {
        "agent": {"name": agent, "binary": agent_binary, "storePath": agent_store_path},
        "builder": {"systemClosure": system_closure, "agentPackage": agent_store_path},
        "source": {"repo": repo, "branch": branch, "gitTree": tree, "uncommittedChanges": bool(dirty)},
        "models": sorted((usage or {}).get("models", {})),
        "usage": {"usd": (usage or {}).get("usd", 0.0), "tokens": (usage or {}).get("tokens", {}),
                  "usdByModel": (usage or {}).get("models", {})},
        "prompt": {"sha256": sha256_hex(prompt or "")},
        "task": {"id": task.get("id"), "origin": task.get("origin"), "attempt": int(task.get("attempt") or 1),
                 "exitCode": exit_code},
        "verify": ({"status": verify.get("status"), "exitCode": verify.get("exit_code")} if verify else None),
        "judge": judge,
        "approvals": approvals,
        "recording": recording,
        "startedOn": utc_iso(started_at) if started_at else None,
        "finishedOn": utc_iso(finished_at) if finished_at else None,
    }
    if include_prompt:
        predicate["prompt"]["text"] = prompt
    return {"_type": STATEMENT_TYPE, "subject": subject, "predicateType": PREDICATE_TYPE, "predicate": predicate}


def envelope_json(envelope):
    return canonical(envelope).decode()


def envelope_digest(envelope):
    return sha256_hex(envelope_json(envelope))


def summary(envelope):
    """A few lines for a PR body: what the envelope attests."""
    st = decode_payload(envelope)
    p = st["predicate"]
    commit = st["subject"][0]["digest"]["gitCommit"]
    v = p.get("verify") or {}
    lines = [
        "**Nestlo provenance** (`%s`)" % PREDICATE_TYPE,
        "- commit `%s`, agent `%s`, task `%s`" % (commit[:12], p["agent"]["name"], p["task"]["id"]),
        "- models: %s; cost $%.4f" % (", ".join(p["models"]) or "unknown", p["usage"]["usd"]),
        "- verify: %s; approvals: %d; recording: %s" % (v.get("status") or "none", len(p["approvals"]),
                                                      "yes" if p.get("recording") else "no"),
        "- signed by key `%s`; envelope sha256 `%s`" % (envelope["signatures"][0]["keyid"][:16], envelope_digest(envelope)),
        "- verify: `nestlo-provenance verify %s`" % commit[:12],
    ]
    return "\n".join(lines)


def decode_payload(envelope):
    try:
        return json.loads(base64.b64decode(envelope["payload"], validate=True))
    except (KeyError, ValueError, TypeError):
        raise ProvenanceError("malformed envelope payload")


# ── verification ─────────────────────────────────────────────────────────
def verify_envelope(envelope, trusted, commit=None, check_paths=True):
    """Check an envelope. Returns {"ok", "checks": [{name, ok, detail}], "statement"}.

    `trusted` is {keyid: raw public key}; `commit` the full commit id the
    envelope must be about (None: not checked)."""
    checks = []

    def check(name, ok, detail=""):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})
        return ok

    statement = None
    try:
        if not isinstance(envelope, dict) or envelope.get("payloadType") != PAYLOAD_TYPE:
            raise ProvenanceError("not a DSSE envelope of type %s" % PAYLOAD_TYPE)
        statement = decode_payload(envelope)
        payload = base64.b64decode(envelope["payload"])
        good = None
        for sig in envelope.get("signatures") or []:
            raw = trusted.get(sig.get("keyid"))
            if raw is None:
                continue
            try:
                Ed25519PublicKey.from_public_bytes(raw).verify(base64.b64decode(sig["sig"]), pae(PAYLOAD_TYPE, payload))
                good = sig["keyid"]
                break
            except (InvalidSignature, ValueError, KeyError, TypeError):
                continue
        if good:
            check("signature", True, "valid, key %s" % good[:16])
        elif not trusted:
            check("signature", False, "no trusted public keys are configured (nestlo.provenance.publicKeys)")
        else:
            check("signature", False, "no signature from a trusted key")
        check("statement", statement.get("_type") == STATEMENT_TYPE and statement.get("predicateType") == PREDICATE_TYPE,
              "%s / %s" % (statement.get("_type"), statement.get("predicateType")))
        commits = {s.get("digest", {}).get("gitCommit") for s in statement.get("subject") or []}
        commits.discard(None)
        if len(commits) != 1:
            check("subject", False, "the subject must name exactly one gitCommit")
        elif commit is None:
            check("subject", True, "gitCommit %s (not compared to a repository)" % next(iter(commits))[:12])
        else:
            check("subject", commit in commits, "attests %s, commit is %s" % (next(iter(commits))[:12], commit[:12]))
        if check_paths:
            builder = statement.get("predicate", {}).get("builder", {})
            for label, path in (("systemClosure", builder.get("systemClosure")), ("agentPackage", builder.get("agentPackage"))):
                if path:
                    # informational: a verifier on another machine will not have the path
                    present = os.path.exists(path)
                    checks.append({"name": "closure:" + label, "ok": True,
                                   "detail": "%s %s" % (path, "present" if present else "not present on this host")})
    except ProvenanceError as exc:
        check("envelope", False, str(exc))
    return {"ok": bool(checks) and all(c["ok"] for c in checks), "checks": checks, "statement": statement}


# ── git notes ────────────────────────────────────────────────────────────
def note_args(sha, envelope):
    return ["-c", "user.name=Nestlo", "-c", "user.email=nestlo@localhost", "-c", "commit.gpgsign=false",
            "notes", "--ref=" + NOTES_REF, "add", "-f", "-m", envelope_json(envelope), sha]


def add_note(git, workdir, sha, envelope):
    """Attach the envelope to `sha`. `git(args, cwd)` runs git as the agent user."""
    res = git(note_args(sha, envelope), workdir)
    if res.returncode != 0:
        raise ProvenanceError("could not write the git note: %s" % (res.stderr or "").strip()[:200])


def _run_git(repo, args):
    res = subprocess.run(["git", *args], cwd=repo, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                         check=False, env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    return res


def read_note(repo, sha):
    res = _run_git(repo, ["notes", "--ref=" + NOTES_REF, "show", sha])
    if res.returncode != 0:
        raise ProvenanceError("no provenance note on %s" % sha[:12])
    try:
        return json.loads(res.stdout)
    except ValueError:
        raise ProvenanceError("the provenance note on %s is not JSON" % sha[:12])


def resolve_commit(repo, rev):
    res = _run_git(repo, ["rev-parse", "--verify", "--quiet", rev + "^{commit}"])
    if res.returncode != 0:
        raise ProvenanceError("not a commit in %s: %s" % (repo, rev))
    return res.stdout.strip()


def tree_of(repo, rev):
    res = _run_git(repo, ["rev-parse", "--verify", "--quiet", rev + "^{tree}"])
    if res.returncode != 0:
        raise ProvenanceError("cannot resolve the tree of %s in %s" % (rev, repo))
    return res.stdout.strip()


# ── CLI ──────────────────────────────────────────────────────────────────
def _keys_from_args(args):
    keys = {}
    paths = args.keys or list(DEFAULT_PUBKEYS)
    keys.update(load_public_keys(paths))
    for text in args.key or []:
        keys.update(parse_public_keys(text))
    return keys


def _load_envelope(arg, repo):
    """(envelope, commit-or-None) from a file, or from the note on a commit-ish."""
    if os.path.isfile(arg):
        try:
            with open(arg) as f:
                return json.load(f), None
        except (OSError, ValueError) as exc:
            raise ProvenanceError("cannot read %s: %s" % (arg, exc))
    sha = resolve_commit(repo, arg)
    return read_note(repo, sha), sha


def cmd_verify(args):
    envelope, commit = _load_envelope(args.target, args.repo)
    if args.commit:
        commit = resolve_commit(args.repo, args.commit)
    result = verify_envelope(envelope, _keys_from_args(args), commit)
    if args.json:
        print(json.dumps({"ok": result["ok"], "checks": result["checks"]}, indent=2))
    else:
        for c in result["checks"]:
            print("%-4s %-22s %s" % ("ok" if c["ok"] else "FAIL", c["name"], c["detail"]))
        print("VERIFIED" if result["ok"] else "NOT VERIFIED")
    return 0 if result["ok"] else 1


def cmd_show(args):
    envelope, _ = _load_envelope(args.target, args.repo)
    st = decode_payload(envelope)
    print("# unverified: run `nestlo-provenance verify` to check the signature")
    print(json.dumps(st, indent=2, sort_keys=True))
    print("# envelope sha256 %s, keys %s" % (envelope_digest(envelope),
                                             ", ".join(s["keyid"][:16] for s in envelope.get("signatures", []))))
    return 0


def cmd_keygen(args):
    pub, created = generate_key(args.key_file, args.pub_file)
    print("nestlo provenance %s signing key; public key (add to nestlo.provenance.publicKeys elsewhere):\n%s"
          % ("generated a new" if created else "using the existing", pub))
    return 0


def _recording_dir(args):
    if args.recordings:
        return args.recordings
    try:
        return configmod.load(args.config)["recording"]["dir"]
    except Exception:
        return "/var/lib/nestlo/recordings"


def cmd_replay_check(args):
    """Compare a task's recording and, optionally, a replayed tree with its provenance.

    Checks: the signature, the recording's transcript hash against the one
    signed, the system closure against this host's, and (with --replayed) the
    tree hash of a replayed run against the signed commit's tree."""
    from .recorder import transcript_digest
    task = args.task
    envelope, commit = _load_envelope(args.envelope or "agent/" + task, args.repo)
    result = verify_envelope(envelope, _keys_from_args(args), commit, check_paths=False)
    checks = result["checks"]
    pred = (result["statement"] or {}).get("predicate", {})

    def add(name, ok, detail):
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    rec = pred.get("recording")
    if not rec:
        add("transcript", False, "the task was not recorded; there is nothing to replay")
    else:
        digest, count = transcript_digest(_recording_dir(args), rec.get("id") or task)
        add("transcript", digest == rec.get("transcriptSha256"),
            "%d requests, sha256 %s (signed %s)" % (count, (digest or "missing")[:16], str(rec.get("transcriptSha256"))[:16]))
    closure = pred.get("builder", {}).get("systemClosure")
    here = os.path.realpath("/run/current-system")
    add("closure", closure == here, "signed %s, this host %s%s" % (closure, here, "" if closure == here else
                                                               " (a replay on a different system is not hermetic)"))
    if args.replayed:
        want = (result["statement"]["subject"][0]["digest"]["gitCommit"] if result["statement"] else None)
        try:
            signed_tree = pred.get("source", {}).get("gitTree") or tree_of(args.repo, want)
            got = tree_of(args.replayed, args.replayed_rev)
            add("tree", got == signed_tree, "replayed %s, signed %s" % (got[:12], signed_tree[:12]))
        except ProvenanceError as exc:
            add("tree", False, str(exc))
    else:
        checks.append({"name": "tree", "ok": True, "detail": "skipped: re-run the task from the recording, then pass --replayed <repo>"})
    ok = all(c["ok"] for c in checks)
    if args.json:
        print(json.dumps({"ok": ok, "checks": checks}, indent=2))
    else:
        for c in checks:
            print("%-4s %-22s %s" % ("ok" if c["ok"] else "FAIL", c["name"], c["detail"]))
        print("CONSISTENT" if ok else "MISMATCH")
    return 0 if ok else 1


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nestlo-provenance", description="Verify Nestlo provenance for AI-authored commits")
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p, keys=True):
        p.add_argument("--repo", default=".", help="git repository (default: .)")
        if keys:
            p.add_argument("--keys", action="append", help="file of trusted public keys (default: %s)" % ", ".join(DEFAULT_PUBKEYS))
            p.add_argument("--key", action="append", help="a trusted base64 Ed25519 public key")
        p.add_argument("--json", action="store_true")

    p = sub.add_parser("verify", help="verify an envelope file or the note on a commit")
    p.add_argument("target", help="envelope file, or a commit-ish carrying a note")
    p.add_argument("--commit", help="the commit the envelope must attest (for an envelope file)")
    common(p)
    p.set_defaults(fn=cmd_verify)
    p = sub.add_parser("show", help="pretty-print the provenance (unverified)")
    p.add_argument("target")
    common(p, keys=False)
    p.set_defaults(fn=cmd_show)
    p = sub.add_parser("replay-check", help="check a task's recording, closure and replayed tree against its provenance")
    p.add_argument("task")
    p.add_argument("--envelope", help="envelope file (default: the note on branch agent/<task> in --repo)")
    p.add_argument("--recordings", help="recordings directory (default: from services.toml)")
    p.add_argument("--config", default=None)
    p.add_argument("--replayed", help="repository holding a replayed run's result")
    p.add_argument("--replayed-rev", default="HEAD")
    common(p)
    p.set_defaults(fn=cmd_replay_check)
    p = sub.add_parser("keygen", help="create the signing key if absent and print the public key")
    p.add_argument("--key-file", required=True)
    p.add_argument("--pub-file")
    p.set_defaults(fn=cmd_keygen)

    args = parser.parse_args(argv)
    try:
        return args.fn(args)
    except ProvenanceError as exc:
        print("nestlo-provenance: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
