# AgentOS services: model gateway (agentos-model-gateway), agent daemon
# (agentos-daemon), orchestrator (agentos-orchestrator, with its root helper
# agentos-task-runner) and scheduler (agentos-scheduler). Source in
# services/; the test suite runs at build time.
{ lib, python3Packages, git, systemd, openssh }:

python3Packages.buildPythonApplication {
  pname = "agentos-services";
  version = "0.4.0";
  pyproject = true;

  src = lib.cleanSource ../../services;

  build-system = [ python3Packages.setuptools ];
  dependencies = [ python3Packages.redis python3Packages.cryptography ];

  nativeCheckInputs = [
    python3Packages.pytestCheckHook
    python3Packages.fakeredis
    git # task runner tests drive real repositories and worktrees
    systemd # systemd-analyze, for the calendar tests
    openssh # ssh-keygen: cloud API tokens are checked against OpenSSH's own signatures
  ];

  pythonImportsCheck = [ "agentos_services" ];

  meta = {
    description = "AgentOS model gateway, agent daemon, orchestrator and scheduler";
    license = lib.licenses.mit;
    mainProgram = "agentos-model-gateway";
    platforms = lib.platforms.linux;
  };
}
