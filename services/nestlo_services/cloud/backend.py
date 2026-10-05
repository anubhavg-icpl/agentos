"""VM runtime: systemd-nspawn machines with persistent ext4 disks.

Each VM is a directory /var/lib/nestlo/cloud/vms/<id>/ holding

    disk.img     a sparse ext4 image, the VM's persistent disk (--disk)
    root/        where the image is mounted (loop) while the VM exists
    vm.json      the last spec the helper applied

and runs as the transient unit nestlo-vm-<id>.service:

    systemd-nspawn --machine=avm-<id> --directory=root/ --private-users=pick
        --private-users-ownership=map --network-bridge=<bridge> --bind-ro=/nix/store
        [--boot | --as-pid2 /.nestlo/init]

so root in the VM is an unprivileged UID range on the host, and the VM sees
the host's Nix store read-only (the default `nestlo` image is a skeleton
whose tools all come from the store). The unit sits in the owner's pool slice
(nestlo-cloud-<pool>.slice: CPUQuota and MemoryMax of the pool) and has its
own CPUQuota and MemoryMax (the VM size). Standalone VMs get a slice of their
own.

Networking: the host end of the VM's veth joins the cloud bridge as an
isolated port (VMs cannot reach each other except through a `peer`
integration), and an nftables bridge rule drops frames whose source IP is
not the VM's own address, so a VM cannot impersonate another to the
integration proxy, which identifies VMs by source address.

This module composes commands; vmd.py runs them as root. Tests replace
`run` with a recorder.
"""

import array
import json
import os
import shlex
import shutil
import socket
import subprocess
import time

VMD_SOCKET = "/run/nestlo-cloud-vmd/vmd.sock"


class BackendError(Exception):
    pass


# ── client (used by nestlo-cloudd) ────────────────────────────────────

class VmdClient:
    """JSON requests to the root helper over its unix socket."""

    def __init__(self, path=VMD_SOCKET, timeout=600):
        self.path = path
        self.timeout = timeout

    def call(self, op, fds=None, **args):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.path)
            data = (json.dumps(dict(args, op=op)) + "\n").encode()
            if fds:
                s.sendmsg([data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))])
            else:
                s.sendall(data)
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except OSError as exc:
            raise BackendError("the VM helper is not reachable: %s" % exc)
        finally:
            s.close()
        try:
            reply = json.loads(buf or b"{}")
        except ValueError:
            raise BackendError("bad reply from the VM helper")
        if reply.get("error"):
            raise BackendError(reply["error"])
        return reply.get("result")

    def create(self, spec, setup=None, prompt=None, registry_auth=None):
        return self.call("create", spec=spec, setup=setup, prompt=prompt, registry_auth=registry_auth)

    def start(self, spec):
        return self.call("start", spec=spec)

    def stop(self, vid):
        return self.call("stop", id=vid)

    def destroy(self, vid):
        return self.call("destroy", id=vid)

    def resize(self, spec):
        return self.call("resize", spec=spec)

    def copy(self, src_id, spec):
        return self.call("copy", src=src_id, spec=spec)

    def stat(self, vid):
        return self.call("stat", id=vid)

    def status(self, vid):
        return self.call("status", id=vid)

    def sync(self, spec):
        return self.call("sync", spec=spec)

    def attach(self, vid, argv, fds, tty=False, term=None):
        """Run argv in the VM with the caller's stdin/stdout/stderr; returns {"exit": code}."""
        return self.call("attach", fds=fds, id=vid, argv=argv, tty=tty, env={"TERM": term} if term else {})


def recv_request(sock, max_bytes=1024 * 1024, max_fds=3):
    """Read one JSON line from a unix socket, with any SCM_RIGHTS fds -> (dict, [fds])."""
    fds, buf = [], b""
    while not buf.endswith(b"\n"):
        msg, anc, _flags, _ = sock.recvmsg(65536, socket.CMSG_SPACE(max_fds * 4))
        for level, kind, data in anc:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                arr = array.array("i")
                arr.frombytes(data[:len(data) - (len(data) % 4)])
                fds.extend(arr)
        if not msg:
            break
        buf += msg
        if len(buf) > max_bytes:
            for fd in fds:
                os.close(fd)
            raise BackendError("request too large")
    try:
        return json.loads(buf or b"{}"), fds
    except ValueError:
        for fd in fds:
            os.close(fd)
        raise BackendError("request is not JSON")


