# VM test of nestlo.openshell.
#
#   nix build .#checks.x86_64-linux.openshell
#
# The OpenShell gateway starts as the dedicated `openshell` user with mutual
# TLS on loopback and the podman compute driver (the podman socket is up, no
# sandbox is created: that needs the sandbox images from ghcr.io, and the VM
# has neither internet nor KVM). The health port answers, the CLI works for
# an operator in the `openshell` group and not for anyone else, the declared
# policy is rendered and is the gateway-global policy, the Nestlo gateway
# profile and provider exist, and the gateway agent `openshell` is registered
# with the Nestlo model gateway (its token works, a wrong one does not).
#
# Sandbox creation (`openshell sandbox create`) is not covered: it pulls
# ghcr.io/nvidia/openshell/{sandbox,supervisor}.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-openshell";
  globalTimeout = 1200;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    virtualisation.diskSize = 4096;

    users.users.alice.isNormalUser = true;
    users.users.bob.isNormalUser = true;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
      };
      openshell = {
        enable = true;
        inference.budgetUsd = 7;
        policies.github-readonly = {
          filesystem_policy = {
            read_only = [ "/usr" "/lib" "/etc" ];
            read_write = [ "/tmp" ];
          };
          network_policies.github_api = {
            endpoints = [{
              host = "api.github.com";
              port = 443;
              protocol = "rest";
              access = "read-only";
              enforcement = "enforce";
            }];
            binaries = [ "/usr/bin/curl" ];
          };
        };
        defaultPolicy = "github-readonly";
        globalPolicy = "github-readonly";
        providers.upstream = [ "github" ];
      };
    };

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };
  };

  testScript = ''
    import json

    as_user = lambda u, cmd: machine.succeed(f"runuser -u {u} -- env HOME=/home/{u} {cmd}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-model-gateway.service")
    machine.wait_for_unit("nestlo-openshell-gateway.service")
    machine.wait_for_unit("nestlo-openshell-gateway-agent.service")
    machine.wait_for_unit("nestlo-openshell-setup.service")

    with subtest("the gateway is a contained service of its own user"):
        props = machine.succeed(
            "systemctl show nestlo-openshell-gateway -p User -p ProtectSystem -p NoNewPrivileges -p SupplementaryGroups"
        )
        assert "User=openshell" in props and "ProtectSystem=strict" in props, props
        assert "NoNewPrivileges=yes" in props and "podman" in props, props
        machine.succeed("pgrep -u openshell -f openshell-gateway")
        assert machine.succeed("stat -c '%a %U %G' /var/lib/openshell").strip() == "750 openshell openshell"

    with subtest("the podman driver is up and the health port answers"):
        machine.succeed("test -S /run/podman/podman.sock")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:17671/healthz")
        print(machine.execute("curl -sS http://127.0.0.1:17671/readyz")[1])
        listening = machine.succeed("ss -ltn")
        assert "127.0.0.1:17670" in listening and "127.0.0.1:17671" in listening, listening
        machine.fail("ss -ltn | grep -E '(0.0.0.0|\\*|\\[::\\]):1767[01]'")
        # the gateway config is schema v2 and names the driver
        cfg = machine.succeed("cat $(systemctl show -p Environment --value nestlo-openshell-gateway | tr ' ' '\\n' | sed -n 's/^OPENSHELL_GATEWAY_CONFIG=//p')")
        assert 'compute_driver = "podman"' in cfg and "version = 2" in cfg, cfg

    with subtest("mutual TLS: only the operators' certificate works"):
        assert machine.succeed("stat -c '%a %G' /var/lib/openshell/client/tls.key").strip() == "640 openshell"
        machine.succeed("test -L /home/alice/.config/openshell/gateways/openshell/mtls")
        # plain HTTP and a missing certificate are refused
        machine.fail("curl -fsS http://127.0.0.1:17670/")
        out = as_user("alice", "openshell status")
        print(out)
        assert "17670" in out and "Connected" in out, out
        as_user("alice", "openshell sandbox list")
        status, out = machine.execute("runuser -u bob -- env HOME=/home/bob openshell status 2>&1")
        assert status != 0, out

    with subtest("the declared policy is rendered and is the global policy"):
        policy = machine.succeed("cat /etc/openshell/policies/github-readonly.yaml")
        assert "github_api" in policy and "path: /usr/bin/curl" in policy, policy
        machine.succeed("test -s /etc/openshell/policies/restrictive.yaml")
        machine.succeed("grep -q 'OPENSHELL_SANDBOX_POLICY=.*github-readonly.yaml' /etc/set-environment")
        out = as_user("alice", "openshell policy get --global --full")
        print(out)
        assert "github_api" in out and "api.github.com" in out, out

    with subtest("provider profiles and the Nestlo gateway provider exist"):
        profiles = as_user("alice", "openshell profile list --global")
        assert "nestlo-gateway" in profiles, profiles
        # upstream profile from providers/*.yaml (read from the package)
        assert "github" in profiles, profiles
        providers = as_user("alice", "openshell provider list --names")
        assert "nestlo" in providers.split(), providers
        # the token never appears in the provider's description
        token = machine.succeed("cat /var/lib/openshell/nestlo-gateway-token").strip()
        assert token not in as_user("alice", "openshell provider get nestlo"), "token leaked"

    with subtest("the gateway agent is registered with the Nestlo model gateway"):
        assert machine.succeed("stat -c '%a %U' /var/lib/openshell/nestlo-gateway-token").strip() == "400 openshell"
        code = lambda t: machine.succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:8080/agent/openshell:{t}/nosuchprovider/v1/models"
        ).strip()
        # a valid token passes authentication (the provider does not exist)
        assert code(token) == "404", code(token)
        assert code("wrong") == "401", code("wrong")
        spend = json.loads(machine.succeed("curl -fsS --unix-socket /run/nestlo-gateway/admin.sock http://x/_nestlo/spend"))
        print(spend)

    with subtest("the units survive a restart of the gateway"):
        machine.succeed("systemctl restart nestlo-openshell-gateway.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:17671/healthz")
        # Requires= restarts the setup unit with the gateway; wait for it
        # instead of restarting it again (that would kill the run in progress)
        machine.wait_until_succeeds("systemctl is-active nestlo-openshell-setup.service", timeout=300)
        as_user("alice", "openshell status")
  '';
}
