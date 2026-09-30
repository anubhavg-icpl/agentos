# ═══════════════════════════════════════════════════════════════════════
# AgentOS — Agent Package Registry
# ═══════════════════════════════════════════════════════════════════════
#
# Every coding agent is exposed here as a Nix package and pre-installed on
# AgentOS via `all-agents` (see nixos/hosts/agentos/default.nix).
#
#   nix profile install .#claude-code
#   nix run .#codex
#
# Three kinds of packages live here:
#
#   1. Nix-built agents. These come from nixpkgs (unstable, since agent CLIs
#      move fast) and are fully reproducible: pinned by flake.lock, built
#      or substituted from cache.nixos.org, no network access at runtime
#      beyond the agent's own API calls.
#
#   2. npm launchers. Agents that nixpkgs doesn't package yet are wrapped
#      as `npx -y <package>@<version>`. The version is pinned, but the
#      code is fetched from registry.npmjs.org on first run, so the host
#      needs egress to the npm registry and the result is not
#      content-addressed. Replace these with real derivations as they
#      land in nixpkgs.
#
#   3. PyPI launchers. Same idea through `uvx`, for Python agents nixpkgs
#      cannot build (fetched from pypi.org on first run).
#
# ┌──────────────────┬──────────────┬───────────────────────┬───────────┐
# │ Agent            │ Command      │ Package               │ Source    │
# ├──────────────────┼──────────────┼───────────────────────┼───────────┤
# │ Claude Code      │ claude       │ claude-code           │ nixpkgs   │
# │ Codex CLI        │ codex        │ codex                 │ nixpkgs   │
# │ Aider            │ aider        │ aider                 │ nixpkgs   │
# │ Gemini CLI       │ gemini       │ gemini-cli            │ nixpkgs   │
# │ Qwen Code        │ qwen         │ qwen-code             │ nixpkgs   │
# │ Amp              │ amp          │ amp                   │ nixpkgs   │
# │ Goose            │ goose        │ goose                 │ nixpkgs   │
# │ OpenCode         │ opencode     │ opencode              │ nixpkgs   │
# │ Crush            │ crush        │ crush                 │ nixpkgs   │
# │ Cursor CLI       │ cursor-agent │ cursor-cli            │ nixpkgs   │
# │ Copilot CLI      │ copilot      │ github-copilot-cli    │ nixpkgs   │
# │ Factory Droid    │ droid        │ factory-droid         │ npm       │
# │ Cline            │ cline        │ cline                 │ npm       │
# │ Continue         │ cn           │ continue-cli          │ npm       │
# │ Open Interpreter │ interpreter  │ open-interpreter      │ PyPI      │
# └──────────────────┴──────────────┴───────────────────────┴───────────┘
#
# ═══════════════════════════════════════════════════════════════════════

{ pkgs
, lib ? pkgs.lib
, ...
}:

let
  # Agent CLIs are taken from nixpkgs-unstable (provided by the flake
  # overlay as pkgs.unstable); fall back to pkgs when used standalone.
  up = pkgs.unstable or pkgs;

  # ── Shared base tools every coding agent needs ─────────────────────
  baseTools = with pkgs; [
    git
    gh
    ripgrep
    fd
    curl
    wget
    jq
    fzf
    bat
    eza
    tree
    unzip
    gzip
    xz
    gnutar
    gnumake
    gcc
  ];

  nodejs = pkgs.nodejs_22;

  # ── Helper: re-export a nixpkgs agent with extra command aliases ───
  # `aliases` maps alias -> target binary inside the package.
  withAliases = { pkg, aliases ? { } }:
    if aliases == { } then pkg else
    pkgs.symlinkJoin {
      name = "${pkg.pname or pkg.name}-agentos";
      paths = [ pkg ];
      postBuild = lib.concatStrings (lib.mapAttrsToList (alias: target: ''
        ln -s $out/bin/${target} $out/bin/${alias}
      '') aliases);
      inherit (pkg) meta;
    };

  # ── Helper: pinned npm launcher for agents not yet in nixpkgs ──────
  mkNpmLauncher = { name, npmPackage, version, bin, commands ? [ bin ], description }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        ${lib.concatMapStrings (cmd: ''
          makeWrapper ${nodejs}/bin/npx $out/bin/${cmd} \
            --add-flags "--yes --package=${npmPackage}@${version} -- ${bin}" \
            --prefix PATH : ${lib.makeBinPath (baseTools ++ [ nodejs ])}
        '') commands}
        runHook postInstall
      '';

      meta = {
        inherit description;
        mainProgram = lib.head commands;
        platforms = lib.platforms.linux;
      };
    };

  # ── Helper: pinned PyPI launcher (uvx) for Python agents ───────────
  mkUvxLauncher = { name, pypiPackage, version, bin, python, description, extraPackages ? [ ] }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = name;
      inherit version;
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.makeWrapper ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        makeWrapper ${pkgs.uv}/bin/uvx $out/bin/${bin} \
          --set UV_PYTHON_DOWNLOADS never \
          --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.zlib ]} \
          --add-flags "--python ${python}/bin/python3 --from ${pypiPackage}==${version} ${lib.concatMapStrings (w: "--with '${w}' ") extraPackages}${bin}" \
          --prefix PATH : ${lib.makeBinPath baseTools}
        runHook postInstall
      '';

      meta = {
        inherit description;
        mainProgram = bin;
        platforms = lib.platforms.linux;
      };
    };

