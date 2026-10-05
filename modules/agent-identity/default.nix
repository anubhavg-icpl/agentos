# Nestlo agent identity module (SPIFFE/SPIRE)
#
# SPIRE (https://spiffe.io, Apache-2.0) gives every workload a short-lived,
# automatically rotated, cryptographically verifiable identity (an SVID)
# instead of a static secret. This module runs a single-host SPIRE:
#
#   - spire-server on 127.0.0.1 (SQLite + disk keys in /var/lib), a hardened
#     DynamicUser unit
#   - spire-agent as root (it must look into other users' /proc to attest
#     them), attested to the server by an x509pop node certificate generated
#     on the first boot from a throw-away CA whose key is then deleted
#   - the Workload API socket /run/nestlo-spire/agent/api.sock for agents
#     (access is by attestation, not by file permissions)
#   - registration entries rendered from Nix: the nestlo-agent user, one
#     identity per declared agent (user + the transient unit `nestlo spawn`
#     creates), Nestlo's own services, and any extra workloads
#   - `nestlo-svid` (fetch / verify JWT-SVIDs) and `nestlo-identity`
#     (register spawned agents at runtime)
#   - the trust bundle (public JWKS) refreshed to a world-readable file, which
#     the model gateway or OpenBao (nestlo.openbao) uses to verify JWT-SVIDs
#
# See docs/agent-identity.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.agentIdentity;
  td = cfg.trustDomain;

  stateDir = "/var/lib/nestlo-spire";
  pkiDir = "${stateDir}/pki";
  pubDir = "${stateDir}/pub";
  serverState = "/var/lib/nestlo-spire-server";
  agentState = "${stateDir}/agent";
  serverSock = "/run/nestlo-spire/server/api.sock";
  bootstrapBundle = "${stateDir}/bootstrap-bundle.pem";
  nodeCn = "nestlo-host";
  # x509pop agent_path_template below: spiffe://<td>/spire/agent/x509pop/<CN>
  nodeId = "spiffe://${td}/spire/agent/x509pop/${nodeCn}";

  spire = cfg.package;
  spireServer = "${spire.server or spire}/bin/spire-server";
  spireAgent = "${spire.agent or spire}/bin/spire-agent";

  # ── registration entries ──────────────────────────────────────────────
  agentUser = "nestlo-agent"; # modules/runtime: the user agents run as
  selectorOf = s:
    let parts = lib.splitString ":" s;
    in { type = lib.head parts; value = lib.concatStringsSep ":" (lib.tail parts); };

  mkEntry = { path, selectors, x509Ttl, jwtTtl, dnsNames ? [ ] }: {
    parent_id = nodeId;
    spiffe_id = "spiffe://${td}/${path}";
    selectors = map selectorOf selectors;
    x509_svid_ttl = if x509Ttl == null then cfg.x509SvidTtl else x509Ttl;
    jwt_svid_ttl = if jwtTtl == null then cfg.jwtSvidTtl else jwtTtl;
    # Marks the entries this module owns ("nestlo:" prefix; `nestlo-identity
    # register` uses "nestlo-dyn:", which the reconcile step leaves alone).
    # Unique per entry: a workload that matches several entries (the agent
    # user and a per-agent unit) gets only one SVID per hint from SPIRE.
    hint = "nestlo:${path}";
  } // lib.optionalAttrs (dnsNames != [ ]) { dns_names = dnsNames; };

  # The nestlo-agent user as a whole, whatever unit it runs in
  allAgents = cfg.agents // lib.optionalAttrs cfg.genericAgent {
    nestlo-agent = { user = agentUser; unit = null; selectors = [ ]; x509Ttl = null; jwtTtl = null; };
  };

  agentEntries = lib.mapAttrsToList
    (name: a: mkEntry {
      path = "agent/${name}";
      selectors = [ "unix:user:${a.user}" ]
        ++ lib.optional (a.unit != null) "systemd:id:${a.unit}" ++ a.selectors;
      inherit (a) x509Ttl jwtTtl;
    })
    allAgents;

  workloadEntries = lib.mapAttrsToList
    (name: w: mkEntry {
      path = w.path;
      inherit (w) selectors x509Ttl jwtTtl dnsNames;
    })
    cfg.workloads;

  # Nestlo's own services: the unit is the selector (several of them run as
  # the same `nestlo` user, so the uid alone cannot tell them apart).
  nestloServices = lib.optionals cfg.serviceIdentities (
    lib.optional config.nestlo.networking.enable { name = "gateway"; unit = "nestlo-model-gateway.service"; }
    ++ lib.optional config.nestlo.runtime.enable { name = "daemon"; unit = "nestlo-daemon.service"; }
    ++ lib.optional config.nestlo.orchestration.enable { name = "orchestrator"; unit = "nestlo-orchestrator.service"; }
    ++ lib.optional config.nestlo.audit.enable { name = "audit"; unit = "nestlo-audit.service"; }
    ++ lib.optionals config.nestlo.cloud.enable [
      { name = "cloud"; unit = "nestlo-cloud.service"; }
      { name = "cloud-vmd"; unit = "nestlo-cloud-vmd.service"; }
    ]
  );
  serviceEntries = map
    (s: mkEntry {
      path = "service/${s.name}";
      selectors = [ "systemd:id:${s.unit}" ];
      x509Ttl = null;
      jwtTtl = null;
    })
    nestloServices;

  entries = agentEntries ++ workloadEntries ++ serviceEntries;
  entriesFile = pkgs.writeText "nestlo-spire-entries.json" (builtins.toJSON { inherit entries; });

  # ── SPIRE configuration (HCL) ─────────────────────────────────────────
  serverConf = pkgs.writeText "nestlo-spire-server.conf" ''
    server {
      bind_address = "127.0.0.1"
      bind_port = ${toString cfg.serverPort}
      socket_path = "${serverSock}"
      trust_domain = "${td}"
      data_dir = "${serverState}"
      log_level = "${cfg.logLevel}"
      ca_ttl = "${cfg.caTtl}"
      default_x509_svid_ttl = "${toString cfg.x509SvidTtl}s"
      default_jwt_svid_ttl = "${toString cfg.jwtSvidTtl}s"
      jwt_issuer = "${cfg.jwtIssuer}"
      ca_subject {
        country = ["XX"]
        organization = ["Nestlo"]
        common_name = "Nestlo SPIRE ${td}"
      }
    }
    plugins {
      DataStore "sql" {
        plugin_data {
          database_type = "sqlite3"
          connection_string = "${serverState}/datastore.sqlite3"
        }
      }
      KeyManager "disk" {
        plugin_data {
          keys_path = "${serverState}/keys.json"
        }
      }
      NodeAttestor "x509pop" {
        plugin_data {
          # The node CA is handed to the unit as a credential
          ca_bundle_path = "$CREDENTIALS_DIRECTORY/node-ca.pem"
          agent_path_template = "/{{ .PluginName }}/{{ .Subject.CommonName }}"
        }
      }
    }
  '';

  agentConf = pkgs.writeText "nestlo-spire-agent.conf" ''
    agent {
      server_address = "127.0.0.1"
      server_port = ${toString cfg.serverPort}
      trust_domain = "${td}"
      trust_bundle_path = "${bootstrapBundle}"
      data_dir = "${agentState}"
      socket_path = "${cfg.workloadSocket}"
      log_level = "${cfg.logLevel}"
    }
    plugins {
      KeyManager "disk" {
        plugin_data {
          directory = "${agentState}"
        }
      }
      NodeAttestor "x509pop" {
        plugin_data {
          private_key_path = "${pkiDir}/node.key"
          certificate_path = "${pkiDir}/node.pem"
        }
      }
      # unix:uid/user/group and systemd:id selectors
      WorkloadAttestor "unix" {
        plugin_data {}
      }
      WorkloadAttestor "systemd" {
        plugin_data {}
      }
    }
  '';

  hardening = {
    NoNewPrivileges = true;
    PrivateTmp = true;
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
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    UMask = "0077";
  };

  # ── scripts ───────────────────────────────────────────────────────────
  pkiScript = pkgs.writeShellApplication {
    name = "nestlo-spire-pki";
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    text = ''
      umask 077
      mkdir -p ${pkiDir}
      cd ${pkiDir}
      # One node (this host) attests with a certificate from a CA that exists
      # only for the moment of signing: the CA key is deleted, so nothing on
      # disk can mint another node identity.
      if [ -s node.pem ] && [ -s node.key ] && [ -s node-ca.pem ] \
         && openssl x509 -in node.pem -noout -checkend $((30 * 86400)) >/dev/null; then
        exit 0
      fi
      openssl ecparam -name prime256v1 -genkey -noout -out ca.key
      openssl req -new -x509 -key ca.key -sha256 -days 3650 -subj "/O=Nestlo/CN=Nestlo SPIRE node CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out node-ca.pem
      openssl ecparam -name prime256v1 -genkey -noout -out node.key
      openssl req -new -key node.key -subj "/O=Nestlo/CN=${nodeCn}" -out node.csr
      printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n' > node.ext
      openssl x509 -req -in node.csr -CA node-ca.pem -CAkey ca.key -CAcreateserial -sha256 -days 365 \
        -extfile node.ext -out node.pem
      rm -f ca.key node.csr node.ext node-ca.srl
    '';
  };

  bundleScript = pkgs.writeShellApplication {
    name = "nestlo-spire-bundle";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      for _ in $(seq 1 60); do
        ${spireServer} healthcheck -socketPath ${serverSock} >/dev/null 2>&1 && break
        sleep 1
      done
      umask 022
      mkdir -p ${pubDir}
      # PEM: the agent's bootstrap trust. JWKS (X.509 and JWT authorities):
      # what verifiers of JWT-SVIDs read.
      ${spireServer} bundle show -socketPath ${serverSock} > ${bootstrapBundle}.new
      mv ${bootstrapBundle}.new ${bootstrapBundle}
      ${spireServer} bundle show -socketPath ${serverSock} -format spiffe > ${pubDir}/bundle.json.new
      mv ${pubDir}/bundle.json.new ${cfg.bundleFile}
    '';
  };

  entriesScript = pkgs.writeShellApplication {
    name = "nestlo-spire-entries";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = ''
      s=(-socketPath ${serverSock})
      stamp=${stateDir}/entries.sha256
      sum=$(sha256sum ${entriesFile} | cut -d' ' -f1)
      have=$(${spireServer} entry show "''${s[@]}" -output json | jq '[.entries[]? | select((.hint // "") | startswith("nestlo:"))] | length')
      want=$(jq '.entries | length' ${entriesFile})
      if [ "$(cat "$stamp" 2>/dev/null || true)" = "$sum" ] && [ "$have" = "$want" ]; then
        echo "registration entries up to date ($want)"
        exit 0
      fi
      for id in $(${spireServer} entry show "''${s[@]}" -output json | jq -r '.entries[]? | select((.hint // "") | startswith("nestlo:")) | .id'); do
        ${spireServer} entry delete "''${s[@]}" -entryID "$id" >/dev/null
      done
      if [ "$want" != 0 ]; then
          ${spireServer} entry create "''${s[@]}" -data ${entriesFile} >/dev/null
      fi
      echo "$sum" > "$stamp"
      echo "registered $want entries"
    '';
  };

  identityCli = pkgs.writeShellApplication {
    name = "nestlo-identity";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = ''
      s=(-socketPath ${serverSock})
      usage() {
        cat <<'U'
      Usage: nestlo-identity <command>      (root; talks to the SPIRE server socket)
        status                       server and agent health, trust domain
        list                         registration entries
        register ID [UNIT] [USER]    identity spiffe://${td}/agent/ID for the workload running as
                                     USER (default ${agentUser}) in UNIT (default nestlo-agent-ID.service)
        unregister ID                remove a runtime-registered identity
        jwt-bundle                   print the trust bundle (JWKS)
      U
      }
      cmd=''${1:-status}; shift || true
      case "$cmd" in
        status)
          ${spireServer} healthcheck "''${s[@]}" -verbose
          ${spireAgent} healthcheck -socketPath ${cfg.workloadSocket} -verbose
          echo "trust domain: ${td}"
          ;;
        list) ${spireServer} entry show "''${s[@]}" ;;
        register)
          id=''${1:?agent id}; unit=''${2:-nestlo-agent-$id.service}; user=''${3:-${agentUser}}
          ${spireServer} entry create "''${s[@]}" -parentID ${nodeId} -spiffeID "spiffe://${td}/agent/$id" \
            -selector "unix:user:$user" -selector "systemd:id:$unit" \
            -x509SVIDTTL ${toString cfg.x509SvidTtl} -jwtSVIDTTL ${toString cfg.jwtSvidTtl} -hint "nestlo-dyn:agent/$id"
          ;;
        unregister)
          id=''${1:?agent id}
          for e in $(${spireServer} entry show "''${s[@]}" -spiffeID "spiffe://${td}/agent/$id" -output json \
                     | jq -r '.entries[]? | select((.hint // "") | startswith("nestlo-dyn:")) | .id'); do
            ${spireServer} entry delete "''${s[@]}" -entryID "$e"
          done
          ;;
        jwt-bundle) cat ${cfg.bundleFile} ;;
        *) usage; exit 1 ;;
      esac
    '';
  };

  svidPython = pkgs.python3.withPackages (ps: [ ps.pyjwt ps.cryptography ]);
  svidTool = pkgs.writeShellScriptBin "nestlo-svid" ''
    export NESTLO_SPIRE_AGENT=${spireAgent}
    exec ${svidPython}/bin/python3 ${./svid.py} "$@"
  '';

  identityConfig = {
    trust_domain = td;
    audience = cfg.gatewayAudience;
    workload_socket = cfg.workloadSocket;
    bundle_file = cfg.bundleFile;
    spire_agent = spireAgent;
    agent_spiffe_prefix = "spiffe://${td}/agent/";
  };

  validAgentId = n: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]{0,63}" n != null;
