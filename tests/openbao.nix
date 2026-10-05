# VM test of nestlo.openbao:
#
#   nix build .#checks.x86_64-linux.openbao
#
# OpenBao is initialised, unsealed and configured by the setup unit; the
# listener is loopback TLS (the generated CA verifies, plain HTTP and other
# CAs do not); the KV v2 mount works; an agent logs in with its SPIRE
# JWT-SVID and reads its own secrets and the shared ones but not another
# agent's; a process with no identity cannot log in; a restart seals the
# vault and the setup unit unseals it again; the audit device records
# requests; /run/secrets/<NAME> is rendered from OpenBao for
# nestlo.secrets-manager's contract. No network access is needed.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-openbao";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 2048;

    nestlo = {
      runtime.enable = true;
      agentIdentity = {
        enable = true;
        agents.worker = { };
        agents.sibling = { };
      };
      openbao = {
        enable = true;
        secretsManager = {
          enable = true;
          secrets = [ "TEST_SECRET" ];
        };
      };
    };
  };

  testScript = ''
    import json

    unit = "systemd-run --quiet --collect --wait --pipe --uid=nestlo-agent --gid=nestlo-agent"
    bao = "nestlo-bao"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-spire-entries.service")
    machine.wait_for_unit("openbao.service")
    machine.wait_for_unit("nestlo-openbao-setup.service")

    with subtest("initialised, unsealed, loopback TLS only"):
        status = json.loads(machine.succeed(f"{bao} status -format=json"))
        assert status["initialized"] and not status["sealed"], status
        listeners = machine.succeed("ss -Hltn")
        assert "127.0.0.1:8200" in listeners and "0.0.0.0:8200" not in listeners, listeners
        machine.succeed("curl -sf --cacert /var/lib/nestlo-openbao/pub/ca.pem https://127.0.0.1:8200/v1/sys/health")
        machine.fail("curl -sf --cacert /var/lib/nestlo-spire/pki/node-ca.pem https://127.0.0.1:8200/v1/sys/health")
        machine.fail("curl -sf http://127.0.0.1:8200/v1/sys/health")
        # the key material is root-only
        for f in ("init/unseal-key", "init/root-token", "pki/ca.key"):
            assert machine.succeed(f"stat -c %a /var/lib/nestlo-openbao/{f}").strip() == "600", f
        machine.fail("runuser -u nestlo-agent -- cat /var/lib/nestlo-openbao/init/root-token")
        # the unit is hardened
        props = machine.succeed("systemctl show openbao.service -p DynamicUser -p CapabilityBoundingSet")
        assert "DynamicUser=yes" in props, props

    with subtest("KV v2 mount, JWT auth and audit device are configured"):
        mounts = json.loads(machine.succeed(f"{bao} secrets list -format=json"))
        assert mounts["nestlo/"]["options"]["version"] == "2", mounts
        assert "spire/" in json.loads(machine.succeed(f"{bao} auth list -format=json"))
        assert "nestlo-file/" in json.loads(machine.succeed(f"{bao} audit list -format=json"))
        roles = json.loads(machine.succeed(f"{bao} list -format=json auth/spire/role"))
        assert {"agent-worker", "agent-sibling", "agent-nestlo-agent"} <= set(roles), roles

    with subtest("KV is readable by the operator"):
        machine.succeed(f"{bao} kv put -mount=nestlo agents/worker/github value=ghp_worker")
        machine.succeed(f"{bao} kv put -mount=nestlo agents/sibling/github value=ghp_sibling")
        machine.succeed(f"{bao} kv put -mount=nestlo shared/motd value=hello")
        machine.succeed(f"{bao} kv put -mount=nestlo secrets-manager/TEST_SECRET value=s3cret")
        assert machine.succeed(f"{bao} kv get -mount=nestlo -field=value shared/motd").strip() == "hello"

    with subtest("an agent logs in with its SVID and reads only its own secrets"):
        get = f"{unit} --unit=nestlo-agent-worker nestlo-openbao-get -a worker"
        assert machine.succeed(f"{get} agents/worker/github").strip() == "ghp_worker"
        assert machine.succeed(f"{get} shared/motd").strip() == "hello"
        machine.fail(f"{get} agents/sibling/github")
        # the SVID of worker cannot be used for sibling's role
        machine.fail(f"{unit} --unit=nestlo-agent-worker nestlo-openbao-login sibling")
        # no identity, no login
        machine.fail("runuser -u nobody -- nestlo-openbao-login nestlo-agent")
        # a worker token cannot write
        tok = machine.succeed(f"{unit} --unit=nestlo-agent-worker nestlo-openbao-login worker").strip()
        machine.fail(f"BAO_TOKEN={tok} BAO_ADDR=https://127.0.0.1:8200 BAO_CACERT=/var/lib/nestlo-openbao/pub/ca.pem bao kv put -mount=nestlo agents/worker/x value=1")

    with subtest("the audit device records requests, secrets HMAC-ed"):
        audit_log = machine.succeed("cat /var/log/nestlo-openbao/audit.log")
        assert '"type":"request"' in audit_log, audit_log[:500]
        assert "ghp_worker" not in audit_log and "s3cret" not in audit_log
        assert machine.succeed("stat -c %a /var/log/nestlo-openbao/audit.log").strip() == "600"

    with subtest("secrets-manager contract: /run/secrets/<NAME>"):
        machine.succeed("systemctl start nestlo-openbao-sync.service")
        assert machine.succeed("cat /run/secrets/TEST_SECRET") == "s3cret"
        assert machine.succeed("stat -c '%a %G' /run/secrets/TEST_SECRET").strip() == "440 nestlo"

    with subtest("a restart seals; the setup unit unseals again and the data is intact"):
        machine.succeed("systemctl restart openbao.service")
        machine.wait_until_succeeds(f"{bao} status -format=json | jq -e '.sealed == false'")
        machine.wait_for_unit("nestlo-openbao-setup.service")
        assert machine.succeed(f"{bao} kv get -mount=nestlo -field=value agents/worker/github").strip() == "ghp_worker"

    with subtest("SPIRE signing keys are re-read by the refresh unit"):
        machine.succeed("systemctl start nestlo-openbao-jwks.service")
        cfg = json.loads(machine.succeed(f"{bao} read -format=json auth/spire/config"))
        assert cfg["data"]["jwt_validation_pubkeys"], cfg

    with subtest("metrics are served for Prometheus without a token"):
        machine.succeed("curl -sf --cacert /var/lib/nestlo-openbao/pub/ca.pem 'https://127.0.0.1:8200/v1/sys/metrics?format=prometheus' | grep -q core_unsealed")
  '';
}
