# VM test of agentos.skills.
#
#   nix build .#checks.x86_64-linux.skills
#
# Enables all skill packs and checks, for the sandboxed agent user and an
# extra user:
#
#   skills are linked into ~/.claude/skills, ~/.codex/skills and
#   ~/.agents/skills (and the other targets), owned by the user -> a skill
#   the user wrote with the same name is left alone -> a stale link of ours
#   is removed on the next run -> `agentos-skills doctor` passes, and fails
#   when a link is missing -> the packs' tools are installed and their MCP
#   servers are in /etc/agentos/mcp-tools.json.
{ pkgs, agentosModules }:

pkgs.testers.runNixOSTest {
  name = "agentos-skills";
  globalTimeout = 600;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 2048;

    users.users.alice.isNormalUser = true;

    agentos = {
      runtime.enable = true;
      mcp-registry.enable = true;
      skills = {
        enable = true;
        users = [ "alice" ];
      };
    };
  };

  testScript = ''
    agent = "/var/lib/agentos/agent-home"
    alice = "/home/alice"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("agentos-skills-link-agentos-agent.service")
    machine.wait_for_unit("agentos-skills-link-alice.service")

    with subtest("skills are linked into the agent user's CLI directories"):
        for d in [".claude/skills", ".codex/skills", ".agents/skills", ".gemini/skills",
                  ".config/opencode/skills", ".copilot/skills", ".cursor/skills",
                  ".factory/skills", ".config/agents/skills", ".config/goose/skills"]:
            machine.succeed(f"test -f {agent}/{d}/baseline-ui/SKILL.md")
            machine.succeed(f"test -f {agent}/{d}/swiftui-liquid-glass/SKILL.md")
            machine.succeed(f"test -f {agent}/{d}/img2threejs/SKILL.md")
        # the links and their directories belong to the user, not root
        assert machine.succeed(f"stat -c %U {agent}/.claude/skills/baseline-ui").strip() == "agentos-agent"
        assert machine.succeed(f"stat -c %U {agent}/.claude/skills").strip() == "agentos-agent"
        assert machine.succeed(f"stat -c %U {alice}/.codex/skills/baseline-ui").strip() == "alice"
        target = machine.succeed(f"readlink {agent}/.agents/skills/baseline-ui").strip()
        assert "-agentos-skills-bundle/skills/baseline-ui" in target, target

    with subtest("a skill the user wrote is not replaced, stale links of ours are removed"):
        machine.succeed(f"su alice -c 'mkdir -p {alice}/.claude/skills/ui-skills-root && echo mine > {alice}/.claude/skills/ui-skills-root/SKILL.md'")
        machine.succeed(f"su alice -c 'rm {alice}/.claude/skills/baseline-ui && ln -s /nix/store/aaaa-agentos-skills-bundle/skills/gone {alice}/.claude/skills/gone'")
        machine.succeed("systemctl restart agentos-skills-link-alice.service")
        assert machine.succeed(f"cat {alice}/.claude/skills/ui-skills-root/SKILL.md").strip() == "mine"
        machine.succeed(f"test ! -L {alice}/.claude/skills/ui-skills-root")
        machine.succeed(f"test -f {alice}/.claude/skills/baseline-ui/SKILL.md")
        machine.succeed(f"test ! -e {alice}/.claude/skills/gone && test ! -L {alice}/.claude/skills/gone")

    with subtest("agentos-skills"):
        out = machine.succeed("agentos-skills list")
        print(out)
        for needle in ["ui-skills", "img2threejs", "fwc-swiftui-skills", "Apache-2.0", "mcp:"]:
            assert needle in out, needle
        coll = machine.succeed("agentos-skills list --collections")
        print(coll)
        for needle in ["design", "dev-workflow", "ui-skills (7)"]:
            assert needle in coll, needle
        path = machine.succeed("agentos-skills path baseline-ui").strip()
        machine.succeed(f"test -f {path}/SKILL.md")
        machine.fail("agentos-skills path no-such-skill")
        machine.succeed("agentos-skills doctor")
        machine.succeed(f"rm {agent}/.codex/skills/baseline-ui")
        machine.fail("agentos-skills doctor")
        machine.succeed("systemctl restart agentos-skills-link-agentos-agent.service")
        machine.succeed("agentos-skills doctor")

    with subtest("tools are installed and MCP servers registered"):
        machine.succeed("ui-skills --help | grep -q Usage")
        machine.succeed("img2threejs version | grep -q 'img2threejs CLI'")
        machine.succeed("${pkgs.jq}/bin/jq -e '.tools[] | select(.name == \"ui-skills\" and .category == \"extra\")' /etc/agentos/mcp-tools.json")
  '';
}
