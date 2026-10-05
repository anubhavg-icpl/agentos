# ouroboros-ai: the `ooo` / `ouroboros` / `ozo` CLI and MCP server.
#
# - Version: upstream derives it from git tags (hatch-vcs); the pinned source
#   has no .git, so it is set explicitly. 0.55.4 is the version the plugin
#   manifests and `ooo:VERSION` marker in the pinned source declare (the
#   CHANGELOG is behind: its newest numbered release is 0.41.0).
# - Telemetry: upstream sends anonymous usage events by default (see
#   TELEMETRY.md). The wrapper turns it off with the two documented opt-outs
#   (DO_NOT_TRACK, OUROBOROS_TELEMETRY). They are defaults only: exporting
#   OUROBOROS_TELEMETRY=1 with DO_NOT_TRACK unset opts back in.
# - The Rust crate crates/ouroboros-tui is the optional native monitor started
#   by `ouroboros tui monitor --backend slt`; nothing else needs it, so it is
#   not built.
{ python3Packages, fetchPypi, bash, git, gnumake, nodejs, perl, sources }:

let
  mcp2 = import ./mcp2.nix { inherit python3Packages fetchPypi; };
in
python3Packages.buildPythonApplication {
  pname = "ouroboros-ai";
  version = "0.55.4";
  pyproject = true;
  src = sources.ouroboros;

  env.SETUPTOOLS_SCM_PRETEND_VERSION = "0.55.4";

  build-system = with python3Packages; [ hatchling hatch-vcs ];
  dependencies = with python3Packages; [
    aiosqlite
    anyio
    click
    jsonschema
    pydantic
    prompt-toolkit
    python-dotenv
    pyyaml
    rich
    sqlalchemy
    structlog
    typer
    mcp2
    # `ouroboros tui` (the `tui` extra upstream)
    textual
    textual-serve
  ];

  makeWrapperArgs = [
    "--set-default" "DO_NOT_TRACK" "1"
    "--set-default" "OUROBOROS_TELEMETRY" "0"
  ];

  pythonImportsCheck = [ "ouroboros" ];

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    pytest-asyncio
    pytest-xdist
  ] ++ [ bash git gnumake nodejs perl ];
  # tests/unit only; integration/ and e2e/ drive real agent runtimes
  enabledTestPaths = [ "tests/unit" ];
  pytestFlags = [ "-n" "4" ];
  # Tests that need what a build sandbox lacks: /bin/bash, or the codex,
  # ourocode and dsh agent CLIs (their adapters are exercised against fakes
  # that expect those names on PATH).
  disabledTestPaths = [
    "tests/unit/scripts/test_install_runtime_selection.py"
    "tests/unit/skills/test_skill_artifacts.py"
    "tests/unit/cli/test_codex_command.py"
    "tests/unit/cli/test_setup.py"
    "tests/unit/providers/test_ourocode_acp_client.py"
    "tests/unit/providers/test_ourocode_llm_adapter.py"
    "tests/unit/providers/test_dsh_acp_client.py"
    "tests/unit/providers/test_codex_cli_adapter.py"
    "tests/unit/orchestrator/test_routing_contract_resume.py"
    # replay commands in a nested sandbox/PATH the build sandbox does not provide
    "tests/unit/orchestrator/evidence/test_command_replay.py"
    "tests/unit/orchestrator/evidence/test_test_reexecution.py"
    "tests/unit/orchestrator/evidence/test_configuration_narrowing.py"
  ];
  disabledTests = [
    # need bash/perl/env semantics or a non-UTF-8 locale the sandbox lacks
    "test_preflight_uses_actual_optional_host_environment"
    "test_shell_created_bindings_match_empty_environment_runtime"
    "test_set_expected_artifacts_materialize_one_semantic_key_across_hash_seeds"
    "test_queued_workflow_outcome_survives_to_a_real_sink"
    "test_utf8_config_round_trips_under_non_utf8_locale"
    "test_concurrent_first_use_prints_notice_exactly_once"
    "test_files_touched_rejects_"
    "test_in_place_editor_inode_replacement_remains_fail_closed"
    "test_perl_module_name_cannot_impersonate_in_place_switch"
    "test_fat_harness_exit_code_only_test_output_is_settled_by_harness_reexecution"
    # Windows-only behavior / sandbox filesystem limits
    "test_atomic_windows_capacity_rejection_does_not_dispatch"
    "test_capsule_uses_typed_rejection_for_windows_workspace_capacity"
    "test_url_refresh_filesystem_failure_is_reported_without_traceback"
    "test_picker_projection_write_and_disk_budgets"
    # internationalized host names: httpx2 wants idna >= 3.18, nixpkgs has 3.15
    "test_auth_settings_match_httpx2_advertised_authority"
    "test_inferred_allowlist_accepts_real_httpx2_wire_host"
  ];
  preCheck = ''
    export HOME=$TMPDIR
    git config --global user.email t@example.invalid
    git config --global user.name t
  '';

  meta = {
    description = "Spec-first workflow for AI coding agents: interview, seed, run, evaluate";
    homepage = "https://github.com/Q00/ouroboros";
    license = "MIT";
    mainProgram = "ooo";
  };
}
