# Nestlo Agent Orca module
#
# Agent Orca (https://github.com/heddles/agent-orca, Apache-2.0) is a
# Kubernetes operator for AI agents: agents, model providers, tools, MCP
# servers, workflows, guardrails and knowledge bases are CRDs, and each run
# is a pod with a model-router sidecar. This module makes it part of Nestlo:
#
#   - a single-node k3s cluster whose pod and service ranges stay clear of
#     Nestlo's own networks, with the operator, UI, model router, MCP
#     ingester, Redis and the pause image built by Nix and loaded into it
#     (nothing of the platform is pulled from a registry)
#   - the agent-orca Helm chart from the same pinned source, deployed by
#     k3s' Helm controller
#   - every model call through the Nestlo model gateway: the ModelProviders
#     point at the gateway as agent `orca` (or `agentId`), so orca runs get
#     Nestlo's budgets, DLP, loop detection, audit trail and real provider
#     keys that never enter the cluster
#   - the UI, the ACP API and the external task API on loopback ports, and
#     `aoctl` pointed at them
#
# See docs/orca.md.
{ config, pkgs, lib, ... }:

let
  cfg = config.nestlo.orca;
  net = config.nestlo.networking;
  orca = cfg.package;

  gwPort = toString net.modelGatewayPort;
  adminSocket = config.nestlo.services.settings.gateway.admin_socket;
  stateDir = "/var/lib/nestlo-orca";
  kubeconfig = "/etc/rancher/k3s/k3s.yaml";
  release = "agent-orca";
  ns = cfg.namespace;
  tag = orca.version;

  # The pause image every pod starts from (as in nixpkgs' k3s tests)
  pauseImage = pkgs.dockerTools.buildLayeredImage {
    name = "nestlo.local/pause";
    inherit tag;
    contents = pkgs.buildEnv {
      name = "nestlo-orca-pause-env";
      paths = [ pkgs.tini (lib.hiPrio pkgs.coreutils) pkgs.busybox ];
    };
    config.Entrypoint = [ "/bin/tini" "--" "/bin/sleep" "inf" ];
  };

  # The chart runs `redis-server` and probes with `sh -c redis-cli ...`
  redisImage = pkgs.dockerTools.buildLayeredImage {
    name = "nestlo.local/redis";
    tag = pkgs.redis.version;
    contents = [ pkgs.redis pkgs.busybox ];
    fakeRootCommands = ''
      mkdir -p data tmp && chmod 1777 tmp && chown 999:999 data
    '';
    config = {
      Env = [ "PATH=/bin" ];
      WorkingDir = "/data";
    };
  };

  img = image: {
    repository = image.imageName;
    tag = image.imageTag;
  };

  chart = pkgs.runCommand "agent-orca-chart-${tag}.tgz" { nativeBuildInputs = [ pkgs.kubernetes-helm ]; } ''
    export HOME=$TMPDIR
    helm package ${orca.chart} --version 0.1.0 --destination .
    mv agent-orca-*.tgz $out
  '';

  chartValues = lib.recursiveUpdate {
    fullnameOverride = release;
    operator = {
      image = img orca.images.operator // { pullPolicy = "Never"; };
      allowedRegistries = lib.concatStringsSep "," cfg.allowedRegistries;
    };
    modelRouter.image = img orca.images.model-router;
    mcpIngester.image = img orca.images.mcp-ingester;
    ui.image = img orca.images.ui-proxy // { pullPolicy = "Never"; };
    redis = {
      enabled = cfg.redis.enable;
      image = img redisImage // { pullPolicy = "Never"; };
    };
    # Run archival needs a separate CloudNativePG cluster, Hindsight a
    # separate memory service; neither is part of this module.
    database.enabled = false;
    hindsight.enabled = false;
    metrics.enabled = true;
  } cfg.chartValues;

  # ModelProviders and the default ModelSelector, written at runtime because
  # the base URLs carry the gateway token
  providerManifest = token: nsName: lib.concatMapStringsSep "\n---\n" (x: builtins.toJSON x) (
    [{
      apiVersion = "v1";
      kind = "Secret";
      metadata = { name = "nestlo-gateway-key"; namespace = nsName; };
      # A placeholder: the gateway swaps it for the provider's real key
      stringData.api-key = "nestlo-managed";
    }]
    ++ lib.mapAttrsToList (name: m: {
      apiVersion = "agentorca.agentorca.io/v1alpha1";
      kind = "ModelProvider";
      metadata = {
        inherit name;
        namespace = nsName;
        labels."app.kubernetes.io/managed-by" = "nestlo";
      };
      spec = {
        litellmModel = m.model;
        baseURL = "http://${cfg.network.gatewayAddress}:${gwPort}/agent/${cfg.agentId}:${token}/${m.provider}/v1";
        credentialsRef = { name = "nestlo-gateway-key"; key = "api-key"; };
        latencyProfile = m.latencyProfile;
      } // lib.optionalAttrs (m.capabilities != [ ]) { inherit (m) capabilities; }
        // lib.optionalAttrs (m.constraints != { }) { inherit (m) constraints; };
    }) cfg.models
    ++ lib.optional (cfg.models != { }) {
      apiVersion = "agentorca.agentorca.io/v1alpha1";
      kind = "ModelSelector";
      metadata = {
        name = "default";
        namespace = nsName;
        labels."app.kubernetes.io/managed-by" = "nestlo";
      };
      spec = {
        strategy = "rule-based";
        providers = map (name: { inherit name; }) (lib.attrNames cfg.models);
      };
    });

  providerNamespaces = lib.unique ([ ns ] ++ cfg.providerNamespaces);
  manifestFile = n: pkgs.writeText "nestlo-orca-providers-${n}.yaml" (providerManifest "@TOKEN@" n);

  setupScript = pkgs.writeShellApplication {
    name = "nestlo-orca-setup";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.kubectl ];
    text = ''
      export KUBECONFIG=${kubeconfig}
      umask 077
      mkdir -p ${stateDir}
      tok=${stateDir}/gateway-token
      if [ ! -s "$tok" ]; then
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$tok"
      fi

      admin() {
        curl -fsS -m 10 --unix-socket ${adminSocket} -X "$1" -H 'Content-Type: application/json' \
          "''${@:3}" "http://x/_nestlo/$2"
      }
      for _ in $(seq 1 60); do
        admin GET health >/dev/null 2>&1 && break
        sleep 1
      done
      hash=$(sha256sum < "$tok" | cut -d' ' -f1)
      admin PUT agents/${cfg.agentId} -d "$(jq -cn --arg h "$hash" '{token_sha256: $h}')" >/dev/null
      admin PUT budget/${cfg.agentId} -d '{"daily_usd": ${toString cfg.budgetUsd}}' >/dev/null

      # The Helm controller installs the chart (and its CRDs) after k3s starts
      for _ in $(seq 1 120); do
        kubectl get crd modelproviders.agentorca.agentorca.io >/dev/null 2>&1 && break
        sleep 5
      done
      kubectl wait --for condition=established --timeout=300s crd/modelproviders.agentorca.agentorca.io crd/modelselectors.agentorca.agentorca.io

      token=$(cat "$tok")
      ${lib.concatMapStrings (n: ''
        kubectl create namespace ${n} --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        sed "s/@TOKEN@/$token/" ${manifestFile n} | kubectl apply -f -
      '') providerNamespaces}
    '';
  };

  forward = name: svc: ports: {
    "nestlo-orca-forward-${name}" = {
      description = "Agent Orca ${name} on loopback";
      wantedBy = [ "multi-user.target" ];
      after = [ "k3s.service" "nestlo-orca-setup.service" ];
      wants = [ "nestlo-orca-setup.service" ];
      environment.KUBECONFIG = kubeconfig;
      serviceConfig = {
        ExecStart = "${pkgs.kubectl}/bin/kubectl port-forward --address 127.0.0.1 -n ${ns} svc/${svc} ${ports}";
        Restart = "always";
        RestartSec = 5;
      };
    };
  };

  modelType = lib.types.submodule {
    options = {
      provider = lib.mkOption {
        type = lib.types.str;
        example = "openai";
        description = ''
          Nestlo gateway provider (a `nestlo.services.settings.providers`
          entry) that serves the model. Orca speaks Chat Completions, so the
          provider must offer `v1/chat/completions`: OpenAI and
          OpenAI-compatible providers do, and so does `anthropic`
          (Anthropic's OpenAI-compatible endpoint).
        '';
      };
      model = lib.mkOption {
        type = lib.types.str;
        example = "gpt-4o";
        description = "Model name as the provider knows it (sent unchanged; no LiteLLM prefix).";
      };
      capabilities = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "code" "reasoning" ];
        description = "Capability tags for orca's rule-based router (reasoning, code, vision, fast, long-context, cheap).";
      };
      latencyProfile = lib.mkOption {
        type = lib.types.enum [ "fast" "medium" "slow" ];
        default = "medium";
        description = "Latency class for orca's router.";
      };
      constraints = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = { contextWindow = 200000; maxOutputTokens = 64000; };
        description = "ModelProvider `spec.constraints` (context window, output limit, prices).";
      };
    };
  };
