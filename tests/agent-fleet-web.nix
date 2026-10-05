# agent-fleet web UIs test.
#
#   nix build .#checks.x86_64-linux.agent-fleet-web
#
# Checks that the static server starts, serves the chat and the hub with the
# right content types (including .wasm and .webmanifest), sends the
# cross-origin isolation headers wllama needs on /chat/ only, refuses path
# traversal and writes, is bound to loopback only, and that the vendored chat
# no longer loads wllama from a CDN.
{ pkgs, nestloModules }:

pkgs.testers.runNixOSTest {
  name = "nestlo-agent-fleet-web";
  globalTimeout = 900;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 1536;

    nestlo.dashboard.agentFleetWeb.enable = true;
    environment.systemPackages = [ pkgs.curl ];
  };

  testScript = ''
    base = "http://127.0.0.1:8484"

    def head(path):
        return machine.succeed(f"curl -sS -D - -o /dev/null {base}{path}").lower()

    machine.wait_for_unit("agent-fleet-web.service")
    machine.wait_for_open_port(8484)

    with subtest("bound to loopback only"):
        listening = machine.succeed("ss -H -ltn 'sport = :8484'")
        print(listening)
        assert "127.0.0.1:8484" in listening, listening
        assert "0.0.0.0" not in listening and "[::]" not in listening and "*:8484" not in listening, listening
        ip = machine.succeed("hostname -I | cut -d' ' -f1").strip()
        machine.fail(f"curl -sS --max-time 3 http://{ip}:8484/chat/")

    with subtest("the chat index and worker are served with the right types"):
        h = head("/chat/")
        assert " 200 " in h.splitlines()[0], h
        assert "content-type: text/html" in h, h
        assert "<title>" in machine.succeed(f"curl -sS {base}/chat/").lower()
        h = head("/chat/chat-worker.js")
        assert "content-type: text/javascript" in h, h
        h = head("/chat/vendor/wllama/wllama.wasm")
        assert "content-type: application/wasm" in h, h
        h = head("/chat/manifest.webmanifest")
        assert "content-type: application/manifest+json" in h, h

    with subtest("the worker imports the vendored wllama, not a CDN"):
        worker = machine.succeed(f"curl -sS {base}/chat/chat-worker.js")
        assert "./vendor/wllama/index.min.js" in worker, worker[:600]
        assert "cdn.jsdelivr.net" not in worker, worker[:600]

    with subtest("cross-origin isolation on the chat, not on the hub"):
        h = head("/chat/")
        assert "cross-origin-opener-policy: same-origin" in h, h
        assert "cross-origin-embedder-policy: require-corp" in h, h
        assert "content-security-policy:" in h, h
        h = head("/chat/vendor/wllama/wllama.wasm")
        assert "cross-origin-embedder-policy: require-corp" in h, h
        h = head("/hub/")
        assert " 200 " in h.splitlines()[0], h
        assert "cross-origin-embedder-policy" not in h, h
        assert "x-content-type-options: nosniff" in h, h

    with subtest("redirects, traversal and writes"):
        assert " 302 " in head("/").splitlines()[0]
        assert " 301 " in head("/chat").splitlines()[0]
        status = machine.succeed(f"curl -sS --path-as-is -o /dev/null -w '%{{http_code}}' {base}/chat/../../etc/passwd").strip()
        assert status == "404", status
        status = machine.succeed(f"curl -sS -o /dev/null -w '%{{http_code}}' -X POST -d x=1 {base}/chat/").strip()
        assert status == "405", status

    with subtest("runs unprivileged and sandboxed"):
        assert machine.succeed("systemctl show -p DynamicUser --value agent-fleet-web.service").strip() == "yes"
        pid = machine.succeed("systemctl show -p MainPID --value agent-fleet-web.service").strip()
        uid = machine.succeed(f"stat -c %U /proc/{pid}").strip()
        assert uid != "root", uid
        assert machine.succeed(f"grep -E '^CapEff' /proc/{pid}/status").split()[1] == "0000000000000000"
  '';
}
