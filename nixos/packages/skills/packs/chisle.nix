# Chisle: terse prose and YAGNI-first code for the agent, plus (Claude Code
# only) hooks that trim tool output before the agent reads it.
#
# The skills are plain Markdown. The hooks are node scripts; they are shipped
# under share/nestlo/chisle/ with the layout they expect (hooks/ next to
# skills/chisle/SKILL.md) and exposed as `passthru.claudeHooks`, a Claude Code
# `hooks` settings fragment that points at the store paths. The NixOS module
# merges it into Claude Code's managed settings; nothing is written to ~/.claude
# at build time. The upstream installer (bin/install.js, `npx chisle`) edits
# ~/.claude and other agents' config in place, so it is deliberately not
# exposed: Nix manages those files.
{ lib, stdenvNoCC, nodejs, mkSkillPack, sources }:

let
  src = sources.chisle;
  node = "${nodejs}/bin/node";

  base = mkSkillPack {
    pack = "chisle";
    version = "3.7.0";
    inherit src;
    skills = {
      chisle = "skills/chisle";
      chisle-review = "skills/chisle-review";
      chisle-help = "skills/chisle-help";
      chisle-audit = "skills/chisle-audit";
    };
    description = "Terse zero-fluff prose and YAGNI-first code; Claude Code hooks trim oversized tool output";
    homepage = "https://github.com/JayPokale/Chisle";
    license = "MIT";
    notes = ''
      Skills are always safe to load. The Claude Code hooks (passthru.claudeHooks)
      inject a terse-mode ruleset every session and replace oversized tool output
      with a trimmed version, so they change behavior globally and are off unless
      the pack is enabled explicitly. State (mode flag, savings stats, spilled
      originals) is written at runtime under $CLAUDE_CONFIG_DIR (default ~/.claude).
      Set CHISLE_DEFAULT_MODE=off or CHISLE_COMPRESS=0 to disable at runtime.
      The upstream installer (npx chisle) is not exposed; it writes into ~/.claude.
    '';
  };

  # hooks/ must sit next to skills/chisle/SKILL.md: chisle-activate.js reads
  # ../skills/chisle/SKILL.md relative to itself.
  placed = stdenvNoCC.mkDerivation {
    pname = "nestlo-chisle-hooks";
    version = "3.7.0";
    inherit src;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      d=$out/share/nestlo/chisle
      mkdir -p $d/skills
      cp -r hooks $d/hooks
      cp -r skills/chisle $d/skills/chisle
      chmod -R u+w $d
      substituteInPlace $d/hooks/chisle-statusline.sh --replace-quiet '#!/bin/bash' '#!/usr/bin/env bash'
      runHook postInstall
    '';
  };

  hooksDir = "${placed}/share/nestlo/chisle/hooks";

  cmd = script: "CHISLE_UPDATE_CHECK=0 ${node} ${hooksDir}/${script}; exit 0";

  claudeHooks = {
    SessionStart = [{
      matcher = "startup|resume|clear|compact";
      hooks = [{ type = "command"; command = cmd "chisle-activate.js"; timeout = 5; statusMessage = "Loading chisle mode..."; }];
    }];
    UserPromptSubmit = [{
      hooks = [{ type = "command"; command = cmd "chisle-mode-tracker.js"; timeout = 5; statusMessage = "Tracking chisle mode..."; }];
    }];
    PostToolUse = [{
      matcher = "Bash|Agent|WebFetch|WebSearch|Grep|Glob|mcp__.*";
      hooks = [{ type = "command"; command = cmd "chisle-compress-output.js"; timeout = 10; statusMessage = "Compressing tool output..."; }];
    }];
  };
in
base.overrideAttrs (old: {
  installPhase = old.installPhase + ''
    mkdir -p $out/share/nestlo/chisle
    ln -s ${placed}/share/nestlo/chisle/hooks $out/share/nestlo/chisle/hooks
    ln -s ${placed}/share/nestlo/chisle/skills $out/share/nestlo/chisle/skills
  '';
  passthru = old.passthru // {
    inherit claudeHooks;
    hooksPath = hooksDir;
    # Output trimming and a per-session ruleset are global behavior changes.
    defaultEnable = false;
  };
})
