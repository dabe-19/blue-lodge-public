#!/usr/bin/env python3
"""Remote Node Dynamic Hardware, Model, LoRA & Service Discovery Probe.

Executed via `ssh <target> python3 - < lib/sys/remote_node_probe.py`.
Stdlib only. Makes zero static assumptions about hostname, GPU vendor,
directory layout, or installed models.
"""

import glob
import json
import os
import platform
import re
import shutil
import socket
import struct
import subprocess
import urllib.request


def sh(cmd, timeout=4):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def discover():
    hostname = socket.gethostname()
    cpus = os.cpu_count() or 1
    cpu_model = sh(r'lscpu 2>/dev/null | awk -F: "/Model name/{gsub(/^[ \t]+/,\"\",\$2); print \$2; exit}"')

    mem_total_mb, mem_avail_mb = 0, 0
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_total_mb = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    mem_avail_mb = int(line.split()[1]) // 1024
    except Exception:
        pass

    try:
        du = shutil.disk_usage(os.path.expanduser("~"))
        disk_free_gb = round(du.free / (1024 ** 3), 1)
        disk_total_gb = round(du.total / (1024 ** 3), 1)
    except Exception:
        disk_free_gb, disk_total_gb = 0.0, 0.0

    gpus = []
    if shutil.which("nvidia-smi"):
        out = sh("nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits")
        for line in out.splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 4:
                gpus.append({
                    "index": parts[0],
                    "name": parts[1],
                    "backend": "cuda",
                    "vram_used_mb": int(float(parts[2])) if parts[2].replace(".", "").isdigit() else 0,
                    "vram_total_mb": int(float(parts[3])) if parts[3].replace(".", "").isdigit() else 0,
                    "gtt_used_mb": 0,
                })

    if not gpus:
        vk_names = []
        if shutil.which("vulkaninfo"):
            vk_out = sh("vulkaninfo --summary 2>/dev/null")
            for m in re.finditer(r"deviceName\s*=\s*(.+)", vk_out):
                dn = m.group(1).strip()
                if "llvmpipe" not in dn.lower():
                    vk_names.append(dn)
        cards = sorted(glob.glob("/sys/class/drm/card[0-9]*/device/mem_info_vram_total"))
        for idx, cpath in enumerate(cards):
            cdir = os.path.dirname(cpath)
            try:
                v_tot = int(open(os.path.join(cdir, "mem_info_vram_total")).read().strip()) // (1024 * 1024)
                v_used = int(open(os.path.join(cdir, "mem_info_vram_used")).read().strip()) // (1024 * 1024)
                gtt_file = os.path.join(cdir, "mem_info_gtt_used")
                g_used = int(open(gtt_file).read().strip()) // (1024 * 1024) if os.path.exists(gtt_file) else 0
            except Exception:
                v_tot, v_used, g_used = 0, 0, 0
            gname = vk_names[idx] if idx < len(vk_names) else (vk_names[0] if vk_names else "AMD/Vulkan GPU")
            gpus.append({
                "index": str(idx),
                "name": gname,
                "backend": "vulkan",
                "vram_used_mb": v_used,
                "vram_total_mb": v_tot,
                "gtt_used_mb": g_used,
            })

    if gpus:
        g0 = gpus[0]
        vram_gb = round(g0["vram_total_mb"] / 1024) if g0["vram_total_mb"] else 0
        gname_clean = re.sub(r"\s*\([^)]*\)\s*$", "", g0["name"]).strip()
        if vram_gb:
            hw_summary = f"{gname_clean} ({vram_gb}GB {g0['backend'].upper()})"
        else:
            hw_summary = f"{gname_clean} ({g0['backend'].upper()})"
    else:
        hw_summary = f"{cpu_model or platform.machine()} ({cpus} vCPU)"

    def read_gguf_header(path):
        info = {"architecture": "", "type": "model", "file_type": None, "size_label": "", "block_count": None}
        try:
            with open(path, "rb") as f:
                magic, version, n_tensors, n_kv = struct.unpack("<4sIQQ", f.read(24))
                if magic != b"GGUF":
                    return info

                def r_str():
                    n = struct.unpack("<Q", f.read(8))[0]
                    return f.read(n).decode("utf-8", "replace")

                def r_val(vt):
                    if vt == 8:
                        return r_str()
                    if vt == 9:
                        at, al = struct.unpack("<IQ", f.read(12))
                        for _ in range(al):
                            r_val(at)
                        return None
                    fmt = {
                        0: "<B", 1: "<b", 2: "<H", 3: "<h",
                        4: "<I", 5: "<i", 6: "<f", 7: "?",
                        10: "<Q", 11: "<q", 12: "<d",
                    }[vt]
                    return struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]

                for _ in range(min(n_kv, 64)):
                    k = r_str()
                    vt = struct.unpack("<I", f.read(4))[0]
                    v = r_val(vt)
                    if k == "general.architecture":
                        info["architecture"] = str(v or "")
                    elif k == "general.type":
                        info["type"] = str(v or "model")
                    elif k == "general.file_type":
                        info["file_type"] = v
                    elif k == "general.size_label":
                        info["size_label"] = str(v or "")
                    elif k.endswith(".block_count"):
                        info["block_count"] = v
        except Exception:
            pass
        return info

    home = os.path.expanduser("~")
    search_dirs = [
        os.path.join(home, "llama.cpp", "models"),
        os.path.join(home, "llama.cpp-prism", "models"),
        os.path.join(home, "models"),
        os.path.join(home, ".george", "adapters"),
        os.path.join(home, "models", "adapters"),
        "/opt/models",
    ]
    seen_files = set()
    models = []
    loras = []
    for d in search_dirs:
        if not os.path.isdir(d):
            continue
        for root, _, files in os.walk(d):
            for fn in sorted(files):
                if not fn.endswith(".gguf") or fn.startswith("ggml-vocab-") or "mmproj" in fn.lower() or fn.lower().startswith("mtp-"):
                    continue
                fp = os.path.realpath(os.path.join(root, fn))
                if fp in seen_files:
                    continue
                seen_files.add(fp)
                try:
                    sz = os.path.getsize(fp)
                except OSError:
                    continue
                if sz < 1024 * 1024:
                    continue
                hdr = read_gguf_header(fp)
                entry = {
                    "name": fn[:-5],
                    "path": fp,
                    "size_mb": round(sz / (1024 * 1024), 1),
                    "size_gb": round(sz / (1024 ** 3), 2),
                    "architecture": hdr["architecture"],
                    "file_type": hdr["file_type"],
                    "size_label": hdr["size_label"],
                    "block_count": hdr["block_count"],
                    "requires_prism": bool(hdr["file_type"] == 143 or "prism" in fp.lower() or "bonsai" in fn.lower()),
                }
                if hdr["type"] == "adapter" or "lora" in fn.lower() or "adapters" in fp.lower():
                    loras.append(entry)
                else:
                    models.append(entry)

    binaries = []
    for cand in [
        os.path.join(home, "llama.cpp", "build", "bin", "llama-server.real"),
        os.path.join(home, "llama.cpp", "build", "bin", "llama-server"),
        os.path.join(home, "llama.cpp-prism", "build", "bin", "llama-server"),
        "/usr/local/bin/llama-server",
    ]:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            binaries.append(cand)

    active = {"online": False, "model": "", "model_path": "", "lora_path": "", "n_ctx": None, "slots_total": None}
    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/props", timeout=2) as r:
            props = json.loads(r.read().decode("utf-8", "replace"))
            active["online"] = True
            dgs = props.get("default_generation_settings") or {}
            active["n_ctx"] = dgs.get("n_ctx") or props.get("n_ctx")
            mp = props.get("model_path") or ""
            active["model_path"] = mp
            active["model"] = os.path.basename(mp).removesuffix(".gguf") if mp else ""
    except Exception:
        pass

    if not active["model"]:
        try:
            with urllib.request.urlopen("http://127.0.0.1:8080/v1/models", timeout=2) as r:
                mdata = json.loads(r.read().decode("utf-8", "replace"))
                arr = mdata.get("data") or []
                if arr:
                    active["online"] = True
                    mid = arr[0].get("id") or ""
                    active["model_path"] = mid
                    active["model"] = os.path.basename(mid).removesuffix(".gguf")
                    if not active["n_ctx"]:
                        active["n_ctx"] = (arr[0].get("meta") or {}).get("n_ctx")
        except Exception:
            pass

    try:
        with urllib.request.urlopen("http://127.0.0.1:8080/slots", timeout=2) as r:
            sdata = json.loads(r.read().decode("utf-8", "replace"))
            if isinstance(sdata, list):
                active["slots_total"] = len(sdata)
                if not active["n_ctx"] and sdata and isinstance(sdata[0], dict):
                    active["n_ctx"] = sdata[0].get("n_ctx")
    except Exception:
        pass

    conf_path = os.path.join(home, ".george", "active_model.conf")
    if os.path.isfile(conf_path):
        try:
            for line in open(conf_path, "r", encoding="utf-8"):
                if line.startswith("ACTIVE_LORA_PATH="):
                    active["lora_path"] = line.split("=", 1)[1].strip().strip("\"'")
                elif line.startswith("ACTIVE_CTX_SIZE=") and not active["n_ctx"]:
                    val = line.split("=", 1)[1].strip().strip("\"'")
                    if val.isdigit():
                        active["n_ctx"] = int(val)
        except Exception:
            pass

    repo_dir = os.path.join(home, "blue-lodge")
    repo_present = os.path.isdir(os.path.join(repo_dir, ".git"))
    repo_branch = sh(f"git -C {repo_dir} rev-parse --abbrev-ref HEAD") if repo_present else ""
    repo_commit = sh(f"git -C {repo_dir} rev-parse --short HEAD") if repo_present else ""
    worker_pid_file = os.path.join(repo_dir, ".george", "swarm", ".worker.pid")
    worker_alive = False
    if os.path.isfile(worker_pid_file):
        try:
            wpid = int(open(worker_pid_file).read().strip())
            worker_alive = os.path.exists(f"/proc/{wpid}")
        except Exception:
            pass

    print(json.dumps({
        "status": "ok",
        "hostname": hostname,
        "os": f"{platform.system()} {platform.release()}",
        "cpus": cpus,
        "cpu_model": cpu_model,
        "ram_total_mb": mem_total_mb,
        "ram_avail_mb": mem_avail_mb,
        "disk_free_gb": disk_free_gb,
        "disk_total_gb": disk_total_gb,
        "gpus": gpus,
        "hardware_summary": hw_summary,
        "binaries": binaries,
        "models": models,
        "loras": loras,
        "active": active,
        "worker": {
            "repo_present": repo_present,
            "repo_branch": repo_branch,
            "repo_commit": repo_commit,
            "worker_daemon_alive": worker_alive,
            "mosquitto_installed": bool(
                shutil.which("mosquitto_sub") or os.path.isfile(os.path.join(home, ".local", "bin", "mosquitto_sub"))
            ),
        },
    }))


if __name__ == "__main__":
    discover()

