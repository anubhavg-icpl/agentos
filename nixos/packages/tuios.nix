# TUIOS: a terminal multiplexer and window manager for coding agents
# (Gaurav-Gosain/tuios, MIT). A daemon keeps sessions across detach and
# reboot; panes report agent state (working / needs input / done), there is an
# inbox for approvals, `fan` runs several agents in git worktrees, a JSON verb
# protocol and event stream on a 0700 socket, tape scripts, an MCP server, an
# SSH server (`tuios ssh`) and a web terminal (`tuios-web`).
#
# nixpkgs has 0.7.0, from before the agent features, so v0.8.5 is built here
# the way upstream's tuios.nix does: the two commands, pure Go, no CGO (the
# optional libghostty-vt emulator is not built).
{ lib
, buildGoModule
, fetchFromGitHub
, git
}:

buildGoModule rec {
  pname = "tuios";
  version = "0.8.5";

  src = fetchFromGitHub {
    owner = "Gaurav-Gosain";
    repo = "tuios";
    rev = "v${version}"; # 0f70da9dca4cc408b8617a048353b84872e8ec75
    hash = "sha256-NqR6rlkTYxNrGVjL0kNwt+iJ4DB5owins8Jv86LyRC4=";
  };

  vendorHash = "sha256-mESjrddAANoY8wE7QNnzTLaxE6ESe5UoVfwsRU10hzM=";

  subPackages = [ "cmd/tuios" "cmd/tuios-web" ];

  # go.mod asks for 1.26.6; no toolchain download in the sandbox
  env.GOTOOLCHAIN = "local";

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
    "-X main.builtBy=nix"
  ];

  # some cmd/tuios tests call git
  nativeCheckInputs = [ git ];

  meta = {
    description = "Terminal multiplexer and window manager with agent state, inbox, fan-out, SSH and web access";
    homepage = "https://github.com/Gaurav-Gosain/tuios";
    license = lib.licenses.mit;
    mainProgram = "tuios";
    platforms = lib.platforms.linux;
  };
}
