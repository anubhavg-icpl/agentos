# Contributing to Nestlo

Thanks for your interest in improving Nestlo! This is an operating system for coding agents, and we welcome contributions of all kinds.

## Getting Started

```bash
# Clone
git clone https://github.com/anubhavg-icpl/agentos.git
cd agentos

# Enter dev shell
nix develop

# Build the ISO
nix build .#iso-image

# Test in a VM (EFI qcow2)
nix build .#vm-image
```

## Project Structure

```
modules/          NixOS modules (27 modules)
  runtime/        Agent sandbox, agent daemon, control-plane Redis
  security/       AppArmor, firewall, audit
  context/        Qdrant vector memory
  ...
agents/           15 coding agent packages
nixos/
  hosts/          Host configurations (bare metal + ISO)
  packages/       CLI, installer, services package, planned-service stubs
services/         Model gateway + agent daemon (Python) and their tests
tests/            End-to-end NixOS VM test
docs/             Documentation
templates/        Agent workspace template
```

## Adding a New Module

1. Create `modules/your-module/default.nix`
2. Define options under `agentos.your-module`
3. Implement config under `config = lib.mkIf cfg.enable`
4. Add import to `modules/default.nix`
5. Enable in `nixos/hosts/agentos/default.nix`
6. Write a CLI tool if the module needs one
7. Document in `docs/FEATURES.md`
8. Commit with: `modules: add <module-name>`

## Adding a New Agent

1. Add the agent package to `agents/default.nix`
2. Add it to the `all-agents` meta-package
3. Map its name(s) to its command in `agentos.runtime.agents` (modules/runtime)
4. Document in `docs/AGENTS.md`
5. Commit with: `agents: add <agent-name>`

## Commit Conventions

We use conventional commits:

```
modules: add <description>
agents: add <description>
docs: add <description>
fix: <description>
chore: <description>
flake: <description>
hosts: <description>
packages: <description>
```

## Testing

```bash
# Evaluate every output on both systems
nix flake check --no-build --all-systems

# Gateway and daemon unit tests (run during the package build)
nix build .#services
# ...or iterate quickly in the dev shell
nix develop -c sh -c 'cd services && python -m pytest'

# Shell scripts are shellchecked when built
nix build .#cli .#installer

# End-to-end VM test (uses KVM when available; very slow without it)
nix build -L .#checks.x86_64-linux.e2e
```

The CI workflow (`.github/workflows/ci.yml`) runs the same commands.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
