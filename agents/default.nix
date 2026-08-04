# ═══════════════════════════════════════════════════════════════════════
# AgentOS — Agent Package Registry
# ═══════════════════════════════════════════════════════════════════════
#
# Every coding agent is packaged here as a Nix derivation.
# All agents are PRE-INSTALLED on AgentOS by default (see hosts/agentos/default.nix).
# Additional agents can be installed at runtime:
#
#   nix profile install .#claude-code
#   nix profile install .#codex
#   nix profile install .#droid
#
# Each agent gets the same shared base tools (git, ripgrep, fd, etc.) so
# they all work identically regardless of language runtime.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │                     PRE-INSTALLED AGENTS                            │
# ├──────────────────┬───────────────┬──────────────────────────────────┤
# │ Agent            │ Command       │ Type                             │
# ├──────────────────┼───────────────┼──────────────────────────────────┤
# │ Claude Code      │ claude        │ Anthropic CLI agent              │
# │ Codex            │ codex         │ OpenAI CLI agent                 │
# │ Factory Droid    │ droid         │ Factory AI CLI agent             │
# │ Aider            │ aider         │ AI pair programmer (terminal)    │
# │ Cursor CLI       │ cursor        │ Cursor headless agent            │
# │ Cline            │ cline         │ Autonomous coding agent          │
# │ Continue         │ continue      │ Open-source AI code assistant    │
# │ GitHub Copilot   │ copilot       │ GitHub Copilot CLI               │
# │ Devin CLI        │ devin         │ Cognition Devin CLI              │
# │ Open Interpreter │ interpreter   │ LLM code execution               │
# │ SWE-Agent        │ sweagent      │ Princeton SWE agent              │
# │ GPT-Engineer     │ gpt-engineer  │ Project builder                  │
# │ Devika           │ devika        │ Open-source Devin alternative    │
# │ AutoGPT          │ autogpt       │ Autonomous AI agents             │
# │ smol-developer   │ smol-dev      │ Minimal AI developer             │
# │ Roo Code         │ roo           │ Cline fork, VS Code agent        │
# │ Gemini CLI       │ gemini        │ Google Gemini CLI                │
# │ Qwen Code        │ qwen-code     │ Alibaba Qwen coding agent        │
# │ Amp              │ amp           │ Sourcegraph Amp CLI              │
# │ Goose            │ goose         │ Block Goose agent                │
# │ OpenCode         │ opencode      │ Open-source coding agent         │
# │ Crush            │ crush         │ Charm crush agent                │
# │ Codex (OSS)      │ opencode      │ SST opencode                     │
# └──────────────────┴───────────────┴──────────────────────────────────┘
#
# ═══════════════════════════════════════════════════════════════════════

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
, ...
}:

