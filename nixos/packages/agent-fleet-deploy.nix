# agent-fleet-deploy: deploy.py of agent-fleet, which publishes the static
# Spaces (chat, agent-hub) to Hugging Face. It talks to huggingface.co with a
# write token and creates or updates Spaces under that account.
#
# deploy.py writes next to itself (spaces/agent-hub, state/), so the wrapper
# runs it from a writable copy of the sources in
# $XDG_STATE_HOME/agent-fleet-deploy (default ~/.local/state/...). The token
# is read from <that dir>/state/hf_token; if the file is missing and
# HF_TOKEN is set, the wrapper writes it there (mode 0600).
{ lib
, writeShellApplication
, python3
, coreutils
, agent-fleet-web
}:

let
  python = python3.withPackages (ps: [ ps.huggingface-hub ]);
  src = agent-fleet-web.src;
in
writeShellApplication {
  name = "agent-fleet-deploy";
  runtimeInputs = [ coreutils ];
  text = ''
    work="''${XDG_STATE_HOME:-$HOME/.local/state}/agent-fleet-deploy"
    mkdir -p "$work/state"
    chmod 700 "$work/state"

    # Refresh the sources, keep state/ (token, credentials)
    rm -rf "$work/spaces" "$work/docs" "$work/deploy.py"
    cp -r --no-preserve=mode ${src}/spaces ${src}/docs "$work/"
    # The pinned deploy.py annotates with HfApi before importing it (NameError
    # at import); postponed annotations make it load
    { printf 'from __future__ import annotations\n'; cat ${src}/deploy.py; } > "$work/deploy.py"

    if [ ! -s "$work/state/hf_token" ] && [ -n "''${HF_TOKEN:-}" ]; then
      (umask 077; printf '%s\n' "$HF_TOKEN" > "$work/state/hf_token")
    fi
    if [ ! -s "$work/state/hf_token" ]; then
      echo "agent-fleet-deploy: no Hugging Face write token." >&2
      echo "  Put it in $work/state/hf_token or export HF_TOKEN." >&2
      echo "  This tool publishes Spaces to your Hugging Face account." >&2
      exit 1
    fi

    cd "$work"
    exec ${python}/bin/python3 deploy.py "$@"
  '';

  meta = {
    description = "Publish the agent-fleet static Spaces to Hugging Face (needs a write token)";
    homepage = "https://github.com/anubhavg-icpl/agent-fleet";
    mainProgram = "agent-fleet-deploy";
    platforms = lib.platforms.linux;
  };
}