in
{
  options.nestlo.orca = {
    enable = lib.mkEnableOption "Agent Orca, the Kubernetes operator for AI agents, on a single-node k3s cluster";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.nestlo.agent-orca;
      defaultText = lib.literalExpression "pkgs.nestlo.agent-orca";
      description = "Agent Orca build (binaries, chart and images).";
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      default = "agent-orca-system";
      description = "Namespace of the operator, the UI and Redis.";
    };

    agentId = lib.mkOption {
      type = lib.types.str;
      default = "orca";
      description = "Gateway agent id that every orca model call is made as (its budget, logs and audit entries).";
    };

    budgetUsd = lib.mkOption {
      type = lib.types.number;
      default = 20;
      description = "Daily gateway budget of `agentId`, in USD.";
    };

    models = lib.mkOption {
      type = lib.types.attrsOf modelType;
      default = {
        claude-sonnet = {
          provider = "anthropic";
          model = "claude-sonnet-4-6";
          capabilities = [ "reasoning" "code" "long-context" ];
        };
        gpt-4o = {
          provider = "openai";
          model = "gpt-4o";
          capabilities = [ "code" "vision" "fast" ];
        };
      };
      description = ''
        ModelProviders to create, by name, all served through the Nestlo
        gateway. A ModelSelector `default` lists them all. Set to `{ }` to
        manage ModelProviders yourself.
      '';
    };

    providerNamespaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "default" ];
      description = "Namespaces besides `namespace` that get the ModelProviders and the `default` ModelSelector (where you create Agents).";
    };

    allowedRegistries = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ghcr.io/heddles/" "registry.example.com/agents/" ];
      description = "Image prefixes agent images may come from; empty allows every registry.";
    };

    redis.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the chart's Redis (checkpoints, spend, token streams).";
    };

    chartValues = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = { operator.oidc.enabled = true; };
      description = ''
        Extra values for the agent-orca chart, merged over Nestlo's. They are
        stored in the world-readable Nix store: no secrets here.
      '';
    };

    k3s = {
      clusterCidr = lib.mkOption {
        type = lib.types.str;
        default = "10.220.0.0/16";
        description = "Pod range (k3s' default 10.42.0.0/16 overlaps Nestlo's nestlo0 network).";
      };
      serviceCidr = lib.mkOption {
        type = lib.types.str;
        default = "10.221.0.0/16";
        description = "Service range.";
      };
      clusterDns = lib.mkOption {
        type = lib.types.str;
        default = "10.221.0.10";
        description = "Cluster DNS service address (inside `serviceCidr`).";
      };
      disable = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "traefik" "servicelb" "metrics-server" "local-storage" ];
        description = ''
          Packaged k3s components left out. CoreDNS stays: the operator and
          the UI find their services by name. k3s pulls its own images
          (CoreDNS) from the internet unless you add `pkgs.k3s.airgap-images`
          to `services.k3s.images`.
        '';
      };
    };

    network.gatewayAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.89.3.1";
      description = ''
        Host address (on lo) where pods reach the model gateway. From the
        cluster network the host accepts the gateway port there, the API
        server and nothing else.
      '';
    };

    ports = {
      ui = lib.mkOption {
        type = lib.types.port;
        default = 9980;
        description = "Loopback port of the Agent Orca web UI.";
      };
      acp = lib.mkOption {
        type = lib.types.port;
        default = 9981;
        description = "Loopback port of the ACP API (agent discovery and runs).";
      };
      tasks = lib.mkOption {
        type = lib.types.port;
        default = 9982;
        description = "Loopback port of the external task API.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = net.enable;
      message = "nestlo.orca sends model calls through the Nestlo model gateway (nestlo.networking.enable).";
    }];

    services.k3s = {
      enable = true;
      role = "server";
      disable = cfg.k3s.disable;
      images = [ pauseImage redisImage ] ++ lib.attrValues orca.images;
      extraFlags = [
        "--pause-image=nestlo.local/pause:${tag}"
        "--cluster-cidr=${cfg.k3s.clusterCidr}"
        "--service-cidr=${cfg.k3s.serviceCidr}"
        "--cluster-dns=${cfg.k3s.clusterDns}"
        "--write-kubeconfig-mode=0600"
      ];
      autoDeployCharts.${release} = {
        package = chart;
        targetNamespace = ns;
        createNamespace = true;
        values = chartValues;
      };
    };

    environment.systemPackages = [ orca pkgs.kubectl ];
    environment.sessionVariables = {
      KUBECONFIG = kubeconfig;
      AOCTL_ENDPOINT = "http://127.0.0.1:${toString cfg.ports.tasks}";
      AOCTL_ACP_ENDPOINT = "http://127.0.0.1:${toString cfg.ports.acp}";
    };

    # The gateway listens on this host address too
    networking.interfaces.lo.ipv4.addresses = [{
      address = cfg.network.gatewayAddress;
      prefixLength = 32;
    }];
    nestlo.services.settings.gateway.listen = [ cfg.network.gatewayAddress ];

    # From pods (on cni0) the host offers the gateway and the API server
    # (the kubernetes service is DNATed to the node) and nothing else
    networking.firewall.extraCommands = ''
      iptables -D INPUT -i cni0 -j nestlo-orca-in 2>/dev/null || true
      iptables -F nestlo-orca-in 2>/dev/null || iptables -N nestlo-orca-in
      iptables -I INPUT 1 -i cni0 -j nestlo-orca-in
      iptables -A nestlo-orca-in -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      iptables -A nestlo-orca-in -d ${cfg.network.gatewayAddress} -p tcp --dport ${gwPort} -j ACCEPT
      iptables -A nestlo-orca-in -p tcp --dport 6443 -j ACCEPT
      iptables -A nestlo-orca-in -j REJECT
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D INPUT -i cni0 -j nestlo-orca-in 2>/dev/null || true
      iptables -F nestlo-orca-in 2>/dev/null || true
      iptables -X nestlo-orca-in 2>/dev/null || true
    '';
    # k3s' bridge and flannel's VXLAN device are not for dhcpcd
    networking.dhcpcd.denyInterfaces = [ "cni0" "flannel.1" "veth*" ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services = {
      nestlo-model-gateway = {
        after = [ "network-addresses-lo.service" ];
        wants = [ "network-addresses-lo.service" ];
      };

      # Gateway agent, token and budget; ModelProviders pointing at the gateway
      nestlo-orca-setup = {
        description = "Agent Orca: gateway agent and ModelProviders";
        wantedBy = [ "multi-user.target" ];
        after = [ "k3s.service" "nestlo-model-gateway.service" ];
        wants = [ "k3s.service" "nestlo-model-gateway.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe setupScript;
          Restart = "on-failure";
          RestartSec = 15;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };
    }
    // forward "ui" "${release}-ui" "${toString cfg.ports.ui}:80"
    // forward "api" "${release}-internal-api" "${toString cfg.ports.acp}:8000 ${toString cfg.ports.tasks}:8084";
  };
}
