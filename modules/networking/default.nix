# Nestlo networking module
# Model API gateway, agent bridge network and NAT
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.networking;
  cidrParts = lib.splitString "/" cfg.agentNetCIDR;
  octets = lib.splitString "." (lib.head cidrParts);
  hostAddress = lib.concatStringsSep "." (lib.take 3 octets ++ [ "1" ]);
  prefixLength = lib.toInt (lib.last cidrParts);

  hostOf = url:
    let m = builtins.match "[a-z]+://([^/:]+).*" url;
    in if m == null then null else lib.head m;

  gatewayUrl = "http://127.0.0.1:${toString cfg.modelGatewayPort}";
  adminSocket = config.nestlo.services.settings.gateway.admin_socket;
  recordingsDir = "/var/lib/nestlo/recordings";

  dlp = config.nestlo.gateway.dlp;
  dlpDetectors = [
    "private_key" "aws_access_key" "aws_secret_key" "github_token" "slack_token" "api_key" "jwt"
    "provider_key" "credential_assignment" "high_entropy"
    "email" "credit_card" "iban" "phone"
  ];
  dlpMode = lib.types.enum [ "off" "log" "mask" "block" ];
  dlpDetectorList = lib.types.listOf (lib.types.enum ([ "all" ] ++ dlpDetectors));

  # Call the gateway admin socket; prints the body, or the error message and a
  # non-zero status. Shared by the two CLIs below.
  adminApi = ''
    ADMIN_SOCKET="${adminSocket}"
    api() {
      local method="$1" path="$2" data="''${3:-}" out code
      local args=(-sS --unix-socket "$ADMIN_SOCKET" -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
      if [ -n "$data" ]; then
        args+=(--data "$data")
      fi
      out=$(curl "''${args[@]}" "http://localhost/_nestlo/$path") \
        || { echo "cannot reach the gateway admin socket $ADMIN_SOCKET" >&2; return 1; }
      code=''${out##*$'\n'}
      out=''${out%$'\n'*}
      if [ "$code" -ge 300 ]; then
        echo "error: $(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null || printf '%s' "$out")" >&2
        return 1
      fi
      printf '%s\n' "$out"
    }
    ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    check_id() {
      [[ "$1" =~ $ID_RE ]] || { echo "invalid id: $1" >&2; exit 1; }
    }
  '';

  replayCli = pkgs.writeShellApplication {
    name = "nestlo-replay";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils pkgs.util-linux ];
    text = ''
      GATEWAY="${gatewayUrl}"
      RECORDINGS="${recordingsDir}"
      ${adminApi}
      usage() {
        cat <<'EOF'
      Usage: nestlo-replay <command>

        list                        Recorded sessions
        show <recording> [<seq>]    Requests of a recording, or one request/response in full
        start <recording> [<id>]    Answer agent <id> (new by default) from a recording,
                                    in order, without contacting the provider (zero cost)
        stop <id>                   End the replay registered for <id>
        status <id>                 Replay position of <id>
        record <id> [on|off]        Record (or stop recording) the requests of agent <id>

      Recording all sessions is a NixOS option: nestlo.networking.recordSessions.
      EOF
      }

      case "''${1:-list}" in
        list)
          api GET recordings | jq -r '
            (["RECORDING", "REQUESTS", "STARTED (UTC)"] | @tsv),
            (.recordings[] | [.id, (.requests | tostring), ((.started // 0) | floor | todate)] | @tsv)' \
            | column -t -s $'\t'
          ;;
        show)
          [ $# -ge 2 ] || { usage; exit 1; }
          check_id "$2"
          if [ $# -ge 3 ]; then
            [[ "$3" =~ ^[0-9]+$ ]] || { echo "invalid sequence number: $3" >&2; exit 1; }
            file="$RECORDINGS/$2/$(printf '%06d' "$((10#$3))").json"
            [ -r "$file" ] || { echo "cannot read $file (operators need the nestlo group)" >&2; exit 1; }
            jq . "$file"
          else
            api GET "recordings/$2" | jq -r '
              (["SEQ", "METHOD", "PATH", "STATUS", "MODEL", "STREAMED"] | @tsv),
              (.requests[] | [(.seq | tostring), .method, .path, (.status | tostring), (.model // "-"), (.streamed | tostring)] | @tsv)' \
              | column -t -s $'\t'
          fi
          ;;
        start)
          [ $# -ge 2 ] || { usage; exit 1; }
          rec="$2"
          check_id "$rec"
          id="''${3:-replay-''${rec:0:30}-$(printf '%04x' "$RANDOM")}"
          check_id "$id"
          res=$(api PUT "replay/$id" "$(jq -cn --arg r "$rec" '{recording: $r}')")
          # The gateway only answers agents that present their registered token
          token=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
          api PUT "agents/$id" "$(jq -cn --arg h "$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)" '{token_sha256: $h}')" >/dev/null
          echo "Replaying $rec as agent $id ($(echo "$res" | jq -r '.replay.total') requests)."
          echo
          echo "Run the agent with these variables; its requests are answered from the recording,"
          echo "in order, and cost nothing. A request that differs from the recording fails with"
          echo "409 replay_diverged."
          echo
          echo "  export NESTLO_AGENT_ID=$id"
          echo "  export ANTHROPIC_BASE_URL=$GATEWAY/agent/$id:$token/anthropic"
          echo "  export ANTHROPIC_API_KEY=nestlo-managed"
          echo "  export OPENAI_BASE_URL=$GATEWAY/agent/$id:$token/openai/v1"
          echo "  export OPENAI_API_KEY=nestlo-managed"
          echo
          echo "'nestlo spawn' chooses its own agent id, so start the agent in your own shell with the"
          echo "variables above (in a workspace with the same starting state as the recorded run)."
          ;;
        stop)
          [ $# -eq 2 ] || { usage; exit 1; }
          check_id "$2"
          api DELETE "replay/$2" >/dev/null
          echo "Replay for $2 ended."
          ;;
        status)
          [ $# -eq 2 ] || { usage; exit 1; }
          check_id "$2"
          api GET "replay/$2" | jq -r '
            if .replay == null then "\(.agent): not replaying"
            else "\(.agent): replaying \(.replay.recording), \(.replay.pos) of \(.replay.total) requests served" end'
          ;;
        record)
          [ $# -ge 2 ] || { usage; exit 1; }
          check_id "$2"
          if [ "''${3:-on}" = off ]; then
            api DELETE "record/$2" >/dev/null
            echo "Recording for $2: off"
          else
            api PUT "record/$2" '{"enabled": true}' >/dev/null
            echo "Recording for $2: on (recordings/$2 in $RECORDINGS)"
          fi
          ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
      esac
    '';
  };

  msgCli = pkgs.writeShellApplication {
    name = "nestlo-msg";
    runtimeInputs = [ pkgs.curl pkgs.jq pkgs.coreutils ];
    text = ''
      ADMIN_SOCKET="${adminSocket}"
      ID_RE='^@?[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

      usage() {
        cat <<'EOF'
      Usage: nestlo-msg <command>

        send [--from <name>] <topic> <text...>   Publish a message ("@<agent-id>" = that agent's inbox)
        read <topic> [--after <cursor>] [--wait <sec>] [--json]
                                                 Read a topic (any inbox needs the nestlo group)
        topics                                   Topics with messages

      Needs membership in the nestlo group (the command uses the gateway's
      admin socket; agents talk on the bus with their own credentials).
      EOF
      }

      # bus METHOD TOPIC QUERY [DATA]: prints the response body
      bus() {
        local method="$1" topic="$2" query="$3" data="''${4:-}" url out code
        local args=(-sS -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}' --max-time 90)
        if [ ! -w "$ADMIN_SOCKET" ]; then
          echo "nestlo-msg needs membership in the nestlo group (admin socket $ADMIN_SOCKET)" >&2
          return 1
        fi
        args+=(--unix-socket "$ADMIN_SOCKET")
        url="http://localhost/_nestlo/bus/$topic$query"
        if [ -n "$data" ]; then
          args+=(--data "$data")
        fi
        out=$(curl "''${args[@]}" "$url") || { echo "cannot reach the gateway" >&2; return 1; }
        code=''${out##*$'\n'}
        out=''${out%$'\n'*}
        if [ "$code" -ge 300 ]; then
          echo "error: $(printf '%s' "$out" | jq -r '.error.message // .' 2>/dev/null || printf '%s' "$out")" >&2
          return 1
        fi
        printf '%s\n' "$out"
      }

      check_topic() {
        [[ "$1" =~ $ID_RE ]] || { echo "invalid topic: $1" >&2; exit 1; }
      }

      case "''${1:-}" in
        send)
          shift
          from=operator
          if [ "''${1:-}" = --from ]; then
            from="''${2:?--from needs a name}"
            shift 2
          fi
          [ $# -ge 2 ] || { usage; exit 1; }
          topic="$1"
          shift
          check_topic "$topic"
          bus POST "$topic" "?from=$from" "$(jq -cn --arg t "$*" '{body: $t}')" \
            | jq -r '"sent to \(.topic) (id \(.id))"'
          ;;
        read)
          shift
          [ $# -ge 1 ] || { usage; exit 1; }
          topic="$1"
          shift
          check_topic "$topic"
          after=0 wait=0 json=0
          while [ $# -gt 0 ]; do
            case "$1" in
              --after) after="''${2:?--after needs a cursor}"; shift 2 ;;
              --wait) wait="''${2:?--wait needs seconds}"; shift 2 ;;
              --json) json=1; shift ;;
              *) usage; exit 1 ;;
            esac
          done
          res=$(bus GET "$topic" "?after=$after&wait=$wait")
          if [ "$json" -eq 1 ]; then
            echo "$res"
          else
            echo "$res" | jq -r '.messages[] | "[\(.id)] \(.ts | floor | todate) \(.from): \(.body | if type == "string" then . else tojson end)"'
            echo "$res" | jq -r '"cursor: \(.cursor)"' >&2
          fi
          ;;
        topics)
          [ -w "$ADMIN_SOCKET" ] || { echo "listing topics needs membership in the nestlo group" >&2; exit 1; }
          curl -fsS --unix-socket "$ADMIN_SOCKET" http://localhost/_nestlo/bus | jq -r '.topics[]'
          ;;
        -h|--help|help|"") usage ;;
        *) usage; exit 1 ;;
      esac
    '';
  };
in
{
  options.nestlo.networking = {
    enable = lib.mkEnableOption "Nestlo networking and the model gateway";

    agentNetCIDR = lib.mkOption {
      type = lib.types.str;
      default = "10.200.0.0/24";
      description = "Subnet for agent containers";
    };

    natExternalInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "enp1s0";
      description = "Uplink interface for NAT of the agent subnet (null: any)";
    };

    modelGatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Port of the LLM model gateway. It listens on 127.0.0.1 and on the
        agent bridge address, so container-isolated agents can reach it.
      '';
    };

    bridgeAddress = lib.mkOption {
      type = lib.types.str;
      default = hostAddress;
      readOnly = true;
      description = "Address of the host on the agent bridge (nestlo0): the .1 of agentNetCIDR";
    };

    recordSessions = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Record every request/response pair of every agent under
        ${recordingsDir}/<agent-id>/<seq>.json (readable by the nestlo
        group), for `nestlo-replay`. Recordings contain prompts and
        completions, so they are kept private to the nestlo group. Recording
        can also be switched on per agent with `nestlo-replay record <id>`.
      '';
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          baseUrl = lib.mkOption {
            type = lib.types.str;
            description = "Upstream API base URL";
          };
          api = lib.mkOption {
            type = lib.types.enum [ "anthropic" "openai" "openai-compatible" "azure-openai" "gemini" ];
            description = ''
              Kind of API: how the key is sent and how token usage is read.

              - anthropic: Messages API (x-api-key)
              - openai: OpenAI Chat Completions and Responses (Bearer)
              - openai-compatible: a local server speaking the OpenAI format
                (ollama, llama.cpp, vLLM). No key needed; every model costs $0
                unless `zeroCost = false`.
              - azure-openai: Azure OpenAI (api-key header, deployments in the
                path; set `apiVersion`)
              - gemini: Google Generative Language API (x-goog-api-key)

              AWS Bedrock and Google Vertex AI are not supported yet (they need
              request signing / OAuth tokens).
            '';
          };
          zeroCost = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = ''
              Count every model of this provider as $0 (local inference) instead
              of using pricing.json, and reserve no budget for its requests.
              null: true for api = "openai-compatible", false otherwise.
            '';
          };
          apiVersion = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "2024-10-21";
            description = "api-version query added to Azure OpenAI requests that lack one";
          };
          fallbacks = lib.mkOption {
            type = lib.types.listOf (lib.types.either lib.types.str (lib.types.submodule {
              options = {
                provider = lib.mkOption {
                  type = lib.types.str;
                  description = "Name of another entry of nestlo.networking.providers";
                };
                model = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Model to request from the fallback (null: keep the requested one)";
                };
              };
            }));
            default = [ ];
            example = [ "openai-backup" { provider = "local"; model = "llama3.1"; } ];
            description = ''
              Providers to try, in order, when this one answers 5xx or 429, times
              out or cannot be reached before the first response byte. Each must
              use the same wire format (same `api` family, so a request body can
              be replayed) and have a key or be a local server. The client's own
              credentials are never sent to a fallback; its configured key is
              injected instead. Nothing is retried once a response has started.
            '';
          };
          timeoutSec = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.positive;
            default = null;
            description = "Upstream timeout for this provider (null: the gateway default)";
          };
          keyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              File holding the provider API key. When readable by the gateway,
              agents get the placeholder key "nestlo-managed" and the gateway
              injects the real one, so agents never see it.
            '';
          };
        };
      });
      default = { };
      description = "LLM providers routed through the gateway at /agent/<id>/<name>/...";
    };
  };

  # ── Data loss prevention in the gateway (docs/dlp.md) ──────────────
  options.nestlo.gateway.dlp = {
    mode = lib.mkOption {
      type = dlpMode;
      default = "off";
      description = ''
        What the gateway does with secrets and personal data it finds in
        request bodies before forwarding them to a provider:
        off (no scan), log (record the detector types in the audit log and
        forward unchanged), mask (replace each match with [REDACTED:type]) or
        block (refuse with 403 dlp_blocked). Matched values are never logged.
      '';
    };

    detectors = lib.mkOption {
      type = dlpDetectorList;
      default = [ "all" ];
      example = [ "private_key" "aws_access_key" "github_token" "credit_card" ];
      description = ''
        Detectors to run: "all", or any of ${lib.concatStringsSep ", " dlpDetectors}.
        provider_key matches the API keys configured in nestlo.networking.providers.
      '';
    };

    scanResponses = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Also scan provider responses with the same policy. Only non-streaming
        responses are scanned (the body is held back until it has been
        checked); event streams are passed through unscanned.
      '';
    };

    maxScanBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16 * 1024 * 1024;
      description = ''
        Largest body that is scanned. In mask and block mode a larger request
        is refused (413 dlp_scan_limit) because it cannot be checked; in log
        mode it is forwarded unscanned.
      '';
    };

    overrides = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          mode = lib.mkOption {
            type = dlpMode;
            description = "Mode for agents whose id starts with this prefix";
          };
          detectors = lib.mkOption {
            type = lib.types.nullOr dlpDetectorList;
            default = null;
            description = "Detectors for these agents (null: the global list)";
          };
          scanResponses = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Response scanning for these agents (null: the global setting)";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''{ "ci-" = { mode = "block"; }; "scratch-" = { mode = "off"; }; }'';
      description = "Per agent-id-prefix policy; the longest matching prefix wins";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.nestlo.runtime.enable;
      message = "nestlo.networking (the model gateway) needs nestlo.runtime.enable";
    }];

    nestlo.networking.providers = {
      anthropic = {
        baseUrl = lib.mkDefault "https://api.anthropic.com";
        api = "anthropic";
        keyFile = lib.mkDefault "/run/secrets/ANTHROPIC_API_KEY";
      };
      openai = {
        baseUrl = lib.mkDefault "https://api.openai.com";
        api = "openai";
        keyFile = lib.mkDefault "/run/secrets/OPENAI_API_KEY";
      };
    };

    # Only the gateway may reach the provider APIs from the agent user
    nestlo.security.gatewayOnlyDomains =
      lib.filter (h: h != null && h != "localhost" && builtins.match "[0-9.]+" h == null)
        (lib.mapAttrsToList (_: p: hostOf p.baseUrl) cfg.providers);

    nestlo.services.settings = {
      gateway = {
        listen = [ "127.0.0.1" hostAddress ];
        port = cfg.modelGatewayPort;
        pricing_file = "/etc/nestlo/pricing.json";
        dlp = {
          inherit (dlp) mode detectors;
          scan_responses = dlp.scanResponses;
          max_scan_bytes = dlp.maxScanBytes;
          overrides = lib.mapAttrs
            (_: o: { inherit (o) mode; }
              // lib.optionalAttrs (o.detectors != null) { inherit (o) detectors; }
              // lib.optionalAttrs (o.scanResponses != null) { scan_responses = o.scanResponses; })
            dlp.overrides;
        };
      };
      recording = {
        enabled = cfg.recordSessions;
        dir = recordingsDir;
      };
      providers = lib.mapAttrs (_: p: {
        base_url = p.baseUrl;
        inherit (p) api;
      } // lib.optionalAttrs (p.keyFile != null) { key_file = p.keyFile; }
        // lib.optionalAttrs (p.zeroCost != null) { zero_cost = p.zeroCost; }
        // lib.optionalAttrs (p.apiVersion != null) { api_version = p.apiVersion; }
        // lib.optionalAttrs (p.timeoutSec != null) { timeout_sec = p.timeoutSec; }
        // lib.optionalAttrs (p.fallbacks != [ ]) {
          fallbacks = map
            (f: if builtins.isString f then { provider = f; }
                else { inherit (f) provider; } // lib.optionalAttrs (f.model != null) { inherit (f) model; })
            p.fallbacks;
        }) cfg.providers;
    };

    environment.etc."nestlo/pricing.json".source = lib.mkDefault ../budget-controller/pricing.json;

    # Session recordings: written by the gateway, readable by operators only
    systemd.tmpfiles.rules = [ "d ${recordingsDir} 0750 nestlo nestlo" ];

    environment.systemPackages = [ replayCli msgCli ];

    # ─ Model gateway ──────────────────────────────────────────────────
    systemd.services.nestlo-model-gateway = {
      description = "Nestlo model gateway (LLM proxy with budgets and rate limits)";
      # The bridge address must exist to bind to it (Restart retries otherwise)
      after = [ "network.target" "redis-nestlo.service" "network-addresses-nestlo0.service" ];
      requires = [ "redis-nestlo.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        config.environment.etc."nestlo/services.toml".source
        config.environment.etc."nestlo/pricing.json".source
      ];

      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        # The service sends READY=1 once listening and WATCHDOG=1 while healthy
        WatchdogSec = 30;
        TimeoutStartSec = 60;
        User = "nestlo";
        Group = "nestlo";
        SupplementaryGroups = [ "redis-nestlo" ];
        ExecStart = "${pkgs.nestlo.services}/bin/nestlo-model-gateway";
        Restart = "on-failure";
        RestartSec = 3;
        # Admin socket: reachable by the nestlo group (operators), not agents
        RuntimeDirectory = "nestlo-gateway";
        RuntimeDirectoryMode = "0750";
        UMask = "0007";

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/nestlo/logs" recordingsDir ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        LockPersonality = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
      };
    };

    # ─ Bridge + NAT for agent containers ──────────────────────────────
    networking.bridges.nestlo0.interfaces = [ ];
    networking.interfaces.nestlo0.ipv4.addresses = [{
      address = hostAddress;
      inherit prefixLength;
    }];

    # Container-isolated agents reach the host only through the gateway and
    # the resolver. This chain comes before the global allowed ports (e.g.
    # SSH), which would otherwise apply to the bridge as well.
    networking.firewall.extraCommands = ''
      iptables -D INPUT -i nestlo0 -j nestlo-in 2>/dev/null || true
      iptables -F nestlo-in 2>/dev/null || iptables -N nestlo-in
      iptables -I INPUT 1 -i nestlo0 -j nestlo-in
      iptables -A nestlo-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -A nestlo-in -d ${hostAddress} -p tcp --dport ${toString cfg.modelGatewayPort} -j ACCEPT
      iptables -A nestlo-in -d ${hostAddress} -p udp --dport 53 -j ACCEPT
      iptables -A nestlo-in -d ${hostAddress} -p tcp --dport 53 -j ACCEPT
      iptables -A nestlo-in -d ${hostAddress} -p icmp --icmp-type echo-request -j ACCEPT
      iptables -A nestlo-in -j REJECT
      ip6tables -D INPUT -i nestlo0 -j DROP 2>/dev/null || true
      ip6tables -I INPUT 1 -i nestlo0 -j DROP
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D INPUT -i nestlo0 -j nestlo-in 2>/dev/null || true
      iptables -F nestlo-in 2>/dev/null || true
      iptables -X nestlo-in 2>/dev/null || true
      ip6tables -D INPUT -i nestlo0 -j DROP 2>/dev/null || true
    '';

    # The resolver answers on the bridge for containers (and, with egress
    # denied, only resolves allowed domains and fills the egress ipsets)
    services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
      settings.listen-address = [ hostAddress ];
    };
    systemd.services.dnsmasq = lib.mkIf config.services.dnsmasq.enable {
      after = [ "network-addresses-nestlo0.service" ];
      wants = [ "network-addresses-nestlo0.service" ];
      serviceConfig.Restart = lib.mkDefault "on-failure";
    };

    networking.nat = {
      enable = true;
      internalInterfaces = [ "nestlo0" ];
      externalInterface = cfg.natExternalInterface;
    };
  };
}
