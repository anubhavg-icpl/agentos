# Nestlo Beacon module
#
# Agent Beacon (https://github.com/Asymptote-Labs/agent-beacon, MIT)
# captures what coding agents do (prompts, tool calls, commands, file edits,
# approvals, MCP calls, tokens) across more than twenty harnesses, keeps it in
# a local JSONL log, replays it (`beacon traces`, `beacon endpoint dashboard`),
# distils workflows and corrections into reviewed project memory
# (`beacon memory`) and serves that memory back to agents over MCP and Agent
# Skills. This module makes it part of Nestlo, local-first: nothing leaves the
# machine unless nestlo.beacon.cloud.enable is set.
#
#   - beacon-collector.service: Beacon's OpenTelemetry collector (built from
#     source without any exporter that could leave the machine) on 127.0.0.1,
#     writing /var/lib/beacon/logs/runtime.jsonl. Own user, no capabilities,
#     IPAddressDeny=any except loopback.
#   - capture: beacon-setup-<user>.service runs, as each user, Beacon's own
#     `beacon endpoint install --user --no-start --service none`, which
#     merges Beacon's hooks, plugins and OTLP settings into the user's
#     agent configuration (Claude Code, Codex, Gemini CLI, OpenCode, Cline,
#     pi, Qwen Code, Cursor, Factory Droid, Kiro, ... discovered on PATH) and
#     keeps other settings, with one backup, instead of overwriting them.
#   - users: operators and `users` log straight into the shared log (group
#     `beacon`); the sandboxed agent user cannot write there from inside
#     `nestlo spawn` (ProtectSystem=strict, only its workspace and home are
#     writable), so it logs under its home and beacon-relay-<user>.service
#     appends that to the shared log. Approved memory is copied the other way
#     (beacon-memory-sync-<user>) so the agent can recall it over MCP.
#   - retention: rotated segments are compressed into /var/lib/beacon/archive
#     and pruned after `retention.days`.
#   - knowledge back to agents: the Beacon skills pack (nestlo.skills), the
#     `beacon` entry of the MCP registry (nestlo-beacon-mcp) and, for
#     approved memory, `beacon memory skills install`.
#   - observability: the collector's own metrics on loopback, scraped by
#     nestlo.observability.
#
# See docs/beacon.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.beacon;
  rt = config.nestlo.runtime;
  obs = config.nestlo.observability;
  agentUser = "nestlo-agent";
  pkg = cfg.package;

  stateDir = "/var/lib/beacon";
  logDir = "${stateDir}/logs";
  # Beacon derives its memory store from the log path: the directory above
  # a directory named `logs` (cli/beacon/internal/learning/store.go,
  # PathForRuntimeLog), so this is /var/lib/beacon/memory.db
  logPath = "${logDir}/runtime.jsonl";
  memoryDb = "${stateDir}/memory.db";
  archiveDir = "${stateDir}/archive";
  etcDir = "/etc/beacon/endpoint";

  homeOf = u:
    if u == agentUser then rt.agentHome
    else if u == "openclaw" then "/var/lib/openclaw"
    else config.users.users.${u}.home;
  # Where each class of user writes its hook events (see the header)
  isolatedLogOf = u: "${homeOf u}/.beacon/endpoint/logs/runtime.jsonl";

  directUsers = lib.unique cfg.users;
  isolatedUsers = lib.unique (lib.optional cfg.includeAgentUser agentUser ++ cfg.isolatedUsers);
  allUsers = lib.unique (directUsers ++ isolatedUsers);
  logOf = u: if lib.elem u isolatedUsers then isolatedLogOf u else logPath;

  harnessArg = if cfg.harnesses == "auto" then "auto" else lib.concatStringsSep "," cfg.harnesses;

  # Native OTLP harnesses get their endpoint configured by `endpoint install`
  # (claude, codex, gemini); hook and plugin harnesses go through the same
  # command (cli/beacon/cmd/endpoint_targets.go)
  allHarnesses = [
    "claude" "codex" "gemini" "antigravity" "opencode" "cline" "pi" "omp" "openclaw" "grok" "prime"
    "omo" "dsh" "qwen" "kimi" "kiro" "muse" "hermes" "factory" "cursor" "devin-cli" "devin-desktop"
  ];

  # ─ Collector ───────────────────────────────────────────────────────
  # The same pipeline Beacon renders for itself (cli/beacon/internal/endpoint/
  # collector/collector.go, ConfigYAML) minus the Splunk and Falcon exporters,
  # which are not compiled into this collector
  # (JSON is YAML, and avoids templating indentation)
  otelcolYaml = pkgs.writeText "beacon-otelcol.yaml" (builtins.toJSON {
    receivers.otlp.protocols = {
      grpc.endpoint = "127.0.0.1:${toString cfg.ports.otlpGrpc}";
      http.endpoint = "127.0.0.1:${toString cfg.ports.otlpHttp}";
    };
    processors = {
      memory_limiter = {
        check_interval = "1s";
        limit_mib = cfg.collector.memoryLimitMiB;
      };
      batch = {
        timeout = "5s";
        send_batch_size = 128;
      };
    };
    exporters.beaconjson = {
      path = logPath;
      max_event_bytes = 65536;
      rotate_bytes = 10485760;
      rotate_archives = 5;
      redact_secrets = true;
    } // lib.optionalAttrs cfg.collector.includeRuntimeMetrics { include_runtime_metrics = true; }
    // lib.optionalAttrs cfg.collector.includeCodexSpans { include_codex_spans = true; };
    extensions.health_check.endpoint = "127.0.0.1:${toString cfg.ports.health}";
    service = {
      telemetry.metrics =
        if cfg.ports.metrics == null then { level = "none"; } else {
          level = "basic";
          readers = [{
            pull.exporter.prometheus = {
              host = "127.0.0.1";
              port = cfg.ports.metrics;
            };
          }];
        };
      extensions = [ "health_check" ];
      pipelines = lib.genAttrs [ "logs" "traces" "metrics" ] (_: {
        receivers = [ "otlp" ];
        processors = [ "memory_limiter" "batch" ];
        exporters = [ "beaconjson" ];
      });
    };
  });

  # What `beacon endpoint status --system`, ResolveRuntimeLog and the hook
  # adapter read (cli/beacon/internal/endpoint/config/config.go). Written at
  # runtime rather than as a store symlink because `beacon endpoint connect`
  # records the Beacon Cloud enrolment in it.
  endpointConfig = pkgs.writeText "beacon-endpoint-config.json" (builtins.toJSON {
    user_mode = false;
    log_path = logPath;
    collector = {
      binary_path = "${pkg}/bin/beacon-otelcol";
      config_path = "${etcDir}/otelcol.yaml";
      grpc_port = cfg.ports.otlpGrpc;
      http_port = cfg.ports.otlpHttp;
      health_port = cfg.ports.health;
      spool_path = "${stateDir}/spool/otlp.jsonl";
      include_runtime_metrics = cfg.collector.includeRuntimeMetrics;
      include_codex_spans = cfg.collector.includeCodexSpans;
    };
    harnesses = [ "claude" "codex" "gemini" ];
    # The scheduled inventory job needs launchd or systemd units that
    # `beacon endpoint install` writes itself; nestlo.beacon does not run it
    inventory_heartbeat.enabled = false;
  });

  configScript = pkgs.writeShellScript "beacon-endpoint-config" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq ]}
    dir=${etcDir}
    install -d -m 0755 /etc/beacon "$dir"
    # keep what `beacon endpoint connect` and `endpoint update` recorded
    if [ -s "$dir/config.json" ] && jq -e . "$dir/config.json" >/dev/null 2>&1; then
      jq --slurpfile new ${endpointConfig} \
        '$new[0] + (if .managed_ingest then {managed_ingest} else {} end) + (if .auto_update then {auto_update} else {} end)' \
        "$dir/config.json" > "$dir/config.json.new"
    else
      cp ${endpointConfig} "$dir/config.json.new"
    fi
    chmod 0644 "$dir/config.json.new"
    mv -f "$dir/config.json.new" "$dir/config.json"
  '';

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    UMask = "0007";
  };
  # Nothing of Beacon's services talks to anything but this machine
  loopbackOnly = {
    IPAddressDeny = "any";
    IPAddressAllow = "localhost";
  };

  # ─ Retention ───────────────────────────────────────────────────────
  # Beacon rotates at 10 MiB and keeps five archives (hook adapter and
  # exporter share that contract and neither reads it from configuration),
  # about 60 MiB of events. Segments are compressed away before they fall
  # off, and removed after `retention.days`.
  archiveScript = pkgs.writeShellScript "beacon-archive" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.zstd ]}
    cd ${stateDir}
    mkdir -p archive
    now=$(date +%s)
    for f in logs/runtime.jsonl.[1-9]; do
      [ -f "$f" ] || continue
      m=$(stat -c %Y "$f")
      # still open for appends by a hook that started before the rotation
      [ $((now - m)) -ge 120 ] || continue
      s=$(stat -c %s "$f")
      dst=archive/runtime-$(date -u -d "@$m" +%Y%m%dT%H%M%SZ)-$s.jsonl.zst
      if [ ! -e "$dst" ]; then
        # set -e does not apply inside && lists: a failed zstd must fail the unit
        zstd -q -f -T1 -19 -o "$dst.tmp" "$f"
        mv "$dst.tmp" "$dst"
      fi
    done
    ${lib.optionalString (cfg.retention.days > 0) ''
      find archive -name 'runtime-*.jsonl.zst' -mtime +${toString cfg.retention.days} -delete
    ''}
  '';

  # ─ Per-user capture ────────────────────────────────────────────────
  setupScript = u: pkgs.writeShellScript "beacon-setup-${u}" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.jq ]}:/run/current-system/sw/bin:/run/wrappers/bin
    # Never ask a question or reach the network
    export BEACON_ONBOARDING=0 BEACON_MANAGED_INGEST=0 BEACON_BACKFILL=0
    home=${homeOf u}
    [ -d "$home" ] || { echo "beacon: home $home does not exist, skipping" >&2; exit 0; }
    mkdir -p "$home/.beacon/endpoint" ${lib.optionalString (lib.elem u isolatedUsers) ''"$home/.beacon/endpoint/logs"''}
    ${pkg}/bin/beacon endpoint install --user --no-start --service none --no-backfill \
      --harness ${lib.escapeShellArg harnessArg} \
      --log-path ${lib.escapeShellArg (logOf u)} \
      --collector ${pkg}/bin/beacon-otelcol \
      --otlp-grpc-port ${toString cfg.ports.otlpGrpc} --otlp-http-port ${toString cfg.ports.otlpHttp} \
      --health-port ${toString cfg.ports.health}
    rc=$?
    ${lib.optionalString (lib.elem u isolatedUsers) ''
      # A user-mode CLI is switched to the system log when a system collector
      # runs on the same ports (lifecycle.ResolveRuntimeLog, selectRuntimeLog),
      # and this user cannot read that log. Different ports in its own
      # config.json keep `beacon memory`, `beacon traces` & co on its own
      # log; the OTLP settings written above are not affected.
      cfgfile="$home/.beacon/endpoint/config.json"
      if [ -s "$cfgfile" ]; then
        jq '.collector.grpc_port += 10000 | .collector.http_port += 10000 | .collector.health_port += 10000' "$cfgfile" > "$cfgfile.tmp" \
          && mv -f "$cfgfile.tmp" "$cfgfile"
      fi
    ''}
    # `endpoint install` writes a timestamped backup of every settings file
    # it merges into, on every run. Keep the oldest per file (the one that
    # still holds the configuration from before Beacon) so reboots do not
    # pile them up
    find "$home" -maxdepth 4 -name '*.beacon.*.bak' -not -path '*/node_modules/*' 2>/dev/null \
      | sed 's/\.beacon\.[0-9TZ]*\.bak$//' | sort -u | while read -r base; do
          ls -1 "$base".beacon.*.bak 2>/dev/null | sort | tail -n +2 | xargs -r rm -f
        done
    exit $rc
  '';

  mkSetup = u: lib.nameValuePair "beacon-setup-${u}" {
    description = "Point the agents of ${u} at Beacon (hooks, plugins, OTLP)";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "systemd-user-sessions.service" "beacon-collector.service" ];
    wants = [ "beacon-collector.service" ];
    restartTriggers = [ (setupScript u) pkg ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = u;
      ExecStart = setupScript u;
      WorkingDirectory = "/";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ReadWritePaths = [ "-${homeOf u}" ] ++ lib.optional (!(lib.elem u isolatedUsers)) "-${logDir}";
      UMask = "0002";
    } // loopbackOnly;
  };

  # ─ Relay for users that cannot write the shared log ────────────────
  relayScript = pkgs.writeScript "beacon-relay" ''
    #!${pkgs.python3}/bin/python3
    """Append the hook events a sandboxed user logged under its home to the
    shared Beacon log. Whole lines only, offset kept in the state directory,
    a rotated segment is drained before the new file is read."""
    import os
    import sys
    import time

    SRC, DST, STATE = sys.argv[1:4]
    CHUNK = 1 << 20


    def load():
        try:
            with open(STATE) as f:
                ino, off = f.read().split()
            return int(ino), int(off)
        except (OSError, ValueError):
            return None, 0


    def save(ino, off):
        with open(STATE + ".tmp", "w") as f:
            f.write("%d %d\n" % (ino, off))
        os.replace(STATE + ".tmp", STATE)


    def drain(path, off):
        """Copy complete lines of path from off; returns the new offset."""
        try:
            with open(path, "rb") as f:
                f.seek(off)
                while True:
                    data = f.read(CHUNK)
                    if not data:
                        return off
                    cut = data.rfind(b"\n")
                    if cut < 0:
                        return off
                    data = data[:cut + 1]
                    fd = os.open(DST, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o666)
                    try:
                        os.write(fd, data)
                    finally:
                        os.close(fd)
                    off += len(data)
                    f.seek(off)
        except OSError:
            return off


    ino, off = load()
    while True:
        try:
            st = os.stat(SRC)
        except OSError:
            time.sleep(2)
            continue
        if ino is None:
            ino, off = st.st_ino, 0
        if st.st_ino != ino:
            # rotated: the old segment is now SRC.1 (or SRC.2, ...)
            for n in range(1, 6):
                seg = "%s.%d" % (SRC, n)
                try:
                    if os.stat(seg).st_ino == ino:
                        drain(seg, off)
                        break
                except OSError:
                    continue
            ino, off = st.st_ino, 0
        elif st.st_size < off:
            off = 0
        new = drain(SRC, off)
        if new != off or st.st_ino != load()[0]:
            off = new
            save(ino, off)
        time.sleep(1)
  '';

  mkRelay = u: lib.nameValuePair "beacon-relay-${u}" {
    description = "Append the Beacon events of ${u} to the shared log";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "beacon-endpoint-config.service" ];
    restartTriggers = [ relayScript ];
    serviceConfig = {
      User = u;
      # Only this process, not the agent's own processes, may touch the
      # shared log (which also holds the operators' sessions)
      SupplementaryGroups = [ "beacon" ];
      ExecStart = "${relayScript} ${isolatedLogOf u} ${logPath} /var/lib/beacon-relay-${u}/offset";
      StateDirectory = "beacon-relay-${u}";
      StateDirectoryMode = "0700";
      Restart = "always";
      RestartSec = 5;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ logDir ];
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      CapabilityBoundingSet = "";
      UMask = "0002";
    } // loopbackOnly;
  };

  # Approved memory only (no evaluations, candidates or their trace
  # evidence), copied table-wise so a schema change fails closed. A memory
  # is current when superseded_by is NULL or empty, as in
  # cli/beacon/internal/learning/store.go.
  memorySyncScript = u: pkgs.writeShellScript "beacon-memory-sync-${u}" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.sqlite ]}
    src=${memoryDb}
    dst=${homeOf u}/.beacon/endpoint/memory.db
    # nothing approved yet (the store is created empty)
    [ -s "$src" ] || exit 0
    mkdir -p "$(dirname "$dst")"
    tmp="$dst.sync"
    rm -f "$tmp" "$tmp-wal" "$tmp-shm" "$tmp-journal"
    ver=$(sqlite3 -readonly "$src" 'PRAGMA user_version;')
    {
      echo 'BEGIN;'
      sqlite3 -readonly "$src" '.schema memories'
      sqlite3 -readonly "$src" ".mode insert memories" "SELECT * FROM memories WHERE superseded_by IS NULL OR length(superseded_by) = 0;"
      echo "PRAGMA user_version = $ver;"
      echo 'COMMIT;'
    } | sqlite3 "$tmp"
    mv -f "$tmp" "$dst"
    rm -f "$dst-wal" "$dst-shm"
  '';

  mkMemorySync = u: {
    services.${"beacon-memory-sync-${u}"} = {
      description = "Copy approved Beacon memory to ${u}";
      # the setup unit creates ~/.beacon, which this unit needs as a writable path
      after = [ "local-fs.target" "beacon-setup-${u}.service" ];
      wants = [ "beacon-setup-${u}.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = u;
        SupplementaryGroups = [ "beacon" ];
        ExecStart = memorySyncScript u;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ "${homeOf u}/.beacon" stateDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        UMask = "0077";
      } // loopbackOnly;
    };
    timers.${"beacon-memory-sync-${u}"} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.memory.syncInterval;
        RandomizedDelaySec = "1min";
      };
    };
  };

  # ─ CLI wrappers ────────────────────────────────────────────────────
  # The memory store is SQLite in WAL mode shared by several users; members
  # of the group need write access to the files each other creates
  beaconCli = pkgs.writeShellScriptBin "beacon" ''
    umask 0002
    exec ${pkg}/bin/beacon "$@"
  '';

  # The MCP server reads the log and the memory store next to it. Members of
  # the group `beacon` read the shared ones; everyone else (the sandboxed
  # agent user) its own under ~/.beacon.
  mcpWrapper = pkgs.writeShellScriptBin "nestlo-beacon-mcp" ''
    umask 0002
    if ${pkgs.coreutils}/bin/id -nG 2>/dev/null | ${pkgs.coreutils}/bin/tr ' ' '\n' | ${pkgs.gnugrep}/bin/grep -qx beacon \
       && [ -r ${logPath} ]; then
      log=${logPath}
    else
      log="$HOME/.beacon/endpoint/logs/runtime.jsonl"
    fi
    exec ${pkg}/bin/beacon mcp serve --log-path "$log" "$@"
  '';

  helper = pkgs.writeShellScriptBin "nestlo-beacon" ''
    set -u
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.systemd pkgs.curl pkgs.jq pkgs.gnugrep ]}:$PATH
    cmd=''${1:-status}
    shift || true
    case "$cmd" in
      status)
        systemctl is-active beacon-collector.service || true
        curl -fsS http://127.0.0.1:${toString cfg.ports.health}/ && echo || echo "collector health check failed"
        ls -l ${logPath} 2>/dev/null || echo "no runtime log yet"
        ${pkg}/bin/beacon endpoint status --system --log-path ${logPath} || true
        ;;
      log)
        echo ${logPath} ;;
      repair)
        # re-run the per-user setup (all users, or the ones named)
        users=("$@"); [ "''${#users[@]}" -gt 0 ] || users=(${lib.escapeShellArgs allUsers})
        for u in "''${users[@]}"; do
          sudo systemctl restart "beacon-setup-$u.service"
        done
        ;;
      archive)
        ls -lh ${archiveDir} ;;
      *)
        echo "usage: nestlo-beacon status|log|repair [user...]|archive" >&2
        exit 2 ;;
    esac
  '';

  # ─ Beacon Cloud (off) ──────────────────────────────────────────────
  forwarderUnit = {
    description = "Beacon Cloud forwarder (Vector), created by `beacon endpoint connect --system`";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "beacon-collector.service" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${etcDir}/asymptote/vector.toml";
    serviceConfig = {
      ExecStart = "${cfg.cloud.vectorPackage}/bin/vector --config ${etcDir}/asymptote/vector.toml";
      Restart = "always";
      RestartSec = 10;
      User = "beacon";
      StateDirectory = "beacon-forwarder";
      # Vector keeps its checkpoints in vector-data/ beside the config
      ReadWritePaths = [ "${etcDir}/asymptote" "${stateDir}" ];
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
    };
  };
