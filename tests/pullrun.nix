# Pullrun test.
#
#   nix build .#checks.x86_64-linux.pullrun
#
# Checks that the root daemon starts, that operators (group nestlo) can talk
# to it through its socket and the sandboxed agent user cannot even reach it,
# that the agent image is built, and that an agent runs in a Pullrun
# container with `nestlo spawn --isolation pullrun`: as the agent user
# without capabilities, with its output captured, reaching the model gateway
# on the pullrun-br0 bridge.
#
# The microVM backend is off: the test VM has no /dev/kvm to rely on, and
# the guest kernel is a local kernel build. `--isolation microvm` is only
# checked to fail clearly.
{ pkgs, nestloModules }:

let
  # Waits long enough for Pullrun to set up the bridge network of the
  # container (it reads the container's pid from runc, so a container that
  # is gone within milliseconds cannot be wired up), probes its surroundings,
  # and keeps its output in the log that `nestlo spawn` follows.
  fakeAgent = pkgs.writeShellApplication {
    name = "fake-agent";
    runtimeInputs = [ pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.iproute2 ];
    text = ''
      sleep 3
      echo "uid=$(id -u) user=$(id -un)"
      grep -E '^(CapEff|CapBnd|NoNewPrivs)' /proc/self/status
      echo "base-url=$ANTHROPIC_BASE_URL"
      echo "pwd=$PWD"
      ip -4 -o addr show eth0 | awk '{print "addr=" $4}' || true
      echo "gateway=$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://10.42.0.1:8080/_nestlo/health || true)"
      touch from-pullrun.txt
      if touch /nix/store/escape 2>/dev/null; then echo store-writable=yes; else echo store-writable=no; fi
      echo "args=$*"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "nestlo-pullrun";
  globalTimeout = 3600;

  nodes.machine = { ... }: {
    imports = nestloModules;

    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    users.users.admin = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
    security.sudo.wheelNeedsPassword = false;

    nestlo = {
      runtime = {
        enable = true;
        agents.fake = "fake-agent";
      };
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
        providers.openai.baseUrl = "http://127.0.0.1:9999";
      };
      pullrun = {
        enable = true;
        vm.enable = false;
        agentContainers.enable = true;
      };
    };

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };
    environment.systemPackages = [ fakeAgent ];
  };

  testScript = ''
    import json

    sock = "/run/pullrun/pullrun.sock"
    pr = f"pullrun --direct=false --socket {sock}"
    ws = "/var/lib/nestlo/workspaces/demo"

    def admin(cmd):
        return machine.succeed(f"su - admin -c {json.dumps(cmd)}")

    def as_agent(cmd):
        return machine.execute(f"su -s /bin/sh nestlo-agent -c {json.dumps(cmd)}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("pullrun-runtime.service")
    machine.wait_for_unit("nestlo-model-gateway.service")
    machine.wait_for_unit("pullrun-agent-image.service")

    with subtest("the daemon runs as root with its socket in an operators-only directory"):
        assert machine.succeed("systemctl show -p User --value pullrun-runtime.service").strip() == ""
        machine.succeed("test -S " + sock)
        assert machine.succeed("stat -c '%a %U %G' /run/pullrun").strip() == "750 root nestlo"
        assert machine.succeed(f"stat -c '%a %U %G' {sock}").strip() == "660 root nestlo"
        machine.succeed("pgrep -u root -f 'pullrun-runtime daemon'")

    with subtest("an operator can list workloads and images through the socket"):
        out = admin(f"{pr} list")
        print(out)
        assert "No workloads" in out, out
        images = json.loads(admin(f"{pr} images --json"))
        assert any(i["image_ref"] == "nestlo-agent:latest" for i in images), images

    with subtest("the sandboxed agent user cannot open the socket"):
        status, out = as_agent(f"{pr} list 2>&1")
        print(out)
        assert status != 0 and "No workloads" not in out, (status, out)
        status, out = as_agent(f"test -e {sock}")
        assert status != 0, "the agent user can see the socket"
        status, out = as_agent("ls /run/pullrun 2>&1")
        assert status != 0, out
        # nor can an arbitrary unprivileged user
        machine.succeed("useradd -m other")
        status, out = machine.execute(f"su other -c '{pr} list' 2>&1")
        assert status != 0, out

    with subtest("the bridge carries the model gateway"):
        machine.succeed("ip -4 addr show pullrun-br0 | grep -q 10.42.0.1")
        out = machine.succeed("curl -fsS http://10.42.0.1:8080/_nestlo/health")
        assert json.loads(out)["providers"]["anthropic"]["managed_key"], out

    admin("nestlo workspace create demo")

    with subtest("modes that cannot work fail clearly"):
        status, out = machine.execute(f"su - admin -c 'cd {ws} && nestlo spawn fake --isolation microvm' 2>&1")
        print(out)
        assert status != 0 and "Firecracker has no host mounts in Pullrun" in out, (status, out)
        status, out = machine.execute(f"su - admin -c 'cd {ws} && nestlo spawn fake --isolation pullrun --gpu' 2>&1")
        assert status != 0 and "--gpu is not supported" in out, (status, out)
        machine.fail("systemctl list-units --all 'nestlo-agent-*' | grep -q nestlo-agent")

    with subtest("an agent runs in a Pullrun container as the agent user without capabilities"):
        out = admin(f"cd {ws} && nestlo spawn fake --isolation pullrun -- one,two 2>&1")
        print(out)
        assert "uid=" in out and "user=nestlo-agent" in out, out
        assert "CapEff:\t0000000000000000" in out and "CapBnd:\t0000000000000000" in out, out
        assert "NoNewPrivs:\t1" in out, out
        assert "args=one,two" in out, out
        assert "store-writable=no" in out, out
        assert f"pwd={ws}" in out, out
        # reaches the gateway on the bridge, with the per-agent token URL
        assert "gateway=200" in out, out
        assert "base-url=http://10.42.0.1:8080/agent/fake-" in out and out.count("/anthropic") >= 1, out
        assert "addr=10.42." in out, out
        # files written by the agent belong to the agent user
        owner = machine.succeed(f"stat -c %U {ws}/from-pullrun.txt").strip()
        assert owner == "nestlo-agent", owner
        state = json.loads(machine.succeed("cat /var/lib/nestlo/state/fake-*.json"))
        assert state["isolation"] == "pullrun" and "unit" not in state, state
  '';
}
