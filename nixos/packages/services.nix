# Nestlo services: model gateway (nestlo-model-gateway), agent daemon
# (nestlo-daemon), orchestrator (nestlo-orchestrator, with its root helper
# nestlo-task-runner) and scheduler (nestlo-scheduler). Source in
# services/; the test suite runs at build time.
{ lib, python3Packages, git, systemd, openssh }:

python3Packages.buildPythonApplication {
  pname = "nestlo-services";
  version = "0.5.0";
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

  pythonImportsCheck = [ "nestlo_services" ];

  meta = {
    description = "Nestlo model gateway, agent daemon, orchestrator and scheduler";
    license = lib.licenses.mit;
    mainProgram = "nestlo-model-gateway";
    platforms = lib.platforms.linux;
  };
}
