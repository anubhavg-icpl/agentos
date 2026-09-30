# Contributing to AgentOS

Thanks for your interest in improving AgentOS! This is an operating system for coding agents, and we welcome contributions of all kinds.

## Getting Started

```bash
# Clone
git clone https://github.com/anubhavg-icpl/agentos.git
cd agentos

# Enter dev shell
nix develop

# Build the ISO
nix build .#iso-image

# Test in a VM
nix build .#vm-image
qemu-system-x86_64 -m 4096 -enable-kvm -hda result/nixos.qcow2
```

## Project Structure

```
modules/          NixOS modules (27 modules)
  runtime/        Container runtime, agent daemon
  security/       AppArmor, firewall, audit
  context/        Qdrant vector memory
  ...
agents/           15 coding agent packages
nixos/
  hosts/          Host configurations (bare metal + ISO)
  packages/       Internal Rust binaries
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
3. Add a case in the `agentos spawn` CLI (nixos/packages/cli.nix)
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
# Check Nix evaluation
nix flake check

# Build a specific host
nixos-rebuild build --flake .#agentos

# Build the ISO
nix build .#iso-image
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
