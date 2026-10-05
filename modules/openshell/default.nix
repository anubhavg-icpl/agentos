# Nestlo OpenShell module
#
# NVIDIA OpenShell (https://github.com/NVIDIA/OpenShell, Apache-2.0) runs AI
# agents in sandboxes: a gateway (control plane), a supervisor per sandbox
# that enforces filesystem (Landlock), syscall (seccomp) and network policy
# (a policy proxy with L7 inspection) and injects provider credentials at the
# proxy, and the `openshell` CLI. This module makes it part of Nestlo:
#
#   - the gateway as a hardened systemd service (dedicated user, state in
#     /var/lib/openshell), on loopback with mutual TLS, driving the podman or
#     docker compute driver Nestlo's runtime already provides
#   - every sandbox model call through the Nestlo model gateway: a provider
#     profile `nestlo-gateway` and a provider instance `nestlo` make the
#     sandbox's proxy swap a credential placeholder for the token of the
#     gateway agent `openshell` (budget, DLP, loop detection and audit trail
#     of nestlo.networking; the real provider keys never enter a sandbox, and
#     neither does the token)
#   - sandbox policies declared in Nix (rendered to OpenShell's policy YAML),
#     optionally applied as the gateway-global policy, plus upstream provider
#     profiles (providers/*.yaml), custom profiles and provider instances
#   - the `openshell` CLI for the operators (and optionally the agent user),
#     pointed at the local gateway with their client certificate
#   - gateway OCSF JSONL log and OTLP export to the Nestlo collector
#
# Sources checked: crates/openshell-server/src/{cli,config_file,defaults,
# certgen}.rs (flags, TOML schema v2, local TLS layout), deploy/deb/
# openshell-gateway.service (unit shape), crates/openshell-policy-schema
# (policy YAML), crates/openshell-providers (profile schema),
# docs/how-it-works/**.
#
# See docs/openshell.md. Nestlo's own policy and audit trail
# (nestlo.policy, nestlo.audit) are separate: OpenShell enforces what runs
# inside its sandboxes, Nestlo audits and budgets the model calls.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.openshell;
  net = config.nestlo.networking;
  rt = config.nestlo.runtime;
  obs = config.nestlo.observability;

  yaml = pkgs.formats.yaml { };
  toml = pkgs.formats.toml { };

  gw = lib.getExe' cfg.package "openshell-gateway";
  cli = lib.getExe' cfg.package "openshell";

  agentUser = "nestlo-agent";
  svcUser = "openshell";
  stateDir = "/var/lib/openshell";
  # generate-certs and the gateway find their files through these
  xdgState = "${stateDir}/state";
  xdgConfig = "${stateDir}/config";
  tlsDir = "${xdgState}/openshell/tls";
  # client bundle the CLI users get (group-readable copy of tlsDir/client)
  clientDir = "${stateDir}/client";
  tokenFile = "${stateDir}/nestlo-gateway-token";
  ocsfFile = "/var/log/openshell/gateway-ocsf.jsonl";
  gatewayName = "openshell"; # the CLI's default gateway name (DEFAULT_GATEWAY_NAME)

  adminSocket = config.nestlo.services.settings.gateway.admin_socket;
  gwPort = toString net.modelGatewayPort;

  endpointHost = if cfg.listen.address == "0.0.0.0" then "127.0.0.1" else cfg.listen.address;
  endpoint = "https://${endpointHost}:${toString cfg.ports.grpc}";
  driverGroup = if cfg.computeDriver == "podman" then "podman" else "docker";
  driverSocket =
    if cfg.computeDriver == "podman" then "/run/podman/podman.sock" else "/var/run/docker.sock";

  # ── policies ──────────────────────────────────────────────────────────
  # The restrictive built-in default (docs/how-it-works/policies/
  # default-policy.mdx): the workdir and /tmp writable, system paths
  # readable, no network.
  upstreamDefault = {
    version = 1;
    filesystem_policy = {
      include_workdir = true;
      read_only = [ "/bin" "/usr" "/lib" "/proc" "/dev/urandom" "/etc" "/var/log" ];
      read_write = [ "/tmp" "/dev/null" ];
    };
    landlock.compatibility = "best_effort";
  };

  allPolicies = lib.optionalAttrs cfg.upstreamDefaultPolicy { restrictive = upstreamDefault; } // cfg.policies;

  # `binaries` take plain paths; the schema wants { path = ...; }
  normalizePolicy = p: p // lib.optionalAttrs (p ? network_policies) {
    network_policies = lib.mapAttrs
      (_: r: r // lib.optionalAttrs (r ? binaries) {
        binaries = map (b: if builtins.isString b then { path = b; } else b) r.binaries;
      })
      p.network_policies;
  };
  policyFile = name: p: yaml.generate "openshell-policy-${name}.yaml" (normalizePolicy p);
  policyFiles = lib.mapAttrs policyFile allPolicies;
  policyPath = name: "/etc/openshell/policies/${name}.yaml";

  # crates/openshell-policy-schema/src/lib.rs: every struct is
  # #[serde(deny_unknown_fields)], so a typo would only surface when a
  # sandbox starts. The field lists below mirror the structs.
  unknownKeys = allowed: attrs: lib.subtractLists allowed (builtins.attrNames attrs);
  schema = {
    top = [ "version" "filesystem_policy" "landlock" "process" "network_policies" "network_middlewares" ];
    filesystem = [ "include_workdir" "read_only" "read_write" ];
    landlock = [ "compatibility" ];
    process = [ "run_as_user" "run_as_group" ];
    rule = [ "name" "endpoints" "binaries" ];
    endpoint = [
      "host" "path" "port" "ports" "protocol" "tls" "enforcement" "access" "rules" "allowed_ips"
      "deny_rules" "allow_encoded_slash" "websocket_credential_rewrite" "request_body_credential_rewrite"
      "allow_uninspected_credentials" "persisted_queries" "graphql_persisted_queries"
      "graphql_max_body_bytes" "credential_signing" "signing_service" "signing_region"
      "credential_binding" "json_rpc" "mcp"
    ];
    middleware = [ "name" "middleware" "order" "config" "on_error" "endpoints" ];
  };

  policyProblems = name: p:
    let
      at = lib.concatStringsSep ".";
      bad = path: allowed: attrs:
        map (k: "${at ([ "policies" name ] ++ path)}: unknown field `${k}`") (unknownKeys allowed attrs);
      sub = key: allowed: lib.optionals (p ? ${key} && builtins.isAttrs p.${key}) (bad [ key ] allowed p.${key});
      rules = p.network_policies or { };
      endpointProblems = rname: r: lib.concatLists (lib.imap0
        (i: e:
          let where = [ "network_policies" rname "endpoints" (toString i) ]; in
          bad where schema.endpoint e
          ++ lib.optional (!(e ? host) && !(e ? allowed_ips))
            "${at ([ "policies" name ] ++ where)}: an endpoint needs `host` or `allowed_ips`"
          ++ lib.optional (!(e ? port) && !(e ? ports))
            "${at ([ "policies" name ] ++ where)}: an endpoint needs `port` or `ports`"
          ++ lib.optional (e ? port && e ? ports)
            "${at ([ "policies" name ] ++ where)}: use `port` or `ports`, not both"
          ++ lib.optional (e ? access && e ? rules)
            "${at ([ "policies" name ] ++ where)}: `access` and `rules` cannot be combined")
        (r.endpoints or [ ]));
    in
    bad [ ] schema.top p
    ++ lib.optional ((p.version or 1) != 1) "policies.${name}: version must be 1"
    ++ sub "filesystem_policy" schema.filesystem
    ++ sub "landlock" schema.landlock
    ++ sub "process" schema.process
    ++ lib.concatLists (lib.mapAttrsToList
      (rname: r:
        bad [ "network_policies" rname ] schema.rule r
        ++ lib.optional (lib.hasPrefix "_provider_" rname)
          "policies.${name}.network_policies.${rname}: rule keys cannot start with `_provider_` (reserved)"
        ++ endpointProblems rname r)
      rules)
    ++ lib.concatLists (lib.mapAttrsToList
      (mname: m: bad [ "network_middlewares" mname ] schema.middleware m)
      (p.network_middlewares or { }));

  allPolicyProblems = lib.concatLists (lib.mapAttrsToList policyProblems allPolicies);

  # ── provider profiles ────────────────────────────────────────────────
  # The profile that lets sandboxes reach the Nestlo model gateway. The
  # credential is a path template: the sandbox client builds its base URL
  # with the placeholder env var and the sandbox proxy resolves it in the
  # URL path (docs/how-it-works/providers/overview.mdx, "URL path segment").
  nestloProfile = {
    id = "nestlo-gateway";
    display_name = "Nestlo model gateway";
    description = "Model calls through the Nestlo model gateway (budget, DLP, audit) as gateway agent ${cfg.inference.agentId}";
    category = "inference";
    inference_capable = true;
    credentials = [{
      name = "gateway_token";
      description = "Token of the Nestlo gateway agent ${cfg.inference.agentId}";
      env_vars = [ "NESTLO_GATEWAY_TOKEN" ];
      required = true;
      auth_style = "path";
      path_template = "/agent/${cfg.inference.agentId}:{credential}";
    }];
    endpoints = [{
      host = cfg.inference.gatewayHost;
      port = net.modelGatewayPort;
      protocol = "rest";
      access = "read-write";
      enforcement = "enforce";
    }];
    inherit (cfg.inference) binaries;
  };

  profileFiles =
    lib.optional cfg.inference.enable { id = nestloProfile.id; file = yaml.generate "openshell-profile-nestlo-gateway.yaml" nestloProfile; }
    ++ map (n: { id = n; file = "${cfg.providers.profilesDir}/${n}.yaml"; }) cfg.providers.upstream
    ++ lib.mapAttrsToList
      (n: p: { id = n; file = yaml.generate "openshell-profile-${n}.yaml" ({ id = n; } // p); })
      cfg.providers.custom;

  credentialName = inst: var: "${inst}-${var}";

  # ── gateway configuration (crates/openshell-server/src/config_file.rs,
  # schema version 2; deny_unknown_fields) ──────────────────────────────
  gatewayConfig = {
    openshell = {
      version = 2;
      gateway = {
        name = gatewayName;
        bind_address = "${cfg.listen.address}:${toString cfg.ports.grpc}";
        health_bind_address = "${cfg.listen.address}:${toString cfg.ports.health}";
        log_level = cfg.logLevel;
        compute_driver = cfg.computeDriver;
        policy_validation_failure_mode = cfg.policyValidationFailureMode;
        guest_tls_ca = "${tlsDir}/ca.crt";
      }
      // lib.optionalAttrs (cfg.ports.metrics != null) {
        metrics_bind_address = "${cfg.listen.address}:${toString cfg.ports.metrics}";
      }
      // lib.optionalAttrs cfg.observability.ocsf.enable {
        ocsf_log = {
          path = ocsfFile;
          rotation = "daily";
          max_files = cfg.observability.ocsf.retainDays;
        };
      }
      // lib.optionalAttrs (cfg.observability.otlp.enable && obs.enable) {
        otlp = {
          endpoint = "http://127.0.0.1:${toString obs.otelCollectorPort}";
          service_name = "openshell-gateway";
        };
      };
      drivers.${cfg.computeDriver} = {
        socket_path = driverSocket;
        image_pull_policy = cfg.images.pullPolicy;
      }
      // lib.optionalAttrs (cfg.images.sandbox != null) { default_image = cfg.images.sandbox; }
      // lib.optionalAttrs (cfg.images.runtime != null) { sandbox_runtime_image = cfg.images.runtime; }
      // lib.optionalAttrs (cfg.images.supervisor != null) { supervisor_image = cfg.images.supervisor; }
      // cfg.driverSettings;
    };
  };
  configFile = toml.generate "openshell-gateway.toml" (lib.recursiveUpdate gatewayConfig cfg.settings);

  # ── units ────────────────────────────────────────────────────────────
  # Certificates (idempotent: all present -> skip), then a group-readable
  # copy of the client bundle for the CLI users.
  preScript = pkgs.writeShellScript "nestlo-openshell-pre" ''
    set -eu
    ${gw} generate-certs --output-dir ${tlsDir} --server-san host.openshell.internal ${
      lib.concatMapStringsSep " " (s: "--server-san ${lib.escapeShellArg s}") cfg.tls.extraSans}
    install -d -m 0750 ${clientDir}
    install -m 0640 ${tlsDir}/ca.crt ${clientDir}/ca.crt
    install -m 0640 ${tlsDir}/client/tls.crt ${clientDir}/tls.crt
    install -m 0640 ${tlsDir}/client/tls.key ${clientDir}/tls.key
  '';

  agentScript = pkgs.writeShellApplication {
    name = "nestlo-openshell-gateway-agent";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      umask 077
      tok=${tokenFile}
      if [ ! -s "$tok" ]; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$tok"
      fi
      chown ${svcUser}:${svcUser} "$tok"
      chmod 0400 "$tok"

      admin() {
        curl -fsS -m 10 --unix-socket ${adminSocket} -X "$1" -H 'Content-Type: application/json' \
          "''${@:3}" "http://x/_nestlo/$2"
      }
      for _ in $(seq 1 60); do
        admin GET health >/dev/null 2>&1 && break
        sleep 1
      done
      admin GET health >/dev/null || { echo "model gateway admin socket ${adminSocket} not available" >&2; exit 1; }
      hash=$(sha256sum < "$tok" | cut -d' ' -f1)
      admin PUT agents/${cfg.inference.agentId} -d "$(jq -cn --arg h "$hash" '{token_sha256: $h}')" >/dev/null
      admin PUT budget/${cfg.inference.agentId} -d '{"daily_usd": ${toString cfg.inference.budgetUsd}}' >/dev/null
    '';
  };

  setupScript = pkgs.writeShellApplication {
    name = "nestlo-openshell-setup";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export OPENSHELL_GATEWAY=${gatewayName}
      for _ in $(seq 1 120); do
        ${cli} status >/dev/null 2>&1 && break
        sleep 1
      done
      ${cli} status >/dev/null

      # Import a profile, or update it when it already exists (every run
      # after the first). An update must carry the profile's current
      # resource_version, so it is read from the gateway and appended to a
      # copy of the file (a top-level YAML key).
      import_profile() {
        if ${cli} profile import -f "$2" --global >/dev/null 2>&1; then
          return 0
        fi
        local rv tmp
        rv=$(${cli} profile export "$1" --global -o json \
          | ${pkgs.jq}/bin/jq -r 'if type == "array" then .[0] else . end | .resource_version // empty')
        [ -n "$rv" ] || { echo "openshell: cannot read resource_version of profile $1" >&2; return 1; }
        tmp=$(mktemp --suffix=.yaml)   # the CLI picks the parser by extension
        { cat "$2"; printf '\nresource_version: %s\n' "$rv"; } > "$tmp"
        ${cli} profile update "$1" -f "$tmp" --global >/dev/null
        rm -f "$tmp"
      }
      ensure_provider() {
        local name=$1; shift
        ${cli} provider get "$name" >/dev/null 2>&1 || ${cli} provider create --name "$name" "$@" >/dev/null
      }

      ${lib.concatMapStrings (p: ''
        import_profile ${lib.escapeShellArg p.id} ${lib.escapeShellArg p.file}
      '') profileFiles}
      ${lib.optionalString cfg.inference.enable ''
        NESTLO_GATEWAY_TOKEN=$(cat ${tokenFile}) ensure_provider ${lib.escapeShellArg cfg.inference.providerName} \
          --type ${nestloProfile.id} --credential NESTLO_GATEWAY_TOKEN
      ''}
      ${lib.concatStrings (lib.mapAttrsToList (inst: i: ''
        (
          ${lib.concatMapStrings (var: ''
            ${var}=$(cat "$CREDENTIALS_DIRECTORY"/${lib.escapeShellArg (credentialName inst var)})
            export ${var}
          '') (builtins.attrNames i.credentialFiles)}
          ensure_provider ${lib.escapeShellArg inst} --type ${lib.escapeShellArg i.type} ${
            lib.concatMapStringsSep " " (var: "--credential ${var}") (builtins.attrNames i.credentialFiles)} ${
            lib.concatStringsSep " " (lib.mapAttrsToList (k: v: "--config ${lib.escapeShellArg "${k}=${v}"}") i.config)}
        )
      '') cfg.providers.instances)}
      ${lib.optionalString (cfg.globalPolicy != null) ''
        ${cli} policy set --global --policy ${policyFiles.${cfg.globalPolicy}} --yes >/dev/null
      ''}
      ${lib.optionalString cfg.observability.ocsf.sandboxJson ''
        ${cli} settings set --global --key ocsf_json_enabled --value true --yes >/dev/null
      ''}
    '';
  };

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
    PrivateDevices = true;
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    SystemCallArchitectures = "native";
    CapabilityBoundingSet = "";
    UMask = "0027";
  };

  cliUsers = lib.unique (cfg.users ++ lib.optional cfg.includeAgentUser agentUser);
  homeOf = u: if u == agentUser then rt.agentHome else config.users.users.${u}.home;
  groupOf = u: if u == agentUser then agentUser else config.users.users.${u}.group;

  # ~/.config/openshell/gateways/openshell/mtls -> the group-readable bundle
  userLinks = u:
    let base = "${homeOf u}/.config/openshell/gateways/${gatewayName}"; in
    map (d: "d ${d} - ${u} ${groupOf u} -") [
      "${homeOf u}/.config"
      "${homeOf u}/.config/openshell"
      "${homeOf u}/.config/openshell/gateways"
      base
    ] ++ [ "L+ ${base}/mtls - - - - ${clientDir}" ];

  profileType = lib.types.submodule {
    freeformType = yaml.type;
    options.display_name = lib.mkOption {
      type = lib.types.str;
      description = "Display name of the profile.";
    };
  };
