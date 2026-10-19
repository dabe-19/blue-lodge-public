"""Model profiles: George drafts, the operator approves, the installer executes.

A profile pins every file by (provider, repo, revision, path, size, sha256) and describes the
llama-server settings. Only allow-listed server/sampling keys with typed ranges are accepted, so a
profile can never smuggle arbitrary CLI flags or paths into the inference container.

Approval binds to the canonical content hash: editing an approved profile invalidates it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import time
from pathlib import Path
from typing import Any

from .common import CID_RE, REPO_RE, SHA256_RE, HubError, george_dir, safe_relpath, shard_info
from .hw import models_dir

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,63}$")
REV_RE = {"huggingface": re.compile(r"^[0-9a-f]{40}$"), "modelscope": re.compile(r"^[A-Za-z0-9._-]{1,64}$"),
          "ipfs": re.compile(r"^$|^[A-Za-z0-9._-]{0,64}$"),
          # "local": a GGUF the operator already has in MODELS_DIR (paths are relative to MODELS_DIR).
          "local": re.compile(r"^$")}
ROLES = {"model", "mmproj", "draft", "lora"}
ADAPTER_ROLES = {"lora", "control_vector"}
ADAPTER_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.gguf$")  # no ':' or ',' (llama.cpp FNAME:SCALE lists)
MAX_ADAPTERS = 8
MAX_FILE = 400 * (1 << 30)

# key: (type, min, max) or (enum set)
SERVER_KEYS: dict[str, Any] = {
    "ctx": (int, 512, 1_048_576), "n_gpu_layers": (int, 0, 999), "ubatch": (int, 16, 8192),
    "batch": (int, 16, 16384), "parallel": (int, 1, 16), "threads": (int, 1, 256),
    "tensor_split": ("split",), "main_gpu": (int, 0, 15), "flash_attn": (bool,), "jinja": (bool,),
    "split_mode": ({"none", "layer", "row"},),
    "cache_type_k": ({"f16", "bf16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"},),
    "cache_type_v": ({"f16", "bf16", "q8_0", "q5_1", "q5_0", "q4_1", "q4_0", "iq4_nl"},),
    "draft_max": (int, 1, 64), "draft_min": (int, 0, 64), "lora_scale": (float, 0.0, 4.0),
    "mlock": (bool,), "no_mmap": (bool,), "reasoning_budget": (int, -1, 1_000_000),
}
SAMPLING_KEYS: dict[str, Any] = {
    "temperature": (float, 0.0, 2.0), "top_p": (float, 0.0, 1.0), "top_k": (int, 0, 1000),
    "min_p": (float, 0.0, 1.0), "repeat_penalty": (float, 0.5, 2.0), "presence_penalty": (float, -2.0, 2.0),
}


def profiles_dir() -> Path:
    d = george_dir() / "models" / "profiles"
    d.mkdir(parents=True, exist_ok=True)
    return d


def profile_path(name: str) -> Path:
    if not NAME_RE.match(name or ""):
        raise HubError("invalid profile name (lowercase a-z0-9._-, 2-64 chars)")
    return profiles_dir() / f"{name}.json"


def canonical_hash(p: dict[str, Any]) -> str:
    body = {k: v for k, v in p.items() if k not in ("status", "approved_sha", "approved_at", "approved_by",
                                                    "installed_at", "local_files", "fit", "notes", "updated_at")}
    return hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def local_root(p: dict[str, Any]) -> Path:
    src = p["source"]
    if src["provider"] == "local":
        return models_dir()
    sub = src["repo"] if src["provider"] != "ipfs" else (src.get("repo") or p["name"])
    return models_dir() / "hub" / src["provider"] / sub


def _rel_root(p: dict[str, Any]) -> str:
    """local_root relative to MODELS_DIR as a posix prefix ('' for local profiles)."""
    rel = local_root(p).relative_to(models_dir()).as_posix()
    return "" if rel in ("", ".") else rel + "/"


def adapters_dir() -> Path:
    """Operator-supplied adapters (e.g. LoRA GGUFs exported from Colab training) live here."""
    return models_dir() / "adapters"


def _validate_adapters(p: dict[str, Any], errs: list[str]) -> None:
    ads = p.get("adapters")
    if ads is None:
        return
    if not isinstance(ads, list) or len(ads) > MAX_ADAPTERS:
        errs.append(f"adapters: must be a list of at most {MAX_ADAPTERS}")
        return
    seen: set[str] = set()
    for i, a in enumerate(ads):
        tag = f"adapters[{i}]"
        if not isinstance(a, dict):
            errs.append(f"{tag}: must be an object")
            continue
        if a.get("role") not in ADAPTER_ROLES:
            errs.append(f"{tag}.role: must be one of {sorted(ADAPTER_ROLES)}")
        path = str(a.get("path", ""))
        if not ADAPTER_NAME_RE.match(path):
            errs.append(f"{tag}.path: must be a plain .gguf file name in the adapters dir (no '/', ':' or ',')")
        elif path in seen:
            errs.append(f"{tag}.path: duplicate")
        seen.add(path)
        if not isinstance(a.get("size"), int) or not 0 < a["size"] <= MAX_FILE:
            errs.append(f"{tag}.size: must be a positive integer")
        if not SHA256_RE.match(str(a.get("sha256", ""))):
            errs.append(f"{tag}.sha256: required (64 lowercase hex)")
        sc = a.get("scale", 1.0)
        if not isinstance(sc, (int, float)) or isinstance(sc, bool) or not -4.0 <= sc <= 4.0:
            errs.append(f"{tag}.scale: must be a number in [-4, 4]")


def _check_typed(section: str, d: dict[str, Any], spec: dict[str, Any], errs: list[str]) -> None:
    for k, v in d.items():
        if k not in spec:
            errs.append(f"{section}.{k}: not an allowed key")
            continue
        s = spec[k]
        if s[0] == "split":
            if not (isinstance(v, list) and 1 <= len(v) <= 16 and all(isinstance(x, (int, float)) and 0 <= x <= 100 for x in v)):
                errs.append(f"{section}.{k}: must be a list of 1-16 numbers 0..100")
        elif isinstance(s[0], set):
            if v not in s[0]:
                errs.append(f"{section}.{k}: must be one of {sorted(s[0])}")
        elif s[0] is bool:
            if not isinstance(v, bool):
                errs.append(f"{section}.{k}: must be true/false")
        else:
            typ, lo, hi = s
            ok = isinstance(v, (int, float)) and not isinstance(v, bool) and (typ is float or float(v).is_integer())
            if not ok or not (lo <= v <= hi):
                errs.append(f"{section}.{k}: must be {typ.__name__} in [{lo}, {hi}]")


def validate(p: dict[str, Any], hw: dict[str, Any] | None = None) -> list[str]:
    errs: list[str] = []
    if not isinstance(p, dict):
        return ["profile must be a JSON object"]
    if p.get("schema") != 1:
        errs.append("schema must be 1")
    if not NAME_RE.match(str(p.get("name", ""))):
        errs.append("name: invalid")
    src = p.get("source") or {}
    prov = src.get("provider")
    if prov not in REV_RE:
        errs.append("source.provider: must be huggingface|modelscope|ipfs|local")
    else:
        if prov not in ("ipfs", "local") and not REPO_RE.match(str(src.get("repo", ""))):
            errs.append("source.repo: invalid repo id")
        if prov == "local" and src.get("repo") not in (None, "") and not REPO_RE.match(str(src.get("repo"))):
            errs.append("source.repo: optional base-model repo id must look like org/name")
        if not REV_RE[prov].match(str(src.get("revision", ""))):
            errs.append("source.revision: must be a pinned commit sha (huggingface) / revision ('' for local)")
    files = p.get("files")
    if not isinstance(files, list) or not 1 <= len(files) <= 32:
        errs.append("files: need 1-32 entries")
        files = []
    roles: dict[str, int] = {}
    shards: set[int] = set()
    total = 0
    for i, f in enumerate(files):
        tag = f"files[{i}]"
        if not isinstance(f, dict):
            errs.append(f"{tag}: must be an object")
            continue
        if f.get("role") not in ROLES:
            errs.append(f"{tag}.role: must be one of {sorted(ROLES)}")
        if not safe_relpath(str(f.get("path", ""))) or not str(f.get("path", "")).endswith(".gguf"):
            errs.append(f"{tag}.path: must be a safe relative .gguf path")
        if not isinstance(f.get("size"), int) or not 0 < f["size"] <= MAX_FILE:
            errs.append(f"{tag}.size: must be a positive integer")
        else:
            total += f["size"]
        if not SHA256_RE.match(str(f.get("sha256", ""))):
            errs.append(f"{tag}.sha256: required (64 lowercase hex) — unverified downloads are not allowed")
        if prov == "ipfs" and not CID_RE.match(str(f.get("cid", ""))):
            errs.append(f"{tag}.cid: required for ipfs")
        if prov == "local" and safe_relpath(str(f.get("path", ""))):
            base = models_dir().resolve()
            fp = (models_dir() / str(f["path"])).resolve()
            if not str(fp).startswith(str(base) + os.sep):
                errs.append(f"{tag}.path: resolves outside the models directory")
        roles[f.get("role")] = roles.get(f.get("role"), 0) + 1
        si = shard_info(str(f.get("path", "")))
        if f.get("role") == "model" and si:
            shards.add(si[1])
    if roles.get("model", 0) == 0:
        errs.append("files: exactly one model (or one complete shard set) is required")
    elif roles["model"] > 1:
        if len(shards) != 1 or roles["model"] != next(iter(shards)):
            errs.append("files: multiple model files must form one complete -0000N-of-0000M shard set")
    for r in ("mmproj", "draft", "lora"):
        if roles.get(r, 0) > 1:
            errs.append(f"files: at most one {r}")
    for f in files:
        if isinstance(f, dict) and f.get("role") == "lora" and re.search(r"[:,]", str(f.get("path", ""))):
            errs.append("files: lora path may not contain ':' or ','")
    _validate_adapters(p, errs)
    _check_typed("server", p.get("server") or {}, SERVER_KEYS, errs)
    _check_typed("sampling", p.get("sampling") or {}, SAMPLING_KEYS, errs)
    if hw and total and (hw.get("disk") or {}).get("free_mb") is not None:
        present = sum(f["size"] for f in files if isinstance(f, dict) and isinstance(f.get("size"), int)
                      and (local_root(p) / f.get("path", "_")).exists()) if not errs else 0
        if (total - present) / (1 << 20) * 1.02 > hw["disk"]["free_mb"]:
            errs.append(f"disk: need {round((total - present) / (1 << 30), 1)} GiB, "
                        f"{round(hw['disk']['free_mb'] / 1024, 1)} GiB free at {hw['disk']['path']}")
    return errs


def load(name: str) -> dict[str, Any]:
    pp = profile_path(name)
    if not pp.exists():
        raise HubError(f"profile '{name}' not found")
    return json.loads(pp.read_text())


def save(p: dict[str, Any]) -> Path:
    pp = profile_path(p["name"])
    p["updated_at"] = int(time.time())
    tmp = pp.with_suffix(".tmp")
    tmp.write_text(json.dumps(p, indent=2, sort_keys=True))
    os.replace(tmp, pp)
    return pp


def save_draft(p: dict[str, Any], hw: dict[str, Any] | None = None, created_by: str = "george") -> dict[str, Any]:
    """Store a draft. Drafts can be overwritten; approval is always reset."""
    p = dict(p)
    p.setdefault("schema", 1)
    p["status"] = "draft"
    p["created_by"] = created_by if created_by in ("george", "operator") else "george"
    for k in ("approved_sha", "approved_at", "approved_by", "installed_at", "local_files"):
        p.pop(k, None)
    errs = validate(p, hw)
    if errs:
        raise HubError("profile invalid:\n  - " + "\n  - ".join(errs[:20]))
    if profile_path(p["name"]).exists():
        old = load(p["name"])
        if old.get("status") == "installed" and canonical_hash(old) == canonical_hash(p):
            return old
    save(p)
    return p


def approve(name: str, approver: str = "operator") -> dict[str, Any]:
    p = load(name)
    errs = validate(p)
    if errs:
        raise HubError("cannot approve invalid profile:\n  - " + "\n  - ".join(errs[:20]))
    p["status"] = "approved"
    p["approved_sha"] = canonical_hash(p)
    p["approved_at"] = int(time.time())
    p["approved_by"] = approver[:40]
    save(p)
    return p


def is_approved(p: dict[str, Any]) -> bool:
    return p.get("status") in ("approved", "installed") and p.get("approved_sha") == canonical_hash(p)


def list_profiles() -> list[dict[str, Any]]:
    out = []
    for f in sorted(profiles_dir().glob("*.json")):
        try:
            p = json.loads(f.read_text())
        except ValueError:
            continue
        model = next((x for x in p.get("files", []) if x.get("role") == "model"), {})
        srv = p.get("server") or {}
        out.append({"name": p.get("name"), "status": p.get("status"), "approved": is_approved(p),
                    "provider": (p.get("source") or {}).get("provider"), "repo": (p.get("source") or {}).get("repo"),
                    "model_file": model.get("path"), "size": sum(x.get("size", 0) for x in p.get("files", [])),
                    "ctx": srv.get("ctx"), "kv": srv.get("cache_type_k"), "created_by": p.get("created_by"),
                    "verdict": (p.get("fit") or {}).get("verdict"),
                    "roles": sorted({x.get("role") for x in p.get("files", []) if x.get("role") != "model"}),
                    "adapters": [{"role": a.get("role"), "path": a.get("path"), "scale": a.get("scale", 1.0)}
                                 for a in p.get("adapters") or []],
                    "updated_at": p.get("updated_at")})
    return out


def render_env(p: dict[str, Any], container_models_root: str = "/models") -> dict[str, str]:
    """llama-server LLAMA_ARG_* env for docker compose (paths are container paths)."""
    if not is_approved(p) or p.get("status") != "installed":
        raise HubError("profile must be approved and installed before activation")
    prefix = _rel_root(p)
    cpath = lambda path: f"{container_models_root}/{prefix}{path}"  # noqa: E731
    files = {f["role"]: f for f in p["files"] if f["role"] != "model"}
    model_files = sorted(f["path"] for f in p["files"] if f["role"] == "model")
    s = p.get("server") or {}
    env = {"LLAMA_ARG_MODEL": cpath(model_files[0])}
    mapping = {"ctx": "LLAMA_ARG_CTX_SIZE", "n_gpu_layers": "LLAMA_ARG_N_GPU_LAYERS", "ubatch": "LLAMA_ARG_UBATCH",
               "batch": "LLAMA_ARG_BATCH", "parallel": "LLAMA_ARG_N_PARALLEL", "threads": "LLAMA_ARG_THREADS",
               "main_gpu": "LLAMA_ARG_MAIN_GPU", "cache_type_k": "LLAMA_ARG_CACHE_TYPE_K",
               "cache_type_v": "LLAMA_ARG_CACHE_TYPE_V", "draft_max": "LLAMA_ARG_DRAFT_MAX",
               "draft_min": "LLAMA_ARG_DRAFT_MIN", "split_mode": "LLAMA_ARG_SPLIT_MODE"}
    for k, e in mapping.items():
        if k in s:
            env[e] = str(s[k])
    if "tensor_split" in s and s["tensor_split"]:
        env["LLAMA_ARG_TENSOR_SPLIT"] = ",".join(str(int(x)) if float(x).is_integer() else str(x) for x in s["tensor_split"])
    if "flash_attn" in s:
        env["LLAMA_ARG_FLASH_ATTN"] = "on" if s["flash_attn"] else "off"
    if s.get("jinja"):
        env["LLAMA_ARG_JINJA"] = "1"
    if "mmproj" in files:
        env["LLAMA_ARG_MMPROJ"] = cpath(files["mmproj"]["path"])
    if "draft" in files:
        env["LLAMA_ARG_MODEL_DRAFT"] = cpath(files["draft"]["path"])
    # LoRA / control vectors have no LLAMA_ARG_* env in llama.cpp: see render_args().
    return env


def _fmt_scale(x: float) -> str:
    return str(int(x)) if float(x).is_integer() else repr(float(x))


def verify_adapters(p: dict[str, Any]) -> None:
    """Re-hash every attached adapter; a changed file means the operator's approval no longer covers it."""
    import hashlib as _h
    for a in p.get("adapters") or []:
        f = adapters_dir() / a["path"]
        if not f.is_file():
            raise HubError(f"adapter {a['path']}: missing from {adapters_dir()}")
        if f.stat().st_size != a["size"]:
            raise HubError(f"adapter {a['path']}: sha256 mismatch (size changed since attach; re-attach and re-approve)")
        h = _h.sha256()
        with open(f, "rb") as fh:
            for chunk in iter(lambda: fh.read(8 << 20), b""):
                h.update(chunk)
        if h.hexdigest() != a["sha256"]:
            raise HubError(f"adapter {a['path']}: sha256 mismatch (file changed since attach; re-attach and re-approve)")


