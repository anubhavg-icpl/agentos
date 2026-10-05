# Nestlo ToolHive module
#
# ToolHive (https://github.com/stacklok/toolhive, Apache-2.0, binary `thv`)
# runs MCP servers in containers with a permission profile: which host paths
# are mounted (read / write) and which hosts and ports the container may reach
# (enforced by an egress proxy when the network is isolated). Here each
# selected MCP server becomes a systemd service that runs
#
#   thv run --foreground --isolate-network --permission-profile <json> ... <image>
#
# on the system Podman, publishing the server on a loopback port. Each server
# is then registered with Nestlo's MCP registry (nestlo.mcp-registry), and, if
# nestlo.agentgateway is enabled, exposed through it (with per-agent
# authorization) instead of being run as an un-isolated stdio child.
#
# The container runtime is root Podman: the thv processes run as root. See
# docs/toolhive.md for what that does and does not isolate.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.toolhive;
  obs = config.nestlo.observability;
  stateDir = "/var/lib/nestlo-toolhive";
  thv = lib.getExe cfg.package;

  profile = name: s: pkgs.writeText "nestlo-toolhive-${name}-profile.json" (builtins.toJSON ({
    inherit name;
    read = s.permissions.read;
    write = s.permissions.write;
    network.outbound =
      if s.permissions.outbound.insecureAllowAll then { insecure_allow_all = true; }
      else {
        allow_host = s.permissions.outbound.allowHost;
        # ToolHive's egress proxy (squid) allows ANY host on allow_port when allow_host is empty
        # (it ANDs only the non-empty lists), so no hosts must mean no ports too
        allow_port = if s.permissions.outbound.allowHost == [ ] then [ ] else s.permissions.outbound.allowPort;
      };
    privileged = false;
  }));

  unitName = name: "nestlo-toolhive-${name}";
  workload = name: "nestlo-${name}";

  runArgs = name: s: [
    "run" "--foreground"
    "--name" (workload name)
    "--host" "127.0.0.1"
    "--proxy-port" (toString s.port)
    "--proxy-mode" s.proxyMode
    "--isolate-network=${lib.boolToString s.isolateNetwork}"
    "--permission-profile" (toString (profile name s))
    "--image-verification" s.imageVerification
  ]
  ++ lib.optionals (s.transport != null) [ "--transport" s.transport ]
  ++ lib.optionals (s.targetPort != null) [ "--target-port" (toString s.targetPort) ]
  ++ lib.optionals (s.environmentFile != null) [ "--env-file" (toString s.environmentFile) ]
  ++ lib.concatLists (lib.mapAttrsToList (k: v: [ "-e" "${k}=${v}" ]) s.env)
  ++ lib.optionals cfg.tracing.enable [
    "--otel-endpoint" cfg.tracing.endpoint
    "--otel-insecure"
    "--otel-tracing-enabled"
    "--otel-sampling-rate" (toString cfg.tracing.samplingRate)
  ]
  ++ [ s.image ]
  ++ lib.optionals (s.args != [ ]) ([ "--" ] ++ s.args);

  serverType = lib.types.submodule ({ name, ... }: {
    options = {
      image = lib.mkOption {
        type = lib.types.str;
        example = "uvx://mcp-server-fetch";
        description = ''
          What to run: a ToolHive registry name (`fetch`), a container image
          (`ghcr.io/github/github-mcp-server`), or a protocol scheme that
          ToolHive turns into a container (`uvx://pkg`, `npx://pkg`,
          `go://pkg`). The image is pulled when the service starts.
        '';
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Arguments passed to the MCP server (after `--`).";
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment of the server. Not for secrets: they would be in the unit and the Nix store; use `environmentFile`.";
      };
      environmentFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        example = "/run/secrets/toolhive-github.env";
        description = "Root-only file with `NAME=value` lines for the server (`thv run --env-file`).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        description = "Loopback port of ToolHive's proxy for this server. Must be unique.";
      };
      proxyMode = lib.mkOption {
        type = lib.types.enum [ "streamable-http" "sse" ];
        default = "streamable-http";
        description = "How the proxy speaks MCP to clients for a stdio server (`sse` is deprecated upstream; agentgateway needs streamable-http).";
      };
      transport = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [ "stdio" "sse" "streamable-http" ]);
        default = null;
        description = "Transport of the server inside the container; null takes it from the registry/image metadata.";
      };
      targetPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Container port of an sse / streamable-http server.";
      };
      isolateNetwork = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Put the container on an isolated network whose only way out is
          ToolHive's egress proxy, which applies `permissions.outbound`.
          ToolHive pulls its proxy images (egress, DNS, ingress) on first use,
          so this needs registry access.
        '';
      };
      imageVerification = lib.mkOption {
        type = lib.types.enum [ "warn" "enabled" "disabled" ];
        default = "warn";
        description = "ToolHive's image provenance verification (Sigstore) for registry servers; `enabled` refuses unverified images.";
      };
      permissions = {
        read = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "/var/lib/nestlo/workspaces:/workspace" ];
          description = "Host paths mounted read-only, as `host[:container]`.";
        };
        write = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Host paths mounted read-write, as `host[:container]`.";
        };
        outbound = {
          insecureAllowAll = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Let the server reach any host and port (ToolHive's `insecure_allow_all`).";
          };
          allowHost = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "api.github.com" ".githubusercontent.com" ];
            description = "Hosts the server may connect to; a leading dot allows subdomains. Empty (with `insecureAllowAll` off) means no outbound network.";
          };
          allowPort = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ 443 ];
            description = "Ports the server may connect to.";
          };
        };
      };
      registerWithGateway = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Expose this server through nestlo.agentgateway (when enabled) as target `${name}`.";
      };
      registerInRegistry = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Add an entry for this server to nestlo.mcp-registry.extraToolServers (an `npx mcp-remote` bridge to the proxy).";
      };
    };
  });
