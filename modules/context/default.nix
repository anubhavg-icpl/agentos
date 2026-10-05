# ═══════════════════════════════════════════════════════════════════════
# Nestlo Context & Memory Module
# ═══════════════════════════════════════════════════════════════════════
#
# Provides persistent memory and semantic search for agents:
#   - Qdrant vector database for embeddings
#   - Embedding service (text → vectors)
#   - Per-agent and per-project memory stores
#   - Context window management (summarization, eviction)
#   - Shared knowledge base across agents
#
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.context;
in
{
  options.nestlo.context = {
    enable = lib.mkEnableOption "Nestlo context and memory system";

    vectorStore = lib.mkOption {
      type = lib.types.enum [ "qdrant" "pgvector" "lancedb" ];
      default = "qdrant";
      description = "Which vector database to use";
    };

    qdrantPort = lib.mkOption {
      type = lib.types.port;
      default = 6333;
      description = "Qdrant HTTP port";
    };

    embeddingModel = lib.mkOption {
      type = lib.types.str;
      default = "text-embedding-3-small";
      description = "Default embedding model";
    };

    memoryRetentionDays = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "How long to keep agent memories";
    };

    enableSharedKnowledge = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable shared knowledge base across agents";
    };
  };

  config = lib.mkIf cfg.enable {
    # ─ Qdrant vector database ────────────────────────────────────────
    services.qdrant = lib.mkIf (cfg.vectorStore == "qdrant") {
      enable = true;
      settings = {
        storage = {
          storage_path = "/var/lib/qdrant";
          snapshots_path = "/var/lib/qdrant/snapshots";
        };
        service = {
          host = "127.0.0.1";
          http_port = cfg.qdrantPort;
          enable_tls = false;
          max_request_size_mb = 256;
        };
      };
    };

    # ─ PostgreSQL with pgvector (alternative) ────────────────────────
    services.postgresql = lib.mkIf (cfg.vectorStore == "pgvector") {
      enable = true;
      ensureDatabases = [ "nestlo" ];
      ensureUsers = [{
        name = "nestlo";
        ensureDBOwnership = true;
      }];
      extensions = [ "pgvector" ];
    };

    # ─ Memory GC (clean up old memories) ─────────────────────────────
    systemd.services.nestlo-memory-gc = {
      description = "Nestlo memory garbage collection";
      startAt = "daily";

      serviceConfig = {
        Type = "oneshot";
        User = "nestlo";
        ExecStart = toString (pkgs.writeShellScript "memory-gc" ''
          set -euo pipefail
          RETENTION=${toString cfg.memoryRetentionDays}

          if [ "${cfg.vectorStore}" = "qdrant" ]; then
            # Delete points older than retention period from all collections
            ${pkgs.curl}/bin/curl -s -X POST "http://localhost:${toString cfg.qdrantPort}/collections" | \
              ${pkgs.jq}/bin/jq -r '.result.collections[]?.name' | while read -r collection; do
                echo "[memory-gc] cleaning collection: $collection"
                ${pkgs.curl}/bin/curl -s -X POST \
                  "http://localhost:${toString cfg.qdrantPort}/collections/$collection/points/delete" \
                  -H 'Content-Type: application/json' \
                  -d "{\"filter\": {\"must\": [{\"key\": \"timestamp\", \"range\": {\"lt\": $(date -d \"-$RETENTION days\" +%s)}}]}}"
              done
          fi
        '');
      };
    };

    # ─ Memory CLI tools ──────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "nestlo-memory" ''
        #!/usr/bin/env bash
        # Memory management CLI
        case "$1" in
          search)
            ${pkgs.curl}/bin/curl -s "http://localhost:${toString cfg.qdrantPort}/collections" | ${pkgs.jq}/bin/jq .
            ;;
          stats)
            echo "Vector store: ${cfg.vectorStore}"
            echo "Embedding model: ${cfg.embeddingModel}"
            echo "Retention: ${toString cfg.memoryRetentionDays} days"
            echo "Shared KB: ${lib.boolToString cfg.enableSharedKnowledge}"
            ${pkgs.curl}/bin/curl -s "http://localhost:${toString cfg.qdrantPort}/collections" | \
              ${pkgs.jq}/bin/jq -r '.result.collections[]?.name' 2>/dev/null | while read -r c; do
                count=$(${pkgs.curl}/bin/curl -s "http://localhost:${toString cfg.qdrantPort}/collections/$c" | ${pkgs.jq}/bin/jq -r '.result.points_count // 0')
                echo "  $c: $count vectors"
              done
            ;;
          forget)
            echo "Clearing all memories..."
            ${pkgs.curl}/bin/curl -s "http://localhost:${toString cfg.qdrantPort}/collections" | \
              ${pkgs.jq}/bin/jq -r '.result.collections[]?.name' 2>/dev/null | while read -r c; do
                ${pkgs.curl}/bin/curl -s -X DELETE "http://localhost:${toString cfg.qdrantPort}/collections/$c"
              done
            echo "Done."
            ;;
          *)
            echo "Usage: nestlo-memory <search|stats|forget>"
            ;;
        esac
      '')
    ];

    # ─ Networking ────────────────────────────────────────────────────
    networking.firewall.interfaces.nestlo0.allowedTCPPorts = [ cfg.qdrantPort ];
  };
}