def render_args(p: dict[str, Any], container_models_root: str = "/models") -> list[str]:
    """Extra llama-server CLI args (LoRA + control vectors). Every value is from the validated profile."""
    if not is_approved(p) or p.get("status") != "installed":
        raise HubError("profile must be approved and installed before activation")
    verify_adapters(p)
    prefix = _rel_root(p)
    s = p.get("server") or {}
    loras: list[str] = []
    cvs: list[str] = []
    for f in p["files"]:
        if f["role"] == "lora":
            loras.append(f"{container_models_root}/{prefix}{f['path']}:{_fmt_scale(s.get('lora_scale', 1.0))}")
    for a in p.get("adapters") or []:
        item = f"{container_models_root}/adapters/{a['path']}:{_fmt_scale(a.get('scale', 1.0))}"
        (loras if a["role"] == "lora" else cvs).append(item)
    args: list[str] = []
    if loras:
        args += ["--lora-scaled", ",".join(loras)]
    if cvs:
        args += ["--control-vector-scaled", ",".join(cvs)]
    return args


def attach(name: str, role: str, src: str, scale: float = 1.0) -> dict[str, Any]:
    """Attach an operator-supplied adapter. The file is copied into the adapters dir and sha-pinned;
    the profile drops back to draft so the operator must re-approve what will be loaded."""
    import hashlib as _h
    import shutil
    if role not in ADAPTER_ROLES:
        raise HubError(f"role must be one of {sorted(ADAPTER_ROLES)}")
    if not -4.0 <= float(scale) <= 4.0:
        raise HubError("scale must be in [-4, 4]")
    sp = Path(src).expanduser()
    if not sp.is_file():
        raise HubError(f"{src}: not a file")
    with open(sp, "rb") as fh:
        if fh.read(4) != b"GGUF":
            raise HubError(f"{sp.name}: not a GGUF file (convert the adapter with llama.cpp convert_lora_to_gguf.py)")
    if not ADAPTER_NAME_RE.match(sp.name):
        raise HubError(f"{sp.name}: rename to a plain name (letters, digits, . _ -) ending in .gguf")
    if sp.stat().st_size > MAX_FILE:
        raise HubError(f"{sp.name}: too large")
    h = _h.sha256()
    with open(sp, "rb") as fh:
        for chunk in iter(lambda: fh.read(8 << 20), b""):
            h.update(chunk)
    sha = h.hexdigest()
    dest_dir = adapters_dir()
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / sp.name
    if sp.resolve() != dest.resolve():
        if dest.exists():
            dh = _h.sha256()
            with open(dest, "rb") as fh:
                for chunk in iter(lambda: fh.read(8 << 20), b""):
                    dh.update(chunk)
            if dh.hexdigest() != sha:
                raise HubError(f"{dest} already exists with different content; rename the new adapter")
        else:
            tmp = dest.with_name(dest.name + ".tmp")
            tmp.unlink(missing_ok=True)
            try:
                os.link(sp.resolve(), tmp)  # same filesystem: no extra disk space
            except OSError:
                shutil.copyfile(sp, tmp)
            os.replace(tmp, dest)
    p = load(name)
    ads = [a for a in (p.get("adapters") or []) if a.get("path") != sp.name]
    ads.append({"role": role, "path": sp.name, "size": sp.stat().st_size, "sha256": sha, "scale": float(scale)})
    p["adapters"] = ads
    return _redraft(p)


