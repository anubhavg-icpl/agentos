# Nestlo agent marketplace
#
# `nestlo-market` searches a registry of community coding agents
# (marketplace/index.json) and installs them into the operator's nix profile.
# An installed agent is registered in /var/lib/nestlo/agents.d/<name>.json so
# `nestlo spawn <name>` can run it in the sandbox. See docs/marketplace.md.
#
# The directory is writable by operators (group `nestlo`) and read-only for
# the sandboxed agent user, which cannot register commands for itself.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.marketplace;
in
{
  options.nestlo.marketplace = {
    enable = lib.mkEnableOption "nestlo-market, the community agent registry";

    index = lib.mkOption {
      type = lib.types.path;
      default = ../../marketplace/index.json;
      description = "Registry file installed as /etc/nestlo/marketplace.json";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.nestlo.runtime.enable;
      message = "nestlo.marketplace needs nestlo.runtime.enable";
    }];

    environment.etc."nestlo/marketplace.json".source = cfg.index;
    systemd.tmpfiles.rules = [
      "d /var/lib/nestlo/agents.d 2775 root nestlo"
    ];
    environment.systemPackages = [ pkgs.nestlo.services ];
  };
}
