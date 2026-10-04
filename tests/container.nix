# Container isolation test.
#
#   nix build .#checks.x86_64-linux.container
#
# Spawns a fake agent with `agentos spawn --isolation container` and checks,
# from inside the agent and from the host, that it runs in its own mount,
# PID, hostname and network namespaces, reaches the model gateway (and
# through it the mock LLM) at the bridge address 10.200.0.1:8080, cannot
# reach the host's other services, cannot write outside its workspace, and
# that the network namespace and veth are removed when the unit ends.
#
# There is no GPU in the VM: `agentos gpu` and `spawn --gpu` are checked for
# graceful absence only.
{ pkgs, agentosModules }:

let
  # Mock of the Anthropic Messages API
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { flakeIgnore = [ "E501" ]; } ''
    import http.server
    import json


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            with open("/var/lib/mock-llm/requests.jsonl", "a") as f:
                f.write(json.dumps({"path": self.path,
                                    "key": self.headers.get("x-api-key")}) + "\n")
            data = json.dumps({"id": "msg_test", "type": "message",
                               "model": body.get("model", "claude-sonnet-5-5"),
                               "content": [{"type": "text", "text": "ok"}],
                               "usage": {"input_tokens": 1000, "output_tokens": 10}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
  '';

  # A host service on all addresses, with its port open in the firewall:
  # containers still must not reach it
  hostService = pkgs.writeShellScript "host-service" ''
    exec ${pkgs.python3}/bin/python3 -m http.server 7777 --bind 0.0.0.0 --directory /var/empty
  '';

  # Probes its surroundings, records the results in the workspace, then
  # idles for $1 seconds (default 600).
  fakeAgent = pkgs.writeShellApplication {
    name = "fake-agent";
    runtimeInputs = [ pkgs.curl pkgs.coreutils pkgs.procps pkgs.iproute2 pkgs.git pkgs.gawk pkgs.gnugrep pkgs.util-linux pkgs.python3 ];
    text = ''
      yesno() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

      id -un > whoami.txt
      for ns in mnt net pid ipc uts; do
        echo "$ns $(readlink "/proc/self/ns/$ns")"
      done > namespaces.txt
      ps -A -o pid=,comm= > ps.txt
      ls /sys/class/net > ifaces.txt
      ip -4 -o addr show eth0 | awk '{print $4}' > address.txt || true
      ip route show default > route.txt
      cat /etc/resolv.conf > resolv.txt
      ls / > rootdir.txt
      echo "$ANTHROPIC_BASE_URL" > base-url.txt

      # Filesystem: only the workspace and the agent's home are writable
      yesno touch ./ok.txt > write-workspace.txt
      yesno touch "$HOME/ok.txt" > write-home.txt
      yesno touch /etc/escape > write-etc.txt
      yesno touch /nix/store/escape > write-store.txt
      yesno touch /var/lib/agentos/escape > write-agentos.txt
      yesno touch /usr/escape > write-usr.txt
      yesno test -e /run/redis-agentos/redis.sock > sees-redis.txt
      yesno test -e /run/agentos-gateway/admin.sock > sees-admin.txt
      yesno test -e /var/lib/agentos/state > sees-state.txt
      yesno test -e /etc/agentos/services.toml > sees-config.txt

      # Tools
      git rev-parse --git-dir > git.txt 2>&1 || echo failed > git.txt
      yesno test -s /etc/ssl/certs/ca-bundle.crt > has-ca-bundle.txt
      curl --version | grep -c https > curl-https.txt || true

      # Network: the gateway and the LLM behind it are reachable ...
      curl -s -m 5 -o /dev/null -w '%{http_code}' http://10.200.0.1:8080/_agentos/health > gateway-health.txt || true
      # ... but not with admin rights, and nothing else on the host is
      curl -s -m 5 -o /dev/null -w '%{http_code}' -X PUT -d '{"daily_usd": 999}' \
        http://10.200.0.1:8080/_agentos/budget/anyone > gateway-admin.txt || true
      curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/_agentos/health > loopback-gateway.txt || true
      curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:9999/ > loopback-llm.txt || true
      curl -s -m 3 -o /dev/null -w '%{http_code}' http://10.200.0.1:7777/ > host-service.txt || true
      curl -s -m 3 -o /dev/null -w '%{http_code}' http://10.200.0.1:9950/metrics > host-metrics.txt || true
      # Provider APIs directly (not via the gateway)
      curl -s -m 3 -o /dev/null -w '%{http_code}' https://api.anthropic.com/ > direct-provider.txt || true

      # Kernel-surface hardening: no user namespaces, no raw sockets, no cloud metadata
      yesno unshare -U true > userns.txt
      yesno python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)' > rawsock.txt
      yesno python3 -c 'import socket; socket.socket(socket.AF_PACKET, socket.SOCK_RAW)' > packet-sock.txt
      curl -s -m 3 -o /dev/null -w '%{http_code}' http://169.254.169.254/ > metadata.txt || true

      code=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "x-api-key: $ANTHROPIC_API_KEY" -H 'content-type: application/json' \
        -d '{"model": "claude-sonnet-5-5", "max_tokens": 16, "messages": []}' \
        "$ANTHROPIC_BASE_URL/v1/messages")
      echo "$code" > llm.txt
      touch done.txt
      sleep "''${1:-600}"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "agentos-container";
  globalTimeout = 3600;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    agentos = {
      runtime = {
        enable = true;
        agents.fake = "fake-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/agentos-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      budget-controller.enable = true;
      security = {
        enable = true;
        defaultEgress = "deny";
        gatewayOnlyDomains = [ "api.anthropic.com" ];
      };
    };

    environment.etc."agentos-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "agentos";
    };

    environment.systemPackages = [ fakeAgent pkgs.iproute2 ];
    networking.firewall.allowedTCPPorts = [ 7777 ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "agentos-model-gateway.service" ];
      serviceConfig = {
        ExecStart = "${mockLlm}/bin/mock-llm";
        StateDirectory = "mock-llm";
      };
    };
    systemd.services.host-service = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = hostService;
    };
  };

  testScript = ''
    import json

    ws = "/var/lib/agentos/workspaces/demo"

    def admin(cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def state_ids():
        return set(machine.succeed("ls /var/lib/agentos/state | grep '[.]json$' || true").split())

    def spawn(*args):
        """Start an agent in the background; returns its id."""
        before = state_ids()
        machine.succeed(
            "setsid -f su - admin -c "
            f"'cd {ws} && agentos spawn fake {' '.join(args)}' "
            ">/tmp/spawn.log 2>&1 </dev/null"
        )
        retry(lambda _: bool(state_ids() - before), timeout_seconds=60)
        return (state_ids() - before).pop()[:-5]

    def wait_probes():
        machine.wait_until_succeeds(f"test -f {ws}/done.txt", timeout=120)

    def ws_file(name):
        return machine.succeed(f"cat {ws}/{name}").strip()

    def leftovers():
        return {
            "netns": machine.succeed("ip netns list").strip(),
            "veth": machine.succeed("ip -o link show type veth").strip(),
            "state": machine.succeed("ls /run/agentos/net 2>/dev/null || true").strip(),
        }

    machine.wait_for_unit("multi-user.target")
    for unit in ["redis-agentos.service", "agentos-model-gateway.service",
                 "agentos-daemon.service", "mock-llm.service", "host-service.service", "dnsmasq.service"]:
        machine.wait_for_unit(unit)
    machine.wait_for_open_port(8080)

    with subtest("the gateway also listens on the agent bridge"):
        machine.succeed("ip -4 addr show agentos0 | grep -q 10.200.0.1")
        out = machine.succeed("curl -fsS http://10.200.0.1:8080/_agentos/health")
        assert json.loads(out)["providers"]["anthropic"]["managed_key"], out
        machine.succeed("curl -fsS http://127.0.0.1:8080/_agentos/health")

    admin("agentos workspace create demo")

    with subtest("GPU absence is handled gracefully"):
        assert "No GPUs" in admin("agentos gpu")
        status, out = machine.execute(f"su - admin -c 'cd {ws} && agentos spawn fake --gpu' 2>&1")
        print(out)
        assert status != 0 and "GPU" in out, (status, out)
        machine.fail("systemctl list-units --all 'agentos-agent-*' | grep -q agentos-agent")

    with subtest("bad isolation modes are refused"):
        machine.fail(f"su - admin -c 'cd {ws} && agentos spawn fake --isolation vm'")
        machine.fail(f"su - admin -c 'cd {ws} && agentos spawn fake --unsandboxed --isolation container'")

    with subtest("spawn a container-isolated agent"):
        agent = spawn("--isolation", "container", "--budget", "3")
        print("agent id:", agent)
        wait_probes()
        state = json.loads(machine.succeed(f"cat /var/lib/agentos/state/{agent}.json"))
        assert state["isolation"] == "container" and state["sandboxed"], state
        assert "isolation: container" in machine.succeed("cat /tmp/spawn.log")

    with subtest("own root filesystem: read-only except workspace and home"):
        assert ws_file("whoami.txt") == "agentos-agent"
        assert ws_file("write-workspace.txt") == "yes"
        assert ws_file("write-home.txt") == "yes"
        for name in ["etc", "store", "agentos", "usr"]:
            assert ws_file(f"write-{name}.txt") == "no", name
        # the control plane is not part of the container's view
        for name in ["redis", "admin", "state", "config"]:
            assert ws_file(f"sees-{name}.txt") == "no", name
        rootdir = ws_file("rootdir.txt").split()
        assert "home" not in rootdir and "root" not in rootdir, rootdir
        machine.fail("test -e /var/lib/agentos/escape")

    with subtest("tools work inside: git and the TLS trust store"):
        assert ws_file("git.txt") == ".git"
        assert ws_file("has-ca-bundle.txt") == "yes"
        assert int(ws_file("curl-https.txt")) >= 1

    with subtest("own mount, net, PID, IPC and hostname namespaces"):
        seen = dict(line.split(" ", 1) for line in ws_file("namespaces.txt").splitlines())
        assert set(seen) == {"mnt", "net", "pid", "ipc", "uts"}, seen
        for ns, target in seen.items():
            host_target = machine.succeed(f"readlink /proc/1/ns/{ns}").strip()
            assert target != host_target, (ns, target, host_target)
        procs = ws_file("ps.txt").splitlines()
        print("processes seen by the agent:", procs)
        assert 0 < len(procs) <= 12, procs
        assert not any(w in p for p in procs for w in ("redis", "python", "dnsmasq", "sshd", "agentos")), procs
        # `agentos shell` enters the same namespaces
        out = admin(f"printf 'ps -A -o comm=\\nreadlink /proc/self/ns/pid\\nreadlink /proc/self/ns/net\\n' | agentos shell {agent}")
        print(out)
        assert "dnsmasq" not in out and "redis" not in out, out
        assert seen["pid"] in out and seen["net"] in out, (seen, out)

    with subtest("own network namespace on the bridge"):
        assert ws_file("ifaces.txt").split() == ["eth0", "lo"], ws_file("ifaces.txt")
        addr = ws_file("address.txt")
        assert addr.startswith("10.200.0.") and addr.endswith("/24") and addr != "10.200.0.1/24", addr
        assert ws_file("route.txt").startswith("default via 10.200.0.1"), ws_file("route.txt")
        assert ws_file("resolv.txt") == "nameserver 10.200.0.1"
        base = ws_file("base-url.txt")
        assert base.startswith(f"http://10.200.0.1:8080/agent/{agent}:") and base.endswith("/anthropic"), base
        assert f"agentos-{agent}" in machine.succeed("ip netns list")
        machine.succeed("ip -o link show type veth | grep -q agentos0")
        machine.succeed("bridge -d link | grep -q 'isolated on'")

    with subtest("reaches the gateway and the mock LLM through it"):
        assert ws_file("gateway-health.txt") == "200"
        assert ws_file("llm.txt") == "200"
        seen = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/requests.jsonl").splitlines()]
        assert seen and all(r["key"] == "sk-test-real-key" for r in seen), seen
        spend = json.loads(admin("agentos budget status --json"))["agents"][agent]
        assert spend["usd"] > 0, spend

    with subtest("cannot reach anything else on the host"):
        assert ws_file("gateway-admin.txt") == "403"
        for name in ["loopback-gateway", "loopback-llm", "host-service", "host-metrics", "direct-provider"]:
            assert ws_file(f"{name}.txt") in ("000", ""), (name, ws_file(f"{name}.txt"))
        # kernel-surface hardening and the default-deny forward policy
        assert ws_file("userns.txt") == "no"
        assert ws_file("rawsock.txt") == "no"
        assert ws_file("packet-sock.txt") == "no"
        assert ws_file("metadata.txt") in ("000", ""), ws_file("metadata.txt")
        fwd = machine.succeed("iptables -S agentos-fwd")
        assert "-d 169.254.169.254/32 -j REJECT" in fwd and "-o agentos0 -j REJECT" in fwd, fwd
        for net in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]:
            assert f"-d {net} -j REJECT" in fwd, net
        # the unit carries the syscall and namespace restrictions
        props = machine.succeed(f"systemctl show agentos-agent-{agent}.service -p RestrictNamespaces -p MemorySwapMax -p MemoryDenyWriteExecute")
        assert "RestrictNamespaces=yes" in props and "MemorySwapMax=0" in props, props
        assert "MemoryDenyWriteExecute=no" in props, props
        # the same service is reachable from the host itself
        machine.succeed("curl -fsS -m 5 http://10.200.0.1:7777/ >/dev/null")
        rules = machine.succeed("iptables -S agentos-fwd")
        print(rules)
        assert "agentos-llm" in rules and "REJECT" in rules
        assert "agentos-in" in machine.succeed("iptables -S INPUT")

    with subtest("two containers get different addresses"):
        other = spawn("--isolation", "container")
        machine.wait_until_succeeds(f"test -s /run/agentos/net/{other}/ip", timeout=60)
        ips = {machine.succeed(f"cat /run/agentos/net/{a}/ip").strip() for a in (agent, other)}
        assert len(ips) == 2, ips
        admin(f"agentos kill {other}")
        machine.wait_until_fails(f"test -e /run/agentos/net/{other}", timeout=30)

    with subtest("namespace and veth are removed when the agent is stopped"):
        admin(f"agentos kill {agent}")
        machine.wait_until_fails(f"systemctl is-active agentos-agent-{agent}.service", timeout=30)
        machine.wait_until_succeeds("test -z \"$(ip netns list)\"", timeout=30)
        left = leftovers()
        print(left)
        assert left == {"netns": "", "veth": "", "state": ""}, left

    with subtest("stale namespaces and veths are swept"):
        machine.succeed("ip netns add agentos-stale-1")
        machine.succeed("ip link add avhdeadbeef type veth peer name avcdeadbeef")
        machine.succeed("$(jq -r .container.netns_helper /etc/agentos/runtime.json) sweep")
        assert "agentos-stale-1" not in machine.succeed("ip netns list")
        machine.fail("ip link show avhdeadbeef")

    with subtest("namespace and veth are removed when the agent exits by itself"):
        machine.succeed(f"rm -f {ws}/done.txt")
        short = spawn("--isolation", "container", "--", "1")
        wait_probes()
        machine.wait_until_fails(f"systemctl is-active agentos-agent-{short}.service", timeout=60)
        machine.wait_until_succeeds("test -z \"$(ip netns list)\"", timeout=30)
        assert leftovers() == {"netns": "", "veth": "", "state": ""}, leftovers()
        machine.wait_until_succeeds(f"test -f /var/lib/agentos/state/history/{short}.json", timeout=60)

    with subtest("sandbox mode is unchanged"):
        machine.succeed(f"rm -f {ws}/done.txt")
        plain = spawn()
        wait_probes()
        assert json.loads(machine.succeed(f"cat /var/lib/agentos/state/{plain}.json"))["isolation"] == "sandbox"
        base = ws_file("base-url.txt")
        assert base.startswith(f"http://127.0.0.1:8080/agent/{plain}:") and base.endswith("/anthropic"), base
        assert leftovers()["netns"] == ""
        admin(f"agentos kill {plain}")
  '';
}
