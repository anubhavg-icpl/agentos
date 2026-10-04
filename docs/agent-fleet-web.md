# agent-fleet web UIs

Two static web pages from [agent-fleet](https://github.com/anubhavg-icpl/agent-fleet), packaged and served by AgentOS:

- **chat**: an AI chat that runs entirely in the browser. llama.cpp runs as WebAssembly (wllama 3.6.1) in a Web Worker; five small open GGUF models (Qwen, Llama) are selectable. It is also a PWA.
- **hub**: the agent-fleet overview page.

```nix
agentos.dashboard.agentFleetWeb = {
  enable = true;
  # port = 8484;
  # deployTool = true;   # adds agent-fleet-deploy, see below
};
```

## Reaching it

The server listens on `127.0.0.1:8484` only. There is no login: it serves public static files and nothing else (GET and HEAD, no listings, no writes). Use an SSH tunnel, as for the dashboard:

```
ssh -L 8484:127.0.0.1:8484 admin@host
```

Then open <http://127.0.0.1:8484/chat/> or <http://127.0.0.1:8484/hub/>. The chat only works from a secure context, which `http://127.0.0.1` is; a tunnel to a non-loopback name is not, so keep the tunnel on `127.0.0.1`.

When the web dashboard runs, its header shows links to both pages (`/api/links`, configured through `agentos.services.settings.dashboard.links`). On the desktop edition (`agentos.desktop.enable`) an "agent-fleet Chat" launcher opens the chat in the default browser.

## What loads from where

| Resource | Source |
|:---|:---|
| Page, scripts, styles, images | the AgentOS host (`pkgs.agentos.agent-fleet-web`) |
| wllama JS and WebAssembly (and its compatibility build) | the host: vendored from the npm tarballs of `@wllama/wllama` and `@wllama/wllama-compat` 3.6.1, pinned by hash. Upstream loads them from `cdn.jsdelivr.net`; the import paths are rewritten at build time |
| GGUF model weights | **the visitor's browser downloads them from `huggingface.co`** (and its CDN hosts) on first use of a model, then caches them. This is the only runtime request to a third party. The chat sends no prompts anywhere: inference is local to the browser |
| Hub links | plain anchors to GitHub and Hugging Face, followed only on click |

Each model is a few hundred MB to a few GB. The machine running the *browser* needs access to huggingface.co, not the AgentOS host.

## Server details

`agent-fleet-web.service` runs a small Python static server (`modules/agent-fleet-web/server.py`) as a dynamic user with no capabilities and a filtered system call set. It sets:

- correct content types for `.wasm` (`application/wasm`), `.mjs`/`.js` and `.webmanifest`;
- for `/chat/` only, `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`, which make the page cross-origin isolated so wllama can use `SharedArrayBuffer` and run multi-threaded. Without them it falls back to a single thread;
- a Content-Security-Policy that limits scripts and workers to the page's own files (`connect-src` allows https for the model download, because Hugging Face redirects downloads to changing hosts).

The CSP and COOP/COEP headers cannot be exercised by the VM test (it has no browser); if a browser reports a CSP violation in the chat, the policy is in `server.py`.

## Publishing to Hugging Face (`deployTool`)

`agentos.dashboard.agentFleetWeb.deployTool = true` adds `agent-fleet-deploy` to the system packages. It is `deploy.py` from agent-fleet with `huggingface_hub` from nixpkgs. **It publishes to Hugging Face**: it creates or updates the static Spaces `chat` and `agent-hub` (and with `--docker`, Docker Spaces that need a paid plan) under the account of the token you give it. Run it only with a token you want to use for that.

```
export HF_TOKEN=hf_...        # a write token; or put it in the state file below
agent-fleet-deploy            # static Spaces + status
agent-fleet-deploy --status   # status only
```

The tool works in `${XDG_STATE_HOME:-~/.local/state}/agent-fleet-deploy`, where it refreshes the sources from the store on each run. The token is read from `state/hf_token` there; if that file is missing, `HF_TOKEN` is written to it (mode 0600). Docker Spaces get generated credentials in `state/agent-fleet-credentials.json`. The command is not installed unless you enable the option.

## Packages

| Package | Contents |
|:---|:---|
| `agent-fleet-web` | `share/agent-fleet/chat/` and `share/agent-fleet/hub/` |
| `agent-fleet-deploy` | the `agent-fleet-deploy` command |

The source is pinned to one agent-fleet commit (`nixos/packages/agent-fleet-web.nix`); bump `rev` and `hash` to update. The VM test is `checks.x86_64-linux.agent-fleet-web`.
