### chisle

Makes the agent use fewer words and skip code the task does not need. Source: [JayPokale/Chisle](https://github.com/JayPokale/Chisle) (MIT).

Skills: `chisle` (the terse-prose and YAGNI-first ruleset), `chisle-review` (flag over-engineering in a diff), `chisle-audit` (ranked bloat report across code and prose), `chisle-help` (command card). They load in every agent CLI like any other skill.

In Claude Code the pack also installs three hooks: a session-start hook that injects the ruleset, a prompt hook that re-states it each turn and handles `/chisle` on/off, and a post-tool hook that trims oversized tool output (long `Bash`, `Grep`, `WebFetch` and MCP results) before the agent reads it. Elided text is kept under `~/.claude/chisle-spill/` so the agent can grep it back.

Because the hooks change what every Claude Code session sees, the pack is not enabled by default (`defaultEnable = false`). Enable it explicitly:

```nix
agentos.skills.packs.chisle.enable = true;   # exact option name is set by the skills module
```

The module merges the pack's `passthru.claudeHooks` into Claude Code's managed settings (`/etc/claude-code/managed-settings.json`), pointing at the node scripts in the Nix store. Nothing is written to `~/.claude` at build time.

Runtime switches (environment): `CHISLE_DEFAULT_MODE=off` disables the ruleset, `CHISLE_COMPRESS=0` disables output trimming, `CHISLE_COMPRESS_TOOLS=Bash,Grep` narrows which tools are trimmed. Inside a session, `/chisle off` and `/chisle` toggle it.

The upstream installer (`npx chisle`) is not exposed: it edits `~/.claude` and other agents' config files, which Nix manages.
