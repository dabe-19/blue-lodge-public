#!/usr/bin/env python3
"""Instrument Rack probe: one snapshot of the whole inference fabric.

The control node (where George's harness, web UI, cron and bridges run) is not
necessarily a compute node. This probe reports both views at once:

  control   host facts, CPU/RAM/load/disk, local GPUs, services, active runs
  nodes     every TIERn_URL in endpoints.conf, probed in parallel, with the
            network path (local / tunnel / lan / remote), latency, live model,
            context, slot usage, configured roles
  roles     which configured roles have at least one online node
  findings  actionable problems derived from the above

Stdlib only. Never prints secrets: API keys are not read into the output, URL
credentials are stripped, and SSH key paths are reduced to "set"/"unset".

Usage: rack_probe.py --george-dir DIR [--timeout SECONDS]
"""

import argparse
import concurrent.futures
import glob
import ipaddress
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

TIERS = (3, 1, 2, 0)
HEARTBEAT_STALE_SECS = 1800


def read_conf(path):
    """Parse KEY=value lines (optionally 'export '-prefixed, quoted)."""
    out = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                if line.startswith("export "):
                    line = line[7:]
                k, v = line.split("=", 1)
                k = k.strip()
                if not re.match(r"^[A-Z0-9_]+$", k):
                    continue
                v = v.strip()
                # Drop trailing inline comments on unquoted values.
                if v[:1] not in ("'", '"') and " #" in v:
                    v = v.split(" #", 1)[0].strip()
                out[k] = v.strip("'\"")
    except OSError:
        pass
    return out


def redact_url(url):
    try:
        p = urllib.parse.urlsplit(url)
    except ValueError:
        return ""
    netloc = p.hostname or ""
    if p.port:
        netloc = f"{netloc}:{p.port}"
    return urllib.parse.urlunsplit((p.scheme, netloc, p.path.rstrip("/"), "", ""))


