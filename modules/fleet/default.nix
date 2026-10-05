# Nestlo remote fleets
#
# `nestlo-fleet` drives other Nestlo hosts over SSH: status of every host,
# `nestlo spawn` and arbitrary commands on a remote host. Hosts declared in
# `nestlo.fleet.hosts` are written to /etc/nestlo/fleet.json; operators can
# add more with `nestlo-fleet add` (kept in ~/.config/nestlo/fleet.json).
#
# It uses the operator's own SSH keys and agent, and leaves host key checking
# at its default (strict). Pin remote host keys with programs.ssh.knownHosts
# or connect once by hand. See docs/fleet.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.fleet;

  hostsJson = pkgs.writeText "nestlo-fleet.json" (builtins.toJSON {
    hosts = lib.mapAttrs
      (_: h: { inherit (h) address port; } // lib.optionalAttrs (h.user != null) { inherit (h) user; })
      cfg.hosts;
  });
in
{
  options.nestlo.fleet = {
    enable = lib.mkEnableOption "nestlo-fleet, the remote Nestlo host manager";

    hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.str;
            example = "agents-1.example.org";
            description = "Host name or IP address";
          };
          user = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "admin";
            description = "SSH user (null: your ssh config decides)";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 22;
            description = "SSH port";
          };
        };
      });
      default = { };
      example = {
        build1 = { address = "10.0.0.5"; user = "admin"; };
      };
      description = "Remote Nestlo hosts, by name. Host names are lower-case letters, digits, `.`, `_` and `-`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = lib.all (n: builtins.match "[a-z0-9][a-z0-9._-]{0,62}" n != null) (lib.attrNames cfg.hosts);
      message = "nestlo.fleet.hosts: host names may only contain lower-case letters, digits, '.', '_' and '-'";
    }];

    environment.etc."nestlo/fleet.json".source = hostsJson;
    environment.systemPackages = [ pkgs.nestlo.services pkgs.openssh ];
  };
}
