# Remote agent fleets

`agentos-fleet` manages other Nestlo hosts over SSH: one status table for all of them, `agentos spawn` on a remote host, and arbitrary commands.

```
agentos-fleet add build1 admin@10.0.0.5 --port 2222
agentos-fleet list
agentos-fleet status                       # every host; add names to narrow, --json for scripts
agentos-fleet spawn build1 claude --workspace api --budget 5
agentos-fleet run build1 -- agentos list
agentos-fleet remove build1
```

## Hosts

Declarative hosts, written to `/etc/agentos/fleet.json`:

```nix
agentos.fleet = {
  enable = true;
  hosts.build1 = { address = "10.0.0.5"; user = "admin"; port = 22; };
};
```

Hosts added with `agentos-fleet add` live in `~/.config/agentos/fleet.json`. A declarative host with the same name wins and cannot be changed or removed from the CLI. Host names are lower-case letters, digits, `.`, `_` and `-`. Addresses and users are validated so they cannot be read by `ssh` as options.

## SSH

`agentos-fleet` runs your own `ssh`, so your keys, agent and `~/.ssh/config` apply. Host key checking is never relaxed: the first connection to a new host fails until its key is trusted (`ssh-keyscan host >> ~/.ssh/known_hosts` after checking the fingerprint, or `programs.ssh.knownHosts`). `status` runs non-interactively (`BatchMode=yes`), `spawn` uses `ssh -t` so the agent gets a terminal.

Remote commands run under `sh -c` with `/run/current-system/sw/bin` on `PATH`, whatever the remote login shell is. The remote user needs to be a Nestlo operator (group `agentos`, passwordless sudo for `spawn`), as when working on that host directly.

## What `status` collects

One SSH call per host, in parallel:

- `systemctl is-active` for the daemon, gateway and Redis
- `agentos-budget status --json` for spend and the global limit
- the agent records in `/var/lib/agentos/state/*.json`

The exit status is 1 when a host is unreachable.
