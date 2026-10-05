"""GPU discovery and exclusive per-agent allocation.

`nestlo spawn --gpu` calls this (as root, through the `nestlo-gpu` script)
to pick GPUs for an agent. A GPU is held by at most one agent: the holder is
recorded as a file <lock_dir>/<index> containing the agent id. Locks are
released by the agent unit's ExecStopPost and, as a safety net, by the agent
daemon's reaper (release_stale) when the holder is gone.

Discovery reads /dev and /sys only, so it works without any GPU (empty list)
and can be tested against a fake tree:
  * NVIDIA: /dev/nvidia<N>, plus the shared nvidiactl/uvm/modeset nodes
  * AMD / Intel: DRM render nodes (/dev/dri/renderD*) classified by PCI
    vendor; AMD also needs /dev/kfd for ROCm
"""

import argparse
import contextlib
import fcntl
import json
import os
import re
import sys
import time

from . import config as configmod

VENDORS = {"0x10de": "nvidia", "0x1002": "amd", "0x8086": "intel"}
NVIDIA_SHARED = ("nvidiactl", "nvidia-uvm", "nvidia-uvm-tools", "nvidia-modeset")

_SPEC = re.compile(r"^(any|[0-9]+(,[0-9]+)*)$")


class GpuError(Exception):
    pass


class Gpu:
    def __init__(self, index, vendor, name, devices, shared=()):
        self.index = index
        self.vendor = vendor
        self.name = name
        self.devices = list(devices)   # per-GPU device nodes
        self.shared = list(shared)     # nodes every GPU of the vendor needs

    def to_dict(self):
        return {"index": self.index, "vendor": self.vendor, "name": self.name,
                "devices": self.devices, "shared": self.shared}


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _nvidia_info(proc):
    """Map device minor -> (model, pci address) from /proc/driver/nvidia."""
    out = {}
    gpus = os.path.join(proc, "driver/nvidia/gpus")
    try:
        names = sorted(os.listdir(gpus))
    except OSError:
        return out
    for pci in names:
        text = _read(os.path.join(gpus, pci, "information"))
        model = re.search(r"^Model:\s*(.+)$", text, re.M)
        minor = re.search(r"^Device Minor:\s*(\d+)$", text, re.M)
        if minor:
            out[int(minor.group(1))] = (model.group(1).strip() if model else "", pci)
    return out


def discover(dev="/dev", sys_root="/sys", proc="/proc"):
    """All GPUs on this machine, NVIDIA first, then by render node number."""
    gpus = []
    info = _nvidia_info(proc)
    try:
        entries = os.listdir(dev)
    except OSError:
        entries = []
    shared = [os.path.join(dev, n) for n in NVIDIA_SHARED if n in entries]

    # DRM render nodes, grouped by the PCI device behind them
    drm = []
    try:
        renders = sorted(n for n in os.listdir(os.path.join(dev, "dri")) if re.fullmatch(r"renderD\d+", n))
    except OSError:
        renders = []
    for node in renders:
        base = os.path.join(sys_root, "class/drm", node, "device")
        vendor = VENDORS.get(_read(os.path.join(base, "vendor")), "other")
        pci = os.path.basename(os.path.realpath(base))
        cards = []
        with contextlib.suppress(OSError):
            cards = sorted(os.listdir(os.path.join(base, "drm")))
        nodes = [os.path.join(dev, "dri", node)]
        nodes += [os.path.join(dev, "dri", c) for c in cards
                  if re.fullmatch(r"card\d+", c) and os.path.exists(os.path.join(dev, "dri", c))]
        drm.append({"vendor": vendor, "pci": pci, "nodes": nodes,
                    "device": _read(os.path.join(base, "device"))})

    for minor in sorted(int(n[6:]) for n in entries if re.fullmatch(r"nvidia\d+", n)):
        model, pci = info.get(minor, ("", None))
        nodes = [os.path.join(dev, "nvidia%d" % minor)]
        for d in drm:
            if d["vendor"] == "nvidia" and pci and d["pci"] == pci:
                nodes += d["nodes"]
        gpus.append(Gpu(len(gpus), "nvidia", model or "NVIDIA GPU", nodes, shared))

    kfd = [os.path.join(dev, "kfd")] if "kfd" in entries else []
    for d in drm:
        if d["vendor"] == "nvidia":
            continue
        label = {"amd": "AMD", "intel": "Intel"}.get(d["vendor"], "GPU")
        name = "%s GPU %s" % (label, d["device"]) if d["device"] else "%s GPU" % label
        gpus.append(Gpu(len(gpus), d["vendor"], name, d["nodes"], kfd if d["vendor"] == "amd" else ()))
    return gpus


def parse_spec(spec):
    """`any`, `N` or `N,M` -> "any" or a list of indexes."""
    spec = (spec or "any").strip()
    if not _SPEC.match(spec):
        raise GpuError("invalid GPU selection %r (use a GPU index, a comma list, or 'any')" % spec)
    if spec == "any":
        return "any"
    return sorted({int(i) for i in spec.split(",")})


