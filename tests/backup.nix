# VM test of backup and disaster recovery.
#
#   nix build .#checks.x86_64-linux.backup
#
# Backs up to a local restic repository, destroys the state, restores it
# with nestlo-restore and checks that nothing was lost:
#
#   state under /var/lib/nestlo, the audit directory, a "secrets" file and
#   the control-plane Redis (BGSAVE + data directory) are backed up; the
#   cache directory is excluded -> a restore drill into a scratch directory
#   leaves the live system alone -> everything is deleted, Redis stopped ->
#   an in-place restore brings the files and the Redis key back.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-backup";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 1536;

    # The control-plane Redis exactly as the runtime module declares it
    services.redis.servers.nestlo = {
      enable = true;
      port = 0;
      unixSocket = "/run/redis-nestlo/redis.sock";
      unixSocketPerm = 660;
      settings = {
        maxmemory = "64mb";
        maxmemory-policy = "noeviction";
        appendonly = "yes";
      };
    };

    environment.etc."restic-password".text = "correct horse battery staple\n";

    nestlo.backup = {
      enable = true;
      repository = "/var/lib/restic-repo";
      passwordFile = "/etc/restic-password";
      schedule = "daily";
      retention = { daily = 3; weekly = 2; monthly = 1; yearly = 1; };
      # Stands in for the sops secrets file
      extraPaths = [ "/etc/nestlo-test-secrets.yaml" ];
    };
  };

  testScript = ''
    redis = "redis-cli -s /run/redis-nestlo/redis.sock"

    machine.wait_for_unit("redis-nestlo.service")

    with subtest("create state"):
        machine.succeed("mkdir -p /var/lib/nestlo/state /var/lib/nestlo/cache /var/lib/nestlo-audit")
        machine.succeed("echo precious > /var/lib/nestlo/state/agent-1.json")
        machine.succeed("echo junk > /var/lib/nestlo/cache/blob")
        machine.succeed("echo audit-line > /var/lib/nestlo-audit/audit.log")
        machine.succeed("echo 'sops: encrypted' > /etc/nestlo-test-secrets.yaml")
        machine.succeed(f"{redis} SET spend:today 12.5")
        machine.succeed(f"{redis} SET budget:global 500")

    with subtest("backup"):
        machine.succeed("systemctl start restic-backups-nestlo.service")
        machine.succeed("restic-nestlo snapshots --json | grep -q '\"paths\"'")
        listing = machine.succeed("restic-nestlo ls latest")
        assert "/var/lib/nestlo/state/agent-1.json" in listing, listing
        assert "/var/lib/nestlo-audit/audit.log" in listing, listing
        assert "/etc/nestlo-test-secrets.yaml" in listing, listing
        assert "dump.rdb" in listing, "the Redis RDB must be in the snapshot"
        assert "/var/lib/nestlo/cache" not in listing, "cache must be excluded"
        # /var/lib/nestlo-stack does not exist here: skipped, not an error
        assert "nestlo-stack" not in listing

    with subtest("restore drill leaves the live system alone"):
        machine.succeed("nestlo-restore --target /tmp/drill --include /var/lib/nestlo/state")
        assert machine.succeed("cat /tmp/drill/var/lib/nestlo/state/agent-1.json").strip() == "precious"
        machine.succeed("systemctl is-active redis-nestlo.service")
        machine.succeed("nestlo-restore --dry-run")

    with subtest("disaster"):
        machine.succeed("systemctl stop redis-nestlo.service")
        machine.succeed("rm -rf /var/lib/nestlo /var/lib/nestlo-audit /var/lib/redis-nestlo /etc/nestlo-test-secrets.yaml")
        machine.fail("test -e /var/lib/nestlo/state/agent-1.json")

    with subtest("restore in place"):
        machine.succeed("nestlo-restore")
        assert machine.succeed("cat /var/lib/nestlo/state/agent-1.json").strip() == "precious"
        assert machine.succeed("cat /var/lib/nestlo-audit/audit.log").strip() == "audit-line"
        assert "sops: encrypted" in machine.succeed("cat /etc/nestlo-test-secrets.yaml")
        machine.wait_for_unit("redis-nestlo.service")
        assert machine.succeed(f"{redis} GET spend:today").strip() == "12.5"
        assert machine.succeed(f"{redis} GET budget:global").strip() == "500"
  '';
}
