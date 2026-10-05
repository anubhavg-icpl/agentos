# Nestlo OpenBao module: the secrets backend for agents
#
# OpenBao (https://openbao.org, MPL-2.0, the community fork of Vault) holds
# the secrets agents need and hands each agent only its own, by identity:
#
#   - nixpkgs' services.openbao (hardened DynamicUser unit) with file
#     storage, one loopback TLS listener (certificate from a CA generated on
#     the first boot), no UI
#   - `nestlo-openbao-setup`: initialises with one key share, unseals and
#     (optionally) auto-unseals on every boot from a root-only file, mounts a
#     KV v2 engine for agent secrets, enables a file audit device, and keeps
#     the configuration declared in Nix in place. This stores the unseal key
#     on the same machine as the data: read "Security trade-off" in
#     docs/openbao.md before using it for anything but a single trusted host.
#   - with nestlo.agentIdentity: a JWT auth method that trusts SPIRE's
#     JWT-SVID signing keys (refreshed by a timer). Each agent identity has a
#     role bound to its SPIFFE ID and a policy that opens
#     nestlo/agents/<agent>/* and nestlo/shared/*, so an agent logs in with
#     its SVID and reads only its own secrets: `nestlo-openbao-get`.
#   - optionally `nestlo-openbao-sync`: renders /run/secrets/<NAME> (the
#     contract of nestlo.secrets-manager) from KV paths
#   - OpenBao's Prometheus metrics in Nestlo observability
#
# See docs/openbao.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.openbao;
  idc = config.nestlo.agentIdentity;
  sm = config.nestlo.secrets-manager;

  stateDir = "/var/lib/nestlo-openbao";
  pkiDir = "${stateDir}/pki";
  pubDir = "${stateDir}/pub";
  initDir = "${stateDir}/init";
  rootTokenFile = "${initDir}/root-token";
  syncTokenFile = "${initDir}/sync-token";
  jwksTokenFile = "${initDir}/jwks-token";
  addr = "https://${cfg.address}:${toString cfg.port}";
  caFile = "${pubDir}/ca.pem";
  bao = "${cfg.package}/bin/bao";
  jwtMount = cfg.jwtAuth.mountPath;
  svid = "${idc.svidTool}/bin/nestlo-svid";

  # Common client environment for the scripts
  # HOME: the CLI reads its token helper file (~/.bao-token); the units run
  # with ProtectHome, where /root is unreadable and every command fails
  clientEnv = ''
    export BAO_ADDR=${addr}
    export BAO_CACERT=${caFile}
    export HOME=/var/empty
  '';

  agentPolicy = name: a: ''
    # Nestlo: agent ${name} (generated; edit nestlo.openbao.agents.${name}.extraPolicy instead)
    path "${cfg.kvMount}/data/agents/${name}/*"     { capabilities = ["read"] }
    path "${cfg.kvMount}/metadata/agents/${name}/*" { capabilities = ["read", "list"] }
    path "${cfg.kvMount}/data/shared/*"             { capabilities = ["read"] }
    path "${cfg.kvMount}/metadata/shared/*"         { capabilities = ["read", "list"] }
    ${a.extraPolicy}
  '';

  agentFiles = lib.mapAttrs (name: a: pkgs.writeText "nestlo-openbao-policy-${name}.hcl" (agentPolicy name a)) cfg.agents;

  jwksPolicy = pkgs.writeText "nestlo-openbao-policy-jwks.hcl" ''
    path "auth/${jwtMount}/config" { capabilities = ["read", "update"] }
  '';

  syncPolicy = pkgs.writeText "nestlo-openbao-policy-sync.hcl" ''
    path "${cfg.kvMount}/data/secrets-manager/*" { capabilities = ["read"] }
  '';

  # ── certificates ──────────────────────────────────────────────────────
  pkiScript = pkgs.writeShellApplication {
    name = "nestlo-openbao-pki";
    runtimeInputs = [ pkgs.openssl pkgs.coreutils ];
    text = ''
      umask 077
      mkdir -p ${pkiDir} ${pubDir}
      cd ${pkiDir}
      if [ ! -s ca.key ] || [ ! -s ca.pem ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out ca.key
        openssl req -new -x509 -key ca.key -sha256 -days 3650 -subj "/O=Nestlo/CN=Nestlo OpenBao CA" \
          -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" -out ca.pem
      fi
      if [ ! -s tls.crt ] || [ ! -s tls.key ] \
         || ! openssl x509 -in tls.crt -noout -checkend $((30 * 86400)) >/dev/null \
         || [ "$(cat tls.sans 2>/dev/null || true)" != ${lib.escapeShellArg sans} ]; then
        openssl ecparam -name prime256v1 -genkey -noout -out tls.key
        openssl req -new -key tls.key -subj "/O=Nestlo/CN=openbao" -out tls.csr
        printf 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=%s\n' \
          ${lib.escapeShellArg sans} > tls.ext
        openssl x509 -req -in tls.csr -CA ca.pem -CAkey ca.key -CAcreateserial -sha256 -days 365 \
          -extfile tls.ext -out tls.crt
        printf '%s' ${lib.escapeShellArg sans} > tls.sans
        rm -f tls.csr tls.ext ca.srl
      fi
      # Clients (agents, Prometheus) verify the listener against this public CA
      install -m 0644 ca.pem ${caFile}
    '';
  };
  sans = lib.concatStringsSep "," ([ "DNS:localhost" "IP:127.0.0.1" ] ++ cfg.extraSans);

  # ── JWT auth: SPIRE's JWT signing keys ────────────────────────────────
  jwksScript = pkgs.writeShellApplication {
    name = "nestlo-openbao-jwks";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      ${clientEnv}
      # The setup unit passes the root token; the timer uses the narrow token
      # that setup creates (it survives keepRootToken = false)
      if [ -z "''${BAO_TOKEN:-}" ]; then
        BAO_TOKEN=$(cat ${jwksTokenFile})
        export BAO_TOKEN
        ${bao} token renew >/dev/null || true
      fi
      # The public JWT authorities of the SPIRE trust bundle, as PEM keys
      keys=$(${svid} jwks-pem)
      if [ "$(jq length <<<"$keys")" = 0 ]; then
        echo "the SPIRE bundle has no JWT signing keys" >&2
        exit 1
      fi
      jq -n --argjson k "$keys" '{jwt_validation_pubkeys: $k}' | ${bao} write auth/${jwtMount}/config - >/dev/null
      echo "auth/${jwtMount}: $(jq length <<<"$keys") signing keys"
    '';
  };

  # ── initialise, unseal, configure ─────────────────────────────────────
  setupScript = pkgs.writeShellApplication {
    name = "nestlo-openbao-setup";
    runtimeInputs = [ pkgs.jq pkgs.coreutils pkgs.curl ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      ${clientEnv}
      umask 077
      mkdir -p ${initDir}

      # Wait for the listener (exit code 1 = cannot connect; 0 and 2 = unsealed and sealed/uninitialised)
      ready=
      for _ in $(seq 1 60); do
        rc=0
        status=$(${bao} status -format=json 2>/tmp/bao-status.err) || rc=$?
        if [ "$rc" != 1 ]; then ready=1; break; fi
        sleep 1
      done
      [ -n "$ready" ] || { echo "OpenBao does not answer on ${addr}:" >&2; cat /tmp/bao-status.err >&2; exit 1; }

      if [ "$(jq -r .initialized <<<"$status")" != true ]; then
        echo "initialising OpenBao (1 key share)"
        ${bao} operator init -key-shares=1 -key-threshold=1 -format=json > ${initDir}/init.json
        jq -r '.unseal_keys_b64[0]' ${initDir}/init.json > ${cfg.unsealKeyFile}
        jq -r '.root_token' ${initDir}/init.json > ${rootTokenFile}
        rm -f ${initDir}/init.json
        status=$(${bao} status -format=json || true)
      fi

      if [ "$(jq -r .sealed <<<"$status")" = true ]; then
        ${if cfg.autoUnseal then ''
          [ -s ${cfg.unsealKeyFile} ] || { echo "sealed, and no unseal key at ${cfg.unsealKeyFile}" >&2; exit 1; }
          # via the API, not `bao operator unseal KEY`: the key must not show up in a process list
          jq -n --rawfile k ${cfg.unsealKeyFile} '{key: ($k | rtrimstr("\n"))}' \
            | curl -sSf --cacert ${caFile} -X PUT -d @- ${addr}/v1/sys/unseal >/dev/null
          echo "unsealed"
        '' else ''
          echo "OpenBao is sealed and nestlo.openbao.autoUnseal is off: run 'nestlo-bao operator unseal'"
          exit 0
        ''}
      fi

      if [ ! -s ${rootTokenFile} ]; then
        echo "no root token at ${rootTokenFile} (keepRootToken = false): nothing to configure" >&2
        exit 0
      fi
      BAO_TOKEN=$(cat ${rootTokenFile})
      export BAO_TOKEN

      # KV v2 for agent secrets
      if ! ${bao} secrets list -format=json | jq -e '."${cfg.kvMount}/"' >/dev/null; then
        ${bao} secrets enable -path=${cfg.kvMount} -version=2 kv >/dev/null
      fi

      ${lib.optionalString cfg.jwtAuth.enable ''
        # Agents authenticate with their SPIFFE JWT-SVID
        if ! ${bao} auth list -format=json | jq -e '."${jwtMount}/"' >/dev/null; then
          ${bao} auth enable -path=${jwtMount} jwt >/dev/null
        fi
        ${jwksScript}/bin/nestlo-openbao-jwks
        ${bao} policy write nestlo-jwks-refresh ${jwksPolicy} >/dev/null
        if [ ! -s ${jwksTokenFile} ] || ! BAO_TOKEN=$(cat ${jwksTokenFile}) ${bao} token lookup >/dev/null 2>&1; then
          ${bao} token create -orphan -policy=nestlo-jwks-refresh -period=768h -display-name=nestlo-jwks-refresh \
            -field=token > ${jwksTokenFile}
        fi

        declared=${lib.escapeShellArg (builtins.toJSON (map (n: "agent-${n}") (lib.attrNames cfg.agents)))}
        ${lib.concatStrings (lib.mapAttrsToList (name: a: ''
          ${bao} policy write nestlo-agent-${name} ${agentFiles.${name}} >/dev/null
          jq -n --arg sub ${lib.escapeShellArg a.spiffeId} --arg pol nestlo-agent-${name} \
                --arg aud ${lib.escapeShellArg cfg.jwtAuth.audience} --arg ttl ${a.tokenTtl} \
            '{role_type: "jwt", user_claim: "sub", bound_subject: $sub, bound_audiences: [$aud],
              token_policies: [$pol], token_ttl: $ttl, token_max_ttl: $ttl, token_type: "service"}' \
            | ${bao} write auth/${jwtMount}/role/agent-${name} - >/dev/null
        '') cfg.agents)}

        # Roles of agents that are no longer declared
        for role in $(${bao} list -format=json auth/${jwtMount}/role 2>/dev/null | jq -r '.[]?'); do
          if ! jq -e --arg r "$role" 'index($r)' <<<"$declared" >/dev/null; then
            ${bao} delete auth/${jwtMount}/role/"$role" >/dev/null
            echo "removed role $role"
          fi
        done
      ''}

      ${lib.optionalString cfg.secretsManager.enable ''
        ${bao} policy write nestlo-secrets-sync ${syncPolicy} >/dev/null
        if [ ! -s ${syncTokenFile} ] || ! BAO_TOKEN=$(cat ${syncTokenFile}) ${bao} token lookup >/dev/null 2>&1; then
          ${bao} token create -orphan -policy=nestlo-secrets-sync -period=768h -display-name=nestlo-secrets-sync \
            -field=token > ${syncTokenFile}
        fi
      ''}

      ${lib.optionalString (!cfg.keepRootToken) ''
        # Drop the root token: later changes need `bao operator generate-root`
        ${bao} token revoke -self >/dev/null
        rm -f ${rootTokenFile}
        echo "root token revoked"
      ''}
      echo "OpenBao ready at ${addr}"
    '';
  };

  syncScript = pkgs.writeShellApplication {
    name = "nestlo-openbao-sync";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.getent ];
    # the secret list is rendered from Nix and may hold a single name
    excludeShellChecks = [ "SC2043" ];
    text = ''
      ${clientEnv}
      BAO_TOKEN=$(cat ${syncTokenFile})
      export BAO_TOKEN
      ${bao} token renew >/dev/null || true
      group=nestlo
      getent group nestlo >/dev/null || group=root
      install -d -m 0751 /run/secrets
      for name in ${lib.escapeShellArgs sync.secrets}; do
        if value=$(${bao} kv get -mount=${cfg.kvMount} -field=value "secrets-manager/$name" 2>/dev/null); then
          tmp=$(mktemp /run/secrets/.XXXXXX)
          printf '%s' "$value" > "$tmp"
          chgrp "$group" "$tmp"
          chmod 0440 "$tmp"
          mv "$tmp" "/run/secrets/$name"
        fi
      done
    '';
  };
  sync = cfg.secretsManager;

  # ── client helpers ────────────────────────────────────────────────────
  loginCli = pkgs.writeShellApplication {
    name = "nestlo-openbao-login";
    runtimeInputs = [ pkgs.jq pkgs.coreutils ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      ${clientEnv}
      agent=''${1:-''${NESTLO_AGENT_ID:-nestlo-agent}}
      jwt=$(${svid} jwt ${cfg.jwtAuth.audience} --agent "$agent")
      jq -n --arg r "agent-$agent" --arg j "$jwt" '{role: $r, jwt: $j}' \
        | ${bao} write -field=token auth/${jwtMount}/login -
    '';
  };

  getCli = pkgs.writeShellApplication {
    name = "nestlo-openbao-get";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${clientEnv}
      usage() { echo "Usage: nestlo-openbao-get [-a AGENT] PATH [FIELD]   (KV path under ${cfg.kvMount}/, e.g. agents/claude/github, FIELD default 'value')" >&2; exit 1; }
      agent=''${NESTLO_AGENT_ID:-nestlo-agent}
      if [ "''${1:-}" = -a ]; then agent=''${2:?}; shift 2; fi
      [ $# -ge 1 ] || usage
      BAO_TOKEN=$(${loginCli}/bin/nestlo-openbao-login "$agent")
      export BAO_TOKEN
      exec ${bao} kv get -mount=${cfg.kvMount} -field="''${2:-value}" "$1"
    '';
  };

  adminCli = pkgs.writeShellApplication {
    name = "nestlo-bao";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      ${clientEnv}
      if [ -z "''${BAO_TOKEN:-}" ] && [ -r ${rootTokenFile} ]; then
        BAO_TOKEN=$(cat ${rootTokenFile})
        export BAO_TOKEN
      fi
      exec ${bao} "$@"
    '';
  };
in
{
  options.nestlo.openbao = {
    enable = lib.mkEnableOption "OpenBao, the secrets backend for agents (docs/openbao.md)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openbao;
      defaultText = lib.literalExpression "pkgs.openbao";
      description = "OpenBao build (the `bao` binary).";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Address of the listener. Loopback by default; the unseal key and the
        root token sit on this machine, so do not expose the listener
        (set a routable address only together with a firewall rule).
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8200;
      description = "TCP port of the listener (TLS).";
    };

    extraSans = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "DNS:bao.example.org" "IP:10.0.0.5" ];
      description = "Further subjectAltName entries of the listener certificate.";
    };

    kvMount = lib.mkOption {
      type = lib.types.strMatching "[a-z0-9_-]+";
      default = "nestlo";
      description = ''
        Mount path of the KV v2 secrets engine. Layout: `agents/<agent>/*`
        is readable by that agent only, `shared/*` by every agent,
        `secrets-manager/<NAME>` feeds nestlo.openbao.secretsManager.
      '';
    };

    autoUnseal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Unseal on every start with the key in `unsealKeyFile`. This keeps the
        service usable after a reboot but means whoever can read the disk
        (as root) can read every secret: OpenBao's seal then protects only
        against a copy of the data directory without the init directory.
        With false the helper still initialises (the key is written once to
        `unsealKeyFile`; move it off the machine) and leaves OpenBao sealed
        after each restart until an operator runs
        `nestlo-bao operator unseal`; the declared configuration is applied
        on the next start that finds it unsealed (`systemctl restart
        nestlo-openbao-setup`).
      '';
    };

    unsealKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "${initDir}/unseal-key";
      description = ''
        File holding the unseal key (mode 0600, root). Point it to a path on
        a separate, removable or network-provided medium (for example a
        systemd credential on tmpfs filled by your own tooling) to keep the
        key away from the data; the helper writes the key there at init.
      '';
    };

    keepRootToken = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the initial root token in ${initDir}/root-token (root only) so
        the setup unit can re-apply the declared configuration and
        `nestlo-bao` works for the operator. With false the token is revoked
        after the first configuration; changing roles or policies then needs
        `bao operator generate-root` and a restart of the setup unit.
      '';
    };

    audit = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable the file audit device.";
      };
      file = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/nestlo-openbao/audit.log";
        description = ''
          Audit log: one JSON line per request and response, with secret
          values and tokens HMAC-ed. Root-only (mode 0600). Rotated weekly
          (4 kept). It is separate from the Nestlo audit chain (nestlo.audit),
          which only accepts its own event types.
        '';
      };
    };

    jwtAuth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = idc.enable;
        defaultText = lib.literalExpression "config.nestlo.agentIdentity.enable";
        description = "JWT auth method trusting SPIRE's JWT-SVIDs, so agents log in by identity.";
      };
      mountPath = lib.mkOption {
        type = lib.types.strMatching "[a-z0-9_-]+";
        default = "spire";
        description = "Auth mount path (auth/<path>).";
      };
      audience = lib.mkOption {
        type = lib.types.str;
        default = "openbao";
        description = "Audience the JWT-SVID must be requested for.";
      };
      refreshInterval = lib.mkOption {
        type = lib.types.str;
        default = "10min";
        description = "How often the SPIRE JWT signing keys are re-read into OpenBao (they rotate at half of nestlo.agentIdentity.caTtl).";
      };
    };

    agents = lib.mkOption {
      default = lib.genAttrs idc.agentNames (_: { });
      defaultText = lib.literalExpression "one entry per nestlo.agentIdentity agent (including nestlo-agent)";
      description = ''
        Agents that may log in with their SVID. Each gets the role
        `agent-<name>` bound to its SPIFFE ID and the policy
        `nestlo-agent-<name>`.
      '';
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          spiffeId = lib.mkOption {
            type = lib.types.str;
            default = "spiffe://${idc.trustDomain}/agent/${name}";
            defaultText = lib.literalExpression ''"spiffe://<trust domain>/agent/<name>"'';
            description = "SPIFFE ID the role is bound to (the JWT's sub).";
          };
          tokenTtl = lib.mkOption {
            type = lib.types.str;
            default = "15m";
            description = "Lifetime of the OpenBao token issued at login.";
          };
          extraPolicy = lib.mkOption {
            type = lib.types.lines;
            default = "";
            example = ''
              path "nestlo/data/providers/openai" { capabilities = ["read"] }
            '';
            description = "Additional policy HCL for this agent.";
          };
        };
      }));
    };

    secretsManager = {
      enable = lib.mkEnableOption ''
        rendering /run/secrets/<NAME> from OpenBao, the file contract of
        nestlo.secrets-manager, so the agent daemon's existing secret
        injection works with OpenBao as the source. Do not combine with the
        sops backend of nestlo.secrets-manager (both write /run/secrets)'';
      secrets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = sm.secrets;
        defaultText = lib.literalExpression "config.nestlo.secrets-manager.secrets";
        description = "Names to render; the value is the `value` field of KV `secrets-manager/<NAME>`.";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = "How often the files are refreshed (also the rotation delay).";
      };
    };

    observability = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Add OpenBao's Prometheus metrics to nestlo.observability's Prometheus when that is enabled.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.jwtAuth.enable || idc.enable;
        message = "nestlo.openbao.jwtAuth needs nestlo.agentIdentity.enable (SPIRE issues the JWT-SVIDs)";
      }
      {
        assertion = !(cfg.secretsManager.enable && sm.enable && sm.backend == "sops" && sm.sopsInitialized);
        message = "nestlo.openbao.secretsManager and the active sops backend of nestlo.secrets-manager both manage /run/secrets";
      }
      {
        assertion = !cfg.jwtAuth.enable || lib.all (a: lib.hasPrefix "spiffe://${idc.trustDomain}/" a.spiffeId) (lib.attrValues cfg.agents);
        message = "nestlo.openbao.agents.*.spiffeId must be in the trust domain ${idc.trustDomain}";
      }
    ];

    services.openbao = {
      enable = true;
      package = cfg.package;
      settings = {
        ui = false;
        # No CAP_IPC_LOCK in the unit; swap is disabled in the unit instead (MemorySwapMax=0)
        disable_mlock = true;
        api_addr = addr;
        storage.file.path = "/var/lib/openbao";
      } // lib.optionalAttrs cfg.audit.enable {
        # Declarative: OpenBao 2.5+ refuses `bao audit enable` over the API.
        # Every request and response, one JSON line each, secrets HMAC-ed.
        audit.file.nestlo-file = {
          description = "Nestlo audit log";
          options = { file_path = cfg.audit.file; mode = "0600"; };
        };
      } // {
        listener.default = {
          type = "tcp";
          address = "${cfg.address}:${toString cfg.port}";
          tls_cert_file = "/run/credentials/openbao.service/tls.crt";
          tls_key_file = "/run/credentials/openbao.service/tls.key";
          tls_min_version = "tls13";
          # /v1/sys/metrics without a token, for the loopback Prometheus
          telemetry.unauthenticated_metrics_access = true;
        };
        telemetry = {
          disable_hostname = true;
          prometheus_retention_time = "1h";
        };
      };
    };

    systemd.services.openbao = {
      requires = [ "nestlo-openbao-pki.service" ];
      after = [ "nestlo-openbao-pki.service" ];
      serviceConfig = {
        LoadCredential = [ "tls.crt:${pkiDir}/tls.crt" "tls.key:${pkiDir}/tls.key" ];
        LogsDirectory = "nestlo-openbao";
        LogsDirectoryMode = "0700";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0711 root root -"
      "d ${pkiDir} 0700 root root -"
      "d ${pubDir} 0755 root root -"
      "d ${initDir} 0700 root root -"
    ];

    systemd.services.nestlo-openbao-pki = {
      description = "Nestlo OpenBao TLS certificate";
      before = [ "openbao.service" ];
      wantedBy = [ "openbao.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkiScript}/bin/nestlo-openbao-pki";
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.services.nestlo-openbao-setup = {
      description = "Initialise, unseal and configure OpenBao for Nestlo";
      wantedBy = [ "openbao.service" "multi-user.target" ];
      after = [ "openbao.service" ]
        ++ lib.optionals cfg.jwtAuth.enable [ "nestlo-spire-bundle.service" "nestlo-spire-entries.service" ];
      wants = lib.optionals cfg.jwtAuth.enable [ "nestlo-spire-bundle.service" ];
      # A restart of openbao seals it: run again
      partOf = [ "openbao.service" ];
      restartTriggers = [ setupScript ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${setupScript}/bin/nestlo-openbao-setup";
        TimeoutStartSec = 180;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir (builtins.dirOf cfg.unsealKeyFile) ];
        PrivateTmp = true;
        ProtectHome = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        SystemCallFilter = [ "@system-service" "~@privileged" ];
        UMask = "0077";
      };
    };

    # SPIRE rotates its JWT signing keys: keep OpenBao's copy current
    systemd.services.nestlo-openbao-jwks = lib.mkIf cfg.jwtAuth.enable {
      description = "Refresh the SPIRE JWT signing keys in OpenBao";
      after = [ "nestlo-openbao-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${jwksScript}/bin/nestlo-openbao-jwks";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadOnlyPaths = [ stateDir ];
      };
    };
    systemd.timers.nestlo-openbao-jwks = lib.mkIf cfg.jwtAuth.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = cfg.jwtAuth.refreshInterval;
      };
    };

    systemd.services.nestlo-openbao-sync = lib.mkIf cfg.secretsManager.enable {
      description = "Render /run/secrets from OpenBao";
      after = [ "nestlo-openbao-setup.service" ];
      wants = [ "nestlo-openbao-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncScript}/bin/nestlo-openbao-sync";
        ProtectSystem = "strict";
        ReadWritePaths = [ "/run" ];
        ReadOnlyPaths = [ stateDir ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        UMask = "0077";
      };
    };
    systemd.timers.nestlo-openbao-sync = lib.mkIf cfg.secretsManager.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.secretsManager.interval;
      };
    };

    services.logrotate.settings = lib.mkIf cfg.audit.enable { "${cfg.audit.file}" = {
      frequency = "weekly";
      rotate = 4;
      compress = true;
      missingok = true;
      notifempty = true;
      # OpenBao reopens its audit files on SIGHUP (ExecReload)
      postrotate = "systemctl reload openbao.service || true";
    }; };

    services.prometheus.scrapeConfigs = lib.mkIf (cfg.observability && config.nestlo.observability.enable) [{
      job_name = "openbao";
      scheme = "https";
      metrics_path = "/v1/sys/metrics";
      params.format = [ "prometheus" ];
      tls_config.ca_file = caFile;
      static_configs = [{ targets = [ "${cfg.address}:${toString cfg.port}" ]; }];
    }];

    environment.variables = {
      BAO_ADDR = addr;
      BAO_CACERT = caFile;
    };
    environment.systemPackages = [ cfg.package adminCli ]
      ++ lib.optionals cfg.jwtAuth.enable [ loginCli getCli ];
  };
}
