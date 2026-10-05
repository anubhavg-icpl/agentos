# Nestlo Pullrun module (experimental)
#
# Pullrun is an OCI runtime that runs one image as a runc container or a
# Firecracker microVM. This module runs its daemon (`pullrun-runtime`) as a
# root systemd service for OPERATORS: whoever can open the daemon socket can
# run arbitrary images as root on this host. The socket is therefore kept in
# a directory that only root and the `nestlo` group (the operators) can
# enter, and the sandboxed agent user cannot reach it.
#
# On top of that, `agentContainers.enable` supports
# `nestlo spawn --isolation pullrun`: agents run in a Pullrun container on
# the shared `pullrun-br0` bridge. See docs/pullrun.md for what works.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.pullrun;
  ac = cfg.agentContainers;
  net = config.nestlo.networking;

  socketDir = "/run/pullrun";
  socket = "${socketDir}/pullrun.sock";
  logDir = "/var/lib/nestlo/pullrun-logs";

  # Hardcoded in Pullrun: the shared bridge for `--net bridge` workloads
  bridge = "pullrun-br0";
  bridgeAddress = "10.42.0.1";
  bridgePrefix = 16;

  pullrunCli = "${cfg.package}/bin/pullrun";
  # Never let the CLI spawn a daemon of its own (its default "direct mode")
  cliArgs = [ "--direct=false" "--socket" socket ];

  # What the daemon shells out to: runc for containers, ip/iptables for the
  # bridge, nsenter for exec, mkfs.ext4 for VM root disks, slirp4netns for VM
  # networking
  daemonPath = [
    pkgs.runc
    pkgs.iproute2
    pkgs.iptables
    pkgs.util-linux
    pkgs.coreutils
    pkgs.e2fsprogs
    pkgs.slirp4netns
  ];

  # Build context of the agent image: an almost empty root filesystem.
  # Everything the agent executes comes from the host's /nix/store, which
  # `nestlo spawn` bind-mounts read-only (as for --isolation container), so
  # the image does not carry a copy of the closure and works for every agent.
  agentImageContext = pkgs.runCommand "nestlo-pullrun-image-context" { } ''
    mkdir -p $out/rootfs/etc
    cat > $out/rootfs/etc/passwd <<'EOF'
    root:x:0:0:root:/root:/bin/sh
    EOF
    cat > $out/rootfs/etc/group <<'EOF'
    root:x:0:
    EOF
    echo "passwd: files" > $out/rootfs/etc/nsswitch.conf
    echo "group: files" >> $out/rootfs/etc/nsswitch.conf
    echo "hosts: files dns" >> $out/rootfs/etc/nsswitch.conf
    echo "nameserver ${bridgeAddress}" > $out/rootfs/etc/resolv.conf
    cat > $out/Dockerfile <<'EOF'
    FROM scratch
    COPY rootfs/ /
    ENV PATH=/run/current-system/sw/bin
    ENV SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
    ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
    CMD ["/run/current-system/sw/bin/bash"]
    EOF
  '';

  kernelPkg = import ./kernel.nix { inherit pkgs lib; };
