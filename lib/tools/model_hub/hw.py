"""Hardware probe (deterministic, no LLM): GPUs, RAM, CPU, disk."""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any


def _run(cmd: list[str], timeout: float = 8.0) -> str:
    if not shutil.which(cmd[0]):
        return ""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _nvidia() -> list[dict[str, Any]]:
    out = _run(["nvidia-smi", "--query-gpu=index,name,memory.total,memory.used,memory.free,driver_version,compute_cap",
                "--format=csv,noheader,nounits"])
    gpus = []
    for line in out.strip().splitlines():
        p = [x.strip() for x in line.split(",")]
        if len(p) < 5 or not p[0].isdigit():
            continue
        gpus.append({"index": int(p[0]), "vendor": "nvidia", "name": p[1], "vram_total_mb": int(float(p[2])),
                     "vram_used_mb": int(float(p[3])), "vram_free_mb": int(float(p[4])),
                     "driver": p[5] if len(p) > 5 else None, "compute_cap": p[6] if len(p) > 6 else None,
                     "backend": "cuda"})
    return gpus


def _rocm() -> list[dict[str, Any]]:
    out = _run(["rocm-smi", "--showmeminfo", "vram", "--showproductname", "--json"])
    try:
        d = json.loads(out) if out else {}
    except ValueError:
        return []
    gpus = []
    for k, v in d.items():
        m = re.match(r"card(\d+)", k)
        if not m or not isinstance(v, dict):
            continue
        tot = int(v.get("VRAM Total Memory (B)", 0)) // (1 << 20)
        used = int(v.get("VRAM Total Used Memory (B)", 0)) // (1 << 20)
        gpus.append({"index": int(m.group(1)), "vendor": "amd", "name": v.get("Card series") or v.get("Card SKU"),
                     "vram_total_mb": tot, "vram_used_mb": used, "vram_free_mb": tot - used, "backend": "rocm"})
    return gpus


def _apple() -> list[dict[str, Any]]:
    if platform.system() != "Darwin":
        return []
    mem = _run(["sysctl", "-n", "hw.memsize"]).strip()
    chip = _run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip()
    if not mem.isdigit():
        return []
    # Metal can wire ~65-75% of unified memory by default.
    tot = int(mem) // (1 << 20)
    usable = int(tot * 0.70)
    return [{"index": 0, "vendor": "apple", "name": chip or "Apple Silicon", "vram_total_mb": usable,
             "vram_used_mb": 0, "vram_free_mb": usable, "backend": "metal", "unified_memory": True}]


def _meminfo() -> dict[str, int]:
    out: dict[str, int] = {}
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            k, v = line.split(":", 1)
            if k in ("MemTotal", "MemAvailable", "SwapTotal"):
                out[k] = int(v.split()[0]) // 1024
    except OSError:
        mem = _run(["sysctl", "-n", "hw.memsize"]).strip()
        if mem.isdigit():
            out["MemTotal"] = out["MemAvailable"] = int(mem) // (1 << 20)
    return out


def _cpu() -> dict[str, Any]:
    name, flags = platform.processor() or "", ""
    try:
        txt = Path("/proc/cpuinfo").read_text()
        m = re.search(r"model name\s*:\s*(.+)", txt)
        name = m.group(1).strip() if m else name
        m = re.search(r"flags\s*:\s*(.+)", txt)
        flags = m.group(1) if m else ""
    except OSError:
        pass
    return {"name": name, "threads": os.cpu_count(), "avx2": " avx2" in f" {flags}",
            "avx512": "avx512f" in flags}


def models_dir() -> Path:
    return Path(os.environ.get("MODELS_DIR") or os.environ.get("MODELS_HOST_DIR") or Path.home() / "models")


def probe() -> dict[str, Any]:
    if os.environ.get("MODEL_HUB_HW_FIXTURE"):
        return json.loads(Path(os.environ["MODEL_HUB_HW_FIXTURE"]).read_text())
    gpus = _nvidia() or _rocm() or _apple()
    mem = _meminfo()
    md = models_dir()
    try:
        du = shutil.disk_usage(md if md.exists() else md.parent if md.parent.exists() else Path.home())
        disk = {"path": str(md), "free_mb": du.free // (1 << 20), "total_mb": du.total // (1 << 20)}
    except OSError:
        disk = {"path": str(md), "free_mb": None, "total_mb": None}
    return {
        "os": f"{platform.system()} {platform.release()}",
        "gpus": gpus,
        "gpu_backend": os.environ.get("MODEL_HUB_BACKEND") or (gpus[0]["backend"] if gpus else
                                                                ("vulkan" if list(Path("/dev/dri").glob("renderD*")) else "cpu")),
        "vram_total_mb": sum(g["vram_total_mb"] for g in gpus),
        "ram_total_mb": mem.get("MemTotal"),
        "ram_available_mb": mem.get("MemAvailable"),
        "cpu": _cpu(),
        "disk": disk,
    }