in
rec {
  # ════════════════════════════════════════════════════════════════════
  # NIX-BUILT AGENTS (from nixpkgs)
  # ════════════════════════════════════════════════════════════════════

  claude-code = up.claude-code;
  codex = up.codex;
  aider = up.aider-chat;
  gemini-cli = up.gemini-cli;
  qwen-code = withAliases { pkg = up.qwen-code; aliases = { qwen-code = "qwen"; }; };
  amp = up.amp-cli;
  goose = up.goose-cli;
  opencode = up.opencode;
  crush = up.crush;
  cursor-cli = withAliases { pkg = up.cursor-cli; aliases = { cursor = "cursor-agent"; }; };
  github-copilot-cli = up.github-copilot-cli;


  # ════════════════════════════════════════════════════════════════════
  # NPM LAUNCHERS (fetched from registry.npmjs.org on first run)
  # ════════════════════════════════════════════════════════════════════

  # https://docs.factory.ai
  factory-droid = mkNpmLauncher {
    name = "factory-droid";
    npmPackage = "@factory/cli";
    version = "0.229.0";
    bin = "droid";
    description = "Factory Droid — AI software engineering agent";
  };

  # https://github.com/cline/cline
  cline = mkNpmLauncher {
    name = "cline";
    npmPackage = "cline";
    version = "3.0.65";
    bin = "cline";
    description = "Cline — autonomous coding agent CLI";
  };

  # https://github.com/continuedev/continue
  continue-cli = mkNpmLauncher {
    name = "continue-cli";
    npmPackage = "@continuedev/cli";
    version = "1.5.47";
    bin = "cn";
    commands = [ "cn" "continue" ];
    description = "Continue — open-source AI code assistant CLI";
  };

  # ════════════════════════════════════════════════════════════════════
  # PYPI LAUNCHERS (fetched from pypi.org on first run)
  # ════════════════════════════════════════════════════════════════════

  # https://github.com/OpenInterpreter/open-interpreter
  # (marked broken in nixpkgs; nixpkgs-unstable reuses the attribute name
  # for an unrelated project)
  open-interpreter = mkUvxLauncher {
    name = "open-interpreter";
    pypiPackage = "open-interpreter";
    version = "0.4.3";
    bin = "interpreter";
    python = pkgs.python311;
    # 0.4.3 still imports pkg_resources, which setuptools 81 removed
    extraPackages = [ "setuptools<81" ];
    description = "Open Interpreter — let LLMs run code";
  };

  # ════════════════════════════════════════════════════════════════════
  # META-PACKAGES
  # ════════════════════════════════════════════════════════════════════

  # ── Every agent ────────────────────────────────────────────────────
  all-agents = pkgs.buildEnv {
    name = "agentos-all-agents";
    paths = [
      claude-code codex aider gemini-cli qwen-code amp goose opencode
      crush cursor-cli github-copilot-cli
      factory-droid cline continue-cli open-interpreter
    ];
    ignoreCollisions = true;
  };

  # ── Only reproducible, Nix-built agents ────────────────────────────
  nix-agents = pkgs.buildEnv {
    name = "agentos-nix-agents";
    paths = [
      claude-code codex aider gemini-cli qwen-code amp goose opencode
      crush cursor-cli github-copilot-cli
    ];
    ignoreCollisions = true;
  };

  # ════════════════════════════════════════════════════════════════════
  # AGENTOS INTERNAL TOOLS
  # ════════════════════════════════════════════════════════════════════
  cli = pkgs.callPackage ../nixos/packages/cli.nix { };
  services = pkgs.callPackage ../nixos/packages/services.nix { };
  installer = pkgs.callPackage ../nixos/packages/installer.nix { };
  # Client CLIs of the orchestrator and scheduler services (in `services`)
  task-cli = pkgs.callPackage ../nixos/packages/task-cli.nix { };
  schedule-cli = pkgs.callPackage ../nixos/packages/schedule-cli.nix { };

  # Service daemons. These are placeholders with no source code yet;
  # they are only referenced when agentos.daemons.enable = true.
  daemon = pkgs.callPackage ../nixos/packages/daemon.nix { };
  mcp-gateway = pkgs.callPackage ../nixos/packages/mcp-gateway.nix { };
  model-gateway = pkgs.callPackage ../nixos/packages/model-gateway.nix { };
  memory-manager = pkgs.callPackage ../nixos/packages/memory-manager.nix { };
  mcp-registry = pkgs.callPackage ../nixos/packages/mcp-registry.nix { };
  budget-controller = pkgs.callPackage ../nixos/packages/budget-controller.nix { };
  provisioner = pkgs.callPackage ../nixos/packages/provisioner.nix { };
  notifier = pkgs.callPackage ../nixos/packages/notifier.nix { };
  circuit-breaker = pkgs.callPackage ../nixos/packages/circuit-breaker.nix { };
}
