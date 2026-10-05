# PR-Agent (Qodo, MIT, https://github.com/qodo-ai/pr-agent): AI pull request
# review, description and suggestions.
#
# Not built by Nix: PR-Agent pins litellm 1.103 and about 60 further
# dependencies (opentelemetry, langfuse, tiktoken, ...) and needs Python
# >= 3.12, none of it in nixpkgs. Like open-interpreter in agents/default.nix
# this is a pinned uvx launcher: the first run (or `nestlo-pr-review --warm`)
# downloads the exact PyPI release into uv's cache, which nestlo.agentSecurity
# keeps under /var/lib/nestlo-agent-security/uv-cache. Later runs are offline
# as long as the cache stays.
{ lib
, stdenvNoCC
, makeWrapper
, uv
, python313
, git
, cacert
}:

stdenvNoCC.mkDerivation rec {
  pname = "pr-agent";
  version = "0.47.0";

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    makeWrapper ${uv}/bin/uvx $out/bin/pr-agent \
      --set UV_PYTHON_DOWNLOADS never \
      --set-default SSL_CERT_FILE ${cacert}/etc/ssl/certs/ca-bundle.crt \
      --add-flags "--python ${python313}/bin/python3 --from pr-agent==${version} pr-agent" \
      --prefix PATH : ${lib.makeBinPath [ git ]}
    runHook postInstall
  '';

  meta = {
    description = "PR-Agent: AI pull request reviewer (pinned uvx launcher)";
    homepage = "https://github.com/qodo-ai/pr-agent";
    license = lib.licenses.mit;
    mainProgram = "pr-agent";
    platforms = lib.platforms.linux;
  };
}
