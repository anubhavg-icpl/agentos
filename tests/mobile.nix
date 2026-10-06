# VM test of nestlo.mobile.
#
#   nix build .#checks.x86_64-linux.mobile
#
# The server is up and hardened as declared. `nestlo-mobile pair` prints a QR
# code, the landing-page URL (http://<host>:7080/pair#v=1&...) and the
# nestlo:// URI; the onboarding listener serves the landing page and the app
# page. A Python client (the same WebSocket code the server uses) pairs with
# the code, pins the fingerprint from the URI, and calls /v1/info, /v1/overview,
# /v1/agents and /v1/sessions. Reusing the code fails with 403, a wrong token
# with 401. It opens a terminal for alice, runs a command, resizes it and
# receives the events stream. Revoking the device makes its token 401.
# The tunnel unit runs stub provider binaries (the VM has no internet): a fake
# cloudflared that prints a trycloudflare.com banner and a fake bore. The pair
# command shows the stub endpoints in its QR text, and the API port serves the
# onboarding pages so one tunnel carries everything.
# VM under TCG: timeouts are generous.
{ pkgs, nestloModules }:

let
  stubCloudflared = pkgs.writeShellScriptBin "cloudflared" ''
    echo "INF Requesting new quick Tunnel on trycloudflare.com..."
    echo "INF |  https://fake-words-here.trycloudflare.com  |"
    echo "args: $*"
    exec ${pkgs.coreutils}/bin/sleep 3600
  '';
  stubBore = pkgs.writeShellScriptBin "bore" ''
    echo "bore_cli::client: listening at bore.pub:40123"
    exec ${pkgs.coreutils}/bin/sleep 3600
  '';
  python = pkgs.python3.withPackages (ps: [ ps.cryptography ps.redis ]);

  client = pkgs.writeText "mobile-client.py" ''
    import asyncio, base64, hashlib, http.client, json, ssl, subprocess, sys, urllib.parse

    from nestlo_services import mobile as M

    uri = open("/tmp/pair.txt").read()
    uri = [l for l in uri.splitlines() if l.startswith("nestlo://")][0]
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(uri).query)
    port, fp, code = int(q["port"][0]), q["fp"][0], q["code"][0]
    assert q["host"][-1] == "localhost", q["host"]

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE


    def pinned(conn):
        der = conn.sock.getpeercert(binary_form=True)
        got = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).decode().rstrip("=")
        assert got == fp, (got, fp)


    def call(method, path, body=None, token=None):
        conn = http.client.HTTPSConnection("127.0.0.1", port, context=ctx, timeout=60)
        conn.connect()
        pinned(conn)
        headers = {"Authorization": "Bearer " + token} if token else {}
        conn.request(method, path, json.dumps(body) if body is not None else None, headers)
        r = conn.getresponse()
        data = json.loads(r.read() or b"null")
        conn.close()
        return r.status, data


    st, paired = call("POST", "/v1/pair", {"code": code, "device_name": "Test phone", "device_model": "vm/test"})
    assert st == 200, (st, paired)
    token, device_id = paired["token"], paired["device_id"]
    assert call("POST", "/v1/pair", {"code": code, "device_name": "again"})[0] == 403
    assert call("GET", "/v1/info", token="wrong")[0] == 401
    assert call("GET", "/v1/info")[0] == 401

    st, info = call("GET", "/v1/info", token=token)
    assert st == 200 and "agents" in info["features"] and "terminal" in info["features"], info
    assert "desktop" not in info["features"], info
    st, ov = call("GET", "/v1/overview", token=token)
    assert st == 200 and set(ov) == {"agents", "spend", "health"} and ov["health"]["redis"] is True, ov
    st, agents = call("GET", "/v1/agents", token=token)
    assert st == 200 and isinstance(agents, list), agents
    st, sessions = call("GET", "/v1/sessions", token=token)
    assert {"id": "shell:alice", "title": "alice shell", "kind": "shell", "user": "alice"} in sessions, sessions
    st, devs = call("GET", "/v1/devices", token=token)
    assert [d["device_id"] for d in devs] == [device_id] and devs[0]["current"], devs


    async def read_until(ws, needle):
        buf = b""
        while needle not in buf:
            msg = await asyncio.wait_for(ws.recv(), 120)
            assert msg is not None, "terminal closed; got %r" % buf
            if msg[0] == M.OP_BIN:
                buf += msg[1]
        return buf


    async def main():
        hdr = {"Authorization": "Bearer " + token}
        ws, _ = await M.ws_connect("127.0.0.1", port, "/v1/term?session=shell:alice&cols=80&rows=24", hdr, ctx)
        await asyncio.sleep(2)
        await ws._frame(M.OP_BIN, b"echo MOBILE-$((40+2))\n")
        await read_until(ws, b"MOBILE-42")
        await ws._frame(M.OP_BIN, b"whoami\n")
        await read_until(ws, b"alice\r\n")
        await ws._frame(M.OP_BIN, b"stty size\n")
        await read_until(ws, b"24 80")
        await ws._frame(M.OP_TEXT, json.dumps({"type": "resize", "cols": 120, "rows": 50}).encode())
        await asyncio.sleep(1)
        await ws._frame(M.OP_BIN, b"stty size\n")
        await read_until(ws, b"50 120")
        await ws._frame(M.OP_BIN, b"exit 7\n")
        while True:
            msg = await asyncio.wait_for(ws.recv(), 60)
            assert msg is not None
            if msg[0] == M.OP_TEXT:
                assert json.loads(msg[1]) == {"type": "exit", "code": 7}, msg
                break
        # a user outside the allowlist is refused before any process starts
        try:
            await M.ws_connect("127.0.0.1", port, "/v1/term?session=shell:root", hdr, ctx)
            raise SystemExit("root terminal was allowed")
        except M.HttpError as e:
            assert e.status == 403, e.status

        ev, _ = await M.ws_connect("127.0.0.1", port, "/v1/events", hdr, ctx)
        msg = await asyncio.wait_for(ev.recv(), 30)
        assert json.loads(msg[1])["type"] == "hello", msg
        seen = None
        for _ in range(3):
            msg = await asyncio.wait_for(ev.recv(), 60)
            seen = json.loads(msg[1])["type"]
            if seen in ("ping", "agent"):
                break
        assert seen in ("ping", "agent"), seen
        await ev.close()

        out = subprocess.run(["nestlo-mobile", "revoke", device_id], capture_output=True, text=True)
        assert out.returncode == 0, out
        assert call("GET", "/v1/info", token=token)[0] == 401
        try:
            await M.ws_connect("127.0.0.1", port, "/v1/term?session=shell:alice", hdr, ctx)
            raise SystemExit("revoked token opened a terminal")
        except M.HttpError as e:
            assert e.status == 401


    asyncio.run(main())
    print("CLIENT-OK")
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-mobile";
  globalTimeout = 1800;

  nodes.machine = { pkgs, ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    environment.systemPackages = [ pkgs.curl ];
    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };

    nestlo = {
      runtime = {
        enable = true;
        operators = [ "alice" ];
      };
      mobile = {
        enable = true;
        advertisedHosts = [ "nestlo.test" ];
        tunnel = {
          enable = true;
          package = stubCloudflared;
          providers.bore = {
            enable = true;
            package = stubBore;
          };
        };
      };
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nestlo-mobile.service", timeout=300)
    machine.wait_for_open_port(7443)
    machine.wait_for_open_port(7080)

    with subtest("the service is up and the state is private"):
        assert machine.succeed("stat -c '%a' /var/lib/nestlo-mobile").strip() == "700"
        machine.succeed("test -s /var/lib/nestlo-mobile/tls/cert.pem")
        assert machine.succeed("stat -c '%a' /var/lib/nestlo-mobile/tls/key.pem").strip() == "600"
        assert machine.succeed("stat -c '%a %G' /run/nestlo-mobile/admin.sock").strip() == "660 wheel"
        props = machine.succeed("systemctl show nestlo-mobile -p RestrictAddressFamilies -p CapabilityBoundingSet")
        assert "AF_NETLINK" in props, props
        # the firewall has both ports open
        fw = machine.succeed("iptables -S nixos-fw 2>/dev/null || nft list ruleset")
        assert "7443" in fw and "7080" in fw, fw

    with subtest("the onboarding pages are served over plain HTTP"):
        page = machine.succeed("curl -sf -D - http://127.0.0.1:7080/pair")
        assert "intent://pair?" in page and "package=dev.nestlo.app" in page and "S.browser_fallback_url=" in page, page
        assert "no-store" in page.lower()
        app = machine.succeed("curl -sf http://127.0.0.1:7080/app")
        assert "https://github.com/anubhavg-icpl/nestlo/releases/latest/download/nestlo-android.apk" in app, app
        machine.fail("curl -sf http://127.0.0.1:7080/app/nestlo.apk")
        machine.fail("curl -sf http://127.0.0.1:7080/v1/info")

    with subtest("nestlo-mobile pair prints a QR code, the landing URL and the URI"):
        machine.succeed("nestlo-mobile pair --via lan --ttl 600 < /dev/null > /tmp/pair.txt 2>&1", timeout=120)
        out = machine.succeed("cat /tmp/pair.txt")
        assert "http://" in out and ":7080/pair#v=1&name=" in out, out
        assert "nestlo://pair?v=1&" in out and "&host=nestlo.test" in out, out
        assert any(c in out for c in "█▀▄"), out
        # an operator in the admin group may use it too, others may not
        machine.succeed("runuser -u alice -- nestlo-mobile devices")

    with subtest("the API port serves the onboarding pages too (one tunnel carries everything)"):
        page = machine.succeed("curl -skf https://127.0.0.1:7443/pair")
        assert "intent://pair?" in page, page
        assert "github.com/anubhavg-icpl/nestlo" in machine.succeed("curl -skf https://127.0.0.1:7443/app")
        machine.fail("curl -skf https://127.0.0.1:7443/v1/info")

    with subtest("quick tunnel through the stub: pair --via tunnel prints its URL in the QR text"):
        machine.fail("systemctl is-active nestlo-mobile-tunnel.service")
        out = machine.succeed("nestlo-mobile pair --via tunnel < /dev/null 2>&1", timeout=180)
        assert "https://fake-words-here.trycloudflare.com/pair#v=1&" in out, out
        assert "&url=https%3A%2F%2Ffake-words-here.trycloudflare.com&" in out, out
        assert "nestlo-mobile tunnel stop" in out, out
        machine.succeed("systemctl is-active nestlo-mobile-tunnel.service")
        ep = json.loads(machine.succeed("cat /run/nestlo-mobile/tunnel.json"))
        assert ep == {"provider": "cloudflare", "url": "https://fake-words-here.trycloudflare.com", "trust": "webpki"}, ep
        assert "fake-words-here" in machine.succeed("nestlo-mobile tunnel status")
        props = machine.succeed("systemctl show nestlo-mobile-tunnel -p ProtectSystem -p NoNewPrivileges")
        assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props, props

    with subtest("a raw TCP provider is listed as host:port; the tunnel can be switched and stopped"):
        out = machine.succeed("nestlo-mobile pair --provider bore < /dev/null 2>&1", timeout=180)
        assert "https://bore.pub:40123/pair#v=1&" in out and "&host=bore.pub%3A40123&" in out, out
        ep = json.loads(machine.succeed("cat /run/nestlo-mobile/tunnel.json"))
        assert ep == {"provider": "bore", "host": "bore.pub", "port": 40123, "trust": "pin"}, ep
        # a provider that is not enabled is refused before anything starts
        rc, out = machine.execute("nestlo-mobile pair --provider ngrok < /dev/null 2>&1", timeout=120)
        assert rc != 0 and "not configured" in out, (rc, out)
        machine.succeed("nestlo-mobile tunnel stop")
        machine.fail("systemctl is-active nestlo-mobile-tunnel.service")
        machine.fail("test -e /run/nestlo-mobile/tunnel.json")

    with subtest("pairing, REST, terminal, resize, events and revoke from a client"):
        res = machine.succeed("PYTHONPATH=${pkgs.nestlo.services}/${pkgs.python3.sitePackages} ${python}/bin/python ${client}")
        assert "CLIENT-OK" in res, res
        assert "no paired devices" in machine.succeed("nestlo-mobile devices")
  '';
}