let
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
    tar
    gnumake
    gcc
    stdenv.cc.cc.lib
  ];

  # ── Language runtimes (shared) ─────────────────────────────────────
  nodejs = pkgs.nodejs_22;
  python = pkgs.python311;
  go = pkgs.go_1_23;

  # ── Helper: create a wrapper package from an npm global ────────────
  # This is how we package Node.js-based agents that are distributed via npm.
  mkNpmAgent = { name, description ? "", npmPackage ? name, command ? name, envVars ? { } }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "latest";
      dontUnpack = true;
      dontBuild = true;

      nativeBuildInputs = [ pkgs.makeWrapper ];

      installPhase = ''
        mkdir -p $out/bin

        cat > $out/bin/${command} <<'WRAPPER'
        #!/usr/bin/env bash
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=\"${v}\"") envVars)}
        exec ${nodejs}/bin/npx ${npmPackage} "$@"
        WRAPPER

        chmod +x $out/bin/${command}

        wrapProgram $out/bin/${command} \
          --prefix PATH : ${lib.makeBinPath (baseTools ++ [ nodejs ])}
      '';

      meta = {
        inherit description;
        mainProgram = command;
        platforms = lib.platforms.linux;
      };
    };

  # ── Helper: create a wrapper package from a pip install ────────────
  mkPipAgent = { name, description ? "", pipPackage, command ? name, extraPackages ? [ ] }:
    let
      pythonEnv = python.withPackages (ps:
        extraPackages ++ [
          (ps.callPackage (pkgs.writeText "pyproject-${name}.toml" "") { })
        ]
      );
    in
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "latest";
      dontUnpack = true;
      dontBuild = true;

      nativeBuildInputs = [ pkgs.makeWrapper python ];

      installPhase = ''
        mkdir -p $out/bin $out/lib/${name}

        # Create a virtual env with the package
        ${python}/bin/python -m venv $out/lib/${name}/venv
        source $out/lib/${name}/venv/bin/activate
        pip install --no-cache-dir ${pipPackage}
        deactivate

        cat > $out/bin/${command} <<'WRAPPER'
        #!/usr/bin/env bash
        source ${placeholder "out"}/lib/${name}/venv/bin/activate
        exec ${command} "$@"
        WRAPPER

        chmod +x $out/bin/${command}

        wrapProgram $out/bin/${command} \
          --prefix PATH : ${lib.makeBinPath (baseTools ++ [ python ])}
      '';

      meta = {
        inherit description;
        mainProgram = command;
        platforms = lib.platforms.linux;
      };
    };

  # ── Helper: create a wrapper package from a binary download ────────
  mkBinaryAgent = { name, description ? "", command ? name, installScript ? "" }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "latest";
      dontUnpack = true;
      dontBuild = true;

      nativeBuildInputs = [ pkgs.makeWrapper ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
        ${installScript}
        runHook postInstall

        # Ensure PATH wrapping for base tools
        if [ -f "$out/bin/${command}" ]; then
          wrapProgram $out/bin/${command} \
            --prefix PATH : ${lib.makeBinPath baseTools}
        fi
      '';

      meta = {
        inherit description;
        mainProgram = command;
        platforms = lib.platforms.linux;
      };
    };

