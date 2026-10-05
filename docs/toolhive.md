# ToolHive (`nestlo.toolhive`)

[ToolHive](https://github.com/stacklok/toolhive) (Apache-2.0, `thv`) runs MCP
servers in containers with a **permission profile**: which host paths are
mounted (read-only or read-write) and which hosts and ports the server may
reach. `nestlo.toolhive` runs selected MCP servers that way, on the system
Podman, instead of as un-isolated `npx`/`uvx` processes:

* each server is a unit `nestlo-toolhive-<name>.service` running
  `thv run --foreground --isolate-network --permission-profile <json> ...`
  with ToolHive's proxy published on `127.0.0.1:<port>`;
* it is registered with Nestlo's MCP registry
  (`nestlo.mcp-registry.extraToolServers`, an `npx mcp-remote` bridge);
* with `nestlo.agentgateway` it is exposed through the gateway as a remote
  target, so the per-agent tool authorization applies
  ([agentgateway.md](agentgateway.md)).

## Enable

```nix
nestlo.toolhive = {
  enable = true;
  servers = {
    fetch = {
      image = "fetch";                      # ToolHive registry name
      port = 9971;
      permissions.outbound.insecureAllowAll = true;   # a fetch tool must reach the web
    };
    github = {
      image = "github";
      port = 9972;
      environmentFile = "/run/secrets/github-mcp.env";   # GITHUB_PERSONAL_ACCESS_TOKEN=...
      permissions.outbound = { allowHost = [ "api.github.com" ]; allowPort = [ 443 ]; };
    };
    notes = {
      image = "uvx://mcp-server-git";       # protocol scheme: ToolHive builds the container
      port = 9973;
      permissions.read = [ "/var/lib/nestlo/workspaces:/workspace" ];
      permissions.write = [ ];
      permissions.outbound.allowHost = [ ];  # no network at all
    };
  };
};
```

## Options (per server)

| Option | Default | |
|--------|---------|-|
| `image` | required | registry name, container image, or `uvx://`/`npx://`/`go://` scheme |
| `args`, `env`, `environmentFile` | | arguments after `--`; `-e` variables; `--env-file` for secrets |
| `port` | required | loopback port of ToolHive's proxy; unique |
| `proxyMode` | `streamable-http` | `sse` is deprecated upstream; agentgateway needs `streamable-http` |
| `transport`, `targetPort` | `null` | override the transport / container port |
| `isolateNetwork` | `true` | container network whose only exit is ToolHive's egress proxy, applying `permissions.outbound` |
| `imageVerification` | `warn` | Sigstore verification of registry images (`enabled` refuses unverified ones) |
| `permissions.read` / `.write` | `[ ]` | host paths mounted, as `host[:container]` |
| `permissions.outbound.insecureAllowAll` | `false` | any host and port |
| `permissions.outbound.allowHost` / `.allowPort` | `[ ]` / `[ 443 ]` | allow-list; empty hosts with `insecureAllowAll = false` means no network |
| `registerWithGateway` | `true` | expose through `nestlo.agentgateway` |
| `registerInRegistry` | `true` | entry in `nestlo.mcp-registry.extraToolServers` |

Global: `package` (default `pkgs.toolhive`, 0.26.1 in this nixpkgs) and
`tracing.{enable,endpoint,samplingRate}` (OTLP to the Nestlo collector,
default on when `nestlo.observability` is).

The flags used (`--foreground`, `--name`, `--host`, `--proxy-port`,
`--proxy-mode`, `--isolate-network=<bool>`, `--permission-profile`,
`--image-verification`, `--transport`, `--target-port`, `--env-file`, `-e`,
`--otel-*`) exist in ToolHive v0.26.1 (checked against the tag's
`cmd/thv/app/run_flags.go`). `--isolate-network` is passed explicitly with a
value because its default differs between releases (false in 0.26, true in
current ones).

## Security notes and limits

* The container runtime is **root Podman**; the `thv` processes run as root
  (hardened: `ProtectSystem=strict`, private `/tmp`, no new privileges), and
  anyone who can talk to `/run/podman/podman.sock` can start containers as
  root. This is not rootless isolation.
* Network isolation is enforced by ToolHive's egress proxy and works only on a
  bridge network; ToolHive pulls its helper images on first use, so the host
  needs registry access then. Images and `uvx://` / `npx://` packages are
  fetched when the service starts: nothing is pinned by Nix.
* `permissions.read`/`write` mount host paths into the container; a server that
  may write a workspace can change it for every agent.
* Inbound restrictions of ToolHive profiles have limited upstream
  implementation; the proxy listens on loopback only.
* The module is modest and **not run here**: no container runtime or registry
  access in the build environment. It was checked by evaluation and against
  ToolHive's CLI reference.
