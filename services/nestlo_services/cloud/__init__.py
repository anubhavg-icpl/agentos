"""Nestlo Cloud: persistent VMs for people and agents, self-hosted.

The design follows exe.dev (docs/cloud.md): a control plane reached over SSH
(`ssh lobby@<host> <command>`) and over HTTPS (`POST /exec` with a token
signed by an SSH key), VMs with persistent disks drawn from a per-user
resource pool, a private-by-default HTTPS proxy in front of every VM with
sharing and custom domains, and integrations that inject secrets at the
network edge so they never enter a VM.

Modules:
  state      Redis model (users, keys, teams, VMs, shares, integrations, ...)
  tokens     nestlo0 / nestlo1 API tokens (SSH signatures, ssh-keygen -Y)
  plans      resource plans and quota checks
  commands   the command language shared by SSH and /exec
  backend    VM runtime drivers (systemd-nspawn, and a fake for tests)
  vmd        the root helper that runs the backend
  server     nestlo-cloudd: /exec, the proxy auth gate, login, integrations
  lobby      the SSH entry points (ForceCommand, AuthorizedKeysCommand)
"""