in
rec {
  # ════════════════════════════════════════════════════════════════════
  # TIER 1 — PRIMARY CODING AGENTS (pre-installed, fully supported)
  # ════════════════════════════════════════════════════════════════════

  # ── Anthropic Claude Code ──────────────────────────────────────────
  # https://docs.anthropic.com/en/docs/claude-code
  claude-code = mkNpmAgent {
    name = "claude-code";
    command = "claude";
    npmPackage = "@anthropic-ai/claude-code";
    description = "Anthropic Claude Code — agentic coding CLI";
  };

  # ── OpenAI Codex CLI ───────────────────────────────────────────────
  # https://github.com/openai/codex
  codex = mkNpmAgent {
    name = "codex";
    command = "codex";
    npmPackage = "@openai/codex";
    description = "OpenAI Codex CLI — coding agent";
  };

  # ── Factory Droid CLI ──────────────────────────────────────────────
  # https://docs.factory.ai
  factory-droid = mkBinaryAgent {
    name = "factory-droid";
    command = "droid";
    description = "Factory Droid — AI software engineering agent";
    installScript = ''
      # Install via npm (factory distributes via npm)
      ${nodejs}/bin/npm install -g @factory-ai/droid --prefix $out
      ln -sf $out/lib/node_modules/@factory-ai/droid/bin/droid $out/bin/droid 2>/dev/null || true

      # Fallback wrapper
      cat > $out/bin/droid <<'WRAPPER'
      #!/usr/bin/env bash
      exec ${nodejs}/bin/npx -y @factory-ai/droid "$@"
      WRAPPER
      chmod +x $out/bin/droid
    '';
  };

  # ── Aider — AI pair programming in terminal ────────────────────────
  # https://aider.chat
  aider = pkgs.python311.pkgs.buildPythonPackage {
    pname = "aider-chat";
    version = "0.82.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "Aider-AI";
      repo = "aider";
      rev = "v0.82.0";
      hash = lib.fakeHash;
    };

    nativeBuildInputs = [ pkgs.python311.pkgs.pip ];

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      # Core deps — aider uses these
      litellm
      openai
      anthropic
      rich
      prompt-toolkit
      gitpython
      tree-sitter
      tree-sitter-languages
      pypandoc
      scipy
      backoff
      jinja2
      jsonschema
      pydantic
      networkx
      diskcache
      sounddevice
      soundfile
    ];

    # Aider needs git in PATH
    makeWrapperArgs = [
      "--prefix PATH : ${lib.makeBinPath baseTools}"
    ];

    meta = {
      description = "Aider — AI pair programming in terminal";
      mainProgram = "aider";
      homepage = "https://aider.chat";
    };
  };

  # ── Google Gemini CLI ──────────────────────────────────────────────
  # https://github.com/google-gemini/gemini-cli
  gemini-cli = mkNpmAgent {
    name = "gemini-cli";
    command = "gemini";
    npmPackage = "@anthropic-ai/gemini-cli";
    description = "Google Gemini CLI — coding agent";
  };

  # ── Qwen Code (Alibaba) ────────────────────────────────────────────
  # https://github.com/QwenLM/qwen-code
  qwen-code = mkNpmAgent {
    name = "qwen-code";
    command = "qwen-code";
    npmPackage = "@alibaba/qwen-code";
    description = "Qwen Code — Alibaba coding agent";
  };

  # ── Sourcegraph Amp ────────────────────────────────────────────────
  # https://github.com/sourcegraph/amp
  amp = mkNpmAgent {
    name = "amp";
    command = "amp";
    npmPackage = "@sourcegraph/amp";
    description = "Sourcegraph Amp — coding agent";
  };

  # ── Block Goose ────────────────────────────────────────────────────
  # https://github.com/block/goose
  goose = mkBinaryAgent {
    name = "goose";
    command = "goose";
    description = "Block Goose — open-source AI agent";
    installScript = ''
      # Goose is a Rust binary distributed via cargo or installer script
      ${pkgs.cargo}/bin/cargo install goose-cli 2>/dev/null || true
      # Fallback: installer script
      cat > $out/bin/goose <<'WRAPPER'
      #!/usr/bin/env bash
      exec ${pkgs.bash}/bin/bash -c "curl -fsSL https://github.com/block/goose/releases/download/latest/install.sh | bash && goose \"$@\""
      WRAPPER
      chmod +x $out/bin/goose
    '';
  };

  # ── OpenCode (SST) ─────────────────────────────────────────────────
  # https://github.com/sst/opencode
  opencode = mkNpmAgent {
    name = "opencode";
    command = "opencode";
    npmPackage = "@sst/opencode";
    description = "OpenCode — open-source AI coding agent (SST)";
  };

  # ── Crush (Charm) ──────────────────────────────────────────────────
  # https://github.com/charmbracelet/crush
  crush = mkBinaryAgent {
    name = "crush";
    command = "crush";
    description = "Charm Crush — AI coding agent";
    installScript = ''
      # Crush is a Go binary
      cat > $out/bin/crush <<'WRAPPER'
      #!/usr/bin/env bash
      exec ${go}/bin/go run github.com/charmbracelet/crush@latest "$@"
      WRAPPER
      chmod +x $out/bin/crush
    '';
  };

  # ════════════════════════════════════════════════════════════════════
  # TIER 2 — EXTENDED CODING AGENTS (pre-installed, supported)
  # ════════════════════════════════════════════════════════════════════

  # ── Cursor CLI (headless agent mode) ───────────────────────────────
  cursor-cli = mkNpmAgent {
    name = "cursor-cli";
    command = "cursor";
    npmPackage = "@cursor-ai/cli";
    description = "Cursor CLI — headless agent mode";
  };

  # ── Cline ──────────────────────────────────────────────────────────
  # https://github.com/cline/cline
  cline = mkNpmAgent {
    name = "cline";
    command = "cline";
    npmPackage = "@cline/cli";
    description = "Cline — autonomous coding agent";
  };

  # ── Continue Dev ───────────────────────────────────────────────────
  # https://github.com/continuedev/continue
  continue-cli = mkNpmAgent {
    name = "continue-cli";
    command = "continue";
    npmPackage = "@continuedev/cli";
    description = "Continue — open-source AI code assistant";
  };

  # ── GitHub Copilot CLI ─────────────────────────────────────────────
  # https://docs.github.com/copilot
  github-copilot-cli = pkgs.stdenv.mkDerivation {
    pname = "github-copilot-cli";
    version = "1.0.0";
    dontUnpack = true;
    dontBuild = true;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    installPhase = ''
      mkdir -p $out/bin

      # GitHub Copilot CLI is a gh extension
      cat > $out/bin/copilot <<'EOF'
      #!/usr/bin/env bash
      exec ${pkgs.gh}/bin/gh copilot "$@"
      EOF

      cat > $out/bin/github-copilot <<'EOF'
      #!/usr/bin/env bash
      exec ${pkgs.gh}/bin/gh copilot "$@"
      EOF

      chmod +x $out/bin/copilot $out/bin/github-copilot

      wrapProgram $out/bin/copilot \
        --prefix PATH : ${lib.makeBinPath (baseTools ++ [ pkgs.gh ])}
      wrapProgram $out/bin/github-copilot \
        --prefix PATH : ${lib.makeBinPath (baseTools ++ [ pkgs.gh ])}
    '';

    meta = {
      description = "GitHub Copilot CLI";
      mainProgram = "copilot";
    };
  };

  # ── Devin CLI (Cognition) ──────────────────────────────────────────
  devin-cli = mkNpmAgent {
    name = "devin-cli";
    command = "devin";
    npmPackage = "@cognition-ai/devin-cli";
    description = "Devin CLI — Cognition AI software engineer";
  };

  # ── Roo Code (Cline fork) ──────────────────────────────────────────
  roo-code = mkNpmAgent {
    name = "roo-code";
    command = "roo";
    npmPackage = "@roo-code/cli";
    description = "Roo Code — autonomous coding agent (Cline fork)";
  };

  # ════════════════════════════════════════════════════════════════════
  # TIER 3 — RESEARCH / EXPERIMENTAL AGENTS (pre-installed)
  # ════════════════════════════════════════════════════════════════════

  # ── Open Interpreter ───────────────────────────────────────────────
  # https://github.com/OpenInterpreter/open-interpreter
  open-interpreter = pkgs.python311.pkgs.buildPythonPackage {
    pname = "open-interpreter";
    version = "0.4.3";
    pyproject = true;
    format = "pyproject";

    src = pkgs.fetchFromGitHub {
      owner = "OpenInterpreter";
      repo = "open-interpreter";
      rev = "v0.4.3";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      appdirs
      astor
      gitpython
      inquirer
      jinja2
      openai
      pyreadline3
      python-dotenv
      pyyaml
      rich
      tokentrim
      tqdm
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "Open Interpreter — let LLMs run code";
      mainProgram = "interpreter";
    };
  };

  # ── SWE-Agent (Princeton) ──────────────────────────────────────────
  # https://github.com/SWE-agent/SWE-agent
  swe-agent = pkgs.python311.pkgs.buildPythonPackage {
    pname = "swe-agent";
    version = "1.0.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "SWE-agent";
      repo = "SWE-agent";
      rev = "v1.0.0";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      anthropic
      openai
      rich
      jinja2
      pyyaml
      tenacity
      tqdm
      lodash
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "SWE-Agent — Princeton software engineering agent";
      mainProgram = "sweagent";
    };
  };

  # ── GPT-Engineer ───────────────────────────────────────────────────
  # https://github.com/gpt-engineer-org/gpt-engineer
  gpt-engineer = pkgs.python311.pkgs.buildPythonPackage {
    pname = "gpt-engineer";
    version = "0.3.1";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "gpt-engineer-org";
      repo = "gpt-engineer";
      rev = "v0.3.1";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      openai
      anthropic
      tiktoken
      langchain
      tabulate
      termcolor
      pydantic
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "GPT-Engineer — specify software, get code";
      mainProgram = "gpt-engineer";
    };
  };

  # ── Devika (open-source Devin alternative) ─────────────────────────
  # https://github.com/stitionai/devika
  devika = pkgs.python311.pkgs.buildPythonPackage {
    pname = "devika";
    version = "0.2.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "stitionai";
      repo = "devika";
      rev = "main";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      flask
      openai
      anthropic
      langchain
      celery
      redis
      pydantic
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "Devika — open-source AI software engineer";
      mainProgram = "devika";
    };
  };

  # ── AutoGPT ────────────────────────────────────────────────────────
  # https://github.com/Significant-Gravitas/AutoGPT
  auto-gpt = pkgs.python311.pkgs.buildPythonPackage {
    pname = "auto-gpt";
    version = "0.6.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "Significant-Gravitas";
      repo = "AutoGPT";
      rev = "v0.6.0";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      openai
      anthropic
      fastapi
      pydantic
      redis
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "AutoGPT — autonomous AI agents";
      mainProgram = "autogpt";
    };
  };

  # ── smol-developer ─────────────────────────────────────────────────
  # https://github.com/smol-ai/smol-developer
  smol-developer = pkgs.python311.pkgs.buildPythonPackage {
    pname = "smol-developer";
    version = "1.0.0";
    pyproject = true;

    src = pkgs.fetchFromGitHub {
      owner = "smol-ai";
      repo = "smol-developer";
      rev = "main";
      hash = lib.fakeHash;
    };

    propagatedBuildInputs = with pkgs.python311.pkgs; [
      openai
      tiktoken
      anthropic
      tree-sitter
      tree-sitter-languages
    ];

    makeWrapperArgs = [ "--prefix PATH : ${lib.makeBinPath baseTools}" ];

    meta = {
      description = "smol-developer — minimal AI developer";
      mainProgram = "smol-developer";
    };
  };

  # Smol-developer short alias
  smol-dev = smol-developer;

  # ════════════════════════════════════════════════════════════════════
  # META-PACKAGES
  # ════════════════════════════════════════════════════════════════════

  # ── Install ALL agents at once ─────────────────────────────────────
  all-agents = pkgs.buildEnv {
    name = "agentos-all-agents";
    paths = [
      # Tier 1
      claude-code
      codex
      factory-droid
      aider
      gemini-cli
      qwen-code
      amp
      goose
      opencode
      crush
      # Tier 2
      cursor-cli
      cline
      continue-cli
      github-copilot-cli
      devin-cli
      roo-code
      # Tier 3
      open-interpreter
      swe-agent
      gpt-engineer
      devika
      auto-gpt
      smol-developer
    ];
  };

  # ── Tier 1 only (primary agents) ──────────────────────────────────
  tier1-agents = pkgs.buildEnv {
    name = "agentos-tier1-agents";
    paths = [
      claude-code
      codex
      factory-droid
      aider
      gemini-cli
      qwen-code
      amp
      goose
      opencode
      crush
    ];
  };

  # ── Tier 1 + Tier 2 ────────────────────────────────────────────────
  tier2-agents = pkgs.buildEnv {
    name = "agentos-tier2-agents";
    paths = [
      claude-code
      codex
      factory-droid
      aider
      gemini-cli
      qwen-code
      amp
      goose
      opencode
      crush
      cursor-cli
      cline
      continue-cli
      github-copilot-cli
      devin-cli
      roo-code
    ];
  };

  # ════════════════════════════════════════════════════════════════════
  # AGENTOS INTERNAL TOOLS
  # ════════════════════════════════════════════════════════════════════
  daemon = pkgs.callPackage ./../nixos/packages/daemon.nix { inherit baseTools; };
  mcp-gateway = pkgs.callPackage ./../nixos/packages/mcp-gateway.nix { inherit baseTools; };
  model-gateway = pkgs.callPackage ./../nixos/packages/model-gateway.nix { inherit baseTools; };
  cli = pkgs.callPackage ./../nixos/packages/cli.nix { inherit baseTools; };
  # New internal tools for feature modules
  memory-manager = pkgs.callPackage ./../nixos/packages/memory-manager.nix { inherit baseTools; };
  orchestrator = pkgs.callPackage ./../nixos/packages/orchestrator.nix { inherit baseTools; };
  mcp-registry = pkgs.callPackage ./../nixos/packages/mcp-registry.nix { inherit baseTools; };
  budget-controller = pkgs.callPackage ./../nixos/packages/budget-controller.nix { inherit baseTools; };
  provisioner = pkgs.callPackage ./../nixos/packages/provisioner.nix { inherit baseTools; };
  notifier = pkgs.callPackage ./../nixos/packages/notifier.nix { inherit baseTools; };
  circuit-breaker = pkgs.callPackage ./../nixos/packages/circuit-breaker.nix { inherit baseTools; };
  scheduler = pkgs.callPackage ./../nixos/packages/scheduler.nix { inherit baseTools; };
  installer = pkgs.callPackage ./../nixos/packages/installer.nix { };
}