in
{
  options.nestlo.beacon = {
    enable = lib.mkEnableOption "Agent Beacon: session capture, replay and reviewed memory for coding agents (local only)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.agent-beacon;
      defaultText = lib.literalExpression "pkgs.nestlo.agent-beacon";
      description = "The Beacon package: the beacon CLI, beacon-hooks and beacon-otelcol, built from source.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.filter (u: config.users.users ? ${u}) rt.operators;
      defaultText = lib.literalExpression "the nestlo.runtime.operators that exist as users";
      example = [ "alice" ];
      description = ''
        Users whose agents are captured and who may read the shared log and
        the memory store. They join the group `beacon`, and their agent
        configuration is merged with Beacon's hooks and OTLP settings by
        `beacon-setup-<user>.service`. Everyone in the group sees everyone's
        sessions: prompts and commands are in the log.
      '';
    };

    includeAgentUser = lib.mkOption {
      type = lib.types.bool;
      default = rt.enable;
      defaultText = lib.literalExpression "config.nestlo.runtime.enable";
      description = ''
        Capture the sandboxed agent user (nestlo-agent). Its hook events are
        written under its home (the only place the `nestlo spawn` sandbox
        lets it write) and appended to the shared log by
        beacon-relay-nestlo-agent.service; its OTLP export goes to the
        collector directly. The agent user is not in the group `beacon`, so
        it cannot read other users' sessions.
      '';
    };

    isolatedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "openclaw" ];
      description = ''
        Further users run in a sandbox that cannot write /var/lib/beacon
        (handled like the agent user). Their homes must exist.
      '';
    };

    harnesses = lib.mkOption {
      type = lib.types.either (lib.types.enum [ "auto" ]) (lib.types.listOf (lib.types.enum allHarnesses));
      default = "auto";
      example = [ "claude" "codex" "opencode" ];
      description = ''
        Which agents get Beacon's hooks, plugins and OTLP settings.
        `"auto"` (Beacon's own default) configures every supported agent it
        finds for the user, on PATH or by its configuration directory, and
        reports the ones that need manual steps (Copilot CLI, goose, OpenHands:
        see docs/beacon.md). A list configures exactly those, whether or not
        they are installed yet.
      '';
    };

    ports = {
      otlpGrpc = lib.mkOption {
        type = lib.types.port;
        default = 4317;
        description = "Loopback OTLP/gRPC port of the collector (4317 is what Beacon's tooling expects)";
      };
      otlpHttp = lib.mkOption {
        type = lib.types.port;
        default = 4318;
        description = "Loopback OTLP/HTTP port of the collector";
      };
      health = lib.mkOption {
        type = lib.types.port;
        default = 13133;
        description = "Loopback port of the collector's health check";
      };
      metrics = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = 9975;
        description = ''
          Loopback port of the collector's own Prometheus metrics (events
          received and written, memory use). null turns them off. Scraped by
          nestlo.observability when that is enabled.
        '';
      };
    };

    collector = {
      memoryLimitMiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 128;
        description = "memory_limiter limit of the collector";
      };
      includeRuntimeMetrics = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Keep generic process and runtime OTLP metrics (CPU, heap, event loop) in the log; they are low-signal and filtered by default.";
      };
      includeCodexSpans = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Keep every high-volume Codex span instead of only the completed turn (troubleshooting).";
      };
    };

    retention = {
      days = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 90;
        description = ''
          Days to keep compressed archives of rotated log segments
          (/var/lib/beacon/archive/*.jsonl.zst). Beacon itself keeps the live
          log plus five segments of 10 MiB; the archive timer compresses
          segments before they fall off, so this is the real history depth.
          0 keeps them forever. Approved memory is never pruned.
        '';
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "15min";
        description = "How often rotated segments are archived and old archives removed";
      };
    };

    memory = {
      shareWithAgents = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Copy approved memory (only that: no evaluations, candidates or trace
          evidence) from the shared store into the home of every isolated
          user, so `beacon mcp serve` and `beacon memory list` in the agent's
          sandbox recall what the operators approved. One-way: the agent
          cannot change the shared store.
        '';
      };
      syncInterval = lib.mkOption {
        type = lib.types.str;
        default = "10min";
        description = "How often approved memory is copied (systemd time span)";
      };
    };

    evaluator = {
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "http://127.0.0.1:9000/v1/systemone";
        description = ''
          BEACON_JEV_ENDPOINT for `beacon memory evaluations run`, which scores
          traces with TypeSafe's Jev evaluator. Left unset, Beacon's built-in
          default is the hosted service https://api.typesafe.ai: a run sends
          projected trace content there, and only a person running that
          command (without --dry-run) with an API key does. Set this to a
          self-hosted, TypeSafe System One compatible endpoint to keep that
          local. It is not a chat-completions API, so it cannot go through
          the Nestlo model gateway.
        '';
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "BEACON_JEV_MODEL for the evaluator";
      };
    };

    mcp.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        List Beacon's local MCP server in the Nestlo MCP registry
        (`nestlo-tools list`) as `beacon`: command `nestlo-beacon-mcp`, which
        runs `beacon mcp serve` over stdio against the right log for the
        calling user. Tools: search_activity, summarize_activity,
        get_activity_event, list_activity_filters, search_memory, get_memory,
        get_memory_context.
      '';
    };

    skills.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Turn on the beacon skill pack of nestlo.skills (recall, distill and promote memory, create lenses) when that module is enabled.";
    };

    dashboard = {
      enable = lib.mkEnableOption "Beacon's local, read-only dashboard (sessions, timelines, memory) as a service on loopback";
      port = lib.mkOption {
        type = lib.types.port;
        default = 8765;
        description = "Loopback port of the dashboard";
      };
    };

    cloud = {
      enable = lib.mkEnableOption ''
        Beacon Cloud forwarding. OFF by default and the only way anything
        Beacon records leaves the machine: it runs the Vector forwarder that
        `beacon endpoint connect --system` configures, which ships the
        runtime log (prompts, commands, file paths) to beacon.sh. Enabling
        the option does not enrol the machine; an administrator still runs
        `sudo beacon endpoint connect --system` and approves the device in a
        browser
      '';
      vectorPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.vector;
        defaultText = lib.literalExpression "pkgs.vector";
        description = "Vector (0.50 or newer) that runs the forwarder; Beacon's release bundles its own";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (u: config.users.users ? ${u}) (lib.filter (u: u != agentUser && u != "openclaw") allUsers);
        message = "nestlo.beacon: unknown user(s): "
          + lib.concatStringsSep ", " (lib.filter (u: u != agentUser && u != "openclaw" && !(config.users.users ? ${u})) allUsers);
      }
      {
        assertion = !(lib.elem agentUser allUsers) || rt.enable;
        message = "nestlo.beacon: the agent user needs nestlo.runtime.enable (or nestlo.beacon.includeAgentUser = false)";
      }
      {
        assertion = lib.all (u: !(lib.elem u directUsers)) isolatedUsers;
        message = "nestlo.beacon: a user cannot be in both users and isolatedUsers";
      }
      {
        assertion = lib.length (lib.unique ([ cfg.ports.otlpGrpc cfg.ports.otlpHttp cfg.ports.health ]
          ++ lib.optional (cfg.ports.metrics != null) cfg.ports.metrics
          ++ lib.optional cfg.dashboard.enable cfg.dashboard.port))
        == 3 + (if cfg.ports.metrics != null then 1 else 0) + (if cfg.dashboard.enable then 1 else 0);
        message = "nestlo.beacon: the OTLP, health, metrics and dashboard ports must all differ";
      }
    ];

    warnings =
      lib.optional cfg.cloud.enable ''
        nestlo.beacon.cloud.enable is set: once the machine is enrolled
        (`sudo beacon endpoint connect --system`), Beacon forwards the runtime
        log, with prompts, commands and file paths, to Beacon Cloud. Leave the
        option off to keep every session on this machine.
      '';

    # ─ Users and state ────────────────────────────────────────────────
    users.users.beacon = {
      isSystemUser = true;
      group = "beacon";
      home = stateDir;
      description = "Beacon collector";
    };
    users.groups.beacon.members = directUsers;

    systemd.tmpfiles.rules = [
      # setgid: files hooks create inherit the group, so the collector can
      # rotate them and members can read each other's
      "d ${stateDir} 2770 beacon beacon -"
      "d ${logDir} 2770 beacon beacon -"
      "d ${stateDir}/spool 2770 beacon beacon -"
      "d ${archiveDir} 0750 beacon beacon -"
      # SQLite creates a database 0644 whatever the umask, so a second
      # operator could not write the shared memory store; created (and kept)
      # group-writable, and its -wal/-shm follow the mode
      "f ${memoryDb} 0660 beacon beacon -"
    ];

    environment.etc."beacon/endpoint/otelcol.yaml".source = otelcolYaml;

    environment.systemPackages = [ (lib.hiPrio beaconCli) pkg mcpWrapper helper ];

    environment.variables = lib.mkMerge [
      # The one place Beacon's own default would send traces off the machine
      (lib.mkIf (cfg.evaluator.endpoint != null) { BEACON_JEV_ENDPOINT = cfg.evaluator.endpoint; })
      (lib.mkIf (cfg.evaluator.model != null) { BEACON_JEV_MODEL = cfg.evaluator.model; })
      (lib.mkIf cfg.cloud.enable { BEACON_VECTOR_BIN = "${cfg.cloud.vectorPackage}/bin/vector"; })
    ];

    # ─ Services ───────────────────────────────────────────────────────
    systemd.services = lib.mkMerge [
      {
        beacon-endpoint-config = {
          description = "Write the system endpoint configuration Beacon reads";
          wantedBy = [ "multi-user.target" ];
          before = [ "beacon-collector.service" ];
          after = [ "local-fs.target" ];
          restartTriggers = [ endpointConfig ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = configScript;
          };
        };

        beacon-collector = {
          description = "Beacon collector (local OTLP endpoint for agent telemetry)";
          wantedBy = [ "multi-user.target" ];
          after = [ "beacon-endpoint-config.service" "local-fs.target" ];
          requires = [ "beacon-endpoint-config.service" ];
          serviceConfig = hardening // loopbackOnly // {
            User = "beacon";
            Group = "beacon";
            ExecStart = "${pkg}/bin/beacon-otelcol --config ${etcDir}/otelcol.yaml";
            Restart = "always";
            RestartSec = 3;
            ReadWritePaths = [ stateDir ];
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
            MemoryMax = "${toString (cfg.collector.memoryLimitMiB * 3)}M";
          };
          restartTriggers = [ otelcolYaml ];
        };

        beacon-archive = {
          description = "Compress rotated Beacon log segments and prune old archives";
          after = [ "local-fs.target" ];
          serviceConfig = hardening // loopbackOnly // {
            Type = "oneshot";
            User = "beacon";
            Group = "beacon";
            ExecStart = archiveScript;
            # zstd copies the source's owner to its output (fchown), which
            # ~@privileged would answer with SIGSYS
            SystemCallFilter = [ "@system-service" "~@privileged" "@chown" ];
            ReadWritePaths = [ stateDir ];
          };
        };
      }

      (lib.listToAttrs (map mkSetup allUsers))
      (lib.listToAttrs (map mkRelay isolatedUsers))
      (lib.mkIf cfg.memory.shareWithAgents (lib.foldl' (acc: u: acc // (mkMemorySync u).services) { } isolatedUsers))

      (lib.mkIf cfg.dashboard.enable {
        beacon-dashboard = {
          description = "Beacon local dashboard";
          wantedBy = [ "multi-user.target" ];
          after = [ "beacon-endpoint-config.service" ];
          serviceConfig = hardening // loopbackOnly // {
            User = "beacon";
            Group = "beacon";
            ExecStart = "${pkg}/bin/beacon endpoint dashboard --system --log-path ${logPath} --addr 127.0.0.1:${toString cfg.dashboard.port}";
            Restart = "on-failure";
            RestartSec = 5;
            ReadWritePaths = [ stateDir ];
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          };
        };
      })

      (lib.mkIf cfg.cloud.enable { beacon-asymptote-forwarder = forwarderUnit; })
    ];

    systemd.timers = lib.mkMerge [
      {
        beacon-archive = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "5min";
            OnUnitActiveSec = cfg.retention.interval;
            RandomizedDelaySec = "1min";
          };
        };
      }
      (lib.mkIf cfg.memory.shareWithAgents (lib.foldl' (acc: u: acc // (mkMemorySync u).timers) { } isolatedUsers))
    ];

    # ─ Knowledge back to agents ───────────────────────────────────────
    nestlo.mcp-registry.extraToolServers = lib.mkIf cfg.mcp.enable {
      beacon = {
        description = "Beacon: search agent activity across harnesses and recall reviewed project memory (read-only, local)";
        command = "${mcpWrapper}/bin/nestlo-beacon-mcp";
      };
    };

    nestlo.skills.packs.beacon.enable = lib.mkIf cfg.skills.enable (lib.mkDefault true);

    # ─ Observability ──────────────────────────────────────────────────
    services.prometheus.scrapeConfigs = lib.mkIf (cfg.ports.metrics != null && obs.enable) [{
      job_name = "beacon-collector";
      static_configs = [{ targets = [ "127.0.0.1:${toString cfg.ports.metrics}" ]; }];
    }];
  };
}
