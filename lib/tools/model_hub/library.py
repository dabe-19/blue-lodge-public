"""Local model library: whatever GGUFs the operator actually has on disk.

Nothing here is curated. The library walks MODELS_DIR (no symlink-following, bounded depth/count),
reads each GGUF's metadata header, and classifies files from that metadata:

  model    a full model (anything not matched below)
  adapter  general.type == "adapter" (LoRA) or architecture "controlvector"
  mmproj   general.type == "mmproj" or architecture "clip" (vision/audio projector)
  draft    speculative-decoding draft / MTP head (file name starts with mtp- or contains "draft")

Metadata and sha256 digests are cached in .george/models/library_cache.json keyed by
(realpath, size, mtime_ns), so re-scans are cheap and a changed file is always re-read.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path
from typing import Any, Callable

from . import gguf
from .common import HubError, george_dir, quant_of, safe_relpath, shard_info
from .hw import models_dir

MAX_DEPTH = 6
MAX_FILES = 2000
SKIP_DIRS = {"__pycache__", "node_modules", "lost+found"}
CHUNK = 8 << 20

# llama.cpp LLAMA_FTYPE -> quant label (fallback when the file name carries no quant).
FTYPE = {0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1", 10: "Q2_K", 11: "Q3_K_S",
         12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M", 16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K",
         19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S", 22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL",
         26: "IQ3_S", 27: "IQ3_M", 28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16",
         36: "TQ1_0", 37: "TQ2_0", 38: "MXFP4"}


def root() -> Path:
    return models_dir()


def real_root() -> Path:
    r = root()
    try:
        return r.resolve()
    except OSError:
        return r


def inside(p: Path, base: Path | None = None) -> bool:
    base = base or real_root()
    try:
        rp = p.resolve()
    except OSError:
        return False
    return rp == base or str(rp).startswith(str(base) + os.sep)


def resolve_rel(rel: str, must_exist: bool = True) -> Path:
    """Map an operator-supplied relative path to a real file inside MODELS_DIR (boundary-checked)."""
    if not safe_relpath(rel or "") or not rel.lower().endswith(".gguf"):
        raise HubError("path must be a relative .gguf path inside the models directory")
    p = root() / rel
    if must_exist and not p.is_file():
        raise HubError(f"{rel}: not found in {root()}")
    if not inside(p):
        raise HubError(f"{rel}: resolves outside the models directory; move the file into {root()}")
    return p


def rel_of(p: Path) -> str:
    return p.resolve().relative_to(real_root()).as_posix()


# ── cache ──────────────────────────────────────────────────────────────────────

def _cache_file() -> Path:
    d = george_dir() / "models"
    d.mkdir(parents=True, exist_ok=True)
    return d / "library_cache.json"


def _load_cache() -> dict[str, Any]:
    try:
        c = json.loads(_cache_file().read_text())
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_cache(c: dict[str, Any]) -> None:
    f = _cache_file()
    tmp = f.with_suffix(".tmp")
    tmp.write_text(json.dumps(c, separators=(",", ":")))
    os.replace(tmp, f)


CACHE_VERSION = 2


def _stamp(st: os.stat_result) -> str:
    return f"v{CACHE_VERSION}:{st.st_size}:{st.st_mtime_ns}"


# ── metadata ───────────────────────────────────────────────────────────────────

def _repo_from_url(url: Any) -> str | None:
    if not isinstance(url, str):
        return None
    m = re.match(r"^https?://(?:www\.)?(?:huggingface\.co|hf\.co|modelscope\.cn/models)/([A-Za-z0-9][\w.-]*/[A-Za-z0-9][\w.-]*)/?$", url)
    return m.group(1) if m else None


def describe(meta: dict[str, Any], filename: str) -> dict[str, Any]:
    """Turn raw GGUF metadata into the fields the library and UI need."""
    arch = str(meta.get("general.architecture") or "unknown")
    gtype = str(meta.get("general.type") or "")
    low = filename.lower()
    adapter_type = None
    if gtype == "adapter" or arch == "controlvector":
        kind = "adapter"
        adapter_type = "control_vector" if arch == "controlvector" else str(meta.get("adapter.type") or "lora")
    elif gtype == "mmproj" or arch == "clip":
        kind = "mmproj"
    elif re.match(r"^(mtp|draft)[-_.]", low) or re.search(r"[-_.]draft[-_.]", low):
        kind = "draft"
    else:
        kind = "model"
    dims = gguf.model_dims(meta)
    base = None
    for k in ("general.base_model.0.repo_url", "general.source.repo_url", "general.source.huggingface.repository"):
        base = _repo_from_url(meta.get(k)) or (meta.get(k) if k.endswith("repository") and isinstance(meta.get(k), str) else None)
        if base:
            break
    if not base and meta.get("general.base_model.0.organization") and meta.get("general.base_model.0.name"):
        base = f"{meta['general.base_model.0.organization']}/{meta['general.base_model.0.name']}"
    sampling = {}
    for k, dst in (("general.sampling.temp", "temperature"), ("general.sampling.top_p", "top_p"),
                   ("general.sampling.top_k", "top_k"), ("general.sampling.min_p", "min_p")):
        v = meta.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            sampling[dst] = int(v) if dst == "top_k" else round(float(v), 4)
    ft = meta.get("general.file_type")
    return {
        "kind": kind, "adapter_type": adapter_type, "arch": arch, "title": meta.get("general.name"),
        "size_label": meta.get("general.size_label"), "finetune": meta.get("general.finetune"),
        "quant": quant_of(filename) or (FTYPE.get(ft) if isinstance(ft, int) else None),
        "ctx_train": dims.get("ctx_train"), "n_layer": dims.get("n_layer"), "n_embd": dims.get("n_embd"),
        "experts": dims.get("expert_count"), "experts_used": dims.get("expert_used_count"),
        "chat_template": bool(dims.get("has_chat_template")), "license": meta.get("general.license"),
        "base_model": base if isinstance(base, str) and len(base) <= 200 else None,
        "adapter_alpha": meta.get("adapter.lora.alpha"),
        "cv_model_hint": meta.get("controlvector.model_hint"),
        "sampling": sampling or None, "dims": dims,
    }


def read_meta(path: Path, cache: dict[str, Any] | None = None) -> dict[str, Any]:
    st = path.stat()
    key = str(path.resolve())
    c = cache if cache is not None else _load_cache()
    hit = c.get(key)
    if hit and hit.get("stamp") == _stamp(st) and "info" in hit:
        return hit["info"]
    try:
        info = describe(gguf.read_local(str(path)), path.name)
    except (HubError, OSError, ValueError, UnicodeDecodeError) as e:
        info = {"kind": "unknown", "error": str(e)[:200]}
    ent = c.get(key) if hit and hit.get("stamp") == _stamp(st) else {}
    ent = dict(ent or {})
    ent.update(stamp=_stamp(st), info=info)
    c[key] = ent
    if cache is None:
        _save_cache(c)
    return info


def sha256_cached(path: Path, on_bytes: Callable[[int], None] | None = None,
                  cancelled: Callable[[], bool] | None = None) -> str:
    """sha256 of a local file, cached by (realpath, size, mtime_ns)."""
    st = path.stat()
    key = str(path.resolve())
    c = _load_cache()
    hit = c.get(key) or {}
    if hit.get("stamp") == _stamp(st) and hit.get("sha256"):
        if on_bytes:
            on_bytes(st.st_size)
        return hit["sha256"]
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            if cancelled and cancelled():
                raise HubError("cancelled by operator")
            h.update(chunk)
            if on_bytes:
                on_bytes(len(chunk))
    if path.stat().st_mtime_ns != st.st_mtime_ns:
        raise HubError(f"{path.name} changed while hashing; try again")
    c = _load_cache()
    ent = c.get(key) if (c.get(key) or {}).get("stamp") == _stamp(st) else {}
    ent = dict(ent or {})
    ent.update(stamp=_stamp(st), sha256=h.hexdigest())
    c[key] = ent
    _save_cache(c)
    return h.hexdigest()


# ── scan ───────────────────────────────────────────────────────────────────────

def _walk(base: Path) -> tuple[list[tuple[Path, bool]], bool]:
    """Yield (path, is_symlink) for *.gguf under base. Never follows directory symlinks."""
    out: list[tuple[Path, bool]] = []
    truncated = False
    base_depth = len(base.parts)
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        d = Path(dirpath)
        if len(d.parts) - base_depth >= MAX_DEPTH:
            dirnames[:] = []
        dirnames[:] = sorted(n for n in dirnames if not n.startswith(".") and not n.endswith(".git")
                             and n not in SKIP_DIRS)
        for fn in sorted(filenames):
            if not fn.lower().endswith(".gguf") or fn.startswith("."):
                continue
            p = d / fn
            out.append((p, p.is_symlink()))
            if len(out) >= MAX_FILES:
                return out, True
    return out, truncated


def _profile_refs() -> dict[str, list[dict[str, str]]]:
    """realpath -> [{name, status, role}] for every profile that pins the file."""
    from . import profiles  # local import: profiles imports hw/common only
    refs: dict[str, list[dict[str, str]]] = {}
    for f in sorted(profiles.profiles_dir().glob("*.json")):
        try:
            p = json.loads(f.read_text())
            lr = profiles.local_root(p)
        except (ValueError, KeyError, TypeError, HubError, OSError):
            continue
        items = [(lr / x.get("path", ""), x.get("role", "")) for x in p.get("files", []) if isinstance(x, dict)]
        items += [(profiles.adapters_dir() / a.get("path", ""), a.get("role", ""))
                  for a in p.get("adapters") or [] if isinstance(a, dict)]
        for path, role in items:
            try:
                rp = str(path.resolve())
            except OSError:
                continue
            refs.setdefault(rp, []).append({"name": p.get("name", "?"), "status": p.get("status", "?"), "role": role})
    return refs


def _active_profile() -> str | None:
    try:
        return json.loads((george_dir() / "models" / "active_profile.json").read_text()).get("name")
    except (OSError, ValueError):
        return None


def scan(with_meta: bool = True) -> dict[str, Any]:
    t0 = time.time()
    base = root()
    res: dict[str, Any] = {"models_dir": str(base), "exists": base.is_dir(), "entries": [], "truncated": False,
                           "active_profile": _active_profile()}
    if not base.is_dir():
        res["totals"] = {"count": 0, "bytes": 0}
        return res
    rbase = real_root()
    paths, res["truncated"] = _walk(base)
    by_real: dict[str, dict[str, Any]] = {}
    aliases: dict[str, list[str]] = {}
    link_only: dict[str, tuple[str, Path, os.stat_result]] = {}
    for p, is_link in paths:
        try:
            rp = p.resolve(strict=True)
            st = rp.stat()
        except (OSError, RuntimeError):
            continue  # dangling symlink
        if not rp.is_file():
            continue
        rel_link = p.relative_to(base).as_posix()
        key = str(rp)
        if is_link:
            aliases.setdefault(key, []).append(rel_link)
            link_only.setdefault(key, (rel_link, rp, st))
            continue
        by_real[key] = {"rel": rel_link, "file": rp.name, "size": st.st_size, "mtime": int(st.st_mtime),
                        "inside": True, "_path": rp}
    for key, (rel_link, rp, st) in link_only.items():
        if key in by_real:
            continue
        # Symlink whose target was not walked (outside MODELS_DIR, hidden dir, or too deep).
        inside_root = str(rp).startswith(str(rbase) + os.sep)
        by_real[key] = {"rel": rp.relative_to(rbase).as_posix() if inside_root else rel_link, "file": rp.name,
                        "size": st.st_size, "mtime": int(st.st_mtime), "inside": inside_root, "_path": rp}
    for e in by_real.values():
        e["dir"] = e["rel"].rsplit("/", 1)[0] if "/" in e["rel"] else ""

    cache = _load_cache() if with_meta else {}
    refs = _profile_refs()
    groups: dict[str, dict[str, Any]] = {}
    entries: list[dict[str, Any]] = []
    for key, e in sorted(by_real.items(), key=lambda kv: kv[1]["rel"].lower()):
        si = shard_info(e["file"])
        e["aliases"] = sorted(aliases.get(key, []))
        e["profiles"] = refs.get(key, [])
        if si:
            stem = key.rsplit("-00", 1)[0]
            g = groups.get(stem)
            if g:
                g["size"] += e["size"]
                g["shards_present"] += 1
                g["profiles"] += [x for x in e["profiles"] if x not in g["profiles"]]
                if si[0] == 1:
                    g["rel"], g["file"], g["_path"] = e["rel"], e["file"], e["_path"]
                continue
            e["shards"], e["shards_present"] = si[1], 1
            groups[stem] = e
        entries.append(e)
    for e in entries:
        p = e.pop("_path")
        if with_meta:
            if e.get("shards") and not e["file"].endswith("-00001-of-%05d.gguf" % e["shards"]):
                e.update(kind="unknown", error="first shard missing")
            else:
                e.update(read_meta(p, cache))
        e["complete"] = not e.get("shards") or e["shards_present"] == e["shards"]
        e["installed_profile"] = next((r["name"] for r in e["profiles"] if r["status"] == "installed"), None)
        e.pop("dims", None)  # full dims are served by fit-local / find(); keep the listing small
    if with_meta:
        live = {k for k in by_real}
        for k in [k for k in cache if k not in live and not os.path.exists(k)]:
            cache.pop(k, None)
        _save_cache(cache)
    res["entries"] = entries
    kinds: dict[str, int] = {}
    for e in entries:
        kinds[e.get("kind", "file")] = kinds.get(e.get("kind", "file"), 0) + 1
    res["totals"] = {"count": len(entries), "bytes": sum(e["size"] for e in entries), "by_kind": kinds}
    res["scan_ms"] = int((time.time() - t0) * 1000)
    return res


def find(rel: str) -> dict[str, Any]:
    p = resolve_rel(rel)
    st = p.resolve().stat()
    e = {"rel": rel_of(p), "file": p.resolve().name, "size": st.st_size, "mtime": int(st.st_mtime)}
    si = shard_info(e["file"])
    if si:
        if si[0] != 1:
            raise HubError("select the first shard (-00001-of-N) of a split model")
        stem = str(p.resolve()).rsplit("-00", 1)[0]
        parts = [Path(f"{stem}-{i:05d}-of-{si[1]:05d}.gguf") for i in range(1, si[1] + 1)]
        missing = [x.name for x in parts if not x.is_file()]
        if missing:
            raise HubError(f"incomplete shard set: missing {', '.join(missing[:3])}")
        e["shard_paths"] = [rel_of(x) for x in parts]
        e["size"] = sum(x.stat().st_size for x in parts)
    e.update(read_meta(p))
    return e


def delete_file(rel: str, force: bool = False) -> dict[str, Any]:
    """Delete a GGUF (all shards of a split model) and its hub sidecars from MODELS_DIR."""
    p = resolve_rel(rel)
    if p.is_symlink():
        p.unlink()
        return {"deleted": [rel], "note": "removed symlink only; the target file was left in place"}
    targets = [p]
    si = shard_info(p.name)
    if si:
        stem = str(p).rsplit("-00", 1)[0]
        targets = [Path(f"{stem}-{i:05d}-of-{si[1]:05d}.gguf") for i in range(1, si[1] + 1)]
    refs = _profile_refs()
    users = sorted({r["name"] for t in targets for r in refs.get(str(t.resolve()), []) if t.exists()})
    if users and not force:
        raise HubError(f"in use by profile(s): {', '.join(users)}. Remove those profiles first, or force delete.")
    deleted = []
    for t in targets:
        for x in (t, t.with_name(t.name + ".sha256"), t.with_name(t.name + ".part")):
            if x.is_file() and inside(x):
                x.unlink()
                deleted.append(x.relative_to(root()).as_posix() if str(x).startswith(str(root())) else x.name)
    c = _load_cache()
    for t in targets:
        c.pop(str(t), None)
    _save_cache(c)
    return {"deleted": deleted, "profiles_affected": users}
