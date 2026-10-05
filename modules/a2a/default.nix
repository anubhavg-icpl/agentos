# Nestlo A2A + ACP module
#
# A2A (Agent2Agent, https://github.com/a2aproject/A2A, Apache-2.0): other
# agent systems discover a Nestlo agent from its Agent Card
# (/.well-known/agent-card.json) and send it work with JSON-RPC (SendMessage,
# GetTask, CancelTask, streaming). Each message becomes a task in the Nestlo
# orchestrator, so the usual gates apply: the orchestrator's validation and
# policy, RBAC, the approval gate, per-task budgets at the model gateway,
# the audit trail. Server: services/nestlo_services/a2a.py (`nestlo-a2a`).
#
# ACP (Agent Client Protocol, https://github.com/agentclientprotocol,
# Apache-2.0): editors (Zed, herdr, ...) drive a coding agent over stdio.
# `nestlo-acp <agent>` starts one of the installed agents in its ACP mode,
# registered with the model gateway like `nestlo spawn` does, so editor
# sessions get their own gateway identity, budget and audit entries.
#
# See docs/a2a.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.a2a;
  acp = cfg.acp;
  rt = config.nestlo.runtime;
  orch = config.nestlo.orchestration;
  net = config.nestlo.networking;

  loopback = a: lib.hasPrefix "127." a || a == "::1";

  skillType = lib.types.submodule {
    options = {
      id = lib.mkOption { type = lib.types.str; default = "run"; description = "Skill id in the Agent Card."; };
      name = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Display name (default: the id)."; };
      description = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "What the skill does (default: the agent's description)."; };
      tags = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "nestlo" ]; description = "Tags in the Agent Card."; };
      examples = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; description = "Example prompts."; };
    };
  };

  agentType = lib.types.submodule {
    options = {
      agent = lib.mkOption {
        type = lib.types.str;
        example = "claude";
        description = "Nestlo agent that runs the tasks (a key of nestlo.runtime.agents with an entry in nestlo.orchestration.taskCommands).";
      };
      workspace = lib.mkOption {
        type = lib.types.str;
        example = "widgets";
        description = ''
          Workspace the tasks run in: a name under nestlo.runtime.workspaceRoot
          or an absolute path below it. Fixed here; a client cannot choose it.
        '';
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Agent Card description. The card is public (unless publicCard is off): do not put anything sensitive in it.";
      };
      version = lib.mkOption { type = lib.types.str; default = "1.0.0"; description = "Agent Card version."; };
      skills = lib.mkOption {
        type = lib.types.listOf skillType;
        default = [ { } ];
        description = "Skills advertised in the Agent Card (informational: every message becomes the same kind of task).";
      };
      budgetUSD = lib.mkOption {
        type = lib.types.nullOr lib.types.numbers.positive;
        default = null;
        description = "Daily budget of each task's gateway agent id in USD (null: the gateway default).";
      };
      timeoutSec = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Task timeout (null: nestlo.orchestration.taskTimeoutSec).";
      };
      isolate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run each task in a git worktree of its own, so concurrent A2A tasks do not share a working tree.";
      };
      gate = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Hold each task until an operator approves it (`nestlo task approve
          <id>`). The A2A task then reports TASK_STATE_INPUT_REQUIRED. Use this
          for any agent reachable by clients you do not fully trust.
        '';
      };
      model = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Model passed to the task."; };
      maxRetries = lib.mkOption { type = lib.types.nullOr lib.types.ints.unsigned; default = null; description = "Retries of a failed task (capped by the orchestrator)."; };
      priority = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; description = "Orchestrator priority of the tasks."; };
    };
  };

  skillToml = s: { inherit (s) id tags; }
    // lib.optionalAttrs (s.name != null) { inherit (s) name; }
    // lib.optionalAttrs (s.description != null) { inherit (s) description; }
    // lib.optionalAttrs (s.examples != [ ]) { inherit (s) examples; };

  agentToml = _: a:
    { inherit (a) agent workspace version isolate gate; skills = map skillToml a.skills; }
    // lib.optionalAttrs (a.description != null) { inherit (a) description; }
    // lib.optionalAttrs (a.budgetUSD != null) { budget_usd = a.budgetUSD; }
    // lib.optionalAttrs (a.timeoutSec != null) { timeout_sec = a.timeoutSec; }
    // lib.optionalAttrs (a.model != null) { inherit (a) model; }
    // lib.optionalAttrs (a.maxRetries != null) { max_retries = a.maxRetries; }
    // lib.optionalAttrs (a.priority != null) { inherit (a) priority; };

  # ── ACP launcher ───────────────────────────────────────────────────────
  acpAgentType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Argument vector that starts the agent in ACP mode (stdio JSON-RPC).";
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra environment for the agent.";
      };
    };
  };

  acpTable = pkgs.writeText "nestlo-acp-agents.json" (builtins.toJSON
    (lib.mapAttrs (_: a: { inherit (a) command env; }) acp.agents));

  acpLauncher = pkgs.writeShellApplication {
    name = "nestlo-acp";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      RUNTIME="''${NESTLO_RUNTIME:-/etc/nestlo/runtime.json}"
      TABLE=${acpTable}
      die() { echo "nestlo-acp: $*" >&2; exit 1; }   # stdout belongs to the ACP stream

      usage() {
        echo "usage: nestlo-acp <agent> [--workspace <name|path>] [--budget <usd>] [--model <m>] [-- extra agent args]" >&2
        echo "       nestlo-acp --list" >&2
        echo "Starts <agent> in Agent Client Protocol mode on stdin/stdout, with its model calls" >&2
        echo "through the Nestlo model gateway. Configure your editor to run this command." >&2
      }

      case "''${1:-}" in
        ""|-h|--help) usage; exit 2 ;;
        --list) jq -r 'to_entries[] | "\(.key)\t\(.value.command | join(" "))"' "$TABLE"; exit 0 ;;
      esac
      agent="$1"; shift
      jq -e --arg a "$agent" 'has($a)' "$TABLE" >/dev/null || die "no ACP launcher for '$agent' (see: nestlo-acp --list)"

      workspace="$PWD" budget="" model=""
      extra=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --workspace) workspace="''${2:?--workspace needs a value}"; shift 2 ;;
          --budget) budget="''${2:?--budget needs a value}"; shift 2 ;;
          --model) model="''${2:?--model needs a value}"; shift 2 ;;
          --) shift; extra+=("$@"); break ;;
          *) extra+=("$1"); shift ;;
        esac
      done

      [ -r "$RUNTIME" ] || die "$RUNTIME not found; is nestlo.runtime enabled?"
      root=$(jq -r .workspace_root "$RUNTIME")
      if [[ "$workspace" != */* ]] && [ -d "$root/$workspace" ]; then workspace="$root/$workspace"; fi
      [ -d "$workspace" ] || die "no such workspace: $workspace"
      workspace=$(realpath "$workspace")

      id="acp-$agent-$(date +%Y%m%d-%H%M%S)-$(printf '%04x' "$RANDOM")"
      export NESTLO_AGENT_ID="$id" NESTLO_WORKSPACE="$workspace"
      [ -z "$model" ] || export NESTLO_MODEL="$model"

      if [ "$(jq -r .gateway_enabled "$RUNTIME")" = true ]; then
        gw=$(jq -r .gateway_url "$RUNTIME")
        sock=$(jq -r .admin_socket "$RUNTIME")
        health=$(curl -fsS -m 5 "$gw/_nestlo/health") || die "model gateway is not responding at $gw"
        [ -w "$sock" ] || die "registering with the model gateway needs membership in the nestlo group"
        # Same scheme as `nestlo spawn`: the gateway answers only this token
        token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
        admin() { curl -fsS -m 10 --unix-socket "$sock" -X PUT -H 'Content-Type: application/json' --data "$2" "http://localhost/_nestlo/$1" >/dev/null; }
        admin "agents/$id" "$(jq -cn --arg h "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" '{token_sha256: $h}')" \
          || die "could not register $id with the model gateway"
        [ -z "$budget" ] || admin "budget/$id" "$(jq -cn --argjson usd "$budget" '{daily_usd: $usd}')"
        export ANTHROPIC_BASE_URL="$gw/agent/$id:$token/anthropic"
        export OPENAI_BASE_URL="$gw/agent/$id:$token/openai/v1"
        # Goose reads hosts, not base URLs (it appends v1/messages, v1/chat/completions)
        export ANTHROPIC_HOST="$gw/agent/$id:$token/anthropic"
        export OPENAI_HOST="$gw/agent/$id:$token/openai"
        # Gemini CLI: only when the gateway has a gemini provider
        if [ "$(echo "$health" | jq -r '.providers.gemini // empty | type')" = object ]; then
          export GOOGLE_GEMINI_BASE_URL="$gw/agent/$id:$token/gemini"
          [ "$(echo "$health" | jq -r '.providers.gemini.managed_key // false')" != true ] || export GEMINI_API_KEY=nestlo-managed
        fi
        for provider in anthropic openai; do
          var="''${provider^^}_API_KEY"
          if [ "$(echo "$health" | jq -r --arg p "$provider" '.providers[$p].managed_key // false')" = true ]; then
            export "$var=nestlo-managed"
          fi
        done
      elif [ -n "$budget" ]; then
        die "--budget needs the model gateway (nestlo.networking.enable)"
      fi

      while IFS=$'\t' read -r k v; do export "$k=$v"; done < <(jq -r --arg a "$agent" '.[$a].env | to_entries[] | "\(.key)\t\(.value)"' "$TABLE")
      mapfile -t argv < <(jq -r --arg a "$agent" '.[$a].command[]' "$TABLE")
      cd "$workspace"
      exec "''${argv[@]}" "''${extra[@]}"
    '';
  };
in
{
  options.nestlo.a2a = {
    enable = lib.mkEnableOption "the A2A (Agent2Agent) server: Nestlo agents as A2A agents";

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to bind. Keep it on loopback and publish it through a TLS reverse proxy; refused otherwise unless allowNonLoopback.";
    };
    allowNonLoopback = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Permit a non-loopback address. The server speaks plain HTTP and bearer tokens: only use this on a trusted, firewalled network.";
    };
    port = lib.mkOption { type = lib.types.port; default = 9966; description = "Port of the A2A server."; };
    publicUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://agents.example.com/a2a";
      description = "Base URL clients reach the server at, written into the Agent Cards (default: http://<address>:<port>). Behind a reverse proxy set this to its URL.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/nestlo-a2a-tokens";
      description = ''
        Root-only file with one client per line: `name:token` or
        `name:token:agent1,agent2` (the agents that client may use; default
        all). Tokens are 16 to 256 characters of `[A-Za-z0-9._~+/=-]`;
        generate with `openssl rand -hex 32`. Required. Passed to the
        service as a systemd credential and re-read when it changes.
      '';
    };

    protocolVersion = lib.mkOption {
      type = lib.types.enum [ "1.0" "0.3" ];
      default = "1.0";
      description = ''
        A2A version of the Agent Card. Requests are answered in the dialect
        of the method name the client uses (SendMessage: 1.0, message/send:
        0.3), whatever this is; set "0.3" if your clients read the card with
        a 0.3 SDK.
      '';
    };
    publicCard = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Serve Agent Cards without authentication, as the specification expects. Off: the card needs a bearer token too.";
    };
    blockTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "How long a blocking SendMessage waits for the task before returning it as it is (clients then poll with GetTask or stream).";
    };

    agents = lib.mkOption {
      type = lib.types.attrsOf agentType;
      default = { };
      example = lib.literalExpression ''
        {
          coder = {
            agent = "claude";
            workspace = "widgets";
            description = "Fixes bugs in the widgets repository";
            budgetUSD = 5;
            gate = true;
          };
        }
      '';
      description = ''
        Agents to expose, by name (`[a-z0-9-]`, at most 32). The Agent Card of
        `coder` is at /agents/coder/.well-known/agent-card.json and its
        JSON-RPC endpoint at /agents/coder.
      '';
    };
    defaultAgent = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Agent served at /.well-known/agent-card.json and POST / (default: the only agent, if there is exactly one).";
    };

    acp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Install `nestlo-acp`, which starts a Nestlo agent in ACP mode for editors (independent of the A2A server).";
      };
      agents = lib.mkOption {
        type = lib.types.attrsOf acpAgentType;
        description = ''
          Agents `nestlo-acp` can start. The defaults are the ones whose ACP
          mode is documented upstream: Claude Code and Codex through their
          ACP adapters, and Gemini CLI, Goose, OpenCode and Qwen Code natively.
        '';
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf acp.enable {
      environment.systemPackages = [ acpLauncher ];
    })

    {
      nestlo.a2a.acp.agents = {
        # https://github.com/agentclientprotocol/claude-agent-acp (npm
        # @agentclientprotocol/claude-agent-acp, bin claude-agent-acp)
        claude.command = lib.mkDefault [ (lib.getExe pkgs.claude-agent-acp) ];
        # https://github.com/agentclientprotocol/codex-acp (bin codex-acp)
        codex.command = lib.mkDefault [ (lib.getExe pkgs.codex-acp) ];
        # gemini-cli docs/cli/acp-mode.md: `gemini --acp` (--experimental-acp is deprecated)
        gemini.command = lib.mkDefault [ "gemini" "--acp" ];
        # goose-cli `goose acp`: "Run goose as an ACP agent server on stdio"
        goose.command = lib.mkDefault [ "goose" "acp" ];
        # opencode docs (acp.mdx): `opencode acp`
        opencode.command = lib.mkDefault [ "opencode" "acp" ];
        # qwen-code packages/cli config: `--acp` (`--experimental-acp` deprecated)
        qwen.command = lib.mkDefault [ "qwen" "--acp" ];
      };
    }

    (lib.mkIf cfg.enable {
      assertions = [
        { assertion = rt.enable; message = "nestlo.a2a needs nestlo.runtime.enable (Redis, the nestlo user, workspaces)"; }
        { assertion = orch.enable; message = "nestlo.a2a submits its work to the orchestrator; set nestlo.orchestration.enable = true"; }
        { assertion = cfg.tokenFile != null; message = "nestlo.a2a.tokenFile must be set: the A2A endpoint is never served unauthenticated"; }
        { assertion = cfg.agents != { }; message = "nestlo.a2a.agents is empty: nothing to expose"; }
        {
          assertion = loopback cfg.address || cfg.allowNonLoopback;
          message = "nestlo.a2a.address must be a loopback address (or set allowNonLoopback)";
        }
        {
          assertion = lib.all (n: builtins.match "[a-z0-9][a-z0-9-]{0,31}" n != null) (lib.attrNames cfg.agents);
          message = "nestlo.a2a.agents: names must match [a-z0-9][a-z0-9-]{0,31}";
        }
        {
          assertion = lib.all (a: rt.agents ? ${a.agent} && orch.taskCommands ? ${a.agent}) (lib.attrValues cfg.agents);
          message = "nestlo.a2a.agents.*.agent must be a key of nestlo.runtime.agents that also has an entry in nestlo.orchestration.taskCommands";
        }
        {
          assertion = cfg.defaultAgent == null || cfg.agents ? ${cfg.defaultAgent};
          message = "nestlo.a2a.defaultAgent is not one of nestlo.a2a.agents";
        }
        {
          assertion = lib.all (a: a.budgetUSD == null) (lib.attrValues cfg.agents) || net.enable;
          message = "nestlo.a2a.agents.*.budgetUSD needs nestlo.networking.enable (budgets are enforced by the model gateway)";
        }
      ];

      nestlo.services.settings.a2a = {
        listen = cfg.address;
        inherit (cfg) port;
        allow_non_loopback = cfg.allowNonLoopback;
        protocol_version = cfg.protocolVersion;
        public_card = cfg.publicCard;
        block_timeout_sec = cfg.blockTimeoutSec;
        agents = lib.mapAttrs agentToml cfg.agents;
      }
      // lib.optionalAttrs (cfg.publicUrl != null) { public_url = cfg.publicUrl; }
      // lib.optionalAttrs (cfg.defaultAgent != null) { default_agent = cfg.defaultAgent; };

      systemd.services.nestlo-a2a = {
        description = "Nestlo A2A (Agent2Agent) server";
        after = [ "network.target" "nestlo-orchestrator.service" ];
        wants = [ "nestlo-orchestrator.service" ];
        wantedBy = [ "multi-user.target" ];
        restartTriggers = [ config.environment.etc."nestlo/services.toml".source ];

        serviceConfig = {
          Type = "simple";
          # `nestlo` is the group of the orchestrator socket (what operators
          # use); the service has no other privileges and does not touch Redis
          User = "nestlo";
          Group = "nestlo";
          LoadCredential = [ "tokens:${toString cfg.tokenFile}" ];
          ExecStart = "${pkgs.nestlo.services}/bin/nestlo-a2a --token-file %d/tokens";
          Restart = "on-failure";
          RestartSec = 3;

          NoNewPrivileges = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          CapabilityBoundingSet = "";
          UMask = "0077";
        };
      };
    })
  ];
}
