# UI Skills (ibelick/ui-skills): skills for design engineers. Seven skills
# (UI cleanup, accessibility, metadata, motion performance, DESIGN.md
# authoring, UI audits, and a routing skill), the `ui-skills` CLI, and the
# project's hosted MCP server.
{ lib, stdenvNoCC, makeWrapper, nodejs, mkSkillPack, sources }:

let
  src = sources.ui-skills;

  # bin/ui-skills.js starts the TypeScript entry point through tsx, which would
  # pull in the site's whole dependency tree. The entry point only uses Node
  # built-ins and `fetch`, so Node's own type stripping runs it directly.
  ui-skills-cli = stdenvNoCC.mkDerivation {
    pname = "ui-skills";
    version = "0.2.4";
    inherit src;
    nativeBuildInputs = [ makeWrapper ];
    dontBuild = true;
    installPhase = ''
      install -Dm644 bin/ui-skills.ts $out/lib/ui-skills/ui-skills.ts
      makeWrapper ${lib.getExe nodejs} $out/bin/ui-skills \
        --add-flags "--no-warnings --experimental-strip-types $out/lib/ui-skills/ui-skills.ts"
    '';
    meta.mainProgram = "ui-skills";
  };
in
mkSkillPack {
  pack = "ui-skills";
  version = "0.2.4";
  inherit src;
  skills = {
    baseline-ui = "skills/baseline-ui";
    create-design-md = "skills/create-design-md";
    fixing-accessibility = "skills/fixing-accessibility";
    fixing-metadata = "skills/fixing-metadata";
    fixing-motion-performance = "skills/fixing-motion-performance";
    improve-ui = "skills/improve-ui";
    ui-skills-root = "skills/ui-skills-root";
  };
  tools = [ ui-skills-cli ];
  # The registry is hosted at ui-skills.com; mcp-remote bridges its HTTP MCP
  # endpoint (tools list_skills and get_skill) to stdio.
  mcp.ui-skills = {
    command = "${nodejs}/bin/npx";
    args = [ "-y" "mcp-remote" "https://www.ui-skills.com/mcp" ];
  };
  description = "UI Skills: UI cleanup, accessibility, metadata and motion-performance fixes, DESIGN.md authoring, UI audits";
  homepage = "https://github.com/ibelick/ui-skills";
  license = "MIT";
  notes = ''
    The bundled skills work offline. The `ui-skills` CLI (start, categories,
    list, get) and the ui-skills MCP server read the skill registry from
    https://www.ui-skills.com at run time, so they need network access. The
    MCP entry starts through `npx -y mcp-remote`, which downloads mcp-remote
    from the npm registry on first use.
  '';
}