def peer_uid(sock):
    import struct
    try:
        return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[1]
    except OSError:
        return None


# ── the nspawn driver (runs inside nestlo-cloud-vmd, as root) ─────────

def unit_name(vid):
    return "nestlo-vm-%s.service" % vid


def machine_name(vid):
    return "avm-%s" % vid          # 12 chars, so the host veth is vb-avm-<id> (15)


def veth_name(vid):
    return "vb-" + machine_name(vid)


def slice_name(pool, vid):
    key = pool if pool else "sa-" + vid
    safe = "".join(c if c.isalnum() else "_" for c in key)
    return "nestlo-cloud-%s.slice" % safe


def run(argv, check=True, input=None, timeout=900):
    p = subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout)
    if check and p.returncode != 0:
        raise BackendError("%s failed (%d): %s" % (argv[0], p.returncode, (p.stderr or p.stdout).strip()[-800:]))
    return p


class Nspawn:
    """VM operations. cfg keys: state_dir, bridge, gateway_ip, prefix_len,
    images {name: store path}, nix_store, init (path), dns, prompt_command."""

    def __init__(self, cfg, runner=run, clock=time.time):
        self.cfg = cfg
        self.run = runner
        self.clock = clock

    # paths
    def dir(self, vid):
        if not vid or not all(c in "0123456789abcdef" for c in vid) or len(vid) > 16:
            raise BackendError("bad VM id %r" % vid)
        return os.path.join(self.cfg["state_dir"], "vms", vid)

    def disk(self, vid):
        return os.path.join(self.dir(vid), "disk.img")

    def root(self, vid):
        return os.path.join(self.dir(vid), "root")

    # ── disks ──────────────────────────────────────────────────────────
    def is_mounted(self, vid):
        return self.run(["mountpoint", "-q", self.root(vid)], check=False).returncode == 0

    def mount(self, vid):
        os.makedirs(self.root(vid), exist_ok=True)
        if not self.is_mounted(vid):
            self.run(["mount", "-o", "loop,nodev,nosuid", self.disk(vid), self.root(vid)])

    def umount(self, vid):
        if self.is_mounted(vid):
            self.run(["umount", self.root(vid)], check=False)
            if self.is_mounted(vid):
                self.run(["umount", "-l", self.root(vid)])

    def make_disk(self, vid, gb):
        os.makedirs(self.dir(vid), mode=0o700, exist_ok=True)
        self.run(["truncate", "-s", "%dG" % gb, self.disk(vid)])
        self.run(["mkfs.ext4", "-q", "-F", "-L", "avm-" + vid, "-m", "1", "-E", "lazy_itable_init=1", self.disk(vid)])

    def grow_disk(self, vid, gb):
        self.run(["truncate", "-s", "%dG" % gb, self.disk(vid)])
        loop = self.run(["losetup", "-j", self.disk(vid)], check=False).stdout.split(":", 1)[0].strip()
        if loop:
            self.run(["losetup", "-c", loop])
            self.run(["resize2fs", loop])
        else:
            self.run(["e2fsck", "-p", "-f", self.disk(vid)], check=False)
            self.run(["resize2fs", self.disk(vid)])

    # ── images ─────────────────────────────────────────────────────────
    def populate(self, vid, image, registry_auth=None):
        root = self.root(vid)
        images = self.cfg.get("images") or {}
        if image in images:
            self.run(["cp", "-a", "--no-preserve=ownership", images[image].rstrip("/") + "/.", root])
            return {"kind": "nix", "boot": False, "expose": []}
        # OCI image: copy with skopeo, unpack with umoci, move the rootfs onto the disk
        work = os.path.join(self.dir(vid), "oci")
        self.run(["rm", "-rf", work])
        argv = ["skopeo", "copy", "--quiet"]
        if registry_auth:
            argv += ["--src-creds", registry_auth]
        ref = image if "://" in image else "docker://" + image
        self.run(argv + [ref, "oci:%s/layout:img" % work], timeout=1800)
        self.run(["umoci", "unpack", "--image", "%s/layout:img" % work, "%s/bundle" % work])
        self.run(["cp", "-a", "%s/bundle/rootfs/." % work, root])
        expose = []
        try:
            with open("%s/bundle/config.json" % work) as f:
                annotations = json.load(f).get("annotations") or {}
            expose = sorted(int(p.split("/")[0]) for p in
                            (annotations.get("org.opencontainers.image.exposedPorts") or "").split(",") if p[:1].isdigit())
        except (OSError, ValueError):
            pass
        self.run(["rm", "-rf", work])
        boot = any(os.path.exists(os.path.join(root, p.lstrip("/")))
                   for p in ("/usr/lib/systemd/systemd", "/lib/systemd/systemd"))
        return {"kind": "oci", "boot": boot, "expose": expose}

    # ── files inside the VM ────────────────────────────────────────────
    def _write(self, vid, rel, text, mode=0o644):
        path = os.path.join(self.root(vid), rel.lstrip("/"))
        real = os.path.realpath(path)
        if not real.startswith(os.path.realpath(self.root(vid)) + os.sep):
            raise BackendError("refusing to write outside the VM: %s" % rel)
        os.makedirs(os.path.dirname(real), exist_ok=True)
        tmp = real + ".nestlo-tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.replace(tmp, real)

    def write_config(self, spec, setup=None, prompt=None):
        vid = spec["id"]
        env = dict(spec.get("env") or {})
        env.update(NESTLO_VM=spec["name"], NESTLO_VM_ID=vid)
        lines = ["export %s=%s" % (k, shlex.quote(str(v))) for k, v in sorted(env.items())]
        self._write(vid, "/.nestlo/env", "\n".join(lines) + "\n", 0o600)
        self._write(vid, "/.nestlo/command", (spec.get("command") or "") + "\n", 0o600)
        if setup is not None:
            self._write(vid, "/.nestlo/setup", setup if setup.startswith("#!") else "#!/bin/sh\n" + setup, 0o700)
        if prompt is not None:
            self._write(vid, "/.nestlo/prompt", prompt, 0o600)
            self._write(vid, "/.nestlo/prompt-command", self.cfg.get("prompt_command", "") + "\n", 0o600)
        gw = self.cfg["gateway_ip"]
        self._write(vid, "/etc/resolv.conf", "nameserver %s\n" % gw)
        hosts = ["127.0.0.1 localhost", "::1 localhost", "%s %s" % (spec.get("ip") or "127.0.1.1", spec["name"])]
        hosts += ["%s %s" % (gw, h) for h in spec.get("hosts", [])]
        self._write(vid, "/etc/hosts", "\n".join(hosts) + "\n")
        self._write(vid, "/etc/hostname", spec["name"] + "\n")
        keys = "\n".join(spec.get("authorized_keys") or [])
        self._write(vid, "/root/.ssh/authorized_keys", keys + "\n" if keys else "", 0o600)
        with open(os.path.join(self.dir(vid), "vm.json"), "w") as f:
            json.dump({k: v for k, v in spec.items() if k != "env"}, f)

    # ── lifecycle ──────────────────────────────────────────────────────
    def unit_active(self, vid):
        return self.run(["systemctl", "is-active", "--quiet", unit_name(vid)], check=False).returncode == 0

    def ensure_slice(self, spec):
        sl = slice_name(spec.get("pool"), spec["id"])
        props = []
        if spec.get("pool"):
            props = ["CPUQuota=%d%%" % (100 * int(spec.get("pool_cpu") or spec["cpu"])),
                     "MemoryMax=%dM" % int(spec.get("pool_memory_mb") or spec["memory_mb"])]
        if props:
            # set-property on a slice that has no unit file yet creates a drop-in
            self.run(["systemctl", "set-property", "--runtime", sl] + props, check=False)
        return sl

    def nspawn_argv(self, spec, meta):
        vid = spec["id"]
        argv = ["systemd-nspawn", "--quiet", "--keep-unit", "--register=yes",
                "--machine=" + machine_name(vid), "--directory=" + self.root(vid),
                "--private-users=pick", "--private-users-ownership=map",
                "--network-bridge=" + self.cfg["bridge"], "--resolv-conf=off", "--timezone=off",
                "--link-journal=no", "--bind-ro=" + self.cfg.get("nix_store", "/nix/store"),
                "--hostname=" + spec["name"], "--setenv=NESTLO_VM=" + spec["name"]]
        for dev in self.cfg.get("devices", ["/dev/fuse", "/dev/net/tun"]):
            if os.path.exists(dev):
                argv.append("--bind=" + dev)
        if meta.get("boot") and not spec.get("command"):
            argv.append("--boot")
        else:
            argv += ["--as-pid2", "/bin/sh", "/.nestlo/init"]
        return argv

    def start(self, spec):
        vid = spec["id"]
        self.mount(vid)
        meta = self.meta(vid)
        self.install_init(vid)
        self.write_config(spec)
        if self.unit_active(vid):
            return self.status(vid)
        sl = self.ensure_slice(spec)
        self.run(["systemctl", "reset-failed", unit_name(vid)], check=False)
        self.run(["systemd-run", "--unit=" + unit_name(vid), "--slice=" + sl, "--collect",
                  "--description=Nestlo Cloud VM " + spec["name"],
                  "--property=CPUQuota=%d%%" % (100 * int(spec["cpu"])),
                  "--property=MemoryMax=%dM" % int(spec["memory_mb"]),
                  "--property=TasksMax=%d" % int(self.cfg.get("tasks_max", 8192)),
                  "--property=KillMode=mixed", "--property=Delegate=yes"]
                 + ["--property=DeviceAllow=%s rwm" % d for d in self.cfg.get("devices", ["/dev/fuse", "/dev/net/tun"])
                    if os.path.exists(d)]
                 + self.nspawn_argv(spec, meta))
        self.network_up(spec)
        return self.status(vid)

    def leader(self, vid):
        p = self.run(["machinectl", "show", machine_name(vid), "-p", "Leader", "--value"], check=False)
        pid = (p.stdout or "").strip()
        return int(pid) if pid.isdigit() else None

    def network_up(self, spec, wait=20.0):
        vid = spec["id"]
        deadline = self.clock() + wait
        pid = self.leader(vid)
        while pid is None and self.clock() < deadline:
            time.sleep(0.2)
            pid = self.leader(vid)
        if pid is None:
            raise BackendError("VM %s did not start (see journalctl -u %s)" % (spec["name"], unit_name(vid)))
        ns = ["nsenter", "-t", str(pid), "-n"]
        cidr = "%s/%d" % (spec["ip"], int(self.cfg.get("prefix_len", 16)))
        self.run(ns + ["ip", "link", "set", "lo", "up"], check=False)
        self.run(ns + ["ip", "addr", "replace", cidr, "dev", "host0"])
        self.run(ns + ["ip", "link", "set", "host0", "up"])
        self.run(ns + ["ip", "route", "replace", "default", "via", self.cfg["gateway_ip"]])
        veth = veth_name(vid)
        self.run(["bridge", "link", "set", "dev", veth, "isolated", "on"], check=False)
        self.antispoof(vid, veth, spec["ip"])

    def antispoof(self, vid, veth, ip):
        table = self.cfg.get("nft_table", "nestlo_cloud")
        self.run(["nft", "add", "table", "bridge", table], check=False)
        self.run(["nft", "add", "chain", "bridge", table, "spoof",
                  "{ type filter hook prerouting priority -200; policy accept; }"], check=False)
        self.clear_antispoof(vid)
        for rule in ("iifname %s ether type ip ip saddr != %s drop" % (veth, ip),
                     "iifname %s ether type arp arp saddr ip != %s drop" % (veth, ip),
                     "iifname %s ether type ip6 drop" % veth):
            self.run(["nft", "add", "rule", "bridge", table, "spoof"] + rule.split() + ["comment", '"avm-%s"' % vid])

    def clear_antispoof(self, vid):
        table = self.cfg.get("nft_table", "nestlo_cloud")
        p = self.run(["nft", "-a", "list", "chain", "bridge", table, "spoof"], check=False)
        for line in (p.stdout or "").splitlines():
            if '"avm-%s"' % vid in line and "# handle" in line:
                handle = line.rsplit("# handle", 1)[1].strip()
                self.run(["nft", "delete", "rule", "bridge", table, "spoof", "handle", handle], check=False)

    def stop(self, vid, timeout=30):
        if self.unit_active(vid):
            self.run(["machinectl", "poweroff", machine_name(vid)], check=False)
            deadline = self.clock() + timeout
            while self.unit_active(vid) and self.clock() < deadline:
                time.sleep(0.5)
            self.run(["systemctl", "stop", unit_name(vid)], check=False)
        self.clear_antispoof(vid)
        return {"status": "stopped"}

    def destroy(self, vid):
        self.stop(vid, timeout=10)
        if os.path.isdir(self.dir(vid)):
            self.umount(vid)
            self.run(["rm", "-rf", "--one-file-system", self.dir(vid)])
        return {"status": "deleted"}

    def meta(self, vid):
        try:
            with open(os.path.join(self.dir(vid), "image.json")) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def install_init(self, vid):
        with open(self.cfg["init"]) as f:
            self._write(vid, "/.nestlo/init", f.read(), 0o755)
        profile = self.cfg.get("profile")
        if profile:
            link = os.path.join(self.root(vid), ".nestlo", "profile-bin")
            if os.path.realpath(os.path.dirname(link)) != os.path.join(os.path.realpath(self.root(vid)), ".nestlo"):
                raise BackendError("refusing to write outside the VM: /.nestlo")
            if not os.path.lexists(link):
                os.symlink(profile.rstrip("/") + "/bin", link)
        if self.meta(vid).get("boot"):
            # Images that boot systemd run the init as a unit
            self._write(vid, "/etc/systemd/system/nestlo-init.service",
                        "[Unit]\nDescription=Nestlo Cloud VM init\nAfter=network.target\n\n"
                        "[Service]\nExecStart=/bin/sh /.nestlo/init\nRestart=always\n\n"
                        "[Install]\nWantedBy=multi-user.target\n")
            wants = os.path.join(self.root(vid), "etc/systemd/system/multi-user.target.wants")
            if os.path.realpath(wants).startswith(os.path.realpath(self.root(vid)) + os.sep):
                os.makedirs(wants, exist_ok=True)
                target = os.path.join(wants, "nestlo-init.service")
                if not os.path.lexists(target):
                    os.symlink("/etc/systemd/system/nestlo-init.service", target)

    def create(self, spec, setup=None, prompt=None, registry_auth=None):
        vid = spec["id"]
        if os.path.exists(self.dir(vid)):
            raise BackendError("VM %s exists already" % vid)
        try:
            self.make_disk(vid, int(spec["disk_gb"]))
            self.mount(vid)
            meta = self.populate(vid, spec["image"], registry_auth)
            with open(os.path.join(self.dir(vid), "image.json"), "w") as f:
                json.dump(dict(meta, image=spec["image"], created=int(self.clock())), f)
            self.install_init(vid)
            self.write_config(spec, setup=setup, prompt=prompt)
            return dict(self.start(spec), expose=meta.get("expose", []))
        except Exception:
            self.destroy(vid)
            raise

    def resize(self, spec):
        vid = spec["id"]
        if self.unit_active(vid):
            self.run(["systemctl", "set-property", "--runtime", unit_name(vid),
                      "CPUQuota=%d%%" % (100 * int(spec["cpu"])), "MemoryMax=%dM" % int(spec["memory_mb"])])
        size = os.path.getsize(self.disk(vid)) // (1024 ** 3)
        if int(spec["disk_gb"]) > size:
            self.grow_disk(vid, int(spec["disk_gb"]))
        self.ensure_slice(spec)
        return self.status(vid)

    def copy(self, src, spec):
        vid = spec["id"]
        if os.path.exists(self.dir(vid)):
            raise BackendError("VM %s exists already" % vid)
        os.makedirs(self.dir(vid), mode=0o700)
        frozen = False
        try:
            if self.unit_active(src) and self.is_mounted(src):
                self.run(["sync", "-f", self.root(src)], check=False)
                frozen = self.run(["fsfreeze", "-f", self.root(src)], check=False).returncode == 0
            self.run(["cp", "--sparse=always", "--reflink=auto", self.disk(src), self.disk(vid)])
        except Exception:
            self.run(["rm", "-rf", self.dir(vid)], check=False)
            raise
        finally:
            if frozen:
                self.run(["fsfreeze", "-u", self.root(src)], check=False)
        try:
            self.run(["e2fsck", "-p", self.disk(vid)], check=False)
            self.run(["tune2fs", "-L", "avm-" + vid, "-U", "random", self.disk(vid)], check=False)
            for name in ("image.json",):
                srcp = os.path.join(self.dir(src), name)
                if os.path.exists(srcp):
                    self.run(["cp", srcp, os.path.join(self.dir(vid), name)])
            size = os.path.getsize(self.disk(vid)) // (1024 ** 3)
            if int(spec["disk_gb"]) > size:
                self.grow_disk(vid, int(spec["disk_gb"]))
            return self.start(spec)
        except Exception:
            self.destroy(vid)
            raise

    def sync(self, spec):
        vid = spec["id"]
        if not os.path.isdir(self.dir(vid)):
            raise BackendError("no VM %s" % vid)
        if self.is_mounted(vid):
            self.write_config(spec)
        self.ensure_slice(spec)
        return {"synced": True}

    def status(self, vid):
        if not os.path.isdir(self.dir(vid)):
            return {"status": "missing"}
        return {"status": "running" if self.unit_active(vid) else "stopped"}

    def stat(self, vid):
        out = self.status(vid)
        if out["status"] == "running":
            p = self.run(["systemctl", "show", unit_name(vid), "-p", "CPUUsageNSec", "-p", "MemoryCurrent",
                          "-p", "TasksCurrent", "-p", "ActiveEnterTimestampMonotonic"], check=False)
            for line in (p.stdout or "").splitlines():
                k, _, v = line.partition("=")
                if v.isdigit():
                    out[{"CPUUsageNSec": "cpu_seconds", "MemoryCurrent": "memory_bytes",
                         "TasksCurrent": "tasks"}.get(k, k)] = int(v) / 1e9 if k == "CPUUsageNSec" else int(v)
            for name in ("rx_bytes", "tx_bytes"):
                try:
                    with open("/sys/class/net/%s/statistics/%s" % (veth_name(vid), name)) as f:
                        # the host end: what the host received is what the VM sent
                        out[{"rx_bytes": "tx_bytes", "tx_bytes": "rx_bytes"}[name]] = int(f.read())
                except OSError:
                    pass
        if self.is_mounted(vid):
            st = os.statvfs(self.root(vid))
            out["disk_used_bytes"] = (st.f_blocks - st.f_bfree) * st.f_frsize
            out["disk_total_bytes"] = st.f_blocks * st.f_frsize
        return out

    ATTACH_SCRIPT = ('. /.nestlo/env 2>/dev/null; [ -f /.nestlo/profile ] && . /.nestlo/profile; '
                     'cd "$HOME" 2>/dev/null; exec "$@"')

    def attach_argv(self, vid, argv, term=None):
        """(argv, env) that runs `argv` (default: a login shell) inside the VM."""
        pid = self.leader(vid)
        if pid is None:
            raise BackendError("the VM is not running")
        env = {"HOME": "/root", "USER": "root", "TERM": term or "xterm-256color",
               "PATH": "/root/.nix-profile/bin:/.nestlo/profile-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
        # the VM's environment replaces ours, so find nsenter on the helper's PATH first
        nsenter = shutil.which("nsenter") or "nsenter"
        return ([nsenter, "-t", str(pid), "-a", "--", "/bin/sh", "-c", self.ATTACH_SCRIPT, "sh"]
                + (list(argv) or ["/bin/sh", "-l"]), env)
