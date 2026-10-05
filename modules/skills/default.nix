# AgentOS agent skills module
#
# Installs skill packs (nixos/packages/skills, docs/skills.md) for every agent
# CLI on the system:
#   - one combined bundle of all enabled packs' skills, flattened to
#     <skill> directories; a name used by two packs fails evaluation
#   - a link <home>/<dir>/<skill> -> bundle for each user and each target
#     CLI (Claude Code, Codex, OpenCode, Gemini CLI, ...), refreshed on
#     every rebuild
#   - the packs' tools in systemPackages and their MCP servers in the MCP
#     registry
#   - `agentos-skills list|doctor|path`
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.skills;

  allPacks = import ../../nixos/packages/skills { inherit pkgs; };
  enabledPacks = lib.filterAttrs (name: _: cfg.packs.${name}.enable) allPacks;
  packList = lib.attrValues enabledPacks;

  # Where each CLI looks for user-level skills, relative to $HOME. Checked
  # against the CLIs' own source or binaries (docs/skills.md lists how).
  knownTargets = {
    # Cross-agent location read by Codex, Gemini CLI, OpenCode, Amp, Goose,
    # Qwen Code and Crush
    agents = ".agents/skills";
    claude-code = ".claude/skills";
    codex = ".codex/skills";
    opencode = ".config/opencode/skills";
    gemini = ".gemini/skills";
    copilot = ".copilot/skills";
    cursor = ".cursor/skills";
    factory-droid = ".factory/skills";
    # Also read by Goose and Crush
    amp = ".config/agents/skills";
    goose = ".config/goose/skills";
    qwen = ".qwen/skills";
    crush = ".config/crush/skills";
  };
  targetDirs = lib.getAttrs cfg.targets knownTargets;

  bundle = pkgs.callPackage ../../nixos/packages/skills/bundle.nix { } packList;
  skillsCli = pkgs.callPackage ../../nixos/packages/skills/cli.nix { };

  userNames = lib.unique (lib.optional cfg.includeAgentUser "agentos-agent" ++ cfg.users);
  homeOf = user:
    if user == "agentos-agent" then config.agentos.runtime.agentHome
    else config.users.users.${user}.home;

  # skill name -> packs providing it
  providers = lib.foldl'
    (acc: p: lib.foldl' (a: s: a // { ${s} = (a.${s} or [ ]) ++ [ p.pack ]; }) acc p.skillNames)
    { }
    packList;
  collisions = lib.filterAttrs (_: ps: lib.length ps > 1) providers;

  # Claude Code hooks of the packs (passthru.claudeHooks: event -> list of
  # hook entries), concatenated per event
  claudeHooks = lib.zipAttrsWith (_: lib.concatLists) (map (p: p.claudeHooks or { }) packList);

  ownedGlob = "/nix/store/*-agentos-skills-bundle/skills/*";

  # Runs as the user, so everything it creates belongs to the user and it can
  # only touch what the user can. It manages the links it owns (symlinks into
  # an agentos-skills-bundle) and leaves any other file or directory, such as
  # a skill the user wrote, in place.
  linkScript = pkgs.writeShellScript "agentos-skills-link" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    bundle=${bundle}
    home="$1"
    [ -d "$home" ] || { echo "agentos-skills: home $home does not exist, skipping" >&2; exit 0; }

    ours() {
      case "$(readlink "$1" 2>/dev/null)" in
        ${ownedGlob}) return 0 ;;
        *) return 1 ;;
      esac
    }

    # Drop our links to skills that are no longer installed, in every known
    # target directory (also those that were deselected)
    for rel in ${lib.concatStringsSep " " (lib.attrValues knownTargets)}; do
      dir="$home/$rel"
      [ -d "$dir" ] || continue
      for link in "$dir"/*; do
        [ -L "$link" ] || continue
        ours "$link" || continue
        [ -L "$bundle/skills/$(basename "$link")" ] && continue
        rm -f "$link"
      done
    done

    for rel in ${lib.concatStringsSep " " (lib.attrValues targetDirs)}; do
      dir="$home/$rel"
      mkdir -p "$dir" || { echo "agentos-skills: cannot create $dir" >&2; continue; }
      for entry in "$bundle"/skills/*; do
        [ -L "$entry" ] || continue
        link="$dir/$(basename "$entry")"
        if [ -L "$link" ]; then
          if ours "$link"; then
            ln -sfn "$entry" "$link"
          else
            echo "agentos-skills: $link is a link of yours, left alone" >&2
          fi
        elif [ -e "$link" ]; then
          echo "agentos-skills: $link exists, left alone" >&2
        else
          ln -s "$entry" "$link"
        fi
      done
    done
  '';

  mkUnit = user: rec {
    name = "agentos-skills-link-${user}";
    value = {
      description = "Link AgentOS skills into the home of ${user}";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "systemd-user-sessions.service" ];
      # a rebuild with different packs restarts the unit
      restartTriggers = [ bundle linkScript ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        ExecStart = "${linkScript} ${homeOf user}";
        ProtectSystem = "strict";
        ReadWritePaths = "-${homeOf user}";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
in
{
  options.agentos.skills = {
    enable = lib.mkEnableOption "AgentOS agent skill packs, linked into every agent CLI";

    packs = lib.mapAttrs
      (name: pack: {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = pack.defaultEnable;
          description = "Install the ${name} skill pack: ${pack.meta.description}";
        };
      })
      allPacks;

    targets = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames knownTargets));
      default = lib.attrNames knownTargets;
      example = [ "agents" "claude-code" ];
      description = ''
        Which skills directories get the links, relative to the user's home:
        ${lib.concatStringsSep ", " (lib.mapAttrsToList (n: d: "${n} (~/${d})") knownTargets)}.
      '';
    };

    includeAgentUser = lib.mkOption {
      type = lib.types.bool;
      default = config.agentos.runtime.enable;
      defaultText = lib.literalExpression "config.agentos.runtime.enable";
      description = "Link the skills into the home of the sandboxed agent user (agentos-agent)";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "admin" ];
      description = "Further users whose home directories get the links";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = collisions == { };
        message = "agentos.skills: skill names provided by more than one enabled pack: "
          + lib.concatStringsSep "; " (lib.mapAttrsToList (s: ps: "${s} (${lib.concatStringsSep ", " ps})") collisions)
          + ". Disable one of the packs with agentos.skills.packs.<name>.enable = false.";
      }
      {
        assertion = lib.all (u: config.users.users ? ${u}) userNames;
        message = "agentos.skills.users: unknown user(s): "
          + lib.concatStringsSep ", " (lib.filter (u: !(config.users.users ? ${u})) userNames);
      }
    ];

    environment.systemPackages = [ skillsCli ] ++ packList;

    environment.etc."agentos/skills.json".text = builtins.toJSON {
      bundle = "${bundle}";
      users = map (u: { name = u; home = homeOf u; }) userNames;
      targets = targetDirs;
    };

    # Claude Code reads drop-ins from the system managed-settings directory
    # (/etc/claude-code on Linux, per its managed settings documentation)
    environment.etc."claude-code/managed-settings.d/50-agentos-skills.json" = lib.mkIf (claudeHooks != { }) {
      text = builtins.toJSON { hooks = claudeHooks; };
    };

    systemd.services = lib.listToAttrs (map mkUnit userNames);

    # MCP servers shipped by the packs (they show up in `agentos-tools list`)
    agentos.mcp-registry.extraToolServers = lib.foldl'
      (acc: p: acc // lib.mapAttrs (_: server: { description = "MCP server of the ${p.pack} skill pack"; } // server) p.mcp)
      { }
      packList;
  };
}
