# ═══════════════════════════════════════════════════════════════════════
# Nestlo Agent Runtime Security
# ═══════════════════════════════════════════════════════════════════════
#
# eBPF runtime monitoring of agent processes with Tetragon
# (https://tetragon.io; Apache-2.0 userspace, GPL-2.0 BPF programs):
#
#   nestlo-tetragon.service            the engine; loads the TracingPolicies
#                                      below and exports JSON events to
#                                      /var/log/tetragon/tetragon.json
#   nestlo-agent-security-forwarder    tails that file, keeps the events of
#                                      agent users, writes alerts to
#                                      /var/log/nestlo-agent-runtime-security,
#                                      sends them to the Nestlo audit writer,
#                                      exposes Prometheus counters and, only
#                                      in enforce mode, kills the process
#
# What is watched (each a TracingPolicy named nestlo-ars-<rule>):
#   credential-access   opening credential files: /run/secrets, provider key
#                       files (nestlo.networking.providers.*.keyFile),
#                       Nestlo secret/audit/API-key state, SSH host keys and
#                       private keys, cloud/CLI credential files
#   write-protected     writes to system locations (/etc, /usr, ...)
#   write-outside-workspace   (off) every write outside the workspace
#   raw-socket          AF_PACKET sockets and SOCK_RAW on IPv4/IPv6
#   ptrace              attach/seize/poke/set-registers and process_vm_writev
#   kernel-module       init_module, finit_module, delete_module
#   egress-bypass       TCP connect to port 443 beyond loopback, that is,
#                       not through the model gateway on 127.0.0.1
#
# Tetragon has no uid selector for kernel hooks. The policies therefore
# match on what is touched, and the forwarder applies "is this one of the
# agent users" (uid) before anything is alerted or killed. That is also why
# enforcement is done by the forwarder (after the fact, uid-checked) and the
# in-kernel Sigkill is a separate, global, opt-in switch.
#
# Default mode: observe only. See docs/agent-runtime-security.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.agentRuntimeSecurity;
  rt = config.nestlo.runtime;
  pol = cfg.policies;

  exportDir = dirOf cfg.export.file;
  alertsDir = "/var/log/nestlo-agent-runtime-security";
  runDir = "/run/tetragon";
  loopbackAddrs = [ "127.0.0.0/8" "::1" ];

  # Provider API key files the gateway injects (never readable by agents)
  providerKeyFiles = lib.filter (p: p != null && lib.hasPrefix "/" p)
    (lib.mapAttrsToList (_: p: p.keyFile) config.nestlo.networking.providers);

  credentialPrefixes = lib.unique (
    pol.credentialAccess.paths
    ++ lib.optionals pol.credentialAccess.providerKeyFiles providerKeyFiles
  );

  # ── TracingPolicy builders ───────────────────────────────────────────
  # https://tetragon.io/docs/concepts/tracing-policy/
  policy = rule: spec: {
    apiVersion = "cilium.io/v1alpha1";
    kind = "TracingPolicy";
    metadata.name = "nestlo-ars-${rule}";
    spec = { kprobes = map (k: k // { tags = [ "nestlo" "agent-runtime-security" rule ]; }) spec; };
  };

  sigkillOn = rule:
    cfg.enforcement.sigkill.enable && builtins.elem rule [ "raw-socket" "ptrace" "kernel-module" ];
  # Applied to every selector of a rule that may kill in the kernel
  killSel = rule: sel:
    sel
    // lib.optionalAttrs (sigkillOn rule) {
      matchActions = [{ action = "Post"; } { action = "Sigkill"; }];
    }
    // lib.optionalAttrs (sigkillOn rule && cfg.enforcement.sigkill.exemptBinaries != [ ]) {
      matchBinaries = [{ operator = "NotPostfix"; values = cfg.enforcement.sigkill.exemptBinaries; }];
    };

  fileArg = { index = 0; type = "file"; };

  policies = lib.filterAttrs (_: v: v != null) {
    credential-access = lib.optionalAttrs pol.credentialAccess.enable (policy "credential-access" [{
      call = "security_file_open";
      syscall = false;
      message = "Agent process opened a credential file";
      args = [ fileArg ];
      selectors = [
        { matchArgs = [{ index = 0; operator = "Prefix"; values = credentialPrefixes; }]; }
      ] ++ lib.optional (pol.credentialAccess.fileSuffixes != [ ]) {
        matchArgs = [{ index = 0; operator = "Postfix"; values = pol.credentialAccess.fileSuffixes; }];
      };
    }]);

    write-protected = lib.optionalAttrs pol.writeProtected.enable (policy "write-protected" [{
      call = "security_file_permission";
      syscall = false;
      message = "Agent process wrote to a protected system location";
      args = [ fileArg { index = 1; type = "int"; } ];
      selectors = [{
        matchArgs = [
          { index = 0; operator = "Prefix"; values = pol.writeProtected.paths; }
          { index = 1; operator = "Equal"; values = [ "2" ]; } # MAY_WRITE
        ];
      }];
    }]);

    write-outside-workspace = lib.optionalAttrs pol.writeOutsideWorkspace.enable (policy "write-outside-workspace" [{
      call = "security_file_permission";
      syscall = false;
      message = "Agent process wrote outside its workspace";
      args = [ fileArg { index = 1; type = "int"; } ];
      selectors = [{
        matchArgs = [
          { index = 0; operator = "NotPrefix"; values = pol.writeOutsideWorkspace.allowedPaths; }
          { index = 1; operator = "Equal"; values = [ "2" ]; }
        ];
      }];
    }]);

    # security_socket_create(family, type, protocol, kern): netlink sockets are
    # SOCK_RAW too, so SOCK_RAW only counts on AF_INET/AF_INET6; kern = 0 is a
    # socket created for userspace
    raw-socket = lib.optionalAttrs pol.rawSockets.enable (policy "raw-socket" [{
      call = "security_socket_create";
      syscall = false;
      message = "Agent process created a raw or packet socket";
      args = [
        { index = 0; type = "int"; }
        { index = 1; type = "int"; }
        { index = 2; type = "int"; }
        { index = 3; type = "int"; }
      ];
      selectors = map (killSel "raw-socket") [
        {
          matchArgs = [
            { index = 0; operator = "Equal"; values = [ "2" "10" ]; } # AF_INET, AF_INET6
            { index = 1; operator = "Equal"; values = [ "3" ]; } # SOCK_RAW
            { index = 3; operator = "Equal"; values = [ "0" ]; }
          ];
        }
        {
          matchArgs = [
            { index = 0; operator = "Equal"; values = [ "17" ]; } # AF_PACKET
            { index = 3; operator = "Equal"; values = [ "0" ]; }
          ];
        }
      ];
    }]);

    # request: POKETEXT 4, POKEDATA 5, POKEUSR 6, SETREGS 13, SETFPREGS 15,
    # ATTACH 16, SEIZE 0x4206
    ptrace = lib.optionalAttrs pol.ptrace.enable (policy "ptrace" [
      {
        call = "sys_ptrace";
        syscall = true;
        message = "Agent process used ptrace on another process";
        args = [ { index = 0; type = "int"; } { index = 1; type = "int"; } ];
        selectors = map (killSel "ptrace") [{
          # more than 4 values: Equal is limited to 4, InMap is not
          matchArgs = [{ index = 0; operator = "InMap"; values = [ "4" "5" "6" "13" "15" "16" "16902" ]; }];
        }];
      }
      {
        call = "sys_process_vm_writev";
        syscall = true;
        message = "Agent process wrote into another process (process_vm_writev)";
        args = [ { index = 0; type = "int"; } ];
        selectors = map (killSel "ptrace") [{ }];
      }
    ]);

    kernel-module = lib.optionalAttrs pol.kernelModules.enable (policy "kernel-module" (map
      (call: {
        inherit call;
        syscall = true;
        message = "Agent process loaded or unloaded a kernel module";
        selectors = map (killSel "kernel-module") [{ }];
      })
      [ "sys_init_module" "sys_finit_module" "sys_delete_module" ]));

    # Matches TCP connects (tcp_connect, the SYN being sent) to the listed
    # ports whose destination is not loopback (the model gateway is 127.0.0.1)
    # or an exempt network, and whose binary is not an exempt helper
    # (git-remote-https, ...). sockaddr arguments only support SAddr/SPort in
    # Tetragon, so the `sock` argument of tcp_connect is used (DPort, NotDAddr).
    egress-bypass = lib.optionalAttrs pol.egressBypass.enable (policy "egress-bypass" [{
      call = "tcp_connect";
      syscall = false;
      message = "Agent process connected out without the model gateway";
      args = [ { index = 0; type = "sock"; } ];
      selectors = [({
        matchArgs = [
          { index = 0; operator = "DPort"; values = map toString pol.egressBypass.ports; }
          { index = 0; operator = "NotDAddr"; values = loopbackAddrs ++ pol.egressBypass.exemptDestinations; }
        ];
      } // lib.optionalAttrs (pol.egressBypass.exemptBinaries != [ ]) {
        matchBinaries = [{ operator = "NotPostfix"; values = pol.egressBypass.exemptBinaries; }];
      })];
    }]);
  };

  # JSON is valid YAML and what Tetragon's loader (sigs.k8s.io/yaml) reads
  policyDir = pkgs.linkFarm "nestlo-agent-runtime-security-policies" (
    lib.mapAttrsToList
      (rule: p: { name = "${rule}.yaml"; path = pkgs.writeText "nestlo-ars-${rule}.yaml" (builtins.toJSON p); })
      (lib.filterAttrs (_: p: p != { }) policies)
    ++ lib.mapAttrsToList
      (name: p: { name = "extra-${name}.yaml"; path = pkgs.writeText "nestlo-ars-extra-${name}.yaml" (builtins.toJSON p); })
      cfg.extraPolicies
  );

  # Only kernel events (not every exec/exit of the machine) go to the file
  allowlist = builtins.toJSON {
    event_set = [ "PROCESS_KPROBE" "PROCESS_LOADER" ]
      ++ lib.optionals cfg.export.processExec [ "PROCESS_EXEC" "PROCESS_EXIT" ];
  };

  tetragonArgs = [
    "--tracing-policy-dir=${policyDir}"
    "--export-filename=${cfg.export.file}"
    "--export-file-max-size-mb=${toString cfg.export.maxSizeMB}"
    "--export-file-perm=640"
    "--export-allowlist=${allowlist}"
    "--server-address=unix://${runDir}/tetragon.sock"
    "--metrics-server=127.0.0.1:${toString cfg.metrics.tetragonPort}"
    "--log-level=${cfg.logLevel}"
  ] ++ lib.optional (cfg.export.rotationInterval != null)
    "--export-file-rotation-interval=${cfg.export.rotationInterval}";

  allRules = [ "credential-access" "write-protected" "write-outside-workspace" "raw-socket" "ptrace" "kernel-module" "egress-bypass" ];

  forwarderConfig = pkgs.writeText "nestlo-agent-security-forwarder.json" (builtins.toJSON {
    export_file = cfg.export.file;
    state_file = "/var/lib/nestlo-agent-runtime-security/offset.json";
    alerts_log = "${alertsDir}/alerts.jsonl";
    audit_socket = if cfg.audit.enable then config.nestlo.services.settings.audit.socket else null;
    audit_event_type = cfg.audit.eventType;
    users = cfg.users;
    mode = cfg.mode;
    enforce_rules = cfg.enforcement.rules;
    kill_scope = cfg.enforcement.scope;
    killable_unit_prefixes = [ "nestlo-agent-" "nestlo-" ];
    dedupe_seconds = cfg.dedupeSeconds;
    metrics_port = cfg.metrics.port;
  });

  # CONFIG_DEBUG_INFO_BTF: Tetragon (CO-RE) needs the kernel's BTF
  # (/sys/kernel/btf/vmlinux). nixpkgs' common-config enables it as an
  # `option yes` (taken when the toolchain supports it) on kernels >= 5.11.
  # `kernel.config.isYes` would read the built .config (import from
  # derivation), so the structured config is inspected instead.
  kernel = config.boot.kernelPackages.kernel;
  unwrapKernelOption = v:
    if v == null then null
    else if (v._type or "") == "if" then (if v.condition then unwrapKernelOption v.content else null)
    else v.tristate or null;
  kernelHasBtf = unwrapKernelOption
    (kernel.structuredExtraConfig.DEBUG_INFO_BTF or kernel.commonStructuredConfig.DEBUG_INFO_BTF or null) == "y";
