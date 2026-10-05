# ═══════════════════════════════════════════════════════════════════════
# Nestlo Databases Module
# ═══════════════════════════════════════════════════════════════════════
#
# Pre-installs and auto-starts common databases so agents can work
# on database-driven projects without manual setup.
#
{ config, pkgs, lib, ... }:

let
  avail = import ../lib/available.nix { inherit pkgs lib; };
  cfg = config.nestlo.databases;
in
{
  options.nestlo.databases = {
    enable = lib.mkEnableOption "Nestlo database services";

    enablePostgres = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable PostgreSQL";
    };

    enableRedis = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Redis";
    };

    enableSQLite = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable SQLite (always available, just installs CLI)";
    };

    enableMongoDB = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable MongoDB (disabled by default: large)";
    };

    enableMySQL = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable MySQL/MariaDB";
    };

    enableDuckDB = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable DuckDB (in-process analytics DB)";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ PostgreSQL ────────────────────────────────────────────────────
    services.postgresql = lib.mkIf cfg.enablePostgres {
      enable = true;
      package = pkgs.postgresql_16;
      ensureDatabases = [ "nestlo" "dev" "test" ];
      ensureUsers = [
        { name = "nestlo"; ensureDBOwnership = true; }
        { name = "admin"; ensureClauses.superuser = true; }
      ];
      authentication = pkgs.lib.mkOverride 10 ''
        local   all   all                     trust
        host    all   all   127.0.0.1/32      trust
        host    all   all   ::1/128           trust
      '';
      settings = {
        shared_buffers = "128MB";
        work_mem = "4MB";
        max_connections = 50;
        log_min_duration_statement = "500";  # log slow queries
      };
    };

    # ─ Redis ─────────────────────────────────────────────────────────
    # A Redis for agents' own projects on localhost:6379, separate from
    # the Nestlo control-plane Redis (redis-nestlo, unix socket only)
    services.redis.servers.dev = lib.mkIf cfg.enableRedis {
      enable = true;
      port = 6379;
      settings = {
        maxmemory = "256mb";
        maxmemory-policy = "allkeys-lru";
        appendonly = "yes";
      };
    };

    # ─ MongoDB ──────────────────────────────────────────────────────
    services.mongodb = lib.mkIf cfg.enableMongoDB {
      enable = true;
      bind_ip = "127.0.0.1";
      dbpath = "/var/lib/mongodb";
    };

    # ─ MySQL/MariaDB ────────────────────────────────────────────────
    services.mysql = lib.mkIf cfg.enableMySQL {
      enable = true;
      package = pkgs.mariadb;
      ensureDatabases = [ "nestlo" "dev" "test" ];
      ensureUsers = [
        { name = "nestlo"; ensurePermissions = { "*.*" = "ALL PRIVILEGES"; }; }
      ];
    };

    # ─ Database CLI tools ────────────────────────────────────────────
    environment.systemPackages = avail (lib.flatten [
      (lib.optionals cfg.enablePostgres (with pkgs; [
        pgcli                    # nice CLI for postgres
        pgcenter                 # monitoring
      ]))

      (lib.optional cfg.enableRedis pkgs.redis)

      (lib.optionals cfg.enableSQLite (with pkgs; [
        sqlite
        sqlite-web              # web UI for sqlite
        litecli                 # nice CLI for sqlite
      ]))

      (lib.optional cfg.enableDuckDB pkgs.duckdb)

      # Migration tools
      (with pkgs; [
        sqitchPg                # database change management
        atlas                   # modern schema management
        sqlx-cli               # Rust SQL toolkit CLI
        sqlfluff               # SQL linter/formatter
      ])

      # ─ Database management CLI ────────────────────────────────────
      (pkgs.writeShellScriptBin "nestlo-db" ''
        #!/usr/bin/env bash
        case "''${1:-status}" in
          status)
            echo "Databases:"
            ${pkgs.postgresql_16}/bin/psql -c "SELECT version();" 2>/dev/null | head -3 && echo "  PostgreSQL: ✅ running" || echo "  PostgreSQL: ❌ down"
            ${pkgs.redis}/bin/redis-cli ping 2>/dev/null | grep -q PONG && echo "  Redis: ✅ running" || echo "  Redis: ❌ down"
            [ -f /var/lib/mongodb/mongod.lock ] && echo "  MongoDB: ✅ running" || echo "  MongoDB: ❌ down"
            echo "  SQLite: ✅ available (in-process)"
            echo "  DuckDB: ✅ available (in-process)"
            ;;
          connect)
            DB="''${2:-postgres}"
            case "$DB" in
              postgres|pg) ${pkgs.postgresql_16}/bin/psql -U nestlo -d nestlo ;;
              redis) ${pkgs.redis}/bin/redis-cli ;;
              sqlite) echo "Usage: sqlite3 <file>" ;;
              duckdb) ${pkgs.duckdb}/bin/duckdb ;;
              *) echo "Unknown database: $DB" ;;
            esac
            ;;
          *) echo "Usage: nestlo-db <status|connect>" ;;
        esac
      '')
    ]);
  };
}
