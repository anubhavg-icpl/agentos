# Nestlo agent authorization with Cedar (https://www.cedarpolicy.com, Apache-2.0)
#
# Declarative Cedar policies and schema, validated at build time and
# rendered to /etc/nestlo/cedar, plus `nestlo-authz`, a CLI that answers
# "may this agent do this to that resource?" with allow / deny and the
# policies that decided. The question is about identities (which agent) and
# resources (repositories, tools, providers, secrets), which complements
# nestlo.policy (what a task may cost and how it runs).
#
# nixpkgs has no Python binding for Cedar, so the check calls the `cedar`
# CLI (a few ms per decision). See docs/agent-identity.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.cedar;

  # Agent -> group membership and attributes, from nestlo.cedar.agents
  agentEntities = lib.mapAttrsToList
    (name: a: {
      uid = { type = "Agent"; id = name; };
      attrs = { tier = a.tier; } // a.attrs;
      parents = map (g: { type = "Group"; id = g; }) a.groups;
    })
    cfg.agents;

  entitiesJson = pkgs.writeText "entities.json" (builtins.toJSON (agentEntities ++ cfg.entities));
  schemaFile = pkgs.writeText "nestlo.cedarschema" cfg.schema;

  policyText = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: text: ''
      @id("${name}")
      ${lib.removePrefix "\n" text}
    '')
    cfg.policies);
  policyFile = pkgs.writeText "policies.cedar" policyText;

  cedar = "${cfg.package}/bin/cedar";

  # The policies must validate against the schema, and the entities must
  # conform to it (a request with a schema validates the entity store)
  rendered = pkgs.runCommand "nestlo-cedar" { nativeBuildInputs = [ cfg.package ]; } ''
    mkdir -p $out
    cp ${schemaFile} $out/schema.cedarschema
    cp ${policyFile} $out/policies.cedar
    cp ${entitiesJson} $out/entities.json
    cd $out
    cedar check-parse --schema schema.cedarschema --policies policies.cedar --entities entities.json
    cedar validate --schema schema.cedarschema --policies policies.cedar
    rc=0
    cedar authorize --schema schema.cedarschema --policies policies.cedar --entities entities.json \
      --principal 'Agent::"nestlo-build-check"' --action 'Action::"clone"' --resource 'Repo::"nestlo-build-check"' \
      >/dev/null || rc=$?
    # 0 allow, 2 deny; 1 is an error (for example an entity that violates the schema)
    [ "$rc" = 0 ] || [ "$rc" = 2 ] || { echo "entities do not conform to the schema" >&2; exit 1; }
  '';

  authz = pkgs.writeShellApplication {
    name = "nestlo-authz";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.jq ];
    excludeShellChecks = [ "SC2016" ];
    text = ''
      dir=''${NESTLO_CEDAR_DIR:-/etc/nestlo/cedar}
      usage() {
        cat >&2 <<'U'
      Usage: nestlo-authz check --principal P --action A --resource R [--context JSON] [--entities FILE] [--json]
        P, R     Type::"id", Type:id, or a bare id (principal: Agent, resource: no default)
        A        a bare action name (clone, push, use_tool, call_provider, read_secret) or Action::"name"
        --entities FILE   use this entity store instead of /etc/nestlo/cedar/entities.json
      Exit status: 0 allow, 2 deny, 1 error.
      Example: nestlo-authz check --principal claude --action push --resource Repo:github.com/acme/app --context '{"branch":"main"}'
      U
        exit 1
      }

      # Type::"id" from Type::"id" | Type::id | Type:id | id
      norm() {
        local raw=$1 default=$2 type id
        if [[ $raw == *::* ]]; then type=''${raw%%::*}; id=''${raw#*::}
        elif [[ $raw == *:* ]]; then type=''${raw%%:*}; id=''${raw#*:}
        else type=$default; id=$raw; fi
        id=''${id#\"}; id=''${id%\"}
        [[ -n $type && -n $id ]] || { echo "nestlo-authz: empty type or id in '$raw'" >&2; exit 1; }
        [[ $type =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "nestlo-authz: bad entity type '$type'" >&2; exit 1; }
        [[ $id != *[\"\\]* ]] || { echo "nestlo-authz: quotes and backslashes are not allowed in ids" >&2; exit 1; }
        printf '%s::"%s"' "$type" "$id"
      }

      [ "''${1:-}" = check ] || usage
      shift
      principal='' action='' resource='' context='' entities=$dir/entities.json json=''
      while [ $# -gt 0 ]; do
        case $1 in
          --principal) principal=''${2:?}; shift 2 ;;
          --action) action=''${2:?}; shift 2 ;;
          --resource) resource=''${2:?}; shift 2 ;;
          --context) context=''${2:?}; shift 2 ;;
          --entities) entities=''${2:?}; shift 2 ;;
          --json) json=1; shift ;;
          *) usage ;;
        esac
      done
      [ -n "$principal" ] && [ -n "$action" ] && [ -n "$resource" ] || usage

      ctx=$(mktemp)
      trap 'rm -f "$ctx"' EXIT
      printf '%s' "''${context:-{\}}" > "$ctx"
      jq -e 'type == "object"' "$ctx" >/dev/null || { echo "nestlo-authz: --context must be a JSON object" >&2; exit 1; }

      p=$(norm "$principal" Agent)
      a=$(norm "$action" Action)
      r=$(norm "$resource" Resource)

      rc=0
      out=$(${cedar} authorize --schema "$dir/schema.cedarschema" --policies "$dir/policies.cedar" \
              --entities "$entities" --principal "$p" --action "$a" --resource "$r" --context "$ctx" \
              --verbose 2>&1) || rc=$?
      if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then
        echo "$out" >&2
        exit 1
      fi
      decision=ALLOW; [ "$rc" = 2 ] && decision=DENY
      # Policy ids (the @id annotations) that decided
      reasons=$(printf '%s\n' "$out" | awk '/following policies/ {on=1; next} on && NF {gsub(/^ +/, ""); print}')
      if [ -n "$json" ]; then
        jq -n --arg d "$decision" --arg p "$p" --arg a "$a" --arg r "$r" --arg reasons "$reasons" \
          '{decision: ($d | ascii_downcase), principal: $p, action: $a, resource: $r,
            reasons: ($reasons | split("\n") | map(select(length > 0)))}'
      else
        printf '%s' "$decision"
        [ -n "$reasons" ] && printf ' (%s)' "$(printf '%s' "$reasons" | paste -sd, -)"
        printf '\n'
      fi
      exit "$rc"
    '';
  };

  # What `nestlo.cedar` ships unless disabled: agents, repositories, tools,
  # providers and secrets, and the five things an agent can do to them.
  defaultSchema = ''
    // Groups of agents (for example "coding", "review")
    entity Group;
    // tier: "trusted" | "sandboxed" | "untrusted" (nestlo.cedar.agents.<name>.tier)
    entity Agent in [Group] = { tier: String };
    entity RepoSet;
    entity Repo in [RepoSet];
    entity ToolSet;
    entity Tool in [ToolSet];
    entity ProviderSet;
    entity Provider in [ProviderSet];
    entity Secret;

    action "clone" appliesTo { principal: Agent, resource: Repo };
    action "push" appliesTo { principal: Agent, resource: Repo, context: { "branch"?: String } };
    action "use_tool" appliesTo { principal: Agent, resource: Tool };
    action "call_provider" appliesTo { principal: Agent, resource: Provider, context: { "model"?: String } };
    action "read_secret" appliesTo { principal: Agent, resource: Secret };
  '';

  examplePolicies = {
    # Coding agents may read the internal repositories
    coding-clone = ''
      permit (principal in Group::"coding", action == Action::"clone", resource in RepoSet::"internal");
    '';
    # ...and push to them when trusted, but never to the default branch
    coding-push = ''
      permit (principal in Group::"coding", action == Action::"push", resource in RepoSet::"internal")
      when { principal.tier == "trusted" };
    '';
    no-default-branch-push = ''
      forbid (principal, action == Action::"push", resource)
      when { context has branch && (context.branch == "main" || context.branch == "master") };
    '';
    # Tools: the safe set for everyone, the shell only for trusted agents
    tools-safe = ''
      permit (principal, action == Action::"use_tool", resource in ToolSet::"safe");
    '';
    tools-shell-trusted = ''
      permit (principal, action == Action::"use_tool", resource in ToolSet::"shell")
      when { principal.tier == "trusted" };
    '';
    # Providers: agents may call the providers of the approved set
    providers-approved = ''
      permit (principal, action == Action::"call_provider", resource in ProviderSet::"approved");
    '';
    # Secrets: never for untrusted agents, whatever else says
    untrusted-no-secrets = ''
      forbid (principal, action == Action::"read_secret", resource)
      when { principal.tier == "untrusted" };
    '';
    untrusted-no-push = ''
      forbid (principal, action == Action::"push", resource)
      when { principal.tier == "untrusted" };
    '';
  };

  defaultEntities = [
    { uid = { type = "Repo"; id = "github.com/nestlo/nestlo"; }; attrs = { }; parents = [{ type = "RepoSet"; id = "internal"; }]; }
    { uid = { type = "Tool"; id = "git"; }; attrs = { }; parents = [{ type = "ToolSet"; id = "safe"; }]; }
    { uid = { type = "Tool"; id = "read-file"; }; attrs = { }; parents = [{ type = "ToolSet"; id = "safe"; }]; }
    { uid = { type = "Tool"; id = "bash"; }; attrs = { }; parents = [{ type = "ToolSet"; id = "shell"; }]; }
    { uid = { type = "Provider"; id = "anthropic"; }; attrs = { }; parents = [{ type = "ProviderSet"; id = "approved"; }]; }
  ];
