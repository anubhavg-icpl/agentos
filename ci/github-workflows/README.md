# GitHub Actions workflows

`ci.yml` (flake check, service tests, end-to-end VM test on every push/PR)
and `release.yml` (verify, publish a GitHub release with notes from
CHANGELOG.md and attach the installer ISO on every `v*` tag).

They live here because the automation that prepared v0.3.0 could not write
to `.github/workflows/`. To enable them, from a checkout with your own
credentials:

```bash
mkdir -p .github/workflows
git mv ci/github-workflows/ci.yml ci/github-workflows/release.yml .github/workflows/
git commit -m "ci: enable workflows" && git push
```

To publish the release for a tag that already exists, re-run it from the
Actions tab or push the tag again (`git push origin :v0.3.0 && git push origin v0.3.0`).
