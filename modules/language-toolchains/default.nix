# ═══════════════════════════════════════════════════════════════════════
# AgentOS Language Toolchains Module
# ═══════════════════════════════════════════════════════════════════════
#
# Pre-installs every major programming language runtime, compiler,
# package manager, and linter/formatter so agents can work on ANY
# project without needing to install anything.
#
# Languages: 20+ runtimes
# Package managers: 15+ managers
# Linters/formatters: 20+ tools
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.language-toolchains;
in
{
  options.agentos.language-toolchains = {
    enable = lib.mkEnableOption "AgentOS language toolchains (all runtimes pre-installed)";

    enableAll = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install ALL language toolchains (set false for minimal)";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = lib.flatten [
      # ════════════════════════════════════════════════════════════════
      # PYTHON
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        python311 python311Packages.pip python311Packages.virtualenv python311Packages.setuptools python311Packages.wheel
        python312 python312Packages.pip python312Packages.virtualenv
        uv pipx poetry conda rye
        # Python linters/formatters
        ruff black mypy pyright isort pylint flake8
        # Python tools
        ipython jupyter httpx
      ]))

      # ════════════════════════════════════════════════════════════════
      # JAVASCRIPT / TYPESCRIPT
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        nodejs_22 nodejs_20
        nodePackages.npm nodePackages.pnpm nodePackages.yarn nodePackages.bun
        nodePackages.ts-node nodePackages.tsx
        deno
        # JS/TS linters/formatters
        nodePackages.prettier nodePackages.eslint nodePackages.eslint_d
        typescript typescript-language-server
        # Build tools
        nodePackages.turbo nodePackages.vite nodePackages.webpack
        tailwindcss
      ]))

      # ════════════════════════════════════════════════════════════════
      # GO
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        go_1_23 go_1_22
        gopls gotools go-tools golangci-lint
        delve # debugger
        air # live reload
        mockery # mock generator
      ]))

      # ════════════════════════════════════════════════════════════════
      # RUST
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        rustc cargo rustfmt clippy rust-analyzer
        cargo-edit cargo-watch cargo-expand cargo-nextest
        cargo-audit cargo-outdated cargo-deny
        wasm-pack
        # Rust toolchain manager
        rustup
      ]))

      # ════════════════════════════════════════════════════════════════
      # C / C++
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        gcc13 gcc14 clang_18 clang-tools gnumake cmake ninja
        pkg-config autoconf automake libtool
        gdb valgrind
        # Package managers
        conan vcpkg
        # Formatters
        clang-format cppcheck
      ]))

      # ════════════════════════════════════════════════════════════════
      # JAVA / KOTLIN / SCALA
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        jdk21 jdk17
        maven gradle
        kotlin kotlin-native
        scala sbt
        # JVM tools
        coursier mill
        # Formatters/Linters
        google-java-format spotbugs
      ]))

      # ════════════════════════════════════════════════════════════════
      # RUBY
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        ruby_3_3
        rubyPackages.solargraph
        bundler rake
        rubocop
      ]))

      # ════════════════════════════════════════════════════════════════
      # PHP
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        php82 composer
        php82Packages.phpstan php82Packages.php-cs-fixer
      ]))

      # ════════════════════════════════════════════════════════════════
      # HASKELL
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        ghc haskellPackages.cabal-install haskellPackages.stack
        haskellPackages.haskell-language-server haskellPackages.hlint
      ]))

      # ════════════════════════════════════════════════════════════════
      # ELIXIR / ERLANG
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        elixir erlang
        mix # comes with elixir
      ]))

      # ════════════════════════════════════════════════════════════════
      # OCAML
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        ocaml dune_3 ocamlPackages.utop
        ocamlPackages.merlin ocamlPackages.ocamlformat
      ]))

      # ════════════════════════════════════════════════════════════════
      # ZIG
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        zig_0_13 zls
      ]))

      # ════════════════════════════════════════════════════════════════
      # LUA
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        lua5_4 luajit
        lua54Packages.luarocks
        stylua
      ]))

      # ════════════════════════════════════════════════════════════════
      # R / JULIA (data science)
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        R
        julia
      ]))

      # ════════════════════════════════════════════════════════════════
      # SWIFT
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        swift swift-format sourcekit-lsp
      ]))

      # ════════════════════════════════════════════════════════════════
      # DART / FLUTTER
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        dart flutter
      ]))

      # ════════════════════════════════════════════════════════════════
      # CLOJURE
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        clojure leiningen babashka
        clojure-lsp
      ]))

      # ════════════════════════════════════════════════════════════════
      # PERL
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        perl538
      ]))

      # ════════════════════════════════════════════════════════════════
      # NIM
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        nim nimble
      ]))

      # ════════════════════════════════════════════════════════════════
      # NIX (native, since we're NixOS)
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        nixfmt nixpkgs-fmt nil alejandra
        nixd
        statix manix
      ]))

      # ════════════════════════════════════════════════════════════════
      # SHELL SCRIPTING
      # ════════════════════════════════════════════════════════════════
      (lib.optionals cfg.enableAll (with pkgs; [
        bashInteractive zsh fish nushell
        shellcheck shfmt bash-language-server
      ]))
    ];

    # ── Language versions command ────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "agentos-langs" ''
        #!/usr/bin/env bash
        echo "╔══════════════════════════════════════════════╗"
        echo "║     AgentOS — Pre-installed Languages        ║"
        echo "╚══════════════════════════════════════════════╝"
        echo ""
        declare -A CMDS=(
          [Python 3.11]="python3.11 --version"
          [Python 3.12]="python3.12 --version"
          [Node.js 22]="node --version"
          [Deno]="deno --version"
          [Go 1.23]="go version"
          [Rust]="rustc --version"
          [C/GCC]="gcc --version"
          [Clang]="clang --version"
          [Java 21]="java --version"
          [Kotlin]="kotlin -version"
          [Scala]="scala -version"
          [Ruby]="ruby --version"
          [PHP]="php --version"
          [Haskell]="ghc --version"
          [Elixir]="elixir --version"
          [Erlang]="erl -version"
          [OCaml]="ocaml --version"
          [Zig]="zig version"
          [Lua]="lua -v"
          [R]="R --version"
          [Julia]="julia --version"
          [Swift]="swift --version"
          [Dart]="dart --version"
          [Clojure]="clojure --version"
          [Perl]="perl --version"
          [Nim]="nim --version"
          [Nix]="nix --version"
        )
        for lang in "''${!CMDS[@]}"; do
          printf "  %-20s " "$lang"
          eval "''${CMDS[$lang]}" 2>/dev/null | head -1 || echo "not available"
        done | sort
      '')
    ];
  };
}
