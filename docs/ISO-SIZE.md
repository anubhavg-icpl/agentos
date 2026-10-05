# Nestlo — ISO Size Analysis

> Sizes on this page are estimates, not measurements of a built image.

## Estimated Sizes by Configuration

| Configuration | ISO Size | Installed | RAM (idle) |
|--------------|----------|-----------|------------|
| **Minimal** (core only, no agents) | ~800 MB | ~2.5 GB | ~256 MB |
| **Standard** (core + 20 agents) | ~2.5 GB | ~8 GB | ~512 MB |
| **Full** (all modules + toolchains) | ~5-7 GB | ~15-20 GB | ~1 GB |
| **Everything** (VIBE + all MCP + all tools) | ~8-10 GB | ~25-30 GB | ~1.5 GB |

## Why NixOS ISOs Are Larger

NixOS stores complete package closures in `/nix/store`, so the ISO includes every dependency for every program. This is the trade-off for reproducibility: no "works on my machine" issues.

## Keeping It Small

### Option 1: Minimal ISO (800 MB)
```nix
nestlo = {
  runtime.enable = true;
  security.enable = true;
  # Disable everything else
  language-toolchains.enableAll = false;
  databases.enable = false;
  vibe-integration.enable = false;
  mcp-servers.enable = false;
};
```

### Option 2: Build with compression
```bash
# nixos/hosts/iso.nix already uses zstd level 19.
# For an even smaller image, set this in nixos/hosts/iso.nix and rebuild:
#   isoImage.squashfsCompression = "xz -Xdict-size 100%";
nix build .#iso-image
```

### Option 3: Netboot (no ISO needed)
```bash
# Nestlo can PXE boot — ISO is only for initial install
# After install, the system is ~2-3 GB on disk
```

## What Takes the Most Space

| Component | Approx Size | Notes |
|-----------|------------|-------|
| 20 Agent CLIs | ~1.5 GB | 16 Nix-built, 3 npm launchers, 1 PyPI launcher (download on first run) |
| Language toolchains (all 20+) | ~3-4 GB | Python, Node, Go, Rust, Java... |
| Databases (Postgres, Redis) | ~300 MB | |
| Browser tools (Chromium) | ~400 MB | |
| AI/ML tools | ~500 MB | |
| VIBE library | ~50 MB | Text files, cached via npx |
| NixOS base system | ~800 MB | Kernel, systemd, core utils |
| Observability (Grafana) | ~200 MB | |

## What the ISO contains

The flake builds one ISO (`nix build .#iso-image`). It's a minimal installer:
the live system has the installer and basic tools, not the agents or
toolchains. `nestlo-install` then installs the full `nestlo` configuration
to disk, downloading packages from cache.nixos.org.

The live ISO also carries the small Nestlo CLIs (`nestlo`, `nestlo-task`,
`nestlo-schedule`, `nestlo-fleet`, `nestlo-market`, `nestlo-gpu`; shell
scripts and a pure-Python package). `all-agents` is deliberately left out: the
20 agents are over 1 GB compressed.

A fully pre-baked offline ISO (roughly 5-7 GB) would need a second ISO
configuration that includes the host's packages in the image; it doesn't
exist yet.
