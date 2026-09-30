# AgentOS services: model gateway (agentos-model-gateway) and agent daemon
# (agentos-daemon). Source in services/; the test suite runs at build time.
{ lib, python3Packages }:

python3Packages.buildPythonApplication {
  pname = "agentos-services";
  version = "0.3.0";
  pyproject = true;

  src = lib.cleanSource ../../services;

  build-system = [ python3Packages.setuptools ];
  dependencies = [ python3Packages.redis ];

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
    python3Packages.fakeredis
  ];

  pythonImportsCheck = [ "agentos_services" ];

  meta = {
    description = "AgentOS model gateway and agent daemon";
    license = lib.licenses.mit;
    mainProgram = "agentos-model-gateway";
    platforms = lib.platforms.linux;
  };
}
