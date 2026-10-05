# Nestlo LLM observability module
#
# Standard GenAI observability for the Nestlo model gateway:
#
#   - the gateway exports one OpenTelemetry span per request, following the
#     OTel GenAI semantic conventions (gen_ai.operation.name,
#     gen_ai.provider.name, gen_ai.request.model, gen_ai.usage.*, plus
#     nestlo.agent.id, nestlo.cost_usd and nestlo.route.*), over OTLP/HTTP
#     JSON, from a background thread that never blocks a request
#     (services/nestlo_services/genai_trace.py)
#   - where the spans go is a choice of backend: the Nestlo OTel collector
#     (nestlo.observability, the default), a Langfuse stack, an OpenLIT
#     stack, or any OTLP endpoint
#   - Langfuse (MIT core) and OpenLIT (Apache-2.0) are opt-in podman stacks,
#     bound to loopback, with image digests pinned and every secret generated
#     on the machine at first start (never in the Nix store)
#
# Nothing heavy is on by default: `enable` alone turns on the exporter only.
# See docs/llm-observability.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.llmObservability;
  lf = cfg.langfuse;
  ol = cfg.openlit;
  collectorHttpPort = 4318;   # modules/observability: otlp http receiver

  lfDir = "/var/lib/nestlo-langfuse";
  olDir = "/var/lib/nestlo-openlit";
  lfNet = "nestlo-langfuse";
  olNet = "nestlo-openlit";

  endpoint =
    if cfg.exporter.endpoint != null then cfg.exporter.endpoint
    else if cfg.exporter.backend == "langfuse" then "http://127.0.0.1:${toString lf.port}/api/public/otel/v1/traces"
    else if cfg.exporter.backend == "openlit" then "http://127.0.0.1:${toString ol.otlpPort}/v1/traces"
    else "http://127.0.0.1:${toString collectorHttpPort}/v1/traces";

  headersFile =
    if cfg.exporter.headersFile != null then toString cfg.exporter.headersFile
    else if cfg.exporter.backend == "langfuse" then "${lfDir}/otlp-headers"
    else null;

  # Langfuse needs an S3 API for its event store. MinIO's community edition is
  # unmaintained and marked insecure in nixpkgs, so Garage (single node) from
  # nixpkgs is built into an image: nothing but the Langfuse, ClickHouse,
  # Postgres and Redis images is pulled from a registry.
  garageConfig = pkgs.writeText "nestlo-garage.toml" ''
    metadata_dir = "/data/meta"
    data_dir = "/data/blocks"
    db_engine = "sqlite"
    replication_factor = 1
    rpc_bind_addr = "127.0.0.1:3901"
    # rpc_secret comes from GARAGE_RPC_SECRET

    [s3_api]
    s3_region = "garage"
    api_bind_addr = "[::]:9000"
  '';
  garageImage = pkgs.dockerTools.buildLayeredImage {
    name = "nestlo.local/garage";
    tag = pkgs.garage_2.version;
    contents = [ pkgs.garage_2 pkgs.busybox ];
    config = {
      Env = [ "PATH=/bin" ];
      Entrypoint = [ "/bin/garage" "-c" "/etc/garage.toml" "server" ];
    };
  };

  # Creates the layout, the bucket and the access key in Garage (once)
  garageSetup = pkgs.writeShellApplication {
    name = "nestlo-langfuse-s3-setup";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused config.virtualisation.podman.package ];
    text = ''
      set -a
      # shellcheck disable=SC1091
      . ${lfDir}/secrets/secrets.env
      set +a
      g() { podman exec nestlo-langfuse-s3 /bin/garage -c /etc/garage.toml "$@"; }
      for _ in $(seq 1 60); do g status >/dev/null 2>&1 && break; sleep 2; done
      if ! g bucket list 2>/dev/null | grep langfuse >/dev/null; then
        node=$(g node id -q | cut -d@ -f1)
        g layout assign -z dc1 -c 1G "$node"
        g layout apply --version 1
        g bucket create langfuse
        g key import --yes -n langfuse "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY"
        g bucket allow --read --write --owner langfuse --key langfuse
      fi
    '';
  };

  # OpenLIT's ClickHouse tables for traces, from openlit's assets/clickhouse-init.sh
  # (openlit-2.1.0); OpenLIT's collector writes to them
  openlitSql = pkgs.writeText "nestlo-openlit-init.sql" ''
    CREATE DATABASE IF NOT EXISTS openlit;
    USE openlit;
    CREATE TABLE IF NOT EXISTS otel_traces
    (
        `Timestamp` DateTime64(9) CODEC(Delta(8), ZSTD(1)),
        `TraceId` String CODEC(ZSTD(1)),
        `SpanId` String CODEC(ZSTD(1)),
        `ParentSpanId` String CODEC(ZSTD(1)),
        `TraceState` String CODEC(ZSTD(1)),
        `SpanName` LowCardinality(String) CODEC(ZSTD(1)),
        `SpanKind` LowCardinality(String) CODEC(ZSTD(1)),
        `ServiceName` LowCardinality(String) CODEC(ZSTD(1)),
        `ResourceAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        `ScopeName` String CODEC(ZSTD(1)),
        `ScopeVersion` String CODEC(ZSTD(1)),
        `SpanAttributes` Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        `Duration` UInt64 CODEC(ZSTD(1)),
        `StatusCode` LowCardinality(String) CODEC(ZSTD(1)),
        `StatusMessage` String CODEC(ZSTD(1)),
        `Events.Timestamp` Array(DateTime64(9)) CODEC(ZSTD(1)),
        `Events.Name` Array(LowCardinality(String)) CODEC(ZSTD(1)),
        `Events.Attributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
        `Links.TraceId` Array(String) CODEC(ZSTD(1)),
        `Links.SpanId` Array(String) CODEC(ZSTD(1)),
        `Links.TraceState` Array(String) CODEC(ZSTD(1)),
        `Links.Attributes` Array(Map(LowCardinality(String), String)) CODEC(ZSTD(1)),
        INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
        INDEX idx_res_attr_key mapKeys(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_res_attr_value mapValues(ResourceAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_span_attr_key mapKeys(SpanAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_span_attr_value mapValues(SpanAttributes) TYPE bloom_filter(0.01) GRANULARITY 1,
        INDEX idx_duration Duration TYPE minmax GRANULARITY 1
    )
    ENGINE = MergeTree
    PARTITION BY toDate(Timestamp)
    ORDER BY (ServiceName, SpanName, toDateTime(Timestamp))
    TTL toDateTime(Timestamp) + toIntervalHour(${toString (ol.retentionDays * 24)})
    SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;

    CREATE TABLE IF NOT EXISTS otel_traces_trace_id_ts
    (
        `TraceId` String CODEC(ZSTD(1)),
        `Start` DateTime CODEC(Delta(4), ZSTD(1)),
        `End` DateTime CODEC(Delta(4), ZSTD(1)),
        INDEX idx_trace_id TraceId TYPE bloom_filter(0.01) GRANULARITY 1
    )
    ENGINE = MergeTree
    PARTITION BY toDate(Start)
    ORDER BY (TraceId, Start)
    TTL toDateTime(Start) + toIntervalHour(${toString (ol.retentionDays * 24)})
    SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;

    CREATE MATERIALIZED VIEW IF NOT EXISTS otel_traces_trace_id_ts_mv TO otel_traces_trace_id_ts
    (
        `TraceId` String,
        `Start` DateTime64(9),
        `End` DateTime64(9)
    )
    AS SELECT
        TraceId,
        min(Timestamp) AS Start,
        max(Timestamp) AS End
    FROM otel_traces
    WHERE TraceId != '''
    GROUP BY TraceId;
  '';

  # Files generated at runtime. Everything under <dir>/secrets is root-only;
  # the only file the gateway can read is the OTLP headers file.
  rand = ''rand() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }'';

  langfuseSecrets = pkgs.writeShellApplication {
    name = "nestlo-langfuse-secrets";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
    text = ''
      ${rand}
      umask 077
      d=${lfDir}
      install -d -m 0710 -o root -g nestlo "$d"
      install -d -m 0700 "$d/secrets"
      s=$d/secrets
      if [ ! -s "$s/secrets.env" ]; then
        {
          echo "POSTGRES_PASSWORD=$(rand 24)"
          echo "CLICKHOUSE_PASSWORD=$(rand 24)"
          echo "REDIS_AUTH=$(rand 24)"
          echo "S3_ACCESS_KEY_ID=GK$(rand 12)"
          echo "S3_SECRET_ACCESS_KEY=$(rand 32)"
          echo "GARAGE_RPC_SECRET=$(rand 32)"
          echo "NEXTAUTH_SECRET=$(rand 32)"
          echo "SALT=$(rand 32)"
          echo "ENCRYPTION_KEY=$(rand 32)"
          echo "PROJECT_PUBLIC_KEY=pk-lf-$(rand 16)"
          echo "PROJECT_SECRET_KEY=sk-lf-$(rand 16)"
          echo "ADMIN_PASSWORD=$(rand 12)"
        } > "$s/secrets.env"
      fi
      set -a
      # shellcheck disable=SC1091
      . "$s/secrets.env"
      set +a

      # One env file per container, so that each sees only its own secrets
      printf 'POSTGRES_USER=postgres\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=postgres\n' "$POSTGRES_PASSWORD" > "$s/postgres.env"
      printf 'CLICKHOUSE_DB=default\nCLICKHOUSE_USER=nestlo\nCLICKHOUSE_PASSWORD=%s\n' "$CLICKHOUSE_PASSWORD" > "$s/clickhouse.env"
      printf 'REDIS_AUTH=%s\n' "$REDIS_AUTH" > "$s/redis.env"
      printf 'GARAGE_RPC_SECRET=%s\n' "$GARAGE_RPC_SECRET" > "$s/s3.env"
      {
        echo "DATABASE_URL=postgresql://postgres:$POSTGRES_PASSWORD@postgres:5432/postgres"
        echo "CLICKHOUSE_PASSWORD=$CLICKHOUSE_PASSWORD"
        echo "REDIS_AUTH=$REDIS_AUTH"
        echo "NEXTAUTH_SECRET=$NEXTAUTH_SECRET"
        echo "SALT=$SALT"
        echo "ENCRYPTION_KEY=$ENCRYPTION_KEY"
        for k in EVENT_UPLOAD MEDIA_UPLOAD BATCH_EXPORT; do
          echo "LANGFUSE_S3_''${k}_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID"
          echo "LANGFUSE_S3_''${k}_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY"
        done
        echo "LANGFUSE_INIT_PROJECT_PUBLIC_KEY=$PROJECT_PUBLIC_KEY"
        echo "LANGFUSE_INIT_PROJECT_SECRET_KEY=$PROJECT_SECRET_KEY"
        echo "LANGFUSE_INIT_USER_PASSWORD=$ADMIN_PASSWORD"
      } > "$s/langfuse.env"

      # What the gateway sends: Langfuse's OTLP endpoint takes Basic auth with the project keys
      auth=$(printf '%s:%s' "$PROJECT_PUBLIC_KEY" "$PROJECT_SECRET_KEY" | base64 -w0)
      umask 037
      printf 'Authorization: Basic %s\n' "$auth" > "$d/otlp-headers.new"
      chgrp nestlo "$d/otlp-headers.new"
      mv -f "$d/otlp-headers.new" "$d/otlp-headers"
    '';
  };

  openlitSecrets = pkgs.writeShellApplication {
    name = "nestlo-openlit-secrets";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${rand}
      umask 077
      install -d -m 0700 ${olDir} ${olDir}/secrets
      s=${olDir}/secrets
      if [ ! -s "$s/clickhouse-password" ]; then
        rand 24 > "$s/clickhouse-password"
      fi
      pw=$(cat "$s/clickhouse-password")
      printf 'CLICKHOUSE_USER=nestlo\nCLICKHOUSE_PASSWORD=%s\nCLICKHOUSE_DB=openlit\n' "$pw" > "$s/clickhouse.env"
      printf 'INIT_DB_USERNAME=nestlo\nINIT_DB_PASSWORD=%s\n' "$pw" > "$s/openlit.env"
    '';
  };

  podmanNetwork = name: pkgs.writeShellScript "${name}-net" ''
    ${config.virtualisation.podman.package}/bin/podman network exists ${name} \
      || ${config.virtualisation.podman.package}/bin/podman network create ${name}
  '';

  hardening = [ "--security-opt=no-new-privileges" ];
  dropCaps = [ "--cap-drop=ALL" ];

  langfuseEnv = {
    NEXTAUTH_URL = lf.url;
    TELEMETRY_ENABLED = "false";
    LANGFUSE_ENABLE_EXPERIMENTAL_FEATURES = "false";
    CLICKHOUSE_MIGRATION_URL = "clickhouse://clickhouse:9000";
    CLICKHOUSE_URL = "http://clickhouse:8123";
    CLICKHOUSE_USER = "nestlo";
    CLICKHOUSE_CLUSTER_ENABLED = "false";
    REDIS_HOST = "redis";
    REDIS_PORT = "6379";
    LANGFUSE_S3_EVENT_UPLOAD_BUCKET = "langfuse";
    LANGFUSE_S3_EVENT_UPLOAD_REGION = "garage";
    LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT = "http://s3:9000";
    LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE = "true";
    LANGFUSE_S3_EVENT_UPLOAD_PREFIX = "events/";
    # Media uploads and batch exports are presigned for a browser; the
    # stack is loopback-only and does not publish the S3 store, so they stay internal
    LANGFUSE_S3_MEDIA_UPLOAD_BUCKET = "langfuse";
    LANGFUSE_S3_MEDIA_UPLOAD_REGION = "garage";
    LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT = "http://s3:9000";
    LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE = "true";
    LANGFUSE_S3_MEDIA_UPLOAD_PREFIX = "media/";
    LANGFUSE_S3_BATCH_EXPORT_ENABLED = "false";
    LANGFUSE_S3_BATCH_EXPORT_BUCKET = "langfuse";
    LANGFUSE_S3_BATCH_EXPORT_REGION = "garage";
    LANGFUSE_S3_BATCH_EXPORT_ENDPOINT = "http://s3:9000";
    LANGFUSE_S3_BATCH_EXPORT_FORCE_PATH_STYLE = "true";
    LANGFUSE_S3_BATCH_EXPORT_PREFIX = "exports/";
  };

  langfuseInit = {
    LANGFUSE_INIT_ORG_ID = "nestlo";
    LANGFUSE_INIT_ORG_NAME = "Nestlo";
    LANGFUSE_INIT_PROJECT_ID = "nestlo-gateway";
    LANGFUSE_INIT_PROJECT_NAME = "Nestlo model gateway";
    LANGFUSE_INIT_USER_EMAIL = lf.adminEmail;
    LANGFUSE_INIT_USER_NAME = "Nestlo admin";
    AUTH_DISABLE_SIGNUP = "true";
  };

  lfDeps = [ "nestlo-langfuse-postgres" "nestlo-langfuse-clickhouse" "nestlo-langfuse-redis" "nestlo-langfuse-s3" ];
  lfFiles = n: [ "${lfDir}/secrets/${n}.env" ];
in
{
  options.nestlo.llmObservability = {
    enable = lib.mkEnableOption "GenAI observability: OpenTelemetry spans from the Nestlo model gateway, optionally into Langfuse or OpenLIT";

    exporter = {
      backend = lib.mkOption {
        type = lib.types.enum [ "collector" "langfuse" "openlit" "custom" ];
        default = "collector";
        description = ''
          Where the gateway sends its spans. "collector" is the Nestlo
          OpenTelemetry collector (nestlo.observability, OTLP/HTTP on
          127.0.0.1:4318, which forwards traces to Tempo and Grafana).
          "langfuse" and "openlit" send to the stack enabled below, on
          loopback. "custom" needs `endpoint`.
        '';
      };

      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://otel.example.com/v1/traces";
        description = ''
          Full OTLP/HTTP traces URL (JSON encoding), overriding the one the
          backend implies. An http:// URL with headers must point at
          loopback; anything else needs https://.
        '';
      };

      headersFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/otlp-headers";
        description = ''
          File of `Name: value` request headers (for example
          `Authorization: Bearer ...`), read by the gateway and re-read when
          it changes. It must be readable by the `nestlo` user and is never
          copied into the Nix store. With the langfuse backend the module
          writes it for you.
        '';
      };

      sampleRatio = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = "Fraction of requests that are traced (0.0 to 1.0).";
      };

      legacySystemAttribute = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Also set `gen_ai.system`, which the GenAI conventions deprecated in
          favour of `gen_ai.provider.name`. For backends that still key on it.
        '';
      };

      queueSize = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2048;
        description = "Spans the exporter holds while it is busy. When full, new spans are dropped (counted) and requests are never delayed.";
      };

      timeoutSec = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Connect and read timeout of one export request.";
      };
    };

    langfuse = {
      enable = lib.mkEnableOption ''
        a Langfuse stack (web, worker, Postgres, ClickHouse, Redis and Garage) as
        podman containers on loopback. It is heavy (about 3-4 GB of RAM)'';

      port = lib.mkOption {
        type = lib.types.port;
        default = 3300;
        description = "Loopback port of the Langfuse web UI and its OTLP endpoint.";
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:${toString lf.port}";
        defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString config.nestlo.llmObservability.langfuse.port}"'';
        example = "https://langfuse.example.com";
        description = "Public URL Langfuse believes it is served at (NEXTAUTH_URL). Change it when you put a reverse proxy in front.";
      };

      adminEmail = lib.mkOption {
        type = lib.types.str;
        default = "admin@nestlo.local";
        description = ''
          Email of the admin user created on first start. Its generated
          password is in ${lfDir}/secrets/secrets.env (ADMIN_PASSWORD, root
          only). Sign-up is disabled.
        '';
      };

      images = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          # Digests resolved from Docker Hub on 2026-10-05 (the tag is kept for humans; podman pulls by digest)
          web = "docker.io/langfuse/langfuse:4.50.0@sha256:3d2ae888a0e6edb41fdba6e7d5baca5e4baede3a870dac7970dadd9d925b018e";
          worker = "docker.io/langfuse/langfuse-worker:4.50.0@sha256:52f7fd41ded2f1a6acab13ff7cb1832d36dfe2cbf44adea402b7a09cfa4ce800";
          clickhouse = "docker.io/clickhouse/clickhouse-server:25.12@sha256:8a790dd3468db22b1d4e7b18a176f378ff5ff6053b9c48dd4ea1fa71a24c5ba6";
          postgres = "docker.io/library/postgres:17@sha256:d74eeac9a635390a49bc21bd49fccd973de707e2a53a76ac49b552b8712ec46f";
          redis = "docker.io/library/redis:7@sha256:c6eabf748fc7a61dbb5a705c78bcf3d6377b1127a97d0ce965c11c44ba46896f";
        };
        description = ''
          Images of the stack (web, worker, clickhouse, postgres, redis),
          pinned by digest. Postgres 17 and ClickHouse 25.12 follow
          Langfuse's own docker-compose.yml. Langfuse's major version
          matters: its database migrations run on start, and a downgrade is
          not supported. Garage (the S3 store) is built by Nix from nixpkgs, not pulled.
        '';
      };

      memoryLimitMB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2048;
        description = "Memory limit of the ClickHouse container (the largest consumer); the others get fixed smaller limits.";
      };
    };

    openlit = {
      enable = lib.mkEnableOption ''
        an OpenLIT stack (UI with its OpenTelemetry collector, and ClickHouse) as
        podman containers on loopback'';

      uiPort = lib.mkOption {
        type = lib.types.port;
        default = 3301;
        description = "Loopback port of the OpenLIT UI.";
      };

      otlpPort = lib.mkOption {
        type = lib.types.port;
        default = 4328;
        description = "Loopback port of OpenLIT's OTLP/HTTP receiver (4318 inside the container; the host's 4318 belongs to the Nestlo collector).";
      };

      retentionDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "How long ClickHouse keeps traces.";
      };

      images = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {
          # openlit 2.1.0 is also `latest`; digests resolved from ghcr.io / Docker Hub on 2026-10-05
          openlit = "ghcr.io/openlit/openlit:2.1.0@sha256:94552ccd09379b5e2fec3c51c4fec1b41d88d6b56b0a5ccc895c116673884fa8";
          # OpenLIT's compose uses 24.4.1 (digest not resolved); the 25.12 image Langfuse uses is the same MergeTree schema
          clickhouse = "docker.io/clickhouse/clickhouse-server:25.12@sha256:8a790dd3468db22b1d4e7b18a176f378ff5ff6053b9c48dd4ea1fa71a24c5ba6";
        };
        description = "Images of the stack (openlit, clickhouse), pinned by digest.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = config.nestlo.networking.enable;
          message = "nestlo.llmObservability traces the Nestlo model gateway (nestlo.networking.enable).";
        }
        {
          assertion = cfg.exporter.backend != "collector" || config.nestlo.observability.enable;
          message = "nestlo.llmObservability.exporter.backend = \"collector\" needs nestlo.observability.enable; pick another backend or set exporter.endpoint.";
        }
        {
          assertion = cfg.exporter.backend != "langfuse" || lf.enable;
          message = "nestlo.llmObservability.exporter.backend = \"langfuse\" needs nestlo.llmObservability.langfuse.enable.";
        }
        {
          assertion = cfg.exporter.backend != "openlit" || ol.enable;
          message = "nestlo.llmObservability.exporter.backend = \"openlit\" needs nestlo.llmObservability.openlit.enable.";
        }
        {
          assertion = cfg.exporter.backend != "custom" || cfg.exporter.endpoint != null;
          message = "nestlo.llmObservability.exporter.backend = \"custom\" needs nestlo.llmObservability.exporter.endpoint.";
        }
        {
          assertion = cfg.exporter.sampleRatio >= 0.0 && cfg.exporter.sampleRatio <= 1.0;
          message = "nestlo.llmObservability.exporter.sampleRatio must be between 0 and 1.";
        }
        {
          assertion = !(lf.enable && ol.enable) || lf.port != ol.uiPort;
          message = "nestlo.llmObservability: the Langfuse and OpenLIT UI ports must differ.";
        }
      ];

      # The gateway reads this ([tracing] in config.py)
      nestlo.services.settings.tracing = {
        enabled = true;
        inherit endpoint;
        sample_ratio = cfg.exporter.sampleRatio;
        legacy_system_attribute = cfg.exporter.legacySystemAttribute;
        queue = cfg.exporter.queueSize;
        timeout_sec = cfg.exporter.timeoutSec;
      } // lib.optionalAttrs (headersFile != null) { headers_file = headersFile; };
    }

    # ─ Langfuse ──────────────────────────────────────────────────────
    (lib.mkIf lf.enable {
      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = lib.mkDefault "podman";

      systemd.services = {
        nestlo-langfuse-secrets = {
          description = "Generate the Langfuse secrets and the gateway's OTLP credentials";
          wantedBy = [ "multi-user.target" ];
          before = [ "nestlo-model-gateway.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${langfuseSecrets}/bin/nestlo-langfuse-secrets";
          };
        };
        nestlo-langfuse-s3-setup = {
          description = "Create the Langfuse bucket and access key in Garage";
          wantedBy = [ "multi-user.target" ];
          after = [ "podman-nestlo-langfuse-s3.service" "nestlo-langfuse-secrets.service" ];
          requires = [ "podman-nestlo-langfuse-s3.service" "nestlo-langfuse-secrets.service" ];
          before = [ "podman-nestlo-langfuse-web.service" "podman-nestlo-langfuse-worker.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${garageSetup}/bin/nestlo-langfuse-s3-setup";
          };
        };
        nestlo-langfuse-network = {
          description = "Podman network of the Langfuse stack";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = podmanNetwork lfNet;
          };
        };
      } // lib.genAttrs (map (n: "podman-${n}") (lfDeps ++ [ "nestlo-langfuse-web" "nestlo-langfuse-worker" ])) (_: {
        after = [ "nestlo-langfuse-secrets.service" "nestlo-langfuse-network.service" ];
        requires = [ "nestlo-langfuse-secrets.service" "nestlo-langfuse-network.service" ];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = 10;
        };
      });

      virtualisation.oci-containers.containers = {
        nestlo-langfuse-postgres = {
          image = lf.images.postgres;
          environmentFiles = lfFiles "postgres";
          volumes = [ "nestlo-langfuse-postgres:/var/lib/postgresql/data" ];
          extraOptions = hardening ++ [ "--network=${lfNet}" "--network-alias=postgres" "--memory=1g" ];
        };
        nestlo-langfuse-redis = {
          image = lf.images.redis;
          environmentFiles = lfFiles "redis";
          entrypoint = "/bin/sh";
          cmd = [ "-c" ''exec docker-entrypoint.sh redis-server --requirepass "$REDIS_AUTH" --maxmemory-policy noeviction'' ];
          volumes = [ "nestlo-langfuse-redis:/data" ];
          extraOptions = hardening ++ [ "--network=${lfNet}" "--network-alias=redis" "--memory=512m" ];
        };
        nestlo-langfuse-clickhouse = {
          image = lf.images.clickhouse;
          environmentFiles = lfFiles "clickhouse";
          volumes = [
            "nestlo-langfuse-clickhouse:/var/lib/clickhouse"
            "nestlo-langfuse-clickhouse-logs:/var/log/clickhouse-server"
          ];
          extraOptions = hardening ++ [
            "--network=${lfNet}"
            "--network-alias=clickhouse"
            "--memory=${toString lf.memoryLimitMB}m"
            "--ulimit=nofile=262144:262144"
          ];
        };
        nestlo-langfuse-s3 = {
          image = "nestlo.local/garage:${pkgs.garage_2.version}";
          imageFile = garageImage;
          environmentFiles = lfFiles "s3";
          volumes = [
            "nestlo-langfuse-s3:/data"
            "${garageConfig}:/etc/garage.toml:ro"
          ];
          extraOptions = hardening ++ dropCaps ++ [ "--network=${lfNet}" "--network-alias=s3" "--memory=512m" ];
        };
        nestlo-langfuse-worker = {
          image = lf.images.worker;
          environment = langfuseEnv;
          environmentFiles = lfFiles "langfuse";
          dependsOn = lfDeps;
          extraOptions = hardening ++ dropCaps ++ [ "--network=${lfNet}" "--memory=1g" ];
        };
        nestlo-langfuse-web = {
          image = lf.images.web;
          environment = langfuseEnv // langfuseInit;
          environmentFiles = lfFiles "langfuse";
          dependsOn = lfDeps;
          # Loopback only
          ports = [ "127.0.0.1:${toString lf.port}:3000" ];
          extraOptions = hardening ++ dropCaps ++ [ "--network=${lfNet}" "--memory=1g" ];
        };
      };
    })

    # ─ OpenLIT ───────────────────────────────────────────────────────
    (lib.mkIf ol.enable {
      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = lib.mkDefault "podman";

      systemd.services = {
        nestlo-openlit-secrets = {
          description = "Generate the OpenLIT database password";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${openlitSecrets}/bin/nestlo-openlit-secrets";
          };
        };
        nestlo-openlit-network = {
          description = "Podman network of the OpenLIT stack";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = podmanNetwork olNet;
          };
        };
      } // lib.genAttrs [ "podman-nestlo-openlit-clickhouse" "podman-nestlo-openlit" ] (_: {
        after = [ "nestlo-openlit-secrets.service" "nestlo-openlit-network.service" ];
        requires = [ "nestlo-openlit-secrets.service" "nestlo-openlit-network.service" ];
        serviceConfig = {
          Restart = lib.mkForce "always";
          RestartSec = 10;
        };
      });

      virtualisation.oci-containers.containers = {
        nestlo-openlit-clickhouse = {
          image = ol.images.clickhouse;
          environmentFiles = [ "${olDir}/secrets/clickhouse.env" ];
          volumes = [
            "nestlo-openlit-clickhouse:/var/lib/clickhouse"
            "${openlitSql}:/docker-entrypoint-initdb.d/init.sql:ro"
          ];
          extraOptions = hardening ++ [ "--network=${olNet}" "--network-alias=clickhouse" "--memory=2g" "--ulimit=nofile=262144:262144" ];
        };
        nestlo-openlit = {
          image = ol.images.openlit;
          environment = {
            TELEMETRY_ENABLED = "false";
            INIT_DB_HOST = "clickhouse";
            INIT_DB_PORT = "8123";
            INIT_DB_DATABASE = "openlit";
            SQLITE_DATABASE_URL = "file:/app/client/data/data.db";
            PORT = "3000";
            DOCKER_PORT = "3000";
          };
          environmentFiles = [ "${olDir}/secrets/openlit.env" ];
          dependsOn = [ "nestlo-openlit-clickhouse" ];
          volumes = [ "nestlo-openlit-data:/app/client/data" ];
          # Loopback only; OpenLIT's OTLP receiver has no authentication
          ports = [
            "127.0.0.1:${toString ol.uiPort}:3000"
            "127.0.0.1:${toString ol.otlpPort}:4318"
          ];
          extraOptions = hardening ++ [ "--network=${olNet}" "--memory=1g" ];
        };
      };
    })
  ]);
}