in
{
  options.nestlo.agentRuntimeSecurity = {
    enable = lib.mkEnableOption "eBPF runtime monitoring of agent processes (Tetragon)";

    package = lib.mkOption {
      type = lib.types.package;
      # Tetragon 1.6.0 refuses to start when any function symbol in
      # /proc/kallsyms is at address 0. The 7.x kernel lists
      # srso_alias_untrain_ret there even with kptr_restrict = 1 (which this
      # module sets), so no policy would load. Upstream main only warns; the
      # check is dropped here the same way.
      default = pkgs.tetragon.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace pkg/ksyms/ksyms.go \
            --replace-fail 'if sym.isFunction() && sym.addr == 0 {' \
                           'if false && sym.isFunction() && sym.addr == 0 {'
        '';
      });
      defaultText = lib.literalExpression "pkgs.tetragon (without the kallsyms address-0 abort)";
      description = "Tetragon package (tetragon and tetra, with the BPF objects under lib/tetragon/bpf).";
    };

    mode = lib.mkOption {
      type = lib.types.enum [ "observe" "enforce" ];
      default = "observe";
      description = ''
        observe: detect and alert only. enforce: the forwarder also kills
        the process of an agent user that triggers one of
        `enforcement.rules`. Observe is the default so a new policy cannot
        take an agent down; review the alerts, then enforce.
      '';
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nestlo-agent" ] ++ lib.optional (config.nestlo.openclaw.enable or false) "openclaw";
      defaultText = lib.literalExpression ''[ "nestlo-agent" ] ++ (openclaw when nestlo.openclaw.enable)'';
      description = ''
        Users whose processes are agents. `nestlo-agent` runs every agent
        spawned by the runtime (`nestlo spawn`, the task runner's
        transient `nestlo-agent-<id>` units) and herdr; OpenClaw has its own
        user. Events of other users are dropped by the forwarder.
      '';
    };

    policies = {
      credentialAccess = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Alert when an agent opens a credential file.";
        };
        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "/run/secrets"
            "/run/credentials"
            "/var/lib/nestlo/secrets"
            "/var/lib/nestlo-audit"
            "/var/lib/nestlo-localai"
            "/var/lib/nestlo-vllm"
            "/etc/ssh/ssh_host_"
            "${rt.agentHome}/.ssh"
            "/root"
          ];
          defaultText = lib.literalExpression ''[ "/run/secrets" "/run/credentials" "/var/lib/nestlo/secrets" ... ]'';
          description = ''
            Path prefixes whose files agents must never open. The files of
            the agent's own logins (`~/.claude`, `~/.codex`, ...) are not
            listed: agents read those all the time.
          '';
        };
        providerKeyFiles = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Also watch every absolute `keyFile` of nestlo.networking.providers (the gateway reads them; agents never should).";
        };
        fileSuffixes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "/.ssh/id_rsa" "/.ssh/id_ed25519" "/.ssh/id_ecdsa" "/.aws/credentials" "/.netrc" "/.git-credentials" "/.config/gh/hosts.yml" "/.docker/config.json" ];
          description = "Files watched in any home directory, matched on the end of the path.";
        };
      };

      writeProtected = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Alert on writes to system locations.";
        };
        paths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "/etc" "/usr" "/boot" "/bin" "/sbin" "/lib" "/lib64" "/root" "/run/current-system" "/var/lib/nestlo/secrets" "/run/secrets" ];
          description = ''
            Path prefixes. A kernel-side "everything except the workspace"
            rule cannot see the user, so this lists the places that matter
            instead; system services rarely write here, which keeps the
            event volume low. Use `writeOutsideWorkspace` for the inverse.
          '';
        };
      };

      writeOutsideWorkspace = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Report every write outside `allowedPaths`. Off by default: the
            kernel hook fires for the writes of all processes (journald,
            the audit writer, ...) and only the forwarder drops the ones
            that are not agents, so this costs CPU and export-file space.
            Enable it for an investigation, or on machines that run little
            besides agents.
          '';
        };
        allowedPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ rt.workspaceRoot rt.agentHome "/tmp" "/var/tmp" "/dev" "/proc" "/sys" "/run/user" "/run/nestlo" "/var/cache" ];
          defaultText = lib.literalExpression ''[ workspaceRoot agentHome "/tmp" "/var/tmp" "/dev" ... ]'';
          description = "Path prefixes agents may write.";
        };
      };

      rawSockets.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Alert on AF_PACKET sockets and SOCK_RAW on AF_INET/AF_INET6 (needs CAP_NET_RAW, so it fires for agents that hold it, such as container-isolated ones).";
      };

      ptrace.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Alert on ptrace attach/seize/poke/set-registers and process_vm_writev.";
      };

      kernelModules.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Alert on init_module, finit_module and delete_module.";
      };

      egressBypass = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Alert when an agent opens a TCP connection to one of `ports`
            on an address that is not loopback. Agents are supposed to reach
            models through the gateway on 127.0.0.1, so a direct HTTPS
            connection is a bypass of budgets, DLP and the audit log. Turn it
            off, or extend the exemptions, where agents legitimately fetch
            from the internet; the alerts then tell you who and what.
          '';
        };
        ports = lib.mkOption {
          type = lib.types.listOf lib.types.port;
          default = [ 443 ];
          description = "Destination ports watched.";
        };
        exemptDestinations = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "10.0.0.0/8" "140.82.112.0/20" ];
          description = "CIDRs (besides loopback) that agents may connect to without an alert.";
        };
        exemptBinaries = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "/git-remote-https" "/git-remote-http" "/ssh" ];
          description = ''
            Binaries that may connect out, matched on the end of their path
            (so `/git-remote-https` matches the Nix store path of git's
            helper). Git over HTTPS is exempt by default: agents push
            branches through it.
          '';
        };
      };
    };

    extraPolicies = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Further TracingPolicy objects (as Nix attrsets), by file name. Name
        the policy `nestlo-ars-<rule>` for the forwarder to alert on it;
        other policies still appear in the export file.
      '';
    };

    enforcement = {
      rules = lib.mkOption {
        type = lib.types.listOf (lib.types.enum allRules);
        default = [ "credential-access" "raw-socket" "ptrace" "kernel-module" ];
        description = "Rules that kill the offending agent process when `mode = \"enforce\"`. egress-bypass and the write rules are alert-only by default.";
      };
      scope = lib.mkOption {
        type = lib.types.enum [ "process" "unit" ];
        default = "unit";
        description = ''
          process: SIGKILL the process. unit: kill the whole systemd unit it
          runs in (an agent's `nestlo-agent-<id>.service`), which ends the
          task; processes outside such a unit are killed individually.
        '';
      };
      sigkill = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Also use Tetragon's in-kernel Sigkill action on raw-socket,
            ptrace and kernel-module. This is synchronous (the call never
            completes) but cannot tell users apart, so it kills every
            process that triggers the hook, root included, except
            `exemptBinaries`. Needs mode = "enforce".
          '';
        };
        exemptBinaries = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "/gdb" "/gdbserver" "/strace" "/ltrace" "/perf" "/bpftrace" "/ping" "/systemd" "/udevadm" "/kmod" "/modprobe" ];
          description = "Binaries (end of path) the in-kernel kill spares.";
        };
      };
    };

    export = {
      file = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/tetragon/tetragon.json";
        description = "Tetragon's JSON export (one event per line, rotated by size). The directory is root:nestlo, setgid, mode 2750.";
      };
      maxSizeMB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 50;
        description = "Rotate the export file at this size (5 rotated files are kept).";
      };
      rotationInterval = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "24h";
        description = "Also rotate at this interval (Go duration); null: by size only.";
      };
      processExec = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also export process exec/exit events of every process. Verbose; for forensics.";
      };
    };

    audit = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = config.nestlo.audit.enable;
        defaultText = lib.literalExpression "config.nestlo.audit.enable";
        description = "Send alerts to the Nestlo audit writer (hash-chained log).";
      };
      eventType = lib.mkOption {
        type = lib.types.str;
        default = "runtime.security";
        description = ''
          Audit event type of an alert. The writer rejects types missing from
          EVENT_TYPES in services/nestlo_services/audit.py, so this type
          has to be added there (docs/agent-runtime-security.md).
        '';
      };
    };

    metrics = {
      port = lib.mkOption {
        type = lib.types.port;
        default = 9976;
        description = "Loopback port of the forwarder's Prometheus endpoint (nestlo_runtime_security_*).";
      };
      tetragonPort = lib.mkOption {
        type = lib.types.port;
        default = 9977;
        description = "Loopback port of Tetragon's own metrics.";
      };
    };

    dedupeSeconds = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 30;
      description = "Identical alerts (rule, user, binary, target) within this window are folded into one with a `repeats` count. Kills are never folded.";
    };

    logLevel = lib.mkOption {
      type = lib.types.enum [ "trace" "debug" "info" "warn" "error" ];
      default = "info";
      description = "Tetragon log level.";
    };

    requireBTF = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Fail the build when the configured kernel lacks CONFIG_DEBUG_INFO_BTF.
        Tetragon loads CO-RE programs against /sys/kernel/btf/vmlinux.
        Set to false for a kernel the check cannot see into (custom
        `boot.kernelPackages` without a `config` attribute); the unit still
        refuses to start without the BTF file.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Tetragon resolves kprobe targets through /proc/kallsyms. Nestlo's
    # hardening sets kptr_restrict = 2, which hides kernel addresses even
    # from CAP_SYSLOG, and every policy then fails to load ("no kernel
    # symbols found"). 1 still hides them from processes without CAP_SYSLOG.
    boot.kernel.sysctl."kernel.kptr_restrict" = lib.mkOverride 90 1;

    assertions = [
      {
        assertion = rt.enable;
        message = "nestlo.agentRuntimeSecurity needs nestlo.runtime.enable (users and groups of the agents)";
      }
      {
        assertion = !cfg.requireBTF || kernelHasBtf;
        message = ''
          nestlo.agentRuntimeSecurity: the kernel (${kernel.version}) does not enable CONFIG_DEBUG_INFO_BTF,
          which Tetragon needs. Use a stock NixOS kernel, or set
          nestlo.agentRuntimeSecurity.requireBTF = false if you know yours has it.
        '';
      }
      {
        assertion = !cfg.enforcement.sigkill.enable || cfg.mode == "enforce";
        message = "nestlo.agentRuntimeSecurity.enforcement.sigkill needs mode = \"enforce\"";
      }
      {
        assertion = !cfg.audit.enable || config.nestlo.audit.enable;
        message = "nestlo.agentRuntimeSecurity.audit.enable needs nestlo.audit.enable";
      }
      {
        assertion = cfg.users != [ ];
        message = "nestlo.agentRuntimeSecurity.users must name at least one user";
      }
      {
        assertion = cfg.metrics.port != cfg.metrics.tetragonPort;
        message = "nestlo.agentRuntimeSecurity: metrics.port and metrics.tetragonPort must differ";
      }
    ];

    warnings = lib.optional (cfg.mode == "enforce" && cfg.enforcement.sigkill.enable)
      "nestlo.agentRuntimeSecurity: enforcement.sigkill kills processes of every user that trigger raw-socket, ptrace or kernel-module; see docs/agent-runtime-security.md";

    environment.systemPackages = [ cfg.package ];

    # Group nestlo (operators) reads the exports; new files inherit it
    systemd.tmpfiles.rules = [
      "d ${exportDir} 2750 root nestlo -"
      "d ${alertsDir} 2750 root nestlo -"
    ];

    systemd.services.nestlo-tetragon = {
      description = "Tetragon eBPF runtime security engine (Nestlo agents)";
      wantedBy = [ "multi-user.target" ];
      after = [ "sysinit.target" "sys-fs-bpf.mount" ];
      serviceConfig = {
        # A missing BTF file is the usual reason Tetragon cannot start
        ExecStartPre = "${pkgs.runtimeShell} -c 'test -r /sys/kernel/btf/vmlinux || { echo \"Tetragon needs a kernel with CONFIG_DEBUG_INFO_BTF (no /sys/kernel/btf/vmlinux)\" >&2; exit 1; }'";
        ExecStart = "${cfg.package}/bin/tetragon ${lib.escapeShellArgs tetragonArgs}";
        RuntimeDirectory = "tetragon";
        RuntimeDirectoryMode = "0750";
        Restart = "on-failure";
        RestartSec = 5;
        LimitMEMLOCK = "infinity";

        # Root with the capabilities BPF and probing other processes need
        # (upstream: CAP_SYS_ADMIN, CAP_SYS_RESOURCE, CAP_NET_ADMIN, CAP_BPF,
        # CAP_PERFMON, CAP_SYS_PTRACE, CAP_DAC_OVERRIDE for /proc and cgroups; the
        # upstream chart runs privileged, so CAP_SYSLOG (kallsyms), CAP_IPC_LOCK and
        # CAP_CHOWN/CAP_FOWNER (export file rotation) are added defensively)
        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_SYS_RESOURCE" "CAP_NET_ADMIN" "CAP_BPF" "CAP_PERFMON" "CAP_SYS_PTRACE" "CAP_DAC_OVERRIDE" "CAP_DAC_READ_SEARCH" "CAP_SYSLOG" "CAP_IPC_LOCK" "CAP_CHOWN" "CAP_FOWNER" ];
        ProtectSystem = "strict";
        ReadWritePaths = [ exportDir ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" "AF_INET" "AF_INET6" ];
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = "any";
        UMask = "0027";
      };
    };

    systemd.services.nestlo-agent-security-forwarder = {
      description = "Forward Tetragon events of Nestlo agents to the audit log";
      wantedBy = [ "multi-user.target" ];
      after = [ "nestlo-tetragon.service" ] ++ lib.optional cfg.audit.enable "nestlo-audit.service";
      wants = [ "nestlo-tetragon.service" ];
      path = [ pkgs.systemd ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 -u ${./forwarder.py} --config ${forwarderConfig}";
        # not nestlo-agent-security: that is the state directory of nestlo.agentSecurity (user nestlo-security)
        StateDirectory = "nestlo-agent-runtime-security";
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 3;

        ReadWritePaths = [ alertsDir ];
        SupplementaryGroups = lib.optional cfg.audit.enable "nestlo-audit";
        # SYS_PTRACE: readlink /proc/<pid>/exe of other users before a kill
        CapabilityBoundingSet = if cfg.mode == "enforce" then [ "CAP_KILL" "CAP_SYS_PTRACE" ] else "";
        AmbientCapabilities = "";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = "any";
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ] ++ lib.optional (cfg.mode != "enforce") "~@privileged";
        UMask = "0027";
      };
    };

    services.prometheus.scrapeConfigs = lib.mkIf config.nestlo.observability.enable [{
      job_name = "nestlo-agent-runtime-security";
      static_configs = [{
        targets = [ "127.0.0.1:${toString cfg.metrics.port}" "127.0.0.1:${toString cfg.metrics.tetragonPort}" ];
      }];
    }];

    services.prometheus.rules = lib.mkIf config.nestlo.observability.enable [
      (builtins.toJSON {
        groups = [{
          name = "nestlo-agent-runtime-security";
          rules = [
            {
              alert = "NestloAgentRuntimeSecurityEvent";
              expr = ''sum by (rule) (increase(nestlo_runtime_security_events_total[10m])) > 0'';
              labels.severity = "critical";
              annotations = {
                summary = "An agent triggered the runtime security rule {{ $labels.rule }}";
                description = "See /var/log/nestlo-agent-runtime-security/alerts.jsonl and `nestlo-audit tail`.";
              };
            }
            {
              alert = "NestloAgentRuntimeSecurityDown";
              expr = ''up{job="nestlo-agent-runtime-security"} == 0'';
              "for" = "5m";
              labels.severity = "warning";
              annotations.summary = "The agent runtime security forwarder or Tetragon is not running";
            }
          ];
        }];
      })
    ];
  };
}
