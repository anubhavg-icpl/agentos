# The MCP 2 Python SDK (mcp 2.0.0) and the three PyPI packages nixpkgs lacks
# for it: mcp-types, httpcore2, httpx2. Ouroboros' MCP server imports
# mcp.server.MCPServer, which exists only in MCP 2 (nixpkgs has mcp 1.x).
# Installed from the pure-Python PyPI wheels; hashes pinned.
#
# httpx2 declares idna>=3.18 while nixpkgs has 3.15; its runtime dependency
# check is skipped for that one over-tight bound (nothing else is relaxed).
{ python3Packages, fetchPypi }:

let
  inherit (python3Packages) buildPythonPackage;
  mcp-types = buildPythonPackage rec {
    pname = "mcp-types";
    version = "2.0.0";
    format = "wheel";
    src = fetchPypi {
      pname = "mcp_types";
      inherit version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-ay3nl8onl/Vot5Up4bJZSONN5RG8wL2C/vEDmm0bjrA=";
    };
    dependencies = with python3Packages; [ pydantic typing-extensions ];
    pythonImportsCheck = [ "mcp_types" ];
  };

  httpcore2 = buildPythonPackage rec {
    pname = "httpcore2";
    version = "2.5.0";
    format = "wheel";
    src = fetchPypi {
      inherit pname version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-XONRiN5GHTHo0AC/uO+L8ixsFlh6IR5Vcd6qXpvfhCo=";
    };
    dependencies = with python3Packages; [ h11 truststore ];
    pythonImportsCheck = [ "httpcore2" ];
  };

  httpx2 = buildPythonPackage rec {
    pname = "httpx2";
    version = "2.5.0";
    format = "wheel";
    src = fetchPypi {
      inherit pname version;
      format = "wheel";
      dist = "py3";
      python = "py3";
      hash = "sha256-PS1NnPS2HxofRqlZR8/bR+gMtWovkcYlasj1jkiR30E=";
    };
    dependencies = (with python3Packages; [ anyio idna truststore ]) ++ [ httpcore2 ];
    dontCheckRuntimeDeps = true;
    pythonImportsCheck = [ "httpx2" ];
  };
in
buildPythonPackage rec {
  pname = "mcp";
  version = "2.0.0";
  format = "wheel";
  src = fetchPypi {
    inherit pname version;
    format = "wheel";
    dist = "py3";
    python = "py3";
    hash = "sha256-HLTHXS0se4wddWNV5dgqOfKCLMfxPiKiBR18o1kjSdY=";
  };
  dependencies = (with python3Packages; [
    anyio
    cryptography
    jsonschema
    opentelemetry-api
    pydantic
    pyjwt
    python-multipart
    sse-starlette
    starlette
    typing-extensions
    typing-inspection
    uvicorn
  ]) ++ [ mcp-types httpx2 ];
  pythonImportsCheck = [ "mcp" "mcp.server" ];
}
