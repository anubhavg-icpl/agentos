# agent-fleet web UIs as a static site: the in-browser chat (llama.cpp via
# wllama in a Web Worker) and the fleet hub.
#
# Source: anubhavg-icpl/agent-fleet (spaces/chat, docs/index.html).
#
# Upstream loads wllama from cdn.jsdelivr.net at runtime. That is vendored
# here (the npm tarballs of @wllama/wllama and @wllama/wllama-compat, both
# 3.6.1) and the import paths are rewritten, so the pages load no third-party
# JavaScript or WebAssembly. What still comes from the network at runtime:
# the GGUF model weights, which the browser downloads from huggingface.co on
# first use (then caches).
#
# Output:
#   share/agent-fleet/chat/   the chat (needs COOP/COEP headers for threads)
#   share/agent-fleet/hub/    the fleet hub
{ lib
, stdenvNoCC
, fetchFromGitHub
, fetchurl
}:

let
  wllamaVersion = "3.6.1";

  wllama = fetchurl {
    url = "https://registry.npmjs.org/@wllama/wllama/-/wllama-${wllamaVersion}.tgz";
    hash = "sha256-hm6UA6jWhuM9XfBRL1B6t5/M+/CJAtS3rdTDp6cGtTk=";
  };

  # Fallback build for browsers without JSPI/Memory64 (Safari, Firefox)
  wllamaCompat = fetchurl {
    url = "https://registry.npmjs.org/@wllama/wllama-compat/-/wllama-compat-${wllamaVersion}.tgz";
    hash = "sha256-yCFfqnCsnA6+ckqu+CI1qOpFZD2e6VNca6MIwNV/Dug=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "agent-fleet-web";
  version = "0-unstable-2026-10-02";

  src = fetchFromGitHub {
    owner = "anubhavg-icpl";
    repo = "agent-fleet";
    rev = "8c134916ef631e33ae1ea9441d188693bddd029b";
    hash = "sha256-ZLPJbyv74/QiBa7q9a7itiLWK1lAgoeujcyLUONEqDU=";
  };

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    site=$out/share/agent-fleet
    mkdir -p $site/chat $site/hub

    # ── chat ──
    cp -r --no-preserve=mode spaces/chat/. $site/chat/
    rm -f $site/chat/README.md

    vendor=$site/chat/vendor/wllama
    mkdir -p $vendor/compat unpack/wllama unpack/compat
    tar -xzf ${wllama} -C unpack/wllama --strip-components=1
    tar -xzf ${wllamaCompat} -C unpack/compat --strip-components=1
    install -m644 unpack/wllama/esm/index.min.js $vendor/index.min.js
    install -m644 unpack/wllama/esm/wasm/wllama.wasm $vendor/wllama.wasm
    install -m644 unpack/wllama/LICENCE $vendor/LICENSE
    install -m644 unpack/compat/wasm/wllama.js $vendor/compat/wllama.js
    install -m644 unpack/compat/wasm/wllama.wasm $vendor/compat/wllama.wasm

    # The CDN import and wasm paths become local ones. The compat build (for
    # browsers without JSPI/Memory64) is also fetched from the CDN by
    # default; point it at the vendored copy.
    substituteInPlace $site/chat/chat-worker.js \
      --replace-fail 'import { Wllama } from "https://cdn.jsdelivr.net/npm/@wllama/wllama@${wllamaVersion}/esm/index.min.js";' \
                     'import { Wllama } from "./vendor/wllama/index.min.js";' \
      --replace-fail 'const CDN = "https://cdn.jsdelivr.net/npm/@wllama/wllama@${wllamaVersion}/esm";' \
                     'const LOCAL = new URL("./vendor/wllama", import.meta.url).href;' \
      --replace-fail 'const CONFIG_PATHS = { default: `''${CDN}/wasm/wllama.wasm` };' \
                     'const CONFIG_PATHS = { default: `''${LOCAL}/wllama.wasm` };' \
      --replace-fail 'wllama = new Wllama(CONFIG_PATHS, { parallelDownloads: 3 });' \
                     'wllama = new Wllama(CONFIG_PATHS, { parallelDownloads: 3 });
          wllama.setCompat({ worker: `''${LOCAL}/compat/wllama.js`, wasm: `''${LOCAL}/compat/wllama.wasm` });'

    # No page of ours may still point at the CDN (the vendored library only
    # names it as a default, which the lines above override)
    if grep -rlI 'cdn.jsdelivr.net' $site/chat --exclude-dir=vendor | grep .; then
      echo "CDN reference left in the chat" >&2
      exit 1
    fi

    # ── hub ──
    install -m644 docs/index.html $site/hub/index.html
    cp -r --no-preserve=mode docs/assets $site/hub/assets
    # Open the chat served next to the hub instead of the GitHub Pages copy
    substituteInPlace $site/hub/index.html \
      --replace-fail 'href="https://anubhavg-icpl.github.io/agent-fleet/chat/"' 'href="../chat/"'

    runHook postInstall
  '';

  meta = {
    description = "agent-fleet browser chat (local llama.cpp via wllama) and fleet hub as a static site";
    homepage = "https://github.com/anubhavg-icpl/agent-fleet";
    platforms = lib.platforms.all;
  };
}
