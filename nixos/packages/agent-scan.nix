# Snyk Agent Scan (formerly Invariant's mcp-scan): scanner for MCP servers,
# agent skills and tools. Apache-2.0, https://github.com/snyk/agent-scan.
#
# Built from the PyPI sdist of the pinned release (0.6.8). `scan` sends what
# it finds to Snyk's analysis API (see docs/agent-security.md); `inspect` is
# local. The upstream pins are newer than nixpkgs' mcp/aiohttp, so the
# version bounds are relaxed (pythonRelaxDeps); only the import is checked.
{ lib
, python3Packages
, fetchPypi
}:

python3Packages.buildPythonApplication rec {
  pname = "snyk-agent-scan";
  version = "0.6.8";
  pyproject = true;

  src = fetchPypi {
    pname = "snyk_agent_scan";
    inherit version;
    hash = "sha256-PN0QkojWlJxK+vHL1MPh3Xf377pV7ofsBuQ9WTBX/5c=";
  };

  build-system = [ python3Packages.hatchling ];

  dependencies = with python3Packages; [
    rich
    pyjson5
    pydantic
    lark
    psutil
    pyyaml
    aiohttp
    rapidfuzz
    truststore
    mcp
    # mcp[cli], which upstream depends on
    typer
    python-dotenv
    regex
    detect-secrets
    certifi
    httpx
  ];

  # upstream pins rich==14.2.0 / mcp==1.30.0 / aiohttp>=3.14.3; nixpkgs is a little behind
  pythonRelaxDeps = true;

  pythonImportsCheck = [ "agent_scan" ];
  doCheck = false;

  meta = {
    description = "Security scanner for MCP servers, agent skills and tools (Snyk Agent Scan, formerly mcp-scan)";
    homepage = "https://github.com/snyk/agent-scan";
    license = lib.licenses.asl20;
    mainProgram = "snyk-agent-scan";
    platforms = lib.platforms.linux;
  };
}
