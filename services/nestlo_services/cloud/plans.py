"""Resource plans and quotas.

A user (or a team) owns a pool: CPU and memory that all of its pool VMs
share, the way exe.dev pools work. Each pool VM is capped at its own size and
the pool caps their sum (a systemd slice per owner). Standalone VMs
(sandboxes) are outside the pool, counted per VM and metered by the hour.

The presets mirror exe.dev's published plans (docs/cloud.md). On a
self-hosted system they are quotas, not prices: the administrator assigns a
plan to each user or team and can override any limit.
"""

GB = 1024  # sizes are kept in MiB

PRESETS = {
    "personal": {
        "pools": 1,
        "pool_vms": 50,
        "pool_cpu": 2, "pool_cpu_max": 16,
        "pool_memory_mb": 4 * GB, "pool_memory_mb_max": 32 * GB,
        "disk_gb_per_2cpu": 100,
        "bandwidth_gb": 200,
        "standalone_vms": 50,
        "standalone_cpu_max": 16, "standalone_memory_mb_max": 32 * GB,
        "sharing": False,
        "custom_domains": True,
    },
    "work": {
        "pools": 0,           # 0: unlimited
        "pool_vms": 1000,
        "pool_cpu": 4, "pool_cpu_max": 512,
        "pool_memory_mb": 8 * GB, "pool_memory_mb_max": 1024 * GB,
        "disk_gb_per_2cpu": 100,
        "bandwidth_gb": 0,    # 50 GB per vCPU, see limits()
        "standalone_vms": 100,
        "standalone_cpu_max": 32, "standalone_memory_mb_max": 64 * GB,
        "sharing": True,
        "custom_domains": True,
    },
    "enterprise": {
        "pools": 0,
        "pool_vms": 0,
        "pool_cpu": 16, "pool_cpu_max": 0,
        "pool_memory_mb": 32 * GB, "pool_memory_mb_max": 0,
        "disk_gb_per_2cpu": 0,
        "bandwidth_gb": 0,
        "standalone_vms": 0,
        "standalone_cpu_max": 0, "standalone_memory_mb_max": 0,
        "sharing": True,
        "custom_domains": True,
    },
}

DEFAULT_VM = {"cpu": 2, "memory_mb": 8 * GB, "disk_gb": 20}


class QuotaError(Exception):
    pass


def limits(plan_name, overrides=None, pool_cpu=None, pool_memory_mb=None):
    """The effective limits of a plan: the preset, the configured overrides,
    and the pool size the owner chose (within the plan's maximum)."""
    if plan_name not in PRESETS:
        raise QuotaError("unknown plan %r (plans: %s)" % (plan_name, ", ".join(PRESETS)))
    out = dict(PRESETS[plan_name])
    out.update(overrides or {})
    out["plan"] = plan_name
    if pool_cpu is not None:
        out["pool_cpu"] = pool_cpu
    if pool_memory_mb is not None:
        out["pool_memory_mb"] = pool_memory_mb
    if plan_name == "work" and not out.get("bandwidth_gb"):
        out["bandwidth_gb"] = 50 * out["pool_cpu"]
    per2 = out.get("disk_gb_per_2cpu") or 0
    out["disk_gb"] = per2 * max(1, out["pool_cpu"] // 2) if per2 else 0
    return out


def check_pool_size(lim, cpu, memory_mb):
    """Raise QuotaError unless a pool of this size fits the plan."""
    if cpu < 1 or memory_mb < 512:
        raise QuotaError("a pool needs at least 1 vCPU and 512 MB")
    if lim["pool_cpu_max"] and cpu > lim["pool_cpu_max"]:
        raise QuotaError("plan %s allows a pool of at most %d vCPUs" % (lim["plan"], lim["pool_cpu_max"]))
    if lim["pool_memory_mb_max"] and memory_mb > lim["pool_memory_mb_max"]:
        raise QuotaError("plan %s allows a pool of at most %s of memory" % (lim["plan"], fmt_mb(lim["pool_memory_mb_max"])))


def check_new_vm(lim, vms, cpu, memory_mb, disk_gb, standalone):
    """Raise QuotaError unless one more VM of this size fits.

    `vms` are the owner's existing VM records."""
    if standalone:
        count = sum(1 for v in vms if v.get("standalone"))
        if lim["standalone_vms"] and count >= lim["standalone_vms"]:
            raise QuotaError("plan %s allows %d standalone VMs" % (lim["plan"], lim["standalone_vms"]))
        if lim["standalone_cpu_max"] and cpu > lim["standalone_cpu_max"]:
            raise QuotaError("a standalone VM can have at most %d vCPUs" % lim["standalone_cpu_max"])
        if lim["standalone_memory_mb_max"] and memory_mb > lim["standalone_memory_mb_max"]:
            raise QuotaError("a standalone VM can have at most %s of memory" % fmt_mb(lim["standalone_memory_mb_max"]))
    else:
        count = sum(1 for v in vms if not v.get("standalone"))
        if lim["pool_vms"] and count >= lim["pool_vms"]:
            raise QuotaError("plan %s allows %d VMs per pool" % (lim["plan"], lim["pool_vms"]))
        # A pool VM can be as large as the pool, not larger
        if cpu > lim["pool_cpu"]:
            raise QuotaError("a VM cannot have more vCPUs (%d) than its pool (%d); grow the pool with "
                             "`billing capacity`" % (cpu, lim["pool_cpu"]))
        if memory_mb > lim["pool_memory_mb"]:
            raise QuotaError("a VM cannot have more memory (%s) than its pool (%s)" % (
                fmt_mb(memory_mb), fmt_mb(lim["pool_memory_mb"])))
    check_disk(lim, vms, disk_gb)


def check_disk(lim, vms, disk_gb, exclude=None):
    if not lim["disk_gb"]:
        return
    used = sum(int(v.get("disk_gb") or 0) for v in vms if v.get("id") != exclude)
    if used + disk_gb > lim["disk_gb"]:
        raise QuotaError("disk quota exceeded: %d GB in use, %d GB requested, plan allows %d GB" % (
            used, disk_gb, lim["disk_gb"]))


def parse_size_mb(text):
    """'8GB', '512MB', '8G', '8' (GB) -> MiB."""
    s = str(text).strip().upper().replace("IB", "B")
    for suffix, mult in (("TB", GB * GB), ("T", GB * GB), ("GB", GB), ("G", GB), ("MB", 1), ("M", 1)):
        if s.endswith(suffix):
            s, factor = s[: -len(suffix)], mult
            break
    else:
        factor = GB
    try:
        value = float(s)
    except ValueError:
        raise QuotaError("bad size %r (use e.g. 8GB or 512MB)" % text)
    mb = int(value * factor)
    if mb <= 0:
        raise QuotaError("size must be positive: %r" % text)
    return mb


def parse_disk_gb(text):
    mb = parse_size_mb(text)
    return max(1, (mb + GB - 1) // GB)


def parse_cpu(text):
    try:
        n = int(str(text))
    except ValueError:
        raise QuotaError("bad CPU count %r" % text)
    if n < 1 or n > 1024:
        raise QuotaError("CPU count must be between 1 and 1024")
    return n


def fmt_mb(mb):
    return "%d GB" % (mb // GB) if mb % GB == 0 else "%d MB" % mb
