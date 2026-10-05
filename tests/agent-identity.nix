# VM test of nestlo.agentIdentity (SPIFFE/SPIRE) and nestlo.cedar:
#
#   nix build .#checks.x86_64-linux.agent-identity
#
# spire-server and spire-agent come up healthy on the loopback, the host's
# node attests with its x509pop certificate and the declared entries are
# registered; a workload running as nestlo-agent fetches an X.509-SVID over
# the Workload API socket (spire-agent api fetch) and a process of another
# user gets nothing; an agent started in the unit nestlo-agent-worker (the
# way `nestlo spawn` starts agents) gets the identity of `worker`, one in a
# different unit does not; its JWT-SVID verifies against the published
# bundle (right audience, wrong audience, tampered); a runtime-registered
# agent works; nestlo-authz allows and denies as the policies say.
# No network access is needed.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-agent-identity";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 2048;

    nestlo = {
      runtime.enable = true;
      agentIdentity = {
        enable = true;
        agents.worker = { };
        workloads.root-job.selectors = [ "unix:uid:0" "systemd:id:root-job.service" ];
      };
      cedar = {
        enable = true;
        agents = {
          claude = { groups = [ "coding" ]; tier = "trusted"; };
          intruder = { groups = [ "coding" ]; tier = "untrusted"; };
        };
        entities = [
          { uid = { type = "Secret"; id = "github-token"; }; attrs = { }; parents = [ ]; }
        ];
        policies.trusted-secret = ''
          permit (principal, action == Action::"read_secret", resource == Secret::"github-token")
          when { principal.tier == "trusted" };
        '';
      };
    };
  };

  testScript = ''
    import json

    server_sock = "/run/nestlo-spire/server/api.sock"
    agent_sock = "/run/nestlo-spire/agent/api.sock"
    td = "spiffe://nestlo.local"
    as_agent = "runuser -u nestlo-agent --"
    unit = "systemd-run --quiet --collect --wait --pipe --uid=nestlo-agent --gid=nestlo-agent"

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-spire-server.service")
    machine.wait_for_unit("nestlo-spire-agent.service")
    machine.wait_for_unit("nestlo-spire-entries.service")

    with subtest("server and agent are healthy, loopback only"):
        machine.succeed(f"spire-server healthcheck -socketPath {server_sock}")
        machine.wait_until_succeeds(f"spire-agent healthcheck -socketPath {agent_sock}")
        listeners = machine.succeed("ss -Hltn")
        assert "127.0.0.1:8081" in listeners, listeners
        assert "0.0.0.0:8081" not in listeners and "*:8081" not in listeners, listeners
        # the node attested with the generated certificate
        machine.succeed(f"spire-server agent list -socketPath {server_sock} | grep -q 'x509pop/nestlo-host'")
        # the node CA key is gone after signing
        machine.fail("test -e /var/lib/nestlo-spire/pki/ca.key")

    with subtest("entries are registered from Nix"):
        out = machine.succeed("nestlo-identity list")
        for path in ("agent/nestlo-agent", "agent/worker", "workload/root-job"):
            assert f"{td}/{path}" in out, out
        # re-running the reconcile unit changes nothing
        assert "up to date" in machine.succeed("systemctl restart nestlo-spire-entries.service; journalctl -u nestlo-spire-entries.service -n 5 --no-pager")

    with subtest("a workload as nestlo-agent gets an X.509-SVID over the Workload API"):
        machine.succeed("install -d -o nestlo-agent -m 0700 /tmp/svid")
        machine.wait_until_succeeds(f"{as_agent} spire-agent api fetch x509 -socketPath {agent_sock} -write /tmp/svid")
        san = machine.succeed("openssl x509 -in /tmp/svid/svid.0.pem -noout -ext subjectAltName")
        assert f"URI:{td}/agent/nestlo-agent" in san, san
        # SPIFFE_ENDPOINT_SOCKET is set for login shells
        assert agent_sock in machine.succeed("bash -lc 'echo $SPIFFE_ENDPOINT_SOCKET'")

    with subtest("a process nobody registered gets no identity"):
        machine.fail(f"runuser -u nobody -- spire-agent api fetch x509 -socketPath {agent_sock}")

    with subtest("per-agent identity: user and systemd unit"):
        tok = machine.succeed(
            f"{unit} --unit=nestlo-agent-worker nestlo-svid jwt nestlo-gateway --agent worker"
        ).strip()
        claims = json.loads(machine.succeed(f"nestlo-svid verify --token {tok}"))
        assert claims["valid"] and claims["spiffe_id"] == f"{td}/agent/worker" and claims["agent"] == "worker", claims
        # another unit of the same user is not `worker`
        machine.fail(f"{unit} --unit=nestlo-agent-other nestlo-svid jwt nestlo-gateway --agent worker")
        # ... and the user alone is not either (a login as nestlo-agent is the generic identity)
        machine.fail(f"{as_agent} nestlo-svid jwt nestlo-gateway --agent worker")
        generic = machine.succeed(f"{as_agent} nestlo-svid jwt nestlo-gateway --agent nestlo-agent").strip()
        assert json.loads(machine.succeed(f"nestlo-svid verify --token {generic}"))["agent"] == "nestlo-agent"

    with subtest("JWT-SVID verification checks audience and signature"):
        bad = json.loads(machine.fail(f"nestlo-svid verify --audience somebody-else --token {tok}"))
        assert not bad["valid"], bad
        head, payload, sig = tok.split(".")
        forged = ".".join([head, payload, sig[:-4] + ("AAAA" if not sig.endswith("AAAA") else "BBBB")])
        assert not json.loads(machine.fail(f"nestlo-svid verify --token {forged}"))["valid"]
        # alg=none is refused
        none_tok = ".".join(["eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0", payload, ""])
        assert not json.loads(machine.fail(f"nestlo-svid verify --token {none_tok}"))["valid"]
        # the bundle is public and has JWT authorities
        keys = json.loads(machine.succeed("cat /var/lib/nestlo-spire/pub/bundle.json"))["keys"]
        assert any(k.get("use") == "jwt-svid" for k in keys), keys
        assert len(json.loads(machine.succeed("nestlo-svid jwks-pem"))) >= 1

    with subtest("agents spawned at runtime can be registered"):
        machine.fail(f"{unit} --unit=nestlo-agent-late nestlo-svid jwt nestlo-gateway --agent late")
        machine.succeed("nestlo-identity register late")
        machine.wait_until_succeeds(
            f"{unit} --unit=nestlo-agent-late nestlo-svid jwt nestlo-gateway --agent late"
        )
        machine.succeed("nestlo-identity unregister late")
        # a reconcile keeps runtime entries and removes nothing it does not own
        machine.succeed("nestlo-identity register kept")
        machine.succeed("systemctl restart nestlo-spire-entries.service")
        assert f"{td}/agent/kept" in machine.succeed("nestlo-identity list")

    with subtest("units are hardened"):
        for u in ("nestlo-spire-server", "nestlo-spire-agent"):
            props = machine.succeed(f"systemctl show {u}.service -p ProtectSystem -p NoNewPrivileges")
            assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props, props
        machine.succeed("systemctl show nestlo-spire-server.service -p DynamicUser | grep -q yes")

    with subtest("cedar policies were validated at build time and nestlo-authz decides"):
        machine.succeed("test -s /etc/nestlo/cedar/policies.cedar -a -s /etc/nestlo/cedar/schema.cedarschema")
        authz = "nestlo-authz check"
        assert "ALLOW" in machine.succeed(f"{authz} --principal claude --action clone --resource Repo:github.com/nestlo/nestlo")
        # push to the default branch is forbidden whatever permits
        out = machine.fail(f"{authz} --principal claude --action push --resource Repo:github.com/nestlo/nestlo --context '{{\"branch\":\"main\"}}'")
        assert "DENY" in out and "no-default-branch-push" in out, out
        machine.succeed(f"{authz} --principal claude --action push --resource Repo:github.com/nestlo/nestlo --context '{{\"branch\":\"fix-1\"}}'")
        # untrusted tier: no push, no secrets (forbid wins)
        machine.fail(f"{authz} --principal intruder --action push --resource Repo:github.com/nestlo/nestlo --context '{{\"branch\":\"x\"}}'")
        machine.fail(f"{authz} --principal intruder --action read_secret --resource Secret:github-token")
        machine.succeed(f"{authz} --principal claude --action read_secret --resource Secret:github-token")
        # tools and providers by set membership
        machine.succeed(f"{authz} --principal claude --action use_tool --resource Tool:git")
        assert "DENY" in machine.fail(f"{authz} --principal intruder --action use_tool --resource Tool:bash")
        machine.succeed(f"{authz} --principal claude --action call_provider --resource Provider:anthropic")
        machine.fail(f"{authz} --principal claude --action call_provider --resource Provider:unknown-vendor")
        # unknown action or unparsable context is an error (exit 1), not a decision
        rc, _ = machine.execute(f"{authz} --principal claude --action fly --resource Repo:x")
        assert rc == 1, rc
        rc, _ = machine.execute(f"{authz} --principal claude --action clone --resource Repo:x --context '[1]'")
        assert rc == 1, rc
        js = json.loads(machine.succeed(f"{authz} --json --principal claude --action clone --resource Repo:github.com/nestlo/nestlo"))
        assert js["decision"] == "allow" and js["reasons"] == ["coding-clone"], js
  '';
}