def environment(granted):
    """Environment variables that make CUDA/ROCm see exactly the granted GPUs."""
    env = {"NESTLO_GPUS": ",".join(str(g.index) for g in granted)}
    nvidia = [g for g in granted if g.vendor == "nvidia"]
    amd = [g for g in granted if g.vendor == "amd"]
    if nvidia:
        ids = ",".join(re.search(r"(\d+)$", g.devices[0]).group(1) for g in nvidia)
        env["CUDA_VISIBLE_DEVICES"] = ids
        env["NVIDIA_VISIBLE_DEVICES"] = ids
    if amd:
        ids = ",".join(str(i) for i in range(len(amd)))
        env["HIP_VISIBLE_DEVICES"] = ids
        env["ROCR_VISIBLE_DEVICES"] = ids
    return env


class Registry:
    def __init__(self, lock_dir, clock=time.time):
        self.dir = lock_dir
        self.clock = clock

    @contextlib.contextmanager
    def _locked(self):
        os.makedirs(self.dir, exist_ok=True)
        path = os.path.join(self.dir, ".lock")
        with open(path, "a") as f:
            # The daemon (group nestlo) takes this lock too
            with contextlib.suppress(OSError):
                os.chmod(path, 0o660)
            fcntl.flock(f, fcntl.LOCK_EX)
            yield

    def _path(self, index):
        return os.path.join(self.dir, str(index))

    def holders(self):
        """{gpu index: agent id}"""
        out = {}
        try:
            names = os.listdir(self.dir)
        except OSError:
            return out
        for name in names:
            if name.isdigit():
                holder = _read(os.path.join(self.dir, name))
                if holder:
                    out[int(name)] = holder
        return out

    def alloc(self, agent, spec, gpus):
        """Reserve GPUs for `agent`; returns the granted Gpu objects."""
        want = parse_spec(spec)
        if not gpus:
            raise GpuError("no GPUs on this machine")
        by_index = {g.index: g for g in gpus}
        with self._locked():
            held = self.holders()
            if want == "any":
                mine = [i for i, a in held.items() if a == agent and i in by_index]
                free = [g.index for g in gpus if g.index not in held]
                chosen = mine or free[:1]
                if not chosen:
                    raise GpuError("all %d GPU(s) are in use: %s" % (
                        len(gpus), ", ".join("%d held by %s" % (i, a) for i, a in sorted(held.items()))))
            else:
                chosen = want
                for i in chosen:
                    if i not in by_index:
                        raise GpuError("no GPU %d (this machine has %d)" % (i, len(gpus)))
                    if held.get(i, agent) != agent:
                        raise GpuError("GPU %d is held by %s" % (i, held[i]))
            for i in chosen:
                with open(self._path(i), "w") as f:
                    f.write(agent + "\n")
            return [by_index[i] for i in chosen]

    def release(self, agent):
        """Free everything `agent` holds; returns the freed indexes."""
        freed = []
        with self._locked():
            for index, holder in sorted(self.holders().items()):
                if holder == agent:
                    with contextlib.suppress(OSError):
                        os.unlink(self._path(index))
                    freed.append(index)
        return freed

    def release_stale(self, is_running, grace=30):
        """Free locks whose holder is not running (and not just being started)."""
        freed = []
        with self._locked():
            for index, holder in sorted(self.holders().items()):
                try:
                    age = self.clock() - os.path.getmtime(self._path(index))
                except OSError:
                    continue
                if age >= grace and not is_running(holder):
                    with contextlib.suppress(OSError):
                        os.unlink(self._path(index))
                    freed.append(index)
        return freed


def main(argv=None):
    parser = argparse.ArgumentParser(prog="nestlo-gpu", description="Nestlo GPU registry")
    parser.add_argument("--config", default=None, help="services.toml path")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list", help="GPUs and who holds them")
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("alloc", help="reserve GPUs for an agent (root)")
    p.add_argument("agent")
    p.add_argument("spec", nargs="?", default="any")
    p = sub.add_parser("release", help="release an agent's GPUs (root)")
    p.add_argument("agent")
    args = parser.parse_args(argv)

    cfg = configmod.load(args.config)
    reg = Registry(os.environ.get("NESTLO_GPU_DIR") or cfg["gpu"]["lock_dir"])
    if args.cmd != "release" and args.cmd != "list" and not configmod.valid_agent_id(args.agent):
        print("invalid agent id", file=sys.stderr)
        return 2
    gpus = discover()

    if args.cmd == "list":
        held = reg.holders()
        if args.json:
            print(json.dumps([dict(g.to_dict(), holder=held.get(g.index)) for g in gpus]))
        elif not gpus:
            print("No GPUs")
        else:
            print("%-5s %-7s %-40s %s" % ("GPU", "VENDOR", "NAME", "HELD BY"))
            for g in gpus:
                print("%-5d %-7s %-40s %s" % (g.index, g.vendor, g.name[:40], held.get(g.index, "-")))
        return 0

    if args.cmd == "release":
        if not configmod.valid_agent_id(args.agent):
            print("invalid agent id", file=sys.stderr)
            return 2
        reg.release(args.agent)
        return 0

    try:
        granted = reg.alloc(args.agent, args.spec, gpus)
    except GpuError as exc:
        print("nestlo-gpu: %s" % exc, file=sys.stderr)
        return 1
    devices = []
    for g in granted:
        for d in g.devices + g.shared:
            if d not in devices:
                devices.append(d)
    print(json.dumps({"gpus": [g.to_dict() for g in granted], "devices": devices,
                      "env": environment(granted)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
