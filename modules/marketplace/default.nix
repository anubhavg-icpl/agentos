# AgentOS agent marketplace
#
# `agentos-market` searches a registry of community coding agents
# (marketplace/index.json) and installs them into the operator's nix profile.
# An installed agent is registered in /var/lib/agentos/agents.d/<name>.json so
# `agentos spawn <name>` can run it in the sandbox. See docs/marketplace.md.
#
# The directory is writable by operators (group `agentos`) and read-only for
# the sandboxed agent user, which cannot register commands for itself.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.marketplace;
in
{
  options.agentos.marketplace = {
    enable = lib.mkEnableOption "agentos-market, the community agent registry";

    index = lib.mkOption {
      type = lib.types.path;
      default = ../../marketplace/index.json;
      description = "Registry file installed as /etc/agentos/marketplace.json";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.agentos.runtime.enable;
      message = "agentos.marketplace needs agentos.runtime.enable";
    }];

    environment.etc."agentos/marketplace.json".source = cfg.index;
    systemd.tmpfiles.rules = [
      "d /var/lib/agentos/agents.d 2775 root agentos"
    ];
    environment.systemPackages = [ pkgs.agentos.services ];
  };
}
