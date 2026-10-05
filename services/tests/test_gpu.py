import json
import os

import pytest

from nestlo_services import gpu
from nestlo_services.gpu import GpuError, Registry, discover


def touch(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def fake_machine(root, nvidia=0, amd=0, intel=0):
    dev, sysfs, proc = (str(root / d) for d in ("dev", "sys", "proc"))
    os.makedirs(dev)
    render = 128
    for n in range(nvidia):
        touch("%s/nvidia%d" % (dev, n))
        pci = "0000:0%d:00.0" % n
        touch("%s/driver/nvidia/gpus/%s/information" % (proc, pci),
              "Model: \t\t NVIDIA RTX %d\nIRQ:   \t\t 1\nDevice Minor: \t %d\n" % (n, n))
    if nvidia:
        for shared in ("nvidiactl", "nvidia-uvm"):
            touch("%s/%s" % (dev, shared))
    for vendor, count in (("0x1002", amd), ("0x8086", intel)):
        for _ in range(count):
            node = "renderD%d" % render
            touch("%s/dri/%s" % (dev, node))
            touch("%s/dri/card%d" % (dev, render - 128))
            base = "%s/class/drm/%s/device" % (sysfs, node)
            touch(base + "/vendor", vendor + "\n")
            touch(base + "/device", "0x1234\n")
            os.makedirs("%s/drm/card%d" % (base, render - 128))
            render += 1
    if amd:
        touch(dev + "/kfd")
    return dict(dev=dev, sys_root=sysfs, proc=proc)


def test_no_gpus(tmp_path):
    assert discover(str(tmp_path / "nodev"), str(tmp_path / "nosys"), str(tmp_path / "noproc")) == []


def test_discover_mixed(tmp_path):
    gpus = discover(**fake_machine(tmp_path, nvidia=2, amd=1, intel=1))
    assert [(g.index, g.vendor) for g in gpus] == [(0, "nvidia"), (1, "nvidia"), (2, "amd"), (3, "intel")]
    assert gpus[0].name == "NVIDIA RTX 0"
    assert gpus[0].devices == [str(tmp_path / "dev/nvidia0")]
    assert [os.path.basename(d) for d in gpus[0].shared] == ["nvidiactl", "nvidia-uvm"]
    assert [os.path.basename(d) for d in gpus[2].devices] == ["renderD128", "card0"]
    assert [os.path.basename(d) for d in gpus[2].shared] == ["kfd"]
    assert gpus[3].shared == []


def test_parse_spec():
    assert gpu.parse_spec("") == "any"
    assert gpu.parse_spec("any") == "any"
    assert gpu.parse_spec("1,0,1") == [0, 1]
    for bad in ("all", "-1", "0;rm", "1,"):
        with pytest.raises(GpuError):
            gpu.parse_spec(bad)


@pytest.fixture
def machine(tmp_path):
    return discover(**fake_machine(tmp_path / "m", nvidia=2))


def test_alloc_is_exclusive(tmp_path, machine):
    reg = Registry(str(tmp_path / "locks"))
    a = reg.alloc("agent-a", "any", machine)
    b = reg.alloc("agent-b", "any", machine)
    assert (a[0].index, b[0].index) == (0, 1)
    assert reg.holders() == {0: "agent-a", 1: "agent-b"}
    with pytest.raises(GpuError, match="in use"):
        reg.alloc("agent-c", "any", machine)
    with pytest.raises(GpuError, match="held by agent-a"):
        reg.alloc("agent-c", "0", machine)
    with pytest.raises(GpuError, match="no GPU 7"):
        reg.alloc("agent-c", "7", machine)
    # asking again is idempotent for the holder
    assert reg.alloc("agent-a", "0", machine)[0].index == 0
    assert reg.alloc("agent-a", "any", machine)[0].index == 0


def test_alloc_without_gpus(tmp_path):
    with pytest.raises(GpuError, match="no GPUs"):
        Registry(str(tmp_path)).alloc("a", "any", [])


def test_release(tmp_path, machine):
    reg = Registry(str(tmp_path))
    reg.alloc("a", "0,1", machine)
    assert reg.release("a") == [0, 1]
    assert reg.holders() == {}
    assert reg.release("a") == []
    assert reg.alloc("b", "any", machine)[0].index == 0


def test_release_stale(tmp_path, machine):
    now = [1000.0]
    reg = Registry(str(tmp_path), clock=lambda: now[0])
    reg.alloc("live", "0", machine)
    reg.alloc("dead", "1", machine)
    for i in (0, 1):
        os.utime(str(tmp_path / str(i)), (900.0, 900.0))
    assert reg.release_stale(lambda a: a == "live", grace=30) == [1]
    assert reg.holders() == {0: "live"}
    # a lock that was just taken is never stale
    reg.alloc("new", "1", machine)
    os.utime(str(tmp_path / "1"), (995.0, 995.0))
    assert reg.release_stale(lambda a: False, grace=30) == [0]
    assert reg.holders() == {1: "new"}


def test_environment(tmp_path):
    gpus = discover(**fake_machine(tmp_path, nvidia=2, amd=2))
    env = gpu.environment([gpus[1], gpus[3]])
    assert env["CUDA_VISIBLE_DEVICES"] == "1"
    assert env["NVIDIA_VISIBLE_DEVICES"] == "1"
    assert env["HIP_VISIBLE_DEVICES"] == "0"
    assert env["NESTLO_GPUS"] == "1,3"
    assert gpu.environment([]) == {"NESTLO_GPUS": ""}


def test_cli(tmp_path, monkeypatch, capsys):
    fake = fake_machine(tmp_path / "m", nvidia=1)
    monkeypatch.setattr(gpu, "discover", lambda: discover(**fake))
    monkeypatch.setenv("NESTLO_GPU_DIR", str(tmp_path / "locks"))
    assert gpu.main(["alloc", "agent-x", "any"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["env"]["CUDA_VISIBLE_DEVICES"] == "0"
    assert out["devices"][0].endswith("nvidia0") and any(d.endswith("nvidiactl") for d in out["devices"])
    assert gpu.main(["alloc", "agent-y", "any"]) == 1
    assert "in use" in capsys.readouterr().err
    assert gpu.main(["list", "--json"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["holder"] == "agent-x"
    assert gpu.main(["release", "agent-x"]) == 0
    assert gpu.main(["list"]) == 0
    assert "-" in capsys.readouterr().out
    assert gpu.main(["alloc", "bad id", "any"]) == 2


def test_cli_no_gpus(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(gpu, "discover", lambda: [])
    monkeypatch.setenv("NESTLO_GPU_DIR", str(tmp_path))
    assert gpu.main(["list"]) == 0
    assert "No GPUs" in capsys.readouterr().out
    assert gpu.main(["alloc", "a", "any"]) == 1
    assert "no GPUs" in capsys.readouterr().err
