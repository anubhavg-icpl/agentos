# ═══════════════════════════════════════════════════════════════════════
# AgentOS Provenance Module
# ═══════════════════════════════════════════════════════════════════════
#
# Verifiable AI-authored code (services/agentos_services/provenance.py,
# docs/provenance.md): the root task runner signs an in-toto statement about
# each agent branch commit (agent, system closure, models, cost, prompt hash,
# approvals, recording hash) with an Ed25519 key it alone can read, stores it
# as a git note, pushes the note with the branch and sets the
# `agentos/provenance` commit status. `agentos-provenance verify` checks it.
#
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.provenance;
  pubDir = "/var/lib/agentos";
  cli = pkgs.writeShellScriptBin "agentos-provenance" ''
    export PATH=${lib.makeBinPath [ pkgs.git ]}:$PATH
    exec ${pkgs.agentos.services}/bin/agentos-provenance "$@"
  '';
in
{
  options.agentos.provenance = {
    enable = lib.mkEnableOption "signed provenance for agent-authored commits made by orchestrator tasks";

    keyFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/agentos/provenance.key";
      example = "/run/secrets/agentos-provenance-key";
      description = ''
        Ed25519 private key (PEM, PKCS#8), root-only (0600); a sops-nix path
        works. Passed to the root task runner as a systemd credential, never
        to the agent. If the file is absent a oneshot generates it at first
        boot (root 0600) and prints the public key to the journal and
        /var/lib/agentos/provenance.pub.
      '';
    };

    publicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "Zm9vYmFyLi4u" ];
      description = ''
        Base64 raw Ed25519 public keys `agentos-provenance verify` trusts
        (written to /etc/agentos/provenance.pub). This host's own key is
        trusted through /var/lib/agentos/provenance.pub.
      '';
    };

    includePrompt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Put the prompt itself in the signed statement (default: only its sha256). Git notes are pushed to the remote, so enable this only for repositories where the prompt may be public.";
    };

    requireForPublish = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Refuse to publish a branch for which no provenance envelope could be produced.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.agentos.orchestration.enable;
      message = "agentos.provenance signs orchestrator tasks; set agentos.orchestration.enable = true";
    }];

    agentos.services.settings.provenance = {
      enable = true;
      include_prompt = cfg.includePrompt;
      require_for_publish = cfg.requireForPublish;
    };

    environment.etc."agentos/provenance.pub".text = lib.concatStringsSep "\n" cfg.publicKeys + "\n";
    environment.systemPackages = [ cli ];
    systemd.tmpfiles.rules = [ "d ${pubDir} 0755 root root" ];

    systemd.services.agentos-provenance-keygen = {
      description = "AgentOS provenance signing key (generated at first boot if absent)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = "${pkgs.agentos.services}/bin/agentos-provenance keygen --key-file ${toString cfg.keyFile} --pub-file ${pubDir}/provenance.pub";
        ProtectSystem = "strict";
        ReadWritePaths = [ pubDir (builtins.dirOf (toString cfg.keyFile)) ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # The key goes to the root helper only, as a credential
    systemd.services."agentos-task-runner@" = {
      requires = [ "agentos-provenance-keygen.service" ];
      after = [ "agentos-provenance-keygen.service" ];
      serviceConfig.LoadCredential = [ "provenance-key:${toString cfg.keyFile}" ];
    };
  };
}
