# Desktop smoke test.
#
#   nix build .#checks.x86_64-linux.desktop
#
# Boots a VM with the AgentOS desktop module (i3), logs in through LightDM
# autologin, and checks that:
#   - X and the display manager come up and i3 answers on its IPC socket,
#     with a version that has built-in gaps (>= 4.22)
#   - the shipped i3 config parses and the AgentOS session pieces started
#     (status bar, notification daemon, the hidden `agentos status` terminal)
#   - a terminal opens as a window
#   - the IDE binaries (VS Code, Zed) and the browser are installed
# and takes screenshots (in the test output) of the empty and populated
# desktop.
#
# The test uses the desktop module on its own, not the full agentos host:
# the toolchains and services of the server host are irrelevant to the
# desktop and would make the VM closure many GB larger. The full desktop
# host configurations are covered by evaluating agentos-desktop.
{ pkgs, agentosModules }:

pkgs.testers.runNixOSTest {
  name = "agentos-desktop";
  globalTimeout = 1800;

  nodes.machine = { ... }: {
    imports = agentosModules;

    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.resolution = { x = 1280; y = 800; };

    users.users.alice = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };

    agentos.desktop = {
      enable = true;
      windowManager = "i3";
      # picom needs GL; keep the VM test independent of the software renderer
      compositor = false;
      autologin = {
        enable = true;
        user = "alice";
      };
    };
  };

  testScript = ''
    import json

    def as_alice(cmd):
        return "su - alice -c 'DISPLAY=:0 XAUTHORITY=/home/alice/.Xauthority " + cmd + "'"

    start_all()
    machine.wait_for_unit("display-manager.service")
    machine.wait_for_x()
    machine.wait_for_file("/home/alice/.Xauthority")

    with subtest("i3 is running and answers on its IPC socket"):
        machine.wait_until_succeeds("pgrep -u alice -x i3")
        machine.wait_until_succeeds(as_alice("i3-msg -t get_version"), timeout=120)
        version = json.loads(machine.succeed(as_alice("i3-msg -t get_version")))
        assert (version["major"], version["minor"]) >= (4, 22), version
        socket = machine.succeed(as_alice("i3 --get-socketpath")).strip()
        machine.succeed("test -S " + socket)

    with subtest("the AgentOS i3 config is valid and in use"):
        machine.succeed(as_alice("i3 -C -c /etc/xdg/i3/config"))
        machine.succeed("grep -q 'gaps inner' /etc/xdg/i3/config")
        machine.succeed(as_alice("i3-msg -t get_bar_config | grep -q bar-"))

    with subtest("session services started"):
        machine.wait_until_succeeds("pgrep -u alice -x dunst")
        machine.wait_until_succeeds(as_alice("i3-msg -t get_tree | grep -q agentos-dash"), timeout=120)

    machine.screenshot("desktop-empty")

    with subtest("a terminal opens"):
        machine.succeed(as_alice("i3-msg \"exec alacritty --class testterm\""))
        machine.wait_until_succeeds(as_alice("i3-msg -t get_tree | grep -q testterm"), timeout=120)
        machine.sleep(3)
        machine.screenshot("desktop-terminal")

    with subtest("IDEs and browser are installed"):
        machine.succeed("command -v code")
        machine.succeed("command -v zeditor")
        machine.succeed("command -v firefox")
        machine.succeed("command -v rofi")
  '';
}