in
{
  options.nestlo.openshell = {
    enable = lib.mkEnableOption "NVIDIA OpenShell: sandboxed runtimes for AI agents (gateway, CLI, policies, inference through the Nestlo model gateway)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.openshell;
      defaultText = lib.literalExpression "pkgs.nestlo.openshell";
      description = ''
        OpenShell build. It must provide the binaries `openshell` (CLI) and
        `openshell-gateway`, and a `providers` attribute (the upstream
        `providers/` directory) for `providers.upstream`.
      '';
    };

    computeDriver = lib.mkOption {
      type = lib.types.enum [ "podman" "docker" ];
      default = if rt.containerRuntime == "docker" then "docker" else "podman";
      defaultText = lib.literalExpression ''if config.nestlo.runtime.containerRuntime == "docker" then "docker" else "podman"'';
      description = ''
        Compute driver that creates the sandboxes. `podman` uses the rootful
        podman socket (enabled by this module) and `docker` the Docker
        daemon (enabled by this module). The gateway user joins the runtime's
        group: that is root-equivalent on the host, which is why the service
        is the only thing that runs as that user.
      '';
    };

    listen.address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        IPv4 address of the gateway's gRPC, health and metrics listeners.
        Loopback by default; the gateway requires mutual TLS in any case.
        Podman sandboxes share the host network and reach the gateway on
        loopback, so a non-loopback address is rarely needed.
      '';
    };

    ports = {
      grpc = lib.mkOption {
        type = lib.types.port;
        default = 17670;
        description = "Gateway API port (OpenShell's default, crates/openshell-core DEFAULT_SERVER_PORT).";
      };
      health = lib.mkOption {
        type = lib.types.port;
        default = 17671;
        description = "Plain-HTTP health port (`/healthz`, `/readyz`, `/health`) on `listen.address`.";
      };
      metrics = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Prometheus `/metrics` port on `listen.address` (null: off). Scraped by Nestlo's Prometheus when nestlo.observability is enabled.";
      };
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Gateway log level (journal).";
    };

    policyValidationFailureMode = lib.mkOption {
      type = lib.types.enum [ "fail_closed" "retain_last_valid" ];
      default = "fail_closed";
      description = "What a sandbox does when it rejects a new policy revision: block network traffic, or keep the last valid policy.";
    };

    images = {
      pullPolicy = lib.mkOption {
        type = lib.types.enum [ "always" "if_not_present" "never" "newer" ];
        default = "if_not_present";
        description = "Image pull policy of the compute driver.";
      };
      sandbox = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "ghcr.io/nvidia/openshell-community/sandboxes/base:latest";
        description = "Default image of `openshell sandbox create` without `--from` (null: the driver's default).";
      };
      runtime = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OCI image the trusted `openshell-sandbox` binary is extracted from (null: upstream's version-pinned `ghcr.io/nvidia/openshell/sandbox`).";
      };
      supervisor = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OCI image with the `openshell-supervisor` binary (null: upstream's version-pinned `ghcr.io/nvidia/openshell/supervisor`).";
      };
    };

    tls.extraSans = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "openshell.example.com" ];
      description = ''
        Extra subject alternative names of the gateway certificate. The
        certificate always covers localhost, 127.0.0.1 and
        host.openshell.internal. Certificates are generated on first start in
        ${tlsDir}; delete that directory to rotate them.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = rt.operators;
      defaultText = lib.literalExpression "config.nestlo.runtime.operators";
      description = ''
        Users who use the `openshell` CLI. They join the `openshell` group,
        which can read the gateway's client certificate, and get
        ~/.config/openshell/gateways/openshell/mtls linked to it. Whoever
        holds the certificate can create sandboxes (and so start containers
        through the gateway), so keep the list to operators.
      '';
    };

    includeAgentUser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also give the `nestlo-agent` user (the sandboxed agent identity) the
        client certificate, so agents can create OpenShell sandboxes for their
        own sub-tasks. Off by default: the agent could then start containers
        with any policy and image the gateway admits.
      '';
    };

    inference = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = net.enable;
        defaultText = lib.literalExpression "config.nestlo.networking.enable";
        description = ''
          Route sandbox model calls through the Nestlo model gateway: register
          the gateway agent `agentId` (token and daily budget) and create the
          provider profile `nestlo-gateway` plus the provider instance
          `providerName` in OpenShell. Attach it with
          `openshell sandbox create --provider ${cfg.inference.providerName}`
          and point the client at
          `http://${cfg.inference.gatewayHost}:${gwPort}/agent/${cfg.inference.agentId}:''${NESTLO_GATEWAY_TOKEN}/<provider>`
          (see `baseUrls`). The sandbox sees only the placeholder in
          NESTLO_GATEWAY_TOKEN; its proxy swaps in the token, and the Nestlo
          gateway adds the real provider key.
        '';
      };
      agentId = lib.mkOption {
        type = lib.types.str;
        default = "openshell";
        description = "Gateway agent id that sandbox model calls are made as (budget, logs, audit).";
      };
      budgetUsd = lib.mkOption {
        type = lib.types.numbers.nonnegative;
        default = 20;
        description = "Daily budget of `agentId` in USD; the gateway answers 402 once it is spent.";
      };
      providerName = lib.mkOption {
        type = lib.types.str;
        default = "nestlo";
        description = "Name of the OpenShell provider instance that carries the gateway token.";
      };
      gatewayHost = lib.mkOption {
        type = lib.types.str;
        default = "host.openshell.internal";
        description = ''
          Host name sandboxes use for the Nestlo model gateway. With the
          podman driver, `host.openshell.internal` is the host's loopback,
          where the gateway listens. With the docker driver it is the bridge
          address, which the Nestlo gateway does not listen on by default.
        '';
      };
      binaries = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "/usr/bin/curl"
          "/usr/local/bin/curl"
          "/usr/bin/python3.*"
          "/usr/local/bin/python3.*"
          "/sandbox/.venv/**"
          "/usr/bin/node"
          "/usr/local/bin/node"
        ];
        description = "Executables inside the sandbox allowed to reach the gateway (the profile's `binaries`; match your image's layout).";
      };
      anthropicProvider = lib.mkOption {
        type = lib.types.str;
        default = "anthropic";
        description = "Nestlo gateway provider for `baseUrls.anthropic`.";
      };
      openaiProvider = lib.mkOption {
        type = lib.types.str;
        default = "openai";
        description = "Nestlo gateway provider for `baseUrls.openai`.";
      };
      baseUrls = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        readOnly = true;
        default = {
          anthropic = "http://${cfg.inference.gatewayHost}:${gwPort}/agent/${cfg.inference.agentId}:\${NESTLO_GATEWAY_TOKEN}/${cfg.inference.anthropicProvider}";
          openai = "http://${cfg.inference.gatewayHost}:${gwPort}/agent/${cfg.inference.agentId}:\${NESTLO_GATEWAY_TOKEN}/${cfg.inference.openaiProvider}/v1";
        };
        description = ''
          Base URLs for clients inside a sandbox, with the provider's
          placeholder variable. Expand them in the sandbox, for example
          `openshell sandbox create --provider nestlo -- sh -c 'ANTHROPIC_BASE_URL=... claude'`.
        '';
      };
    };

    policies = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        freeformType = yaml.type;
        options.version = lib.mkOption {
          type = lib.types.int;
          default = 1;
          description = "Policy schema version (must be 1).";
        };
      });
      default = { };
      example = lib.literalExpression ''
        {
          github-readonly = {
            filesystem_policy = {
              read_only = [ "/usr" "/lib" "/etc" ];
              read_write = [ "/tmp" "/sandbox" ];
            };
            network_policies.github = {
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
        }
      '';
      description = ''
        Sandbox policies by name, in OpenShell's policy YAML shape (the keys
        `filesystem_policy`, `landlock`, `process`, `network_policies`,
        `network_middlewares`; docs/how-it-works/policies/schema.mdx).
        Unknown fields are rejected at evaluation, as OpenShell would at
        sandbox creation. `binaries` entries may be plain paths. Each policy is
        rendered to /etc/openshell/policies/<name>.yaml; use it with
        `openshell sandbox create --policy /etc/openshell/policies/<name>.yaml`,
        `defaultPolicy` or `globalPolicy`.
      '';
    };

    upstreamDefaultPolicy = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also render OpenShell's restrictive built-in default (workdir and /tmp
        writable, system paths readable, no network) as policy `restrictive`,
        to start declared policies from.
      '';
    };

    defaultPolicy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Policy that `openshell sandbox create` uses without `--policy`, for
        every login session (OPENSHELL_SANDBOX_POLICY). Null: OpenShell's
        own default.
      '';
    };

    globalPolicy = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Policy applied as the gateway-global policy at every start
        (`openshell policy set --global`). A global policy locks every
        sandbox to it: sandbox-level policies and provider-contributed rules
        no longer apply, so list everything sandboxes need in it.
      '';
    };

    providers = {
      profilesDir = lib.mkOption {
        type = lib.types.path;
        default = cfg.package.providers;
        defaultText = lib.literalExpression "config.nestlo.openshell.package.providers";
        description = "Directory with the upstream provider profiles (providers/*.yaml in the OpenShell source).";
      };
      upstream = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "github" "anthropic" "openai" ];
        description = ''
          Upstream profiles to import into the gateway (names of
          providers/<name>.yaml: anthropic, aws, aws-bedrock, aws-s3,
          claude-code, codex, copilot, cursor, deepinfra, github,
          google-cloud, google-vertex-ai, nvidia, oci-genai, openai,
          openrouter, pypi). Read the header of each file first: its
          `binaries` assume a reference image layout and may need a custom
          copy (`custom`). Imported at platform scope, at every start.
        '';
      };
      custom = lib.mkOption {
        type = lib.types.attrsOf profileType;
        default = { };
        example = lib.literalExpression ''
          {
            ollama-openai = {
              display_name = "Ollama";
              description = "Host-local Ollama";
              category = "inference";
              inference_capable = true;
              credentials = [ ];
              endpoints = [{ host = "host.openshell.internal"; port = 11434; protocol = "rest"; access = "read-write"; enforcement = "enforce"; }];
              binaries = [ "/usr/bin/curl" ];
            };
          }
        '';
        description = "Own provider profiles by id, in OpenShell's profile YAML shape (docs/how-it-works/providers/profiles.mdx). Imported at platform scope.";
      };
      instances = lib.mkOption {
        default = { };
        description = ''
          Provider instances to create (once; delete one in OpenShell to have
          it recreated) from a profile and secret files. Attach them to
          sandboxes with `--provider <name>`. Real keys stay on the host:
          sandboxes receive placeholders.
        '';
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            type = lib.mkOption {
              type = lib.types.str;
              description = "Profile id of the provider.";
            };
            credentialFiles = lib.mkOption {
              type = lib.types.attrsOf lib.types.path;
              default = { };
              example = { GITHUB_TOKEN = "/run/secrets/GITHUB_TOKEN"; };
              description = "Credential environment variable -> file with its value (read as a systemd credential, root can read it).";
            };
            config = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Provider config key/value pairs (`--config KEY=VALUE`).";
            };
          };
        });
      };
    };

    observability = {
      ocsf.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Write the gateway's OCSF events (policy and settings changes, TLS
          reloads; ${ocsfFile}, one JSON object per line, daily rotation) for
          a SIEM. Sandbox-side events (network, process and filesystem
          decisions) stay in the sandboxes and in `openshell logs`; see
          `ocsf.sandboxJson`.
        '';
      };
      ocsf.retainDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 14;
        description = "Rotated OCSF files kept.";
      };
      ocsf.sandboxJson = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Set the global setting `ocsf_json_enabled`: supervisors also write OCSF JSON files (/var/log/openshell-ocsf.*.log inside each sandbox).";
      };
      otlp.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Export the gateway's traces over OTLP/gRPC to the Nestlo collector when nestlo.observability is enabled.";
      };
    };

    driverSettings = lib.mkOption {
      type = toml.type;
      default = { };
      example = { enable_bind_mounts = false; sandbox_pids_limit = 1024; };
      description = "Extra keys for `[openshell.drivers.<computeDriver>]` (see crates/openshell-driver-{podman,docker}/src config structs; unknown keys make the gateway refuse to start).";
    };

    settings = lib.mkOption {
      type = toml.type;
      default = { };
      example = { openshell.gateway.ssh_session_ttl_secs = 3600; };
      description = "Extra gateway TOML merged over the generated one (schema v2, crates/openshell-server/src/config_file.rs). It is stored in the world-readable Nix store: no secrets.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !cfg.inference.enable || net.enable;
        message = "nestlo.openshell.inference sends sandbox model calls through the Nestlo model gateway (nestlo.networking.enable)";
      }
      {
        assertion = !lib.hasInfix ":" cfg.listen.address;
        message = "nestlo.openshell.listen.address must be an IPv4 address";
      }
      {
        assertion = cfg.ports.grpc != cfg.ports.health && cfg.ports.metrics != cfg.ports.grpc && cfg.ports.metrics != cfg.ports.health;
        message = "nestlo.openshell.ports must be distinct";
      }
      {
        assertion = allPolicyProblems == [ ];
        message = "nestlo.openshell.policies are not valid OpenShell policies:\n  ${lib.concatStringsSep "\n  " allPolicyProblems}";
      }
      {
        assertion = cfg.defaultPolicy == null || allPolicies ? ${cfg.defaultPolicy};
        message = "nestlo.openshell.defaultPolicy \"${toString cfg.defaultPolicy}\" is not in nestlo.openshell.policies";
      }
      {
        assertion = cfg.globalPolicy == null || allPolicies ? ${cfg.globalPolicy};
        message = "nestlo.openshell.globalPolicy \"${toString cfg.globalPolicy}\" is not in nestlo.openshell.policies";
      }
      {
        assertion = lib.all (u: u == agentUser || config.users.users ? ${u}) cliUsers;
        message = "nestlo.openshell.users must be users defined in users.users";
      }
      {
        assertion = !(cfg.inference.enable && cfg.providers.custom ? ${nestloProfile.id});
        message = "nestlo.openshell.providers.custom.${nestloProfile.id} clashes with the generated Nestlo gateway profile";
      }
      {
        assertion = !(cfg.inference.enable && lib.elem nestloProfile.id cfg.providers.upstream);
        message = "\"${nestloProfile.id}\" is not an upstream profile; it is generated by nestlo.openshell.inference";
      }
    ];

    warnings =
      lib.optional (cfg.listen.address != "127.0.0.1")
        "nestlo.openshell.listen.address = ${cfg.listen.address}: the OpenShell API is reachable beyond loopback (mutual TLS still applies)"
      ++ lib.optional (cfg.inference.enable && cfg.computeDriver == "docker" && cfg.inference.gatewayHost == "host.openshell.internal")
        "nestlo.openshell: with the docker driver, host.openshell.internal is the Docker bridge address, where the Nestlo model gateway does not listen; set nestlo.openshell.inference.gatewayHost to an address it serves"
      ++ lib.optional cfg.includeAgentUser
        "nestlo.openshell.includeAgentUser: the sandboxed agent identity can create OpenShell sandboxes (containers with policies it chooses)";

    virtualisation.podman.enable = lib.mkIf (cfg.computeDriver == "podman") true;
    virtualisation.docker.enable = lib.mkIf (cfg.computeDriver == "docker") true;

    users.users.${svcUser} = {
      isSystemUser = true;
      group = svcUser;
      home = stateDir;
      description = "OpenShell gateway";
      extraGroups = [ driverGroup ];
    };
    users.groups.${svcUser}.members = cliUsers;

    environment.systemPackages = [ cfg.package ];

    environment.etc = {
      # System-wide gateway registration; the client certificate comes from
      # each user's ~/.config/openshell/gateways/openshell/mtls
      # (crates/openshell-bootstrap/src/{metadata,paths}.rs)
      "openshell/active_gateway".text = gatewayName;
      "openshell/gateways/${gatewayName}/metadata.json".text = builtins.toJSON {
        name = gatewayName;
        gateway_endpoint = endpoint;
        is_remote = false;
        gateway_port = cfg.ports.grpc;
      };
    } // lib.mapAttrs' (n: f: lib.nameValuePair "openshell/policies/${n}.yaml" { source = f; }) policyFiles;

    environment.sessionVariables = lib.mkIf (cfg.defaultPolicy != null) {
      OPENSHELL_SANDBOX_POLICY = policyPath cfg.defaultPolicy;
    };

    systemd.tmpfiles.rules =
      [ "d ${stateDir} 0750 ${svcUser} ${svcUser} -" ]
      ++ lib.concatMap userLinks cliUsers
      # the setup unit runs as the service user with XDG_CONFIG_HOME below
      # stateDir and needs the client bundle where the CLI looks for it
      ++ [
        "d ${xdgConfig} 0750 ${svcUser} ${svcUser} -"
        "d ${xdgConfig}/openshell 0750 ${svcUser} ${svcUser} -"
        "d ${xdgConfig}/openshell/gateways 0750 ${svcUser} ${svcUser} -"
        "d ${xdgConfig}/openshell/gateways/${gatewayName} 0750 ${svcUser} ${svcUser} -"
        "L+ ${xdgConfig}/openshell/gateways/${gatewayName}/mtls - - - - ${clientDir}"
      ];

    systemd.services.nestlo-openshell-gateway = {
      description = "OpenShell gateway (sandbox control plane)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "${driverGroup}.socket" "network-online.target" ];
      after = [ "${driverGroup}.socket" "network-online.target" ];
      restartTriggers = [ configFile ];
      environment = {
        HOME = stateDir;
        XDG_STATE_HOME = xdgState;
        XDG_CONFIG_HOME = xdgConfig;
        OPENSHELL_LOCAL_TLS_DIR = tlsDir;
        OPENSHELL_GATEWAY_CONFIG = "${configFile}";
      };
      serviceConfig = hardening // {
        Type = "simple";
        User = svcUser;
        Group = svcUser;
        SupplementaryGroups = [ driverGroup ];
        StateDirectory = "openshell";
        StateDirectoryMode = "0750";
        LogsDirectory = "openshell";
        LogsDirectoryMode = "0750";
        ExecStartPre = "${preScript}";
        ExecStart = gw;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.nestlo-openshell-gateway-agent = lib.mkIf cfg.inference.enable {
      description = "OpenShell: register the Nestlo gateway agent ${cfg.inference.agentId}";
      wantedBy = [ "multi-user.target" ];
      after = [ "nestlo-model-gateway.service" ];
      wants = [ "nestlo-model-gateway.service" ];
      restartTriggers = [ agentScript ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 120;
        ExecStart = lib.getExe agentScript;
        ReadWritePaths = stateDir;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.services.nestlo-openshell-setup = {
      description = "OpenShell: provider profiles, providers and global policy";
      wantedBy = [ "multi-user.target" ];
      after = [ "nestlo-openshell-gateway.service" ]
        ++ lib.optional cfg.inference.enable "nestlo-openshell-gateway-agent.service";
      requires = [ "nestlo-openshell-gateway.service" ]
        ++ lib.optional cfg.inference.enable "nestlo-openshell-gateway-agent.service";
      restartTriggers = [ setupScript configFile ];
      environment = {
        HOME = stateDir;
        XDG_STATE_HOME = xdgState;
        XDG_CONFIG_HOME = xdgConfig;
      };
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        User = svcUser;
        Group = svcUser;
        TimeoutStartSec = 300;
        ReadWritePaths = stateDir;
        ExecStart = lib.getExe setupScript;
        Restart = "on-failure";
        RestartSec = 15;
        LoadCredential = lib.concatLists (lib.mapAttrsToList
          (inst: i: lib.mapAttrsToList (var: path: "${credentialName inst var}:${path}") i.credentialFiles)
          cfg.providers.instances);
      };
      unitConfig.StartLimitIntervalSec = 0;
    };

    services.prometheus.scrapeConfigs = lib.mkIf (cfg.ports.metrics != null && obs.enable) [{
      job_name = "openshell-gateway";
      static_configs = [{ targets = [ "${endpointHost}:${toString cfg.ports.metrics}" ]; }];
    }];
  };
}
