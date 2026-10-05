# Security Policy

## Supported versions

Security fixes go to the latest release and to `main`. Older releases are not patched; upgrade instead.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (private vulnerability reporting). If that is unavailable, email **anubhavg@infopercept.com** with the subject `AgentOS security`.

Include what you can:

- the affected component (gateway, daemon, orchestrator, sandbox, installer, a module, a release artifact) and version or commit
- steps or a proof of concept, and the impact you expect
- whether the issue is already public

## What to expect

| Step | Target |
|:---|:---|
| Acknowledgement | within 3 business days |
| Initial assessment and severity | within 7 days |
| Fix or mitigation for high and critical issues | within 30 days, sooner when actively exploited |
| Public advisory | after a fix is released, coordinated with you |

We credit reporters in the advisory unless you prefer to stay anonymous. We will not pursue legal action for good-faith research that avoids privacy violations, data destruction and service disruption, and that gives us a reasonable time to fix before disclosure (90 days by default).

## Scope

In scope: the code in this repository, the NixOS modules and their defaults, and the release artifacts (ISO, checksums, signatures, SBOM).

Out of scope: vulnerabilities in third-party agents, MCP servers and packages that AgentOS installs (report those upstream; tell us if our defaults make them worse), and findings that need an already-compromised operator account.

## Verifying releases

Once the release workflow in `ci/proposed-workflows/release.yml` is installed in `.github/workflows`, release assets carry a SHA256SUMS file, GitHub build provenance, a keyless cosign signature and a CycloneDX SBOM; releases made before that do not. See [docs/operations.md](docs/operations.md#release-verification).
