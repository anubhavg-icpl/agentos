# VM test of Nestlo Cloud (nestlo.cloud, docs/cloud.md).
#
#   nix build .#checks.x86_64-linux.cloud
#
# Boots a host with the control plane, the VM helper, the lobby, Caddy
# (internal TLS) and the resolver; alice (a declared user with an SSH key)
# then creates a VM over SSH, opens a shell in it, serves HTTP from it through
# the private proxy (login refused, public after set-public), calls the HTTPS
# API with a token she minted, and reaches the reflection integration, the
# metadata service and an http-proxy integration (which injects a secret
# the VM never sees) from inside the VM.
{ pkgs, nestloModules }:

let
  domain = "cloud.test";
  # nixpkgs' well-known test key pair (no import from derivation)
  snakeoil = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  aliceKey = snakeoil.snakeOilEd25519PrivateKey;
  upstream = pkgs.writers.writePython3Bin "upstream" { } ''
    import http.server
    import json


    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = json.dumps({"auth": self.headers.get("Authorization")}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass


    http.server.HTTPServer(("127.0.0.1", 9997), H).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "nestlo-cloud";
  globalTimeout = 2400;

  nodes.machine = { lib, ... }: {
    imports = nestloModules;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.diskSize = 8192;

    nestlo.runtime.enable = true;
    nestlo.cloud = {
      enable = true;
      inherit domain;
      verifyDns = false;
      llm.enable = false;
      agentUi.enable = false;
      image.packages = with pkgs; [ coreutils curl iproute2 openssh python3 ];
      defaultDiskGB = 1;
      users = [{ email = "alice@example.com"; admin = true; keys = [ snakeoil.snakeOilEd25519PublicKey ]; }];
      integrations = [{
        name = "secret-api";
        type = "http-proxy";
        target = "http://127.0.0.1:9997";
        bearerFile = "/etc/nestlo-test/api-token";
        attach = [ "auto:all" ];
      }];
    };
    environment.etc."nestlo-test/api-token" = { text = "tok-never-in-the-vm"; user = "nestlo-cloud"; mode = "0400"; };
    networking.hosts."127.0.0.1" = [ domain "web.${domain}" "web-8000.${domain}" ];
    environment.systemPackages = [ pkgs.jq pkgs.curl ];
    systemd.services.upstream = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${upstream}/bin/upstream";
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-nestlo.service", "nestlo-cloud-vmd.service", "nestlo-cloud.service",
                 "caddy.service", "sshd.service", "nestlo-cloud-dns.service"]:
        machine.wait_for_unit(unit)
    machine.succeed("install -Dm600 ${aliceKey} /root/.ssh/id_ed25519")
    machine.succeed("printf 'Host *\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n' > /root/.ssh/config")
    lobby = "ssh -o BatchMode=yes lobby@localhost"

    with subtest("the lobby knows alice and nobody else"):
        try:
            out = json.loads(machine.succeed(lobby + " whoami --json"))
        except Exception:
            print(machine.execute("journalctl --no-pager -u sshd -u 'sshd@*' -u nestlo-cloud | tail -60")[1])
            print(machine.execute("sudo -u lobby /etc/ssh/nestlo-cloud-keys ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDPQXmEVMVLmeFRyafKMVWgPDkv8/uRBTwmcEDatZzMD 2>&1")[1])
            raise
        assert out["email"] == "alice@example.com" and out["admin"], out
        machine.succeed("ssh-keygen -q -t ed25519 -N ''' -f /root/stranger")
        out = machine.fail("ssh -o BatchMode=yes -i /root/stranger lobby@localhost ls 2>&1")

    with subtest("new VM, shell, and HTTP through the private proxy"):
        out = json.loads(machine.succeed(lobby + " new --name web --port 8000 --json"))
        assert out["https_url"] == "https://web.${domain}/", out
        machine.wait_until_succeeds(lobby + " ssh web true", timeout=120)
        assert machine.succeed(lobby + " ssh web cat /etc/hostname").strip() == "web"
        machine.succeed(lobby + " ssh web 'nohup python3 -m http.server 8000 --directory /etc </dev/null >/dev/null 2>&1 &'")
        machine.wait_until_succeeds("curl -sk -o /dev/null -w '%{http_code}' https://web.${domain}/hostname | grep -q 401", timeout=60)
        machine.succeed(lobby + " share set-public web")
        machine.wait_until_succeeds("curl -sk https://web.${domain}/hostname | grep -q web", timeout=60)

    with subtest("the HTTPS API with a minted token"):
        tok = json.loads(machine.succeed(lobby + " ssh-key generate-api-key --cmds=ls --exp=1h --json"))["token"]
        out = machine.succeed(f"curl -sk -X POST https://${domain}/exec -H 'Authorization: Bearer {tok}' -d 'ls'")
        assert json.loads(out)["vms"][0]["vm_name"] == "web", out
        code = machine.succeed(f"curl -sk -o /dev/null -w '%{{http_code}}' -X POST https://${domain}/exec -H 'Authorization: Bearer {tok}' -d 'rm web'")
        assert code == "403", code

    with subtest("integrations, reflection and metadata from inside the VM"):
        meta = json.loads(machine.succeed(lobby + " ssh web curl -s http://169.254.169.254/"))
        assert meta["reflection_url"] == "http://reflection.int.${domain}", meta
        refl = json.loads(machine.succeed(lobby + " ssh web curl -s http://reflection.int.${domain}/integrations"))
        assert any(i["name"] == "secret-api" for i in refl["integrations"]), refl
        got = json.loads(machine.succeed(lobby + " ssh web curl -s http://secret-api.int.${domain}/"))
        assert got["auth"] == "Bearer tok-never-in-the-vm", got
        machine.fail(lobby + " ssh web grep -r tok-never-in-the-vm /.nestlo /etc /root")

    with subtest("the VM cannot reach the host's other services"):
        machine.fail(lobby + " ssh web curl -s -m 3 http://10.210.0.1:${toString 9940}/")

    with subtest("stop, start, and delete"):
        machine.succeed(lobby + " stop web")
        machine.fail(lobby + " ssh web true")
        machine.succeed(lobby + " rm web")
        assert json.loads(machine.succeed(lobby + " ls --json"))["vms"] == []
  '';
}
