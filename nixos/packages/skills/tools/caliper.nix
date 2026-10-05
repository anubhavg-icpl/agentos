# caliper-eval: runs an agent with and without a skill (or MCP server, or
# other instructions) and compares the results. It drives agent CLIs (claude,
# codex, ...) it finds on PATH; it is not wrapped, so it sees the user's PATH
# and the agent CLIs installed there.
{ python3Packages, git, sources }:

python3Packages.buildPythonApplication {
  pname = "caliper-eval";
  version = "0.17.0";
  pyproject = true;
  src = sources.caliper;

  build-system = [ python3Packages.hatchling ];
  dependencies = with python3Packages; [
    typer
    click
    rich
    pydantic
    psutil
    pyyaml
    tomli-w
  ];

  pythonImportsCheck = [ "caliper" ];
  nativeCheckInputs = [ python3Packages.pytestCheckHook git ];
  preCheck = "export HOME=$TMPDIR";

  meta = {
    description = "Evaluation harness that tests whether agent skills help";
    homepage = "https://github.com/edonadei/caliper";
    license = "MIT";
    mainProgram = "caliper";
  };
}