def detach(name: str, path: str) -> dict[str, Any]:
    p = load(name)
    ads = p.get("adapters") or []
    keep = [a for a in ads if a.get("path") != path]
    if len(keep) == len(ads):
        raise HubError(f"profile '{name}' has no adapter '{path}'")
    p["adapters"] = keep
    if not keep:
        p.pop("adapters")
    return _redraft(p)


def tune(name: str, patch: dict[str, Any]) -> dict[str, Any]:
    """Merge operator edits into a profile's server/sampling settings (null removes a key).

    Only allow-listed keys with typed ranges survive validation; the profile drops back to draft so
    the operator re-approves exactly what will be served."""
    if not isinstance(patch, dict) or not set(patch) <= {"server", "sampling"}:
        raise HubError("tune expects {\"server\": {...}, \"sampling\": {...}}")
    p = load(name)
    for sec in ("server", "sampling"):
        edits = patch.get(sec)
        if edits is None:
            continue
        if not isinstance(edits, dict) or len(edits) > 40:
            raise HubError(f"{sec}: must be an object")
        cur = dict(p.get(sec) or {})
        for k, v in edits.items():
            if v is None:
                cur.pop(k, None)
            else:
                cur[k] = v
        p[sec] = cur
    before = load(name)
    if canonical_hash(before) == canonical_hash(p):
        return before
    return _redraft(p)


def _redraft(p: dict[str, Any]) -> dict[str, Any]:
    p["status"] = "draft"
    for k in ("approved_sha", "approved_at", "approved_by", "installed_at", "local_files"):
        p.pop(k, None)
    errs = validate(p)
    if errs:
        raise HubError("profile invalid:\n  - " + "\n  - ".join(errs[:20]))
    save(p)
    return p
