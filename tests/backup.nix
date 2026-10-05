# VM test of backup and disaster recovery.
#
#   nix build .#checks.x86_64-linux.backup
#
# Backs up to a local restic repository, destroys the state, restores it
# with agentos-restore and checks that nothing was lost:
#
#   state under /var/lib/agentos, the audit directory, a "secrets" file and
#   the control-plane Redis (BGSAVE + data directory) are backed up; the
#   cache directory is excluded -> a restore drill into a scratch directory
#   leaves the live system alone -> everything is deleted, Redis stopped ->
#   an in-place restore brings the files and the Redis key back.
{ pkgs, agentosModules }:

pkgs.testers.runNixOSTest {
  name = "agentos-backup";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 1536;

    # The control-plane Redis exactly as the runtime module declares it
    services.redis.servers.agentos = {
      enable = true;
      port = 0;
      unixSocket = "/run/redis-agentos/redis.sock";
      unixSocketPerm = 660;
      settings = {
        maxmemory = "64mb";
        maxmemory-policy = "noeviction";
        appendonly = "yes";
      };
    };

    environment.etc."restic-password".text = "correct horse battery staple\n";

    agentos.backup = {
      enable = true;
      repository = "/var/lib/restic-repo";
      passwordFile = "/etc/restic-password";
      schedule = "daily";
      retention = { daily = 3; weekly = 2; monthly = 1; yearly = 1; };
      # Stands in for the sops secrets file
      extraPaths = [ "/etc/agentos-test-secrets.yaml" ];
    };
  };

  testScript = ''
    redis = "redis-cli -s /run/redis-agentos/redis.sock"

    machine.wait_for_unit("redis-agentos.service")

    with subtest("create state"):
        machine.succeed("mkdir -p /var/lib/agentos/state /var/lib/agentos/cache /var/lib/agentos-audit")
        machine.succeed("echo precious > /var/lib/agentos/state/agent-1.json")
        machine.succeed("echo junk > /var/lib/agentos/cache/blob")
        machine.succeed("echo audit-line > /var/lib/agentos-audit/audit.log")
        machine.succeed("echo 'sops: encrypted' > /etc/agentos-test-secrets.yaml")
        machine.succeed(f"{redis} SET spend:today 12.5")
        machine.succeed(f"{redis} SET budget:global 500")

    with subtest("backup"):
        machine.succeed("systemctl start restic-backups-agentos.service")
        machine.succeed("restic-agentos snapshots --json | grep -q '\"paths\"'")
        listing = machine.succeed("restic-agentos ls latest")
        assert "/var/lib/agentos/state/agent-1.json" in listing, listing
        assert "/var/lib/agentos-audit/audit.log" in listing, listing
        assert "/etc/agentos-test-secrets.yaml" in listing, listing
        assert "dump.rdb" in listing, "the Redis RDB must be in the snapshot"
        assert "/var/lib/agentos/cache" not in listing, "cache must be excluded"
        # /var/lib/agentos-stack does not exist here: skipped, not an error
        assert "agentos-stack" not in listing

    with subtest("restore drill leaves the live system alone"):
        machine.succeed("agentos-restore --target /tmp/drill --include /var/lib/agentos/state")
        assert machine.succeed("cat /tmp/drill/var/lib/agentos/state/agent-1.json").strip() == "precious"
        machine.succeed("systemctl is-active redis-agentos.service")
        machine.succeed("agentos-restore --dry-run")

    with subtest("disaster"):
        machine.succeed("systemctl stop redis-agentos.service")
        machine.succeed("rm -rf /var/lib/agentos /var/lib/agentos-audit /var/lib/redis-agentos /etc/agentos-test-secrets.yaml")
        machine.fail("test -e /var/lib/agentos/state/agent-1.json")

    with subtest("restore in place"):
        machine.succeed("agentos-restore")
        assert machine.succeed("cat /var/lib/agentos/state/agent-1.json").strip() == "precious"
        assert machine.succeed("cat /var/lib/agentos-audit/audit.log").strip() == "audit-line"
        assert "sops: encrypted" in machine.succeed("cat /etc/agentos-test-secrets.yaml")
        machine.wait_for_unit("redis-agentos.service")
        assert machine.succeed(f"{redis} GET spend:today").strip() == "12.5"
        assert machine.succeed(f"{redis} GET budget:global").strip() == "500"
  '';
}