in
{
  options.nestlo.cedar = {
    enable = lib.mkEnableOption "Cedar authorization for agents: policies, schema and the nestlo-authz command (docs/agent-identity.md)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.cedar;
      defaultText = lib.literalExpression "pkgs.cedar";
      description = "Cedar CLI (4.x).";
    };

    schema = lib.mkOption {
      type = lib.types.lines;
      default = defaultSchema;
      defaultText = lib.literalMD "Nestlo's schema: Agent (in Group, with `tier`), Repo, Tool, Provider, Secret and the actions clone, push, use_tool, call_provider, read_secret";
      description = "Cedar schema (Cedar syntax). Policies are validated against it when the system is built.";
    };

    policies = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = examplePolicies;
      defaultText = lib.literalMD "an example policy set (see docs/agent-identity.md)";
      description = ''
        Cedar policies, one policy per attribute; the name becomes the
        policy's `@id`, which `nestlo-authz` reports as the reason of a
        decision. Cedar denies by default and `forbid` always wins over
        `permit`. Set to `{ }` or override single entries to change the
        example set.
      '';
      example = lib.literalExpression ''
        {
          claude-providers = '''
            permit (principal == Agent::"claude", action == Action::"call_provider", resource == Provider::"anthropic");
          ''';
        }
      '';
    };

    agents = lib.mkOption {
      default = { };
      description = ''
        The agents policies talk about. The name is the principal id
        (Agent::"<name>"), the same as the gateway agent id and the SPIFFE
        path of nestlo.agentIdentity.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          groups = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "coding" ];
            description = "Groups the agent belongs to (Group::\"<name>\").";
          };
          tier = lib.mkOption {
            type = lib.types.str;
            default = "sandboxed";
            description = "Trust tier attribute (the example policies know trusted, sandboxed and untrusted).";
          };
          attrs = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = "Further attributes (they must be declared in the schema).";
          };
        };
      });
    };

    entities = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      default = defaultEntities;
      defaultText = lib.literalMD "the example repository, tools and provider of the example policies";
      description = ''
        Resource entities in Cedar's JSON entity format ({ uid = { type;
        id; }; attrs; parents = [ { type; id; } ]; }): which repositories
        belong to which RepoSet, which tools to which ToolSet, and so on.
      '';
    };

    rendered = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = rendered;
      description = "Directory with the validated schema, policies and entities (also /etc/nestlo/cedar).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."nestlo/cedar".source = rendered;
    environment.systemPackages = [ cfg.package authz ];
  };
}
