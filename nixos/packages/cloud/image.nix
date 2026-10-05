# The `agentos` image of AgentOS Cloud VMs: a small root skeleton. Its tools
# come from the host's Nix store, which every VM sees read-only, through
# /.agentos/profile-bin (a profile of `packages`); a VM's disk holds only what
# the user changes. Copied onto each new VM's disk by agentos-cloud-vmd.
{ lib, runCommand, buildEnv, bashInteractive, cacert, packages ? [ ] }:

let
  profile = buildEnv {
    name = "agentos-cloud-vm-profile";
    paths = [ bashInteractive ] ++ packages;
    pathsToLink = [ "/bin" "/sbin" "/share" "/etc" "/lib" ];
    ignoreCollisions = true;
  };
in
runCommand "agentos-cloud-image" { passthru = { inherit profile; }; } ''
  mkdir -p $out/{bin,usr/bin,etc/ssl/certs,root/.ssh,home,tmp,var/empty,var/log,run,srv,.agentos}
  ln -s ${bashInteractive}/bin/sh $out/bin/sh
  ln -s ${bashInteractive}/bin/bash $out/bin/bash
  ln -s ${profile}/bin/env $out/usr/bin/env
  ln -s ${profile} $out/.agentos/profile-root
  ln -s ${profile}/bin $out/.agentos/profile-bin
  ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
  ln -s ${cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt
  cat > $out/etc/passwd <<PW
  root:x:0:0:root:/root:/bin/bash
  sshd:x:74:74:sshd privsep:/var/empty:/bin/false
  nobody:x:65534:65534:nobody:/var/empty:/bin/false
  PW
  sed -i 's/^  //' $out/etc/passwd
  printf 'root:x:0:\nsshd:x:74:\nnogroup:x:65534:\n' > $out/etc/group
  printf 'hosts: files dns\n' > $out/etc/nsswitch.conf
  cat > $out/etc/os-release <<OS
  NAME="AgentOS Cloud VM"
  ID=agentos
  PRETTY_NAME="AgentOS Cloud VM"
  OS
  sed -i 's/^  //' $out/etc/os-release
  cat > $out/etc/profile <<'PROFILE'
  export PATH=/.agentos/profile-bin:/root/.nix-profile/bin:/usr/local/bin:/usr/bin:/bin
  export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
  export NIX_SSL_CERT_FILE=$SSL_CERT_FILE
  [ -f /.agentos/env ] && . /.agentos/env
  PS1='\u@\h:\w\$ '
  PROFILE
  sed -i 's/^  //' $out/etc/profile
  printf '. /etc/profile\n' > $out/root/.bashrc
  printf '. /etc/profile\n' > $out/root/.profile
  mkdir -p $out/etc/containers
  printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' \
    > $out/etc/containers/storage.conf
  printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > $out/etc/containers/policy.json
  printf 'unqualified-search-registries = ["docker.io"]\n' > $out/etc/containers/registries.conf
  chmod 700 $out/root/.ssh
  chmod 1777 $out/tmp
''