in
{
  options.nestlo.toolhive = {
    enable = lib.mkEnableOption "ToolHive, running selected MCP servers isolated in Podman containers";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.toolhive;
      defaultText = lib.literalExpression "pkgs.toolhive";
      description = "ToolHive (`thv`).";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = { };
      example = lib.literalExpression ''
        {
          fetch = {
            image = "fetch";
            port = 9971;
            permissions.outbound.insecureAllowAll = true;
          };
          github = {
            image = "github";
            port = 9972;
            environmentFile = "/run/secrets/github-mcp.env";
            permissions.outbound.allowHost = [ "api.github.com" ];
          };
        }
      '';
      description = ''
        MCP servers to run in containers, by name. The name is the registry
        and agentgateway name, so it must not contain `_`. Each runs as
        `nestlo-toolhive-<name>.service`.
      '';
    };

    tracing = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = obs.enable;
        defaultText = lib.literalExpression "config.nestlo.observability.enable";
        description = "Send each server's OTLP traces to the Nestlo observability collector.";
      };
      endpoint = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:${toString obs.otelCollectorPort}";
        defaultText = lib.literalExpression ''"127.0.0.1:''${toString config.nestlo.observability.otelCollectorPort}"'';
        description = "OTLP endpoint (host:port, plain HTTP via --otel-insecure).";
      };
      samplingRate = lib.mkOption {
        type = lib.types.numbers.between 0 1;
        default = 1.0;
        description = "Fraction of requests traced.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length (lib.unique (lib.mapAttrsToList (_: s: s.port) cfg.servers)) == lib.length (lib.attrNames cfg.servers);
        message = "nestlo.toolhive.servers: every server needs its own port";
      }
      {
        assertion = lib.all (n: builtins.match "[a-z0-9][a-z0-9-]*" n != null) (lib.attrNames cfg.servers);
        message = "nestlo.toolhive.servers: names must match [a-z0-9][a-z0-9-]* (no '_': agentgateway separates server and tool at the first one)";
      }
    ];

    virtualisation.podman.enable = true;

    environment.systemPackages = [ cfg.package ];

    # The registry knows each server as a stdio bridge to ToolHive's proxy
    nestlo.mcp-registry.extraToolServers = lib.mapAttrs
      (name: s: {
        command = "npx";
        args = [ "-y" "mcp-remote" "http://127.0.0.1:${toString s.port}/${if s.proxyMode == "sse" then "sse" else "mcp"}" ];
        description = "${name}: MCP server isolated in a container by ToolHive";
      })
      (lib.filterAttrs (_: s: s.registerInRegistry) cfg.servers);

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services = lib.mapAttrs'
      (name: s: lib.nameValuePair (unitName name) {
        description = "ToolHive: MCP server ${name} in a container";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" "podman.socket" ];
        wants = [ "network-online.target" ];
        requires = [ "podman.socket" ];
        path = [ pkgs.podman ];
        environment = {
          HOME = stateDir;
          XDG_CONFIG_HOME = "${stateDir}/config";
          XDG_DATA_HOME = "${stateDir}/data";
          XDG_STATE_HOME = "${stateDir}/state";
          XDG_RUNTIME_DIR = "/run/nestlo-toolhive";
          # root Podman's API socket (podman.socket)
          TOOLHIVE_PODMAN_SOCKET = "/run/podman/podman.sock";
          TOOLHIVE_DEBUG = "";
        };
        serviceConfig = {
          ExecStart = "${thv} ${lib.escapeShellArgs (runArgs name s)}";
          # remove a leftover container of a crashed run before and after
          ExecStartPre = "-${thv} rm ${workload name}";
          ExecStopPost = "-${thv} rm ${workload name}";
          Restart = "on-failure";
          RestartSec = 10;
          TimeoutStopSec = 60;
          StateDirectory = "nestlo-toolhive";
          RuntimeDirectory = "nestlo-toolhive";

          # thv is root (it talks to root Podman) but needs little else
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ stateDir ] ++ s.permissions.write;
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        };
      })
      cfg.servers;
  };
}
