#!/bin/sh
# AgentOS Cloud VM init. systemd-nspawn runs it as PID 2 (its stub PID 1
# reaps orphans), or, for images that boot systemd, the agentos-init unit
# runs it. It sets up the VM once (setup script, sshd host keys), starts the
# VM's own sshd and the agent UI, runs the --prompt agent once, and then
# runs --command (restarted when it exits) or waits.
set -u
export HOME=/root USER=root
[ -f /.agentos/env ] && . /.agentos/env
[ -f /.agentos/profile ] && . /.agentos/profile
PATH="/.agentos/profile-bin:/root/.nix-profile/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
cd /root 2>/dev/null || cd /
mkdir -p /var/log /run /tmp 2>/dev/null
chmod 1777 /tmp 2>/dev/null
# exe.dev compatibility marker: tools such as Shelley look for it
: > /exe.dev 2>/dev/null

if [ -x /.agentos/setup ] && [ ! -e /.agentos/setup.done ]; then
  echo "agentos: running the setup script" >&2
  /.agentos/setup >/var/log/agentos-setup.log 2>&1
  echo $? > /.agentos/setup.done
fi

# The VM's own sshd: root, keys only, keys managed by AgentOS Cloud
if command -v sshd >/dev/null 2>&1 && grep -q '^sshd:' /etc/passwd 2>/dev/null; then
  mkdir -p /etc/ssh /var/empty /root/.ssh
  chmod 700 /root/.ssh
  [ -f /etc/ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/ssh_host_ed25519_key
  cat > /.agentos/sshd_config <<CONF
Port 22
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysFile /root/.ssh/authorized_keys
StrictModes no
UsePAM no
PidFile none
Subsystem sftp internal-sftp
AcceptEnv LANG LC_* COLORTERM
CONF
  "$(command -v sshd)" -D -e -f /.agentos/sshd_config >/var/log/sshd.log 2>&1 &
fi

# The agent web UI (Shelley) on port 9999
if [ "${AGENTOS_AGENT_UI:-1}" != 0 ] && command -v shelley >/dev/null 2>&1; then
  mkdir -p /root/.config/shelley
  ( while true; do
      shelley -db /root/.config/shelley/shelley.db serve -port "${AGENTOS_AGENT_UI_PORT:-9999}" >>/var/log/shelley.log 2>&1
      sleep 3
    done ) &
fi

# --prompt: run the configured agent once on the prompt
if [ -s /.agentos/prompt ] && [ ! -e /.agentos/prompt.done ]; then
  cmd=$(cat /.agentos/prompt-command 2>/dev/null)
  if [ -n "$cmd" ]; then
    ( mkdir -p /root/work && cd /root/work && \
      sh -c "$cmd \"\$1\"" agentos-prompt "$(cat /.agentos/prompt)" >/var/log/agentos-prompt.log 2>&1
      echo $? > /.agentos/prompt.done ) &
  fi
fi

cmd=$(cat /.agentos/command 2>/dev/null)
if [ -n "$cmd" ]; then
  while true; do
    sh -c "$cmd"
    echo "agentos: command exited with $?; restarting in 2s" >&2
    sleep 2
  done
fi
while true; do sleep 3600; done
