# VM test of nestlo.orca (Agent Orca on single-node k3s):
#
#   nix build .#checks.x86_64-linux.orca
#
# Boots k3s with the Nix-built images only (no registry: CoreDNS and the
# chart's Redis are left out, so nothing is pulled), then checks that the
# Helm controller deploys the agent-orca chart and the operator becomes
# ready, that the setup unit registers agent `orca` with the model gateway
# and creates ModelProviders and the default ModelSelector that point at the
# gateway, that a pod reaches the gateway through the firewall chain and its
# Chat Completions call to the anthropic provider arrives upstream with the
# real key (never the placeholder) and is billed to `orca`, that pods reach
# nothing else on the host, and that the UI answers on its loopback port.
{ pkgs, nestloModules }:

let
  # Mock upstream: Chat Completions (Anthropic's OpenAI-compatible endpoint)
  mockLlm = pkgs.writers.writePython3Bin "mock-llm" { } ''
    import http.server
    import json

    LOG = "/var/lib/mock-llm/requests.jsonl"


    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"{}")
            with open(LOG, "a") as f:
                f.write(json.dumps({
                    "path": self.path,
                    "model": body.get("model"),
                    "x-api-key": self.headers.get("x-api-key"),
                    "authorization": self.headers.get("Authorization"),
                }) + "\n")
            data = json.dumps({
                "id": "chatcmpl-1", "object": "chat.completion",
                "model": body.get("model"),
                "choices": [{"index": 0, "finish_reason": "stop",
                             "message": {"role": "assistant",
                                         "content": "hello from the mock"}}],
                "usage": {"prompt_tokens": 1000, "completion_tokens": 10},
            }).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass


    http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
  '';

  curlImage = pkgs.dockerTools.buildLayeredImage {
    name = "nestlo.local/curl";
    tag = "test";
    contents = [ pkgs.curl pkgs.busybox ];
    config.Env = [ "PATH=/bin" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "nestlo-orca";
  globalTimeout = 3600;

  nodes.machine = { lib, ... }: {
    imports = nestloModules;

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      diskSize = 8192;
    };

    nestlo = {
      runtime.enable = true;
      networking = {
        enable = true;
        providers.anthropic = {
          baseUrl = "http://127.0.0.1:9999";
          keyFile = "/etc/nestlo-test/anthropic.key";
        };
      };
      orca = {
        enable = true;
        budgetUsd = 5;
        redis.enable = false;
        models.claude-sonnet = { provider = "anthropic"; model = "claude-test"; };
        k3s.disable = [ "coredns" "traefik" "servicelb" "metrics-server" "local-storage" ];
      };
    };

    services.k3s.images = [ curlImage ];

    environment.etc."nestlo-test/anthropic.key" = {
      text = "sk-test-real-key";
      mode = "0440";
      group = "nestlo";
    };

    environment.systemPackages = [ pkgs.jq ];

    systemd.services.mock-llm = {
      wantedBy = [ "multi-user.target" ];
      before = [ "nestlo-model-gateway.service" ];
      serviceConfig = {
        ExecStart = "${mockLlm}/bin/mock-llm";
        StateDirectory = "mock-llm";
      };
    };
  };

  testScript = ''
    import json

    KC = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl "
    ADMIN = "curl -fsS --unix-socket /run/nestlo-gateway/admin.sock http://x/_nestlo/"

    def kubectl(args):
        return machine.succeed(KC + args)

    def pod_curl(name, argv):
        """Run curl with argv in a throwaway pod; returns (phase, log)."""
        pod = {"apiVersion": "v1", "kind": "Pod",
               "metadata": {"name": name, "namespace": "default"},
               "spec": {"restartPolicy": "Never", "containers": [{
                   "name": name, "image": "nestlo.local/curl:test", "imagePullPolicy": "Never",
                   "command": ["curl"] + argv}]}}
        machine.succeed(f"cat > /tmp/{name}.json <<'EOF'\n{json.dumps(pod)}\nEOF")
        kubectl(f"apply -f /tmp/{name}.json")
        machine.wait_until_succeeds(
            KC + f"get pod {name} -n default -o jsonpath='{{.status.phase}}' | grep -Eq 'Succeeded|Failed'",
            timeout=300)
        phase = kubectl(f"get pod {name} -n default -o jsonpath='{{.status.phase}}'").strip()
        return phase, kubectl(f"logs -n default {name}")

    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("k3s.service")
    machine.wait_for_unit("nestlo-model-gateway.service")

    with subtest("the chart is deployed and the operator becomes ready"):
        machine.wait_until_succeeds(KC + "get deployment -n agent-orca-system agent-orca", timeout=900)
        machine.wait_until_succeeds(
            KC + "rollout status -n agent-orca-system deployment/agent-orca --timeout=30s", timeout=900)
        crds = kubectl("get crd -o name")
        for crd in ["agents", "agentruns", "agentworkflows", "modelproviders", "modelselectors", "tools"]:
            assert f"{crd}.agentorca.agentorca.io" in crds, crds

    with subtest("agent orca is registered and the ModelProviders point at the gateway"):
        machine.wait_until_succeeds(KC + "get modelprovider -n default claude-sonnet", timeout=900)
        for ns in ["agent-orca-system", "default"]:
            mp = json.loads(kubectl(f"get modelprovider -n {ns} claude-sonnet -o json"))
            base = mp["spec"]["baseURL"]
            assert base.startswith("http://10.89.3.1:"), base
            assert "/agent/orca:" in base and base.endswith("/anthropic/v1"), base
            assert mp["spec"]["litellmModel"] == "claude-test", mp
            sel = json.loads(kubectl(f"get modelselector -n {ns} default -o json"))
            assert {"name": "claude-sonnet"} in sel["spec"]["providers"], sel
        key = kubectl("get secret -n default nestlo-gateway-key -o jsonpath='{.data.api-key}' | base64 -d")
        assert key == "nestlo-managed", key
        mode = machine.succeed("stat -c %a /var/lib/nestlo-orca/gateway-token").strip()
        assert mode == "600", mode

    with subtest("a pod calls the model through the gateway, which adds the real key"):
        base = json.loads(kubectl("get modelprovider -n default claude-sonnet -o json"))["spec"]["baseURL"]
        body = json.dumps({"model": "claude-test", "messages": [{"role": "user", "content": "hi"}]})
        phase, out = pod_curl("llm", ["-sS", "-m", "60", "-X", "POST", base + "/chat/completions",
                                      "-H", "Authorization: Bearer nestlo-managed",
                                      "-H", "Content-Type: application/json", "-d", body])
        print(phase, out)
        assert phase == "Succeeded" and "hello from the mock" in out, out
        seen = [json.loads(l) for l in machine.succeed("cat /var/lib/mock-llm/requests.jsonl").splitlines()]
        assert seen[-1]["path"] == "/v1/chat/completions", seen
        assert seen[-1]["x-api-key"] == "sk-test-real-key", seen
        assert seen[-1]["authorization"] is None, seen
        # billed to orca, which only exists because the setup unit registered it
        spend = json.loads(machine.succeed(ADMIN + "spend"))
        assert spend["agents"]["orca"]["tokens"]["input_tokens"] == 1000, spend

    with subtest("pods reach nothing else on the host"):
        # the mock LLM listens on 127.0.0.1 only; probe a host port that is
        # open on every address instead: the API server's 6443 is allowed,
        # kubelet's 10250 is not
        phase, out = pod_curl("probe", ["-sS", "-m", "5", "-k", "-o", "/dev/null", "https://10.89.3.1:10250/"])
        print(phase, out)
        assert phase == "Failed", out

    with subtest("the UI answers on loopback"):
        machine.wait_until_succeeds(
            KC + "rollout status -n agent-orca-system deployment/agent-orca-ui --timeout=30s", timeout=600)
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9980/ | grep -qi '<div id=\"root\"'", timeout=300)
        listeners = machine.succeed("ss -Htln")
        for port in ["9980", "9981", "9982"]:
            assert f"127.0.0.1:{port}" in listeners, listeners

    with subtest("aoctl is installed and configured"):
        machine.succeed("aoctl --help")
        env = machine.succeed("bash -lc 'echo $AOCTL_ENDPOINT $AOCTL_ACP_ENDPOINT'")
        assert "127.0.0.1:9982" in env and "127.0.0.1:9981" in env, env
  '';
}
