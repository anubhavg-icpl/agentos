# VM test of nestlo.agentgateway (agentgateway as the MCP enforcement point).
#
#   nix build .#checks.x86_64-linux.agentgateway
#
# Runs the real `agentgateway` binary (nixos/packages/agentgateway.nix, a
# Rust build from source: expect a long first build).
#
# Checks:
#   the generated configuration passes `agentgateway --validate-only`
#   the MCP endpoint is on loopback and refuses requests without a key
#   agent `reader` (tools = demo: echo) sees and can call only demo_echo;
#     demo_secret is hidden from tools/list and refused on tools/call
#   agent `admin` (tools = demo: *) sees both
#   the stdio MCP server runs with a cleared environment: it sees neither
#     the key hashes nor the model gateway token
#   per-agent key files are mode 0640 root:nestlo and hold the key whose
#     hash is in the gateway's environment, not in the configuration
#   `nestlo-agentgateway-mcp-config` prints a client configuration
{ pkgs, nestloModules }:

let
  # A minimal stdio MCP server: tools echo, secret and env_leak
  demoServer = pkgs.writers.writePython3Bin "demo-mcp" { flakeIgnore = [ "E501" ]; } ''
    import json
    import os
    import sys

    TOOLS = [
        {"name": n, "description": n, "inputSchema": {"type": "object", "properties": {}}}
        for n in ("echo", "secret", "env_leak")
    ]


    def reply(i, result):
        print(json.dumps({"jsonrpc": "2.0", "id": i, "result": result}), flush=True)


    for line in sys.stdin:
        msg = json.loads(line)
        method, i = msg.get("method"), msg.get("id")
        if method == "initialize":
            reply(i, {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                      "serverInfo": {"name": "demo", "version": "1"}})
        elif method == "tools/list":
            reply(i, {"tools": TOOLS})
        elif method == "tools/call":
            name = msg["params"]["name"]
            if name == "env_leak":
                leaked = sorted(k for k in os.environ if k.startswith(("AG_", "NESTLO_")))
                text = "leaked:" + ",".join(leaked)
            else:
                text = "ran " + name
            reply(i, {"content": [{"type": "text", "text": text}]})
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-agentgateway";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = nestloModules ++ [ ../modules/agentgateway ];

    virtualisation.memorySize = 2048;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "admin" ];
      };
      agentgateway = {
        enable = true;
        # the package file itself, so the test does not depend on the overlay entry
        package = pkgs.callPackage ../nixos/packages/agentgateway.nix { };
        registerInRegistry = false;
        mcp.extraServers.demo = {
          command = "${demoServer}/bin/demo-mcp";
        };
        mcp.agents.reader.tools.demo = [ "echo" ];
        mcp.agents.admin.tools.demo = [ "*" ];
      };
    };

    environment.systemPackages = [ pkgs.jq pkgs.curl ];
  };

  testScript = ''
    import json

    MCP = "http://127.0.0.1:9961/mcp"

    def key(agent):
        return machine.succeed(f"cat /var/lib/nestlo-agentgateway/keys/{agent}").strip()

    def post(payload, token, session=None):
        hdr = "-H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18'"
        if token:
            hdr += f" -H 'Authorization: Bearer {token}'"
        if session:
            hdr += f" -H 'Mcp-Session-Id: {session}'"
        out = machine.succeed(
            f"curl -s -D /tmp/headers -w '\\n%{{http_code}}' {hdr} -d {json.dumps(json.dumps(payload))} {MCP}")
        body, code = out.rsplit("\n", 1)
        data = None
        for line in body.splitlines():
            if line.startswith("data:"):
                data = json.loads(line[5:])
        if data is None and body.startswith("{"):
            data = json.loads(body)
        sid = machine.succeed("grep -i '^mcp-session-id:' /tmp/headers || true").split(":", 1)[-1].strip()
        return int(code), data, sid

    def session(token):
        code, data, sid = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                           "clientInfo": {"name": "test", "version": "1"}}}, token)
        assert code == 200, (code, data)
        post({"jsonrpc": "2.0", "method": "notifications/initialized"}, token, sid)
        return sid

    def tools(token, sid):
        code, data, _ = post({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, token, sid)
        assert code == 200, (code, data)
        return sorted(t["name"] for t in data["result"]["tools"])

    def call(token, sid, name):
        return post({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                     "params": {"name": name, "arguments": {}}}, token, sid)

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-agentgateway-setup.service")
    machine.wait_for_unit("nestlo-agentgateway.service")
    machine.wait_for_open_port(9961)

    with subtest("the generated configuration validates"):
        machine.succeed("systemctl cat nestlo-agentgateway | grep -o '/nix/store[^ ]*yaml' | head -1 > /tmp/cfg")
        machine.succeed("set -a; . /var/lib/nestlo-agentgateway/env; set +a; "
                        "agentgateway --validate-only -f $(cat /tmp/cfg)")

    with subtest("listeners are loopback only"):
        out = machine.succeed("ss -ltn")
        assert "127.0.0.1:9961" in out and "0.0.0.0:9961" not in out, out

    with subtest("keys live in files, hashes in the environment, neither in the configuration"):
        machine.succeed("stat -c '%a %U:%G' /var/lib/nestlo-agentgateway/keys/reader | grep -x '640 root:nestlo'")
        k = key("reader")
        machine.fail(f"grep -r {k} /nix/store/*agentgateway*.yaml")
        machine.succeed("grep -F 'sha256:''${AG_KEYHASH_0}' $(cat /tmp/cfg)")
        machine.fail("grep -E 'sha256:[0-9a-f]{64}' $(cat /tmp/cfg)")

    with subtest("no key, a wrong key and another agent's guess are refused"):
        assert post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, None)[0] == 401
        assert post({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, "agw_wrong")[0] == 401

    with subtest("reader sees and calls only demo_echo"):
        tok = key("reader")
        sid = session(tok)
        assert tools(tok, sid) == ["demo_echo"], tools(tok, sid)
        code, data, _ = call(tok, sid, "demo_echo")
        assert code == 200 and "ran echo" in json.dumps(data), data
        code, data, _ = call(tok, sid, "demo_secret")
        assert "ran secret" not in json.dumps(data), data

    with subtest("admin sees every tool of the server"):
        tok = key("admin")
        sid = session(tok)
        assert tools(tok, sid) == ["demo_echo", "demo_env_leak", "demo_secret"], tools(tok, sid)
        code, data, _ = call(tok, sid, "demo_secret")
        assert "ran secret" in json.dumps(data), data

    with subtest("the MCP server gets a cleared environment"):
        code, data, _ = call(tok, sid, "demo_env_leak")
        assert "leaked:" in json.dumps(data) and "AG_KEYHASH" not in json.dumps(data) and "NESTLO_GW_TOKEN" not in json.dumps(data), data

    with subtest("the client configuration helper works"):
        out = json.loads(machine.succeed("nestlo-agentgateway-mcp-config reader"))
        assert out["mcpServers"]["nestlo"]["url"] == MCP, out
        assert out["mcpServers"]["nestlo"]["headers"]["Authorization"] == "Bearer " + key("reader"), out
  '';
}