in
{
  options.nestlo.pullrun = {
    enable = lib.mkEnableOption ''
      the Pullrun OCI runtime (containers and Firecracker microVMs). The
      daemon runs as root; operators in the nestlo group can run any image
      as root through it. Experimental'';

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.pullrun;
      defaultText = lib.literalExpression "pkgs.nestlo.pullrun";
      description = "Pullrun package (the `pullrun` CLI and `pullrun-runtime` daemon).";
    };

    storeRoot = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/pullrun";
      description = "Pullrun's image store and workload state.";
    };

    socket = lib.mkOption {
      type = lib.types.path;
      default = socket;
      readOnly = true;
      description = ''
        gRPC socket of the daemon, in a root:nestlo 0750 directory. The
        socket itself is root:nestlo 0660.
      '';
    };

    vm = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable the Firecracker microVM backend of the daemon. Needs
          /dev/kvm on the host, `nestlo.pullrun.kernel`, and (with the
          default kernel) a local kernel build the first time. Container
          workloads (`pullrun run --backend container`) work without it.
        '';
      };
    };

    firecracker = lib.mkOption {
      type = lib.types.package;
      default = pkgs.firecracker;
      defaultText = lib.literalExpression "pkgs.firecracker";
      description = "Firecracker package.";
    };

    kernel = lib.mkOption {
      type = lib.types.path;
      default = "${kernelPkg.dev}/vmlinux";
      defaultText = lib.literalExpression ''"''${kernel.dev}/vmlinux"'';
      description = ''
        Uncompressed `vmlinux` that Firecracker boots VMs with. The default
        is built from nixpkgs' 6.12 kernel with a Firecracker-guest config
        (modules/pullrun/kernel.nix): virtio-mmio/blk/net/vsock, ext4,
        devtmpfs and the serial console built in, because Pullrun boots with
        no initrd. nixpkgs has no ready-made Firecracker kernel and the
        stock NixOS kernels cannot boot this way (their storage drivers are
        modules). Set this to a store path of your own to avoid the local
        kernel build (for example a kernel from Firecracker's CI artifacts,
        fetched with `fetchurl` and a pinned hash).
      '';
    };

    agentContainers = {
      enable = lib.mkEnableOption ''
        `nestlo spawn --isolation pullrun` (experimental): the bridge
        ${bridge} for the containers, the model gateway on it, the firewall
        rules for it, and the agent image'';

      image = lib.mkOption {
        type = lib.types.str;
        default = "nestlo-agent:latest";
        description = ''
          Tag of the agent image in Pullrun's store. A systemd oneshot
          (pullrun-agent-image.service) builds it from a Nix-generated
          `FROM scratch` Dockerfile at boot. The image is almost empty: the
          host's /nix/store and system profile are bind-mounted read-only
          at spawn time. To use a different image (one the operator pushed
          to a registry and pulled, or one built with `pullrun build`), set
          this to its tag and set `buildImage = false`.
        '';
      };

      buildImage = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Build `image` at boot from the Nix-generated Dockerfile.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [{
        assertion = !ac.enable || (net.enable && config.nestlo.runtime.enable);
        message = "nestlo.pullrun.agentContainers.enable needs nestlo.networking.enable and nestlo.runtime.enable (model gateway and agent user)";
      }];

      environment.systemPackages = [ cfg.package cfg.firecracker pkgs.e2fsprogs ];

      users.groups.nestlo = { };

      # The socket directory: only root and the operators (group nestlo)
      # can reach the socket inside. The agent user cannot even stat it.
      systemd.tmpfiles.rules = [
        "d ${socketDir} 0750 root nestlo -"
        "d ${cfg.storeRoot} 0700 root root -"
      ];

      systemd.services.pullrun-runtime = {
        description = "Pullrun runtime daemon (OCI containers and Firecracker microVMs; root, operators only)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = daemonPath;
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.concatStringsSep " " ([
            "${cfg.package}/bin/pullrun-runtime"
            "daemon"
            "--socket"
            socket
            "--store-root"
            (toString cfg.storeRoot)
          ] ++ lib.optionals cfg.vm.enable [
            "--vm-firecracker"
            "${cfg.firecracker}/bin/firecracker"
            "--vm-kernel"
            (toString cfg.kernel)
            "--vm-root"
            "${cfg.storeRoot}/vm"
          ]);
          # The daemon creates its socket with mode 0700 (root only). Open it
          # to the operators; the directory above stays the outer gate.
          ExecStartPost = pkgs.writeShellScript "pullrun-socket-perms" ''
            for _ in $(seq 1 300); do
              [ -S ${socket} ] && break
              sleep 0.1
            done
            [ -S ${socket} ]
            ${pkgs.coreutils}/bin/chgrp nestlo ${socket}
            ${pkgs.coreutils}/bin/chmod 0660 ${socket}
          '';
          Restart = "on-failure";
          RestartSec = 3;
          UMask = "0077";

          # It has to be root and to manage namespaces, cgroups, mounts and
          # network devices, so the sandbox is loose. What does not need to
          # be reachable is closed.
          NoNewPrivileges = true;
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectClock = true;
          LockPersonality = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
        };
      };
    }

    # ── Containers for agents ───────────────────────────────────────────
    (lib.mkIf ac.enable {
      # The bridge exists before the first workload so the gateway can bind
      # to it; Pullrun reuses a bridge that is already there
      networking.bridges.${bridge}.interfaces = [ ];
      networking.interfaces.${bridge}.ipv4.addresses = [{
        address = bridgeAddress;
        prefixLength = bridgePrefix;
      }];
      networking.nat.internalInterfaces = [ bridge ];

      # The gateway listens on the bridge too (the list merges with the
      # networking module's own)
      nestlo.services.settings.gateway.listen = [ bridgeAddress ];
      systemd.services.nestlo-model-gateway = {
        after = [ "network-addresses-${bridge}.service" ];
        wants = [ "network-addresses-${bridge}.service" ];
      };
      services.dnsmasq.settings.listen-address =
        lib.mkIf config.services.dnsmasq.enable [ bridgeAddress ];
      systemd.services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
        after = [ "network-addresses-${bridge}.service" ];
        wants = [ "network-addresses-${bridge}.service" ];
      };

      # Output of the agents (their stdout is not captured by Pullrun) and the
      # per-agent passwd/group files; written by operators, `nestlo spawn`
      systemd.tmpfiles.rules = [ "d ${logDir} 2770 root nestlo -" ];

      # Like the nestlo0 rules of the networking module: the containers
      # reach the host only through the gateway (and DNS), and what they
      # forward goes through the same egress chain as the other containers.
      # The FORWARD jump is only there with nestlo.security.enable.
      networking.firewall.extraCommands = lib.mkAfter ''
        iptables -D INPUT -i ${bridge} -j pullrun-in 2>/dev/null || true
        iptables -F pullrun-in 2>/dev/null || iptables -N pullrun-in
        iptables -I INPUT 1 -i ${bridge} -j pullrun-in
        iptables -A pullrun-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A pullrun-in -d ${bridgeAddress} -p tcp --dport ${toString net.modelGatewayPort} -j ACCEPT
        iptables -A pullrun-in -d ${bridgeAddress} -p udp --dport 53 -j ACCEPT
        iptables -A pullrun-in -d ${bridgeAddress} -p tcp --dport 53 -j ACCEPT
        iptables -A pullrun-in -d ${bridgeAddress} -p icmp --icmp-type echo-request -j ACCEPT
        iptables -A pullrun-in -j REJECT
        ip6tables -D INPUT -i ${bridge} -j DROP 2>/dev/null || true
        ip6tables -I INPUT 1 -i ${bridge} -j DROP
        ip6tables -D FORWARD -i ${bridge} -j REJECT 2>/dev/null || true
        ip6tables -I FORWARD 1 -i ${bridge} -j REJECT
        ${lib.optionalString config.nestlo.security.enable ''
          iptables -D FORWARD -i ${bridge} -j nestlo-fwd 2>/dev/null || true
          iptables -I FORWARD 1 -i ${bridge} -j nestlo-fwd
        ''}
      '';
      networking.firewall.extraStopCommands = ''
        iptables -D INPUT -i ${bridge} -j pullrun-in 2>/dev/null || true
        iptables -F pullrun-in 2>/dev/null || true
        iptables -X pullrun-in 2>/dev/null || true
        iptables -D FORWARD -i ${bridge} -j nestlo-fwd 2>/dev/null || true
        ip6tables -D INPUT -i ${bridge} -j DROP 2>/dev/null || true
        ip6tables -D FORWARD -i ${bridge} -j REJECT 2>/dev/null || true
      '';

      systemd.services.pullrun-agent-image = lib.mkIf ac.buildImage {
        description = "Build the Pullrun agent image (${ac.image})";
        wantedBy = [ "multi-user.target" ];
        after = [ "pullrun-runtime.service" ];
        requires = [ "pullrun-runtime.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.concatStringsSep " " ([ pullrunCli ] ++ cliArgs ++ [
            "build"
            "${agentImageContext}/Dockerfile"
            "${agentImageContext}"
            "-t"
            ac.image
          ]);
        };
      };
    })
  ]);
}
