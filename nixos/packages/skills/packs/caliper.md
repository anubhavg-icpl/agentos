### caliper

Tests whether a skill actually helps. Caliper runs the agent on the same tasks with and without the skill (it also works for MCP servers and other instructions), judges the results and compares them. Source: edonadei/caliper 0.17.0 (MIT).

- Skills: `grill-skill`, `evaluate-skill`.
- Tool: `caliper` on PATH (`caliper run my-skill.eval.yaml`, `caliper report`, `caliper compare`).
- Caliper drives agent CLIs (`claude`, `codex`, `pi`, `hermes`) that it finds on PATH; it is not wrapped and brings none of them. Enable the agent you want to evaluate.
- Network and keys: the unit tests are offline, but every real evaluation calls the agent's model, so the agent CLI must be logged in or keyed (an Anthropic or OpenAI key, or a subscription login), and it costs tokens. Git skill sources (`git:` entries in a spec) need `git` on PATH and network access. Nothing else phones home.
- Build: `python3Packages.buildPythonApplication` from the pinned source with nixpkgs dependencies, no patches. The full upstream test suite (1035 tests) runs during the build.
