# Drop packages that cannot be built for the host platform, so the same
# module works on x86_64-linux and aarch64-linux (several toolchains and
# proprietary tools are x86_64-only).
#
#   let avail = import ../lib/available.nix { inherit pkgs lib; }; in
#   environment.systemPackages = avail (with pkgs; [ ... ]);
{ pkgs, lib }:
lib.filter (p: lib.meta.availableOn pkgs.stdenv.hostPlatform p)