def http_get(url, timeout):
    """Return (status_code|None, parsed_json|None, latency_ms)."""
    t0 = time.monotonic()
    req = urllib.request.Request(url, headers={"User-Agent": "george-rack-probe/1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(512 * 1024)
            ms = int((time.monotonic() - t0) * 1000)
            try:
                return resp.status, json.loads(body.decode("utf-8", "replace")), ms
            except ValueError:
                return resp.status, None, ms
    except urllib.error.HTTPError as e:
        return e.code, None, int((time.monotonic() - t0) * 1000)
    except (urllib.error.URLError, OSError, ValueError):
        return None, None, int((time.monotonic() - t0) * 1000)


def classify_path(url, remote):
    """local / tunnel / lan / remote, plus a human 'via' string."""
    try:
        p = urllib.parse.urlsplit(url)
        host = (p.hostname or "").lower()
        port = p.port or (443 if p.scheme == "https" else 80)
    except ValueError:
        return "invalid", ""
    tunnel_ports = set()
    for key in ("REMOTE_LOCAL_LLAMACPP_PORT", "REMOTE_LOCAL_OLLAMA_PORT"):
        if remote.get(key, "").isdigit():
            tunnel_ports.add(int(remote[key]))
    if host in ("127.0.0.1", "localhost", "::1", "0.0.0.0"):
        if port in tunnel_ports and remote.get("REMOTE_SSH_TARGET"):
            via = remote.get("REMOTE_SSH_TARGET", "")
            if remote.get("REMOTE_FORWARD_HOST"):
                via += f" -> {remote['REMOTE_FORWARD_HOST']}"
            if remote.get("REMOTE_JUMP_HOST"):
                via += f" (jump {remote['REMOTE_JUMP_HOST']})"
            return "tunnel", via
        return "local", "this host"
    if host.endswith(".local") or host.endswith(".lan"):
        return "lan", host
    try:
        ip = ipaddress.ip_address(host)
        if ip.is_private or ip.is_link_local:
            return "lan", host
    except ValueError:
        pass
    return "remote", host


def probe_node(url, timeout):
    """Probe one endpoint. Provider-agnostic: llama.cpp, Ollama, OpenAI-compatible."""
    base = url.rstrip("/")
    res = {"online": False, "provider": None, "latency_ms": None, "live_model": None,
           "live_ctx": None, "slots_total": None, "slots_busy": None, "health": None}

    code, body, ms = http_get(base + "/health", timeout)
    if code is not None:
        res["latency_ms"] = ms
        res["health"] = (body or {}).get("status") if isinstance(body, dict) else ("ok" if code == 200 else str(code))
    if code == 200:
        res["online"] = True

    code, props, ms = http_get(base + "/props", timeout)
    if code == 200 and isinstance(props, dict):
        res["online"] = True
        res["provider"] = "llama.cpp"
        res["latency_ms"] = res["latency_ms"] or ms
        dgs = props.get("default_generation_settings") or {}
        n_ctx = dgs.get("n_ctx") or props.get("n_ctx")
        if isinstance(n_ctx, int):
            res["live_ctx"] = n_ctx
        mp = props.get("model_path")
        if isinstance(mp, str) and mp:
            res["live_model"] = os.path.basename(mp).removesuffix(".gguf")
        code, slots, _ = http_get(base + "/slots", timeout)
        if code == 200 and isinstance(slots, list):
            res["slots_total"] = len(slots)
            res["slots_busy"] = sum(1 for s in slots if isinstance(s, dict) and (s.get("is_processing") or s.get("state") == 1))

    if res["provider"] is None:
        code, tags, ms = http_get(base + "/api/tags", timeout)
        if code == 200 and isinstance(tags, dict) and "models" in tags:
            res["online"] = True
            res["provider"] = "ollama"
            res["latency_ms"] = res["latency_ms"] or ms
            names = [m.get("name") for m in tags.get("models", []) if isinstance(m, dict) and m.get("name")]
            res["models_available"] = names[:20]

    if res["online"] and res["live_model"] is None:
        code, models, _ = http_get(base + "/v1/models", timeout)
        if code == 200 and isinstance(models, dict):
            data = models.get("data") or []
            if data and isinstance(data[0], dict) and data[0].get("id"):
                res["live_model"] = os.path.basename(str(data[0]["id"])).removesuffix(".gguf")
            if res["provider"] is None:
                res["provider"] = "openai-compatible"
    return res


def meminfo():
    out = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                k, _, v = line.partition(":")
                if k in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
                    out[k] = int(v.strip().split()[0]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return out


def local_gpus():
    smi = "/usr/lib/wsl/lib/nvidia-smi" if os.path.exists("/usr/lib/wsl/lib/nvidia-smi") else shutil.which("nvidia-smi")
    if not smi:
        return []
    try:
        out = subprocess.run(
            [smi, "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    gpus = []
    for line in out.stdout.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 7:
            def num(x):
                try:
                    return float(x)
                except ValueError:
                    return None
            gpus.append({"index": parts[0], "name": parts[1], "util_pct": num(parts[2]),
                         "vram_used_mb": num(parts[3]), "vram_total_mb": num(parts[4]),
                         "temp_c": num(parts[5]), "power_w": num(parts[6])})
    return gpus


def pid_alive(pid_file):
    try:
        with open(pid_file, "r", encoding="utf-8") as f:
            tok = f.read().split()
        pid = int(tok[0]) if tok else 0
    except (OSError, ValueError):
        return False
    return pid > 0 and os.path.exists(f"/proc/{pid}")


def process_count(pattern):
    """Count processes whose cmdline matches pattern (excluding this probe)."""
    rx = re.compile(pattern)
    me = os.getpid()
    n = 0
    for d in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            pid = int(d.split("/")[2])
            if pid == me:
                continue
            with open(d, "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode("utf-8", "replace")
        except (OSError, ValueError):
            continue
        if rx.search(cmd):
            n += 1
    return n


def docker_containers():
    if not shutil.which("docker"):
        return None
    try:
        out = subprocess.run(["docker", "ps", "--format", "{{.Names}}\t{{.Status}}"],
                             capture_output=True, text=True, timeout=4, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    rows = []
    for line in out.stdout.splitlines():
        name, _, status = line.partition("\t")
        if re.match(r"^[A-Za-z0-9_.-]{1,128}$", name):
            rows.append({"name": name, "status": status[:80]})
    return rows


def heartbeats(george_dir):
    now = int(time.time())
    rows = []
    for path in sorted(glob.glob(os.path.join(george_dir, "heartbeats", "*.json"))):
        try:
            with open(path, "r", encoding="utf-8") as f:
                v = json.load(f)
        except (OSError, ValueError):
            continue
        name = str(v.get("name", ""))
        if not re.match(r"^[A-Za-z0-9_-]{1,64}$", name):
            continue
        ts = v.get("ts") if isinstance(v.get("ts"), int) else 0
        age = max(0, now - ts)
        rows.append({"name": name, "age_s": age, "stale": age > HEARTBEAT_STALE_SECS})
    return rows


def control_node(george_dir):
    try:
        with open("/proc/version", "r", encoding="utf-8") as f:
            wsl = "microsoft" in f.read().lower()
    except OSError:
        wsl = False
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            uptime = int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        uptime = None
    try:
        load = [round(x, 2) for x in os.getloadavg()]
    except OSError:
        load = None
    try:
        du = shutil.disk_usage(george_dir)
        disk = {"total_gb": round(du.total / 2**30, 1), "free_gb": round(du.free / 2**30, 1),
                "free_pct": round(100 * du.free / du.total, 1) if du.total else None}
    except OSError:
        disk = None

    sess_dir = os.path.join(george_dir, "discord_sessions")
    discord_sessions = sum(1 for p in glob.glob(os.path.join(sess_dir, "session_*.pid")) if pid_alive(p))
    active_runs = len(glob.glob(os.path.join(sess_dir, "active_run_*.json")))

    services = {
        "george_web": process_count(r"george-web"),
        "cron_loop": process_count(r"_cron_loop_runner"),
        "event_bus": process_count(r"george-event-bus"),
        "mcp_servers": process_count(r"lib/tools/mcp_server_"),
        "discord_sessions": discord_sessions,
        "discord_active_runs": active_runs,
        "llama_server": process_count(r"llama-server"),
        "ollama": process_count(r"ollama (serve|runner)"),
    }
    return {
        "hostname": socket.gethostname(),
        "os": f"{platform.system()} {platform.release()}",
        "wsl": wsl,
        "cpus": os.cpu_count(),
        "load": load,
        "uptime_s": uptime,
        "memory_mb": meminfo(),
        "disk": disk,
        "gpus": local_gpus(),
        "services": services,
        "containers": docker_containers(),
        "heartbeats": heartbeats(george_dir),
    }


def active_base_model(models_dir=None):
    models_dir = models_dir or os.environ.get("MODELS_DIR") or os.path.join(os.path.expanduser("~"), "models")
    try:
        target = os.readlink(os.path.join(models_dir, "active", "current", "base.gguf"))
    except OSError:
        return None
    return os.path.basename(target).removesuffix(".gguf") or None


def build_nodes(endpoints, remote, timeout, models_dir=None):
    specs = []
    for t in TIERS:
        url = endpoints.get(f"TIER{t}_URL", "").strip()
        if not url:
            continue
        if not re.match(r"^https?://", url, re.I):
            specs.append({"tier": t, "url": redact_url(url) or "(invalid)", "invalid": True})
            continue
        ctx = endpoints.get(f"TIER{t}_CONTEXT", "")
        specs.append({
            "tier": t,
            "url": redact_url(url),
            "_raw_url": url,
            "name": endpoints.get(f"TIER{t}_NAME", "") or f"tier{t}",
            "configured_model": endpoints.get(f"TIER{t}_MODEL", ""),
            "configured_ctx": int(ctx) if ctx.isdigit() else None,
            "hardware": endpoints.get(f"TIER{t}_HARDWARE", ""),
            "enabled": endpoints.get(f"TIER{t}_ENABLED", "1").lower() in ("1", "true", "yes", "on"),
            "roles": [r.strip() for r in endpoints.get(f"TIER{t}_ROLES", "").split(",") if r.strip()],
        })

    def run(spec):
        if spec.get("invalid"):
            return spec
        path, via = classify_path(spec["_raw_url"], remote)
        spec["path"], spec["via"] = path, via
        if spec["enabled"]:
            spec.update(probe_node(spec["_raw_url"], timeout))
            # The hub serves the active profile as "base.gguf"; name the real file.
            if spec.get("live_model") == "base" and path == "local":
                spec["live_model"] = active_base_model(models_dir) or "base"
        else:
            spec.update({"online": False, "provider": None, "latency_ms": None})
        spec.pop("_raw_url", None)
        return spec

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(specs))) as ex:
        nodes = list(ex.map(run, specs))
    for n in nodes:
        n.pop("_raw_url", None)
        if n.get("invalid"):
            n["status"] = "invalid"
        elif not n.get("enabled"):
            n["status"] = "disabled"
        else:
            n["status"] = "online" if n.get("online") else "offline"
    return nodes


def role_coverage(nodes):
    roles = {}
    for n in nodes:
        if not n.get("enabled"):
            continue
        for r in n.get("roles", []):
            ent = roles.setdefault(r, {"role": r, "nodes": [], "online": []})
            ent["nodes"].append(n["name"])
            if n.get("online"):
                ent["online"].append(n["name"])
    return sorted(roles.values(), key=lambda e: (bool(e["online"]), e["role"]))


def findings(control, nodes, roles, remote):
    out = []

    def add(level, msg):
        out.append({"level": level, "msg": msg})

    enabled = [n for n in nodes if n.get("enabled")]
    online = [n for n in enabled if n.get("online")]
    if not nodes:
        add("error", "No compute nodes configured (endpoints.conf has no TIERn_URL).")
    elif not online:
        add("error", "No enabled compute node is reachable; George cannot run inference.")

    for n in nodes:
        label = f"Tier {n['tier']} '{n.get('name', '')}'"
        if n.get("invalid"):
            add("error", f"{label} has an invalid URL; only http(s) endpoints are supported.")
            continue
        if not n.get("enabled"):
            continue
        if not n.get("online"):
            if n.get("path") == "tunnel":
                add("warn", f"{label} is offline and routed through the SSH tunnel ({n.get('via')}); re-establish the tunnel.")
            else:
                add("warn", f"{label} at {n['url']} is enabled but unreachable.")
            continue
        cm, lm = n.get("configured_model"), n.get("live_model")
        if cm and lm and lm != "base" and cm.lower() not in lm.lower() and lm.lower() not in cm.lower():
            add("info", f"{label} is serving '{lm}' but endpoints.conf says '{cm}'.")
        cc, lc = n.get("configured_ctx"), n.get("live_ctx")
        if cc and lc and cc > lc:
            add("warn", f"{label}: configured context {cc} exceeds the server's n_ctx {lc}; prompts may be truncated.")
        st, sb = n.get("slots_total"), n.get("slots_busy")
        if st and sb is not None and sb >= st:
            add("info", f"{label}: all {st} slot(s) busy; new requests will queue.")
        if n.get("latency_ms") and n["latency_ms"] > 1500:
            add("info", f"{label}: slow health response ({n['latency_ms']} ms).")

    for r in roles:
        if not r["online"]:
            add("warn", f"Role '{r['role']}' has no online node (configured on: {', '.join(r['nodes'])}).")

    mem = control.get("memory_mb") or {}
    if mem.get("MemTotal") and mem.get("MemAvailable") is not None and mem["MemAvailable"] < 0.1 * mem["MemTotal"]:
        add("warn", f"Control node memory is low ({mem['MemAvailable']} MB available).")
    disk = control.get("disk") or {}
    if disk.get("free_pct") is not None and disk["free_pct"] < 10:
        add("warn", f"Control node disk is {100 - disk['free_pct']:.0f}% full ({disk['free_gb']} GB free).")
    load, cpus = control.get("load"), control.get("cpus") or 1
    if load and load[0] > 2 * cpus:
        add("info", f"Control node load {load[0]} is high for {cpus} CPUs.")
    for hb in control.get("heartbeats", []):
        if hb["stale"]:
            add("warn", f"Heartbeat '{hb['name']}' is stale ({hb['age_s'] // 60} min); that daemon may be down.")
    if remote.get("REMOTE_SSH_TARGET") and not any(n.get("path") == "tunnel" for n in nodes):
        add("info", "remote.conf defines an SSH target but no tier routes through its tunnel port.")
    return out


def main():
    ap = argparse.ArgumentParser(description="Instrument Rack fabric probe")
    ap.add_argument("--george-dir", required=True)
    ap.add_argument("--timeout", type=float, default=2.0)
    args = ap.parse_args()

    gd = os.path.realpath(args.george_dir)
    endpoints = read_conf(os.path.join(gd, "endpoints.conf"))
    remote = read_conf(os.path.join(gd, "remote.conf"))
    models_dir = read_conf(os.path.join(gd, "lodge.conf")).get("MODELS_DIR") or None
    timeout = min(max(args.timeout, 0.2), 5.0)

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        f_ctrl = ex.submit(control_node, gd)
        f_nodes = ex.submit(build_nodes, endpoints, remote, timeout, models_dir)
        control, nodes = f_ctrl.result(), f_nodes.result()

    roles = role_coverage(nodes)
    tunnel = None
    if remote.get("REMOTE_SSH_TARGET"):
        tunnel = {
            "target": remote.get("REMOTE_SSH_TARGET", ""),
            "forward_host": remote.get("REMOTE_FORWARD_HOST", ""),
            "jump_host": remote.get("REMOTE_JUMP_HOST", ""),
            "local_llamacpp_port": remote.get("REMOTE_LOCAL_LLAMACPP_PORT", ""),
            "local_ollama_port": remote.get("REMOTE_LOCAL_OLLAMA_PORT", ""),
            "node_mode": remote.get("REMOTE_NODE_MODE", "hybrid"),
            "key": "set" if remote.get("REMOTE_SSH_KEY") else "unset",
        }
    swarm_nodes = []
    try:
        with open(os.path.join(gd, "swarm", "nodes.json"), "r", encoding="utf-8") as f:
            sn = json.load(f)
            if isinstance(sn, list):
                swarm_nodes = sn
    except (OSError, ValueError):
        pass
    fifo_channels = {}
    for st_path in glob.glob(os.path.join(gd, "ipc", "channels", "*", "state.json")):
        try:
            with open(st_path, "r", encoding="utf-8") as f:
                st = json.load(f)
            cid = st.get("channel_id")
            if cid:
                fifo_channels[cid] = {
                    "status": st.get("status"),
                    "credits": st.get("credits"),
                    "window_size": st.get("window_size"),
                    "backpressure": st.get("backpressure"),
                }
        except (OSError, ValueError):
            pass
    for n in nodes:
        for sn in swarm_nodes:
            if isinstance(sn, dict) and (sn.get("id") == n.get("name") or sn.get("host") == n.get("name")):
                n["swarm_mode"] = sn.get("mode")
                n["swarm_status"] = sn.get("status")
                fc = sn.get("fifo_channel")
                if fc and fc in fifo_channels:
                    n["fifo_channel"] = fc
                    n["fifo_credits"] = fifo_channels[fc].get("credits")
                    n["fifo_window"] = fifo_channels[fc].get("window_size")
                    n["fifo_backpressure"] = fifo_channels[fc].get("backpressure")

    print(json.dumps({
        "generated_at": int(time.time()),
        "control": control,
        "nodes": nodes,
        "roles": roles,
        "tunnel": tunnel,
        "swarm_nodes": swarm_nodes,
        "findings": findings(control, nodes, roles, remote),
    }))


if __name__ == "__main__":
    main()
