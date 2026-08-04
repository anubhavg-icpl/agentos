# AgentOS — ISO Size Analysis

## Estimated Sizes by Configuration

| Configuration | ISO Size | Installed | RAM (idle) |
|--------------|----------|-----------|------------|
| **Minimal** (core only, no agents) | ~800 MB | ~2.5 GB | ~256 MB |
| **Standard** (core + 22 agents) | ~2.5 GB | ~8 GB | ~512 MB |
| **Full** (all modules + toolchains) | ~5-7 GB | ~15-20 GB | ~1 GB |
| **Everything** (VIBE + all MCP + all tools) | ~8-10 GB | ~25-30 GB | ~1.5 GB |

## Why NixOS ISOs Are Larger

NixOS stores complete package closures in `/nix/store`, so the ISO includes every dependency for every program. This is the trade-off for reproducibility: no "works on my machine" issues.

## Keeping It Small

### Option 1: Minimal ISO (800 MB)
```nix
agentos = {
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
# The flake.nix already uses zstd level 19
# For even smaller: use xz
nix build .#iso-image --override-config isoImage.squashfsCompression "xz -Xdict-size 100%"
```

### Option 3: Netboot (no ISO needed)
```bash
# AgentOS can PXE boot — ISO is only for initial install
# After install, the system is ~2-3 GB on disk
```

## What Takes the Most Space

| Component | Approx Size | Notes |
|-----------|------------|-------|
| 22 Agent CLIs (npm wrappers) | ~200 MB | npx downloads on demand |
| Language toolchains (all 20+) | ~3-4 GB | Python, Node, Go, Rust, Java... |
| Databases (Postgres, Redis) | ~300 MB | |
| Browser tools (Chromium) | ~400 MB | |
| AI/ML tools | ~500 MB | |
| VIBE library | ~50 MB | Text files, cached via npx |
| NixOS base system | ~800 MB | Kernel, systemd, core utils |
| Observability (Grafana) | ~200 MB | |

## Recommended: Two ISOs

AgentOS builds two ISO variants:

1. **agentos-iso-minimal** (~800 MB): Just the installer + agent runtime. Agents and tools are fetched on first boot.
2. **agentos-iso-full** (~5-7 GB): Everything pre-baked. Works fully offline.
