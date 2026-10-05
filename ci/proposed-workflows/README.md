# Proposed workflows

These files could not be pushed to `.github/workflows/`: the automation that prepared them has no permission to write there. **The repository owner must copy them in.**

```sh
cp ci/proposed-workflows/*.yml .github/workflows/   # release.yml replaces the existing file
git add .github/workflows && git commit -m "ci: supply-chain workflows"
```

| File | What it does |
|:---|:---|
| `release.yml` | Replaces the current release workflow. Adds `SHA256SUMS`, build provenance for the ISO (`actions/attest-build-provenance`), keyless `cosign sign-blob --bundle` signatures, and a CycloneDX SBOM from `sbomnix` attested to the ISO. Also runs the `backup` VM test. |
| `vuln-scan.yml` | Nightly `vulnix` on the closure of the `nestlo` host, uploaded as SARIF to code scanning. |
| `scorecard.yml` | OpenSSF Scorecard, weekly and on pushes to `main`. |
| `update-flake-lock.yml` | Weekly `nix flake update`, opened as a pull request with the `gh` CLI. |

All actions are pinned to full commit SHAs (the tag is in a trailing comment) and every job sets the minimal `permissions:` it needs. To bump a pin, resolve the new tag with `git ls-remote https://github.com/<owner>/<action> 'refs/tags/<tag>*'` and use the commit it points to (the line ending in `^{}` for annotated tags).

## Repository settings these rely on

- **Code scanning** enabled (Settings, Code security) for the SARIF uploads.
- **Artifact attestations**: available on public repositories; private ones need GitHub Enterprise Cloud.
- Optional secret `FLAKE_UPDATE_TOKEN` (fine-grained token with contents and pull-requests write) so CI runs on the flake.lock pull requests; without it the workflow falls back to `GITHUB_TOKEN`, whose pull requests do not trigger other workflows.
- Branch protection on `main` improves the Scorecard result.

## Not verified here

The workflows were linted as YAML only; they have not run. The first release after adopting them is the test: check that the release carries `nestlo-<tag>.iso`, `nestlo-<tag>.cdx.json`, `SHA256SUMS`, and two `.sigstore.json` bundles, and run the verification commands in [docs/operations.md](../../docs/operations.md#release-verification). The `vulnix` JSON-to-SARIF conversion is written against vulnix 1.12's output (`name`, `affected_by`, `cvssv3_basescore`) and should be checked on the first nightly run.
