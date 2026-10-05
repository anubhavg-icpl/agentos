# Commands each agent package puts on PATH: package attribute -> commands,
# the first being the primary one (the package's mainProgram). The runtime
# agent map (nestlo.runtime.agents in modules/runtime/default.nix) must
# point only at these commands, and every package here must be part of
# `all-agents`; the `agent-inclusion` flake check enforces both at
# evaluation time. Update this file when adding an agent to default.nix.
{
  claude-code = [ "claude" ];
  codex = [ "codex" ];
  aider = [ "aider" ];
  antigravity-cli = [ "agy" ];
  # Deprecated upstream (retired 2026-06-18); use antigravity-cli
  gemini-cli = [ "gemini" ];
  qwen-code = [ "qwen" "qwen-code" ];
  amp = [ "amp" ];
  goose = [ "goose" ];
  opencode = [ "opencode" ];
  crush = [ "crush" ];
  cursor-cli = [ "cursor-agent" "cursor" ];
  github-copilot-cli = [ "copilot" ];
  kilocode-cli = [ "kilocode" ];
  mistral-vibe = [ "vibe" ];
  kiro-cli = [ "kiro-cli" ];
  codebuff = [ "codebuff" ];
  pi-coding-agent = [ "pi" ];
  grok-cli = [ "grok" ];
  factory-droid = [ "droid" ];
  cline = [ "cline" ];
  continue-cli = [ "cn" "continue" ];
  open-interpreter = [ "interpreter" ];
}