in
{
  imports = [ ./cedar.nix ];

  options.nestlo.agentIdentity = {
    enable = lib.mkEnableOption "workload identity for agents and Nestlo services with SPIFFE/SPIRE (docs/agent-identity.md)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.spire;
      defaultText = lib.literalExpression "pkgs.spire";
      description = "SPIRE build (provides spire-server and spire-agent).";
    };

    trustDomain = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9]([a-z0-9._-]*[a-z0-9])?";
      default = "nestlo.local";
      description = ''
        SPIFFE trust domain: the second component of every SPIFFE ID
        (spiffe://<trust domain>/agent/claude). Pick a name you own if you
        plan to federate with other SPIRE deployments; it is not resolved
        through DNS. Changing it later invalidates every issued SVID and the
        server database (delete /var/lib/nestlo-spire* to start over).
      '';
    };

    jwtIssuer = lib.mkOption {
      type = lib.types.str;
      default = "https://spire.${td}";
      defaultText = lib.literalExpression ''"https://spire.''${trustDomain}"'';
      description = "`iss` claim of the JWT-SVIDs (informational; verifiers pin the key, not the issuer).";
    };

    x509SvidTtl = lib.mkOption {
      type = lib.types.ints.between 60 86400;
      default = 3600;
      description = "Default lifetime of X.509-SVIDs in seconds (SPIRE rotates them at half-life).";
    };

    jwtSvidTtl = lib.mkOption {
      type = lib.types.ints.between 30 3600;
      default = 300;
      description = ''
        Default lifetime of JWT-SVIDs in seconds. They are bearer tokens: keep
        this short, since there is no revocation other than expiry.
      '';
    };

    caTtl = lib.mkOption {
      type = lib.types.str;
      default = "24h";
      description = "Lifetime of the SPIRE CA and JWT signing keys (rotated automatically at half-life).";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Loopback port of the SPIRE server API (the agent connects to it; nothing else should).";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "DEBUG" "INFO" "WARN" "ERROR" ];
      default = "INFO";
      description = "Log level of spire-server and spire-agent.";
    };

    workloadSocket = lib.mkOption {
      type = lib.types.path;
      default = "/run/nestlo-spire/agent/api.sock";
      readOnly = true;
      description = ''
        SPIFFE Workload API socket (set as SPIFFE_ENDPOINT_SOCKET in login
        shells). It is world-connectable on purpose: SPIRE decides what a
        caller gets by attesting its pid (user, unit), not by file mode.
      '';
    };

    bundleFile = lib.mkOption {
      type = lib.types.path;
      default = "${pubDir}/bundle.json";
      readOnly = true;
      description = "Public trust bundle in JWKS form (X.509 and JWT authorities), world-readable, refreshed periodically.";
    };

    bundleRefreshInterval = lib.mkOption {
      type = lib.types.str;
      default = "10min";
      description = "How often the bundle file is rewritten (JWT signing keys rotate at half of caTtl).";
    };

    gatewayAudience = lib.mkOption {
      type = lib.types.str;
      default = "nestlo-gateway";
      description = ''
        Audience a JWT-SVID must carry to be accepted by the Nestlo model
        gateway as an agent credential (see docs/agent-identity.md for the
        gateway patch). Written to /etc/nestlo/agent-identity.json.
      '';
    };

    serviceIdentities = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Register identities for the Nestlo services that are enabled
        (spiffe://<td>/service/{gateway,daemon,orchestrator,audit,cloud,cloud-vmd}),
        selected by their systemd unit.
      '';
    };

    genericAgent = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Register spiffe://<td>/agent/nestlo-agent for any process of the
        nestlo-agent user, whatever unit it runs in. Every agent then has
        some identity; the named `agents` below are more specific
        (user and unit) and are returned in addition to it.
      '';
    };

    agents = lib.mkOption {
      default = { };
      description = ''
        Agent identities, spiffe://<trust domain>/agent/<name>. An agent
        workload matches when it runs as `user` and, if `unit` is set, inside
        that systemd unit. `nestlo spawn` / the task runner start agents with
        systemd-run as the single user nestlo-agent in a unit called
        nestlo-agent-<id>, so a per-agent identity is the pair (user, unit).
        Spawned agents whose ids are not known at build time can be
        registered at runtime with `nestlo-identity register <id>`.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          user = lib.mkOption {
            type = lib.types.str;
            default = agentUser;
            description = "Unix user the workload runs as (selector unix:user).";
          };
          unit = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = "nestlo-agent-${name}.service";
            defaultText = lib.literalExpression ''"nestlo-agent-<name>.service"'';
            description = "systemd unit the workload runs in (selector systemd:id); null matches any unit.";
          };
          selectors = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "unix:group:nestlo-agent" ];
            description = "Extra SPIRE selectors (type:value...) that must also match.";
          };
          x509Ttl = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "X.509-SVID lifetime in seconds (null: x509SvidTtl).";
          };
          jwtTtl = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "JWT-SVID lifetime in seconds (null: jwtSvidTtl).";
          };
        };
      }));
    };

    workloads = lib.mkOption {
      default = { };
      example = lib.literalExpression ''
        {
          backup = {
            selectors = [ "unix:uid:0" "systemd:id:restic-backups-nightly.service" ];
          };
        }
      '';
      description = "Further workloads to give an identity: spiffe://<trust domain>/<path>.";
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          path = lib.mkOption {
            type = lib.types.strMatching "[A-Za-z0-9._/-]+";
            default = "workload/${name}";
            defaultText = lib.literalExpression ''"workload/<name>"'';
            description = "Path of the SPIFFE ID.";
          };
          selectors = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "SPIRE selectors (unix:uid:N, unix:user:U, systemd:id:UNIT, ...); all must match.";
          };
          x509Ttl = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; description = "X.509-SVID lifetime in seconds (null: x509SvidTtl)."; };
          jwtTtl = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; description = "JWT-SVID lifetime in seconds (null: jwtSvidTtl)."; };
          dnsNames = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "DNS SANs for the X.509-SVID."; };
        };
      }));
    };

    agentNames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.attrNames allAgents;
      description = "Names of all agent identities, including the generic one (for nestlo.openbao).";
    };

    svidTool = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = svidTool;
      description = "The nestlo-svid command (used by nestlo.openbao).";
    };

    nodeId = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = nodeId;
      description = "SPIFFE ID of this host's SPIRE agent (the parent of every entry).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all validAgentId (lib.attrNames cfg.agents);
        message = "nestlo.agentIdentity.agents: names must be valid gateway agent ids ([A-Za-z0-9][A-Za-z0-9._-]{0,63})";
      }
      {
        assertion = lib.all (w: w.selectors != [ ]) (lib.attrValues cfg.workloads);
        message = "nestlo.agentIdentity.workloads: every workload needs at least one selector (an entry without selectors would match any process)";
      }
    ];

    environment.systemPackages = [ spire svidTool identityCli ];
    environment.variables.SPIFFE_ENDPOINT_SOCKET = "unix://${cfg.workloadSocket}";
    environment.etc."nestlo/agent-identity.json".text = builtins.toJSON identityConfig;

    systemd.tmpfiles.rules = [
      # Traversable so verifiers can read pub/; everything else inside is 0700
      "d ${stateDir} 0711 root root -"
      "d ${pkiDir} 0700 root root -"
      "d ${pubDir} 0755 root root -"
      "d ${agentState} 0700 root root -"
    ];

    systemd.services.nestlo-spire-pki = {
      description = "Nestlo SPIRE node certificate";
      wantedBy = [ "nestlo-spire-server.service" ];
      before = [ "nestlo-spire-server.service" "nestlo-spire-agent.service" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkiScript}/bin/nestlo-spire-pki";
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
      };
    };

    systemd.services.nestlo-spire-server = {
      description = "Nestlo SPIRE server";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nestlo-spire-pki.service" ];
      after = [ "nestlo-spire-pki.service" "network.target" ];
      restartTriggers = [ serverConf ];
      serviceConfig = hardening // {
        ExecStart = "${spireServer} run -expandEnv -config ${serverConf}";
        Restart = "on-failure";
        RestartSec = 2;
        DynamicUser = true;
        StateDirectory = "nestlo-spire-server";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "nestlo-spire/server";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = false;
        LoadCredential = [ "node-ca.pem:${pkiDir}/node-ca.pem" ];
        CapabilityBoundingSet = "";
        PrivateDevices = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryMax = "512M";
      };
    };

    # Writes the bootstrap bundle and the public JWKS; re-run by a timer
    systemd.services.nestlo-spire-bundle = {
      description = "Publish the Nestlo SPIRE trust bundle";
      requires = [ "nestlo-spire-server.service" ];
      after = [ "nestlo-spire-server.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${bundleScript}/bin/nestlo-spire-bundle";
        ReadWritePaths = [ stateDir ];
        TimeoutStartSec = 120;
      };
    };
    systemd.timers.nestlo-spire-bundle = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnUnitActiveSec = cfg.bundleRefreshInterval;
        OnBootSec = "5min";
      };
    };

    systemd.services.nestlo-spire-agent = {
      description = "Nestlo SPIRE agent (Workload API)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nestlo-spire-bundle.service" "nestlo-spire-pki.service" ];
      after = [ "nestlo-spire-bundle.service" "nestlo-spire-pki.service" "dbus.service" ];
      restartTriggers = [ agentConf ];
      serviceConfig = hardening // {
        ExecStart = "${spireAgent} run -expandEnv -config ${agentConf}";
        Restart = "on-failure";
        RestartSec = 2;
        # Root: attesting a process means reading its /proc entries (exe,
        # cgroup) and asking systemd about its unit over D-Bus. Nothing else.
        User = "root";
        CapabilityBoundingSet = [ "CAP_SYS_PTRACE" "CAP_DAC_READ_SEARCH" ];
        ReadWritePaths = [ agentState ];
        RuntimeDirectory = "nestlo-spire/agent";
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = false;
        # The default umask would make the socket unusable for other users
        UMask = "0022";
        PrivateDevices = true;
        MemoryMax = "256M";
      };
    };

    systemd.services.nestlo-spire-entries = {
      description = "Register Nestlo workload identities with SPIRE";
      wantedBy = [ "multi-user.target" ];
      requires = [ "nestlo-spire-server.service" ];
      after = [ "nestlo-spire-server.service" "nestlo-spire-bundle.service" "nestlo-spire-agent.service" ];
      restartTriggers = [ entriesFile ];
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${entriesScript}/bin/nestlo-spire-entries";
        ReadWritePaths = [ stateDir ];
        TimeoutStartSec = 120;
      };
    };
  };
}
