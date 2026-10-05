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
#
# Which packs are on: a pack's own default (opt-in packs are off), turned on
# by agentos.skills.enableAll or by agentos.skills.collections naming one of
# the pack's collections; packs.<name>.enable set explicitly always wins.
{ config, pkgs, lib, ... }:

let
  cfg = config.agentos.skills;

  allPacks = import ../../nixos/packages/skills { inherit pkgs; };
  enabledPacks = lib.filterAttrs (name: _: cfg.packs.${name}.enable) allPacks;
  packList = lib.attrValues enabledPacks;

  # Every collection a pack declares (mkSkillPack `collections`)
  knownCollections = lib.sort (a: b: a < b) (lib.unique (lib.concatMap (p: p.collections) (lib.attrValues allPacks)));
  wanted = pack: cfg.enableAll || lib.any (c: lib.elem c cfg.collections) pack.collections;

  # Each skill's name and description is part of every agent session's
  # context (the agent decides from it when to load a skill)
  skillCount = lib.foldl' (n: p: n + lib.length p.skillNames) 0 packList;
  warnAbove = 300;
  tokensPerSkill = 100;
  biggest = lib.take 5 (lib.sort (a: b: a.n > b.n)
    (map (p: { inherit (p) pack; n = lib.length p.skillNames; }) packList));

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

    enableAll = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable every skill pack, including the opt-in ones (the community
        collections: Superpowers, gstack, Everything Claude Code, the
        scientific skills, 800+ Composio app automations, ...). A pack
        whose `enable` is set explicitly keeps that value. This adds
        well over a thousand skills; each costs about ${toString tokensPerSkill}
        tokens of context in every agent session, so evaluation warns above
        ${toString warnAbove} skills.
      '';
    };

    collections = lib.mkOption {
      type = lib.types.listOf (lib.types.enum knownCollections);
      default = [ ];
      example = [ "community" "security" ];
      description = ''
        Enable every pack that belongs to one of these collections (a pack
        can belong to several). A pack whose `enable` is set explicitly keeps
        that value. Collections: ${lib.concatStringsSep ", " knownCollections}.
        `community` is the moderate-size set of community packs; `large`
        marks packs with more than 150 skills and `automation` the Composio
        packs, which need an account; see docs/skills.md.
      '';
    };

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
    # enableAll / collections switch packs on at mkDefault priority: above the
    # option default, below an explicit packs.<name>.enable
    agentos.skills.packs = lib.mapAttrs
      (_: pack: { enable = lib.mkIf (wanted pack) (lib.mkDefault true); })
      allPacks;

    warnings = lib.optional (skillCount > warnAbove)
      ("agentos.skills: ${toString skillCount} skills are enabled. Every agent session lists each skill's name and "
        + "description (about ${toString tokensPerSkill} tokens per skill), roughly ${toString (skillCount * tokensPerSkill / 1000)}k tokens "
        + "of context before any work, which also dilutes which skill the agent picks. Largest packs: "
        + lib.concatMapStringsSep ", " (b: "${b.pack} (${toString b.n})") biggest
        + ". Turn packs off with agentos.skills.packs.<name>.enable = false or choose collections "
        + "instead of agentos.skills.enableAll.");

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
