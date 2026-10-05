# Verifiable AI-authored code (provenance)

When an orchestrator task finishes, the root task runner signs a statement about the commit the agent produced: which agent, on which system closure, with which models, at what cost, from which prompt (by hash), approved by whom, and whether the session was recorded. A run that fails, times out or is cancelled after committing still gets its commit signed (the predicate records the exit code), but is never published. The signed envelope is stored as a git note on the commit, pushed with the branch (in one atomic push, so the branch never lands without its note), summarised in the PR body, and surfaced as a commit status you can require before merging. `nestlo-provenance` verifies it.

Code: `services/nestlo_services/provenance.py` (statement, DSSE signing, verification, CLI), `taskrunner.py` (builds it), `publish.py` (note push, PR body, status). NixOS module: `nestlo.provenance`.

## Format

An [in-toto Statement v1](https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md) in a [DSSE](https://github.com/secure-systems-lab/dsse) envelope (`payloadType` `application/vnd.in-toto+json`), signed with Ed25519. The `keyid` is the sha256 of the raw public key.

- `subject`: `{"name": "git+commit:agent/<task>", "digest": {"gitCommit": "<sha>"}}`. The copy stored in the task result also carries the PR URL as a second subject (the pushed note cannot, the PR does not exist yet).
- `predicateType`: `https://nestlo.dev/provenance/agent-run/v1`
- `predicate`:

| Field | Content |
|:---|:---|
| `agent` | name, resolved binary, Nix store path of the agent package |
| `builder` | `systemClosure` (realpath of `/run/current-system`), `agentPackage` |
| `source` | repo (when published), branch, `gitTree` of the commit, whether uncommitted changes existed |
| `models`, `usage` | models used, tokens and USD for the task's agent id (the task id), from the gateway's Redis books |
| `prompt` | `sha256` of the prompt the agent received; `text` only with `includePrompt` |
| `task` | id, origin, attempt, exit code |
| `verify` | status and exit code of the task's `verify` command |
| `judge` | swarm group, role, judge winner when already known (a member finishes before its judge) |
| `approvals` | approver, uid, time, note (the orchestrator's approval record) |
| `recording` | recording id, request count, `transcriptSha256` (when recording was on) |
| `startedOn`, `finishedOn` | UTC timestamps |

The transcript hash is the sha256 of one `<seq> <sha256 of entry file>` line per recorded request. Models per task are tracked by the gateway (`models:<date>:agent:<id>`), so they are known without a recording.

## Setup

```nix
nestlo.provenance = {
  enable = true;
  # keyFile = "/run/secrets/nestlo-provenance-key";   # sops path; default /var/lib/nestlo/provenance.key
  publicKeys = [ "<base64 key of the signing host>" ];  # what `verify` trusts, besides this host's own key
  requireForPublish = true;                             # no envelope, no PR
  # includePrompt = false;                              # notes are pushed: keep prompts out unless the repo is public
};
```

If `keyFile` does not exist, `nestlo-provenance-keygen.service` creates an Ed25519 key at first boot (root, 0600), writes the public key to `/var/lib/nestlo/provenance.pub` and prints it to the journal (`journalctl -u nestlo-provenance-keygen`). The key reaches `nestlo-task-runner@` as a systemd credential, like the GitHub token; the agent sandbox never sees it. Treat the key like a release-signing key: back it up, and rotate it by adding the new public key to `publicKeys` before removing the old one.

The GitHub token for `nestlo.git-automation.publish` needs the additional **Commit statuses: write** permission.

## What it protects against, and what it does not

Threat model. The adversary is an agent (prompt-injected, buggy or malicious), a repository contributor, or a reviewer in a hurry, not root on the signing host.

- An agent cannot forge a statement: the key is root-only and held by the task runner, not the sandbox. It cannot claim other models, another prompt hash, approvals that did not happen, or a different system closure, because those facts are collected by the runner from the gateway, the orchestrator record and the host, not from the agent.
- Changing the commit after signing, or moving the note to another commit, fails the subject check; editing the predicate fails the signature.
- A commit with no valid note by a trusted key was not produced by this pipeline. With the merge gate below, that is enforced.

It does not tell you the code is correct or safe (review and CI still do that); it says who and what produced it. Root on the signing host (or a stolen key) can sign anything, so keep the key off the agent host if your threat model includes host compromise (use `keyFile` from a secret store and a separate trusted `publicKeys` list). The statement is a claim about one task run, not a reproducible-build attestation: model output is not deterministic, which is why the recording hash exists. `uid` in approvals is the unix uid of the approver on the host. If the task ran with `includePrompt = false` the prompt is only committed to by hash, so a verifier who holds the prompt can confirm it but not recover it.

## Verification

```sh
nestlo-provenance verify <commit-or-envelope.json> [--repo DIR] [--key B64 | --keys FILE]
nestlo-provenance show <commit-or-envelope.json>
nestlo-provenance replay-check <task> [--replayed REPO] [--recordings DIR]
```

Fetch the notes first: `git fetch origin refs/notes/nestlo-provenance:refs/notes/nestlo-provenance`.

`verify` checks (1) the DSSE signature against the trusted keys (`--key`, `--keys`, default `/etc/nestlo/provenance.pub` from `publicKeys` and `/var/lib/nestlo/provenance.pub`), (2) that the statement and predicate types are the Nestlo ones, (3) that the subject `gitCommit` is the commit you asked about, and (4) reports whether the closure and agent package store paths exist on this host (informational: a verifier on another machine will not have them). Exit status 0 means verified, 1 not verified, 2 usage or input errors. `show` pretty-prints without verifying.

`replay-check` is the partial form of "does this run reproduce": it verifies the envelope, recomputes the recording's transcript hash and compares it with the signed one, compares the signed system closure with this host's, and, if you give `--replayed REPO`, compares the tree hash of the replayed result with the signed `gitTree`. Re-running the agent from the recording is a manual step, because replay needs a live agent against the gateway: register a new agent id with `nestlo-replay start <task-id> <new-id>`, run the same agent and prompt as that id in a fresh checkout of the base commit, then run `replay-check <task> --replayed <that checkout>`. Agents are not deterministic given identical model answers (tool timing, temp paths), so a tree mismatch is a prompt to look, not proof of tampering; the transcript hash is the strong check.

## Merge gate

The status `nestlo/provenance` is `success` on the pushed commit when a signed envelope is attached, `failure` when provenance is on but none could be produced. To require it:

1. Repository Settings, Branches (or Rulesets), protect `main`, enable "Require status checks to pass", add `nestlo/provenance`.
2. Because only the publisher's token sets that context, also restrict who can push statuses (a fine-grained token with Commit statuses: write held only by the task runner).
3. Optional stricter gate in CI: fetch the notes and run `nestlo-provenance verify "$GITHUB_SHA" --key "$NESTLO_PUBKEY"` for commits on `agent/*` branches; a status can be set by any token holder, a signature cannot.

Statuses prove the publisher said so; the signature proves the host said so. Use the CI check where those differ.

## Comparison with Copilot session-log linking

GitHub's [trace any Copilot coding agent commit to its session logs](https://github.blog/changelog/2026-03-20-trace-any-copilot-coding-agent-commit-to-its-session-logs/) links an agent commit to the logs of the session that made it, on GitHub's infrastructure. That answers "what did the agent do" for people who can read the logs, and it relies on GitHub as the party you trust. Nestlo provenance is complementary and different in kind: it is a signed, portable attestation under a key you control, checkable offline without trusting the forge, it binds the exact system closure and agent package, and it commits to the cost, approvals and the recording (hash) rather than linking to a log service. It does not replace reading a transcript; the recording and the `transcriptSha256` give you the transcript and let you prove it is the one the commit was signed against.
