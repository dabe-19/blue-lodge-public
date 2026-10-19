"""Hub providers: Hugging Face, ModelScope (independent hub), IPFS (decentralized transport).

Every provider returns the same normalized shapes:
  search  -> [{provider, repo, downloads, likes, updated, tags, gated}]
  inspect -> {provider, repo, revision, gated, license, arch, params, ctx_max, base_model,
              files:[{path, size, sha256, quant, shard, kind}], quants:{QUANT:[paths]}}
  file_url(repo, revision, path) -> download URL (pinned revision)
"""

from __future__ import annotations

import os
import re
import urllib.parse
from typing import Any

from .common import (CID_RE, REPO_RE, SHA256_RE, HubError, get_json, get_token, quant_of, safe_relpath,
                     shard_info)


def _kind(path: str) -> str:
    low = path.lower()
    if not low.endswith(".gguf"):
        return "other"
    if "mmproj" in low:
        return "mmproj"
    if re.search(r"(^|[-_/])(mtp|draft)([-_.]|$)", low):
        return "draft"
    if "lora" in low or "adapter" in low:
        return "lora"
    if "imatrix" in low:
        return "other"
    return "model"


def _summarize_files(files: list[dict[str, Any]]) -> dict[str, list[str]]:
    quants: dict[str, list[str]] = {}
    for f in files:
        if f["kind"] == "model" and f.get("quant"):
            quants.setdefault(f["quant"], []).append(f["path"])
    return quants


def _norm_file(path: str, size: Any, sha: Any) -> dict[str, Any] | None:
    if not safe_relpath(path):
        return None
    sha = (sha or "").lower() or None
    if sha and not SHA256_RE.match(sha):
        sha = None
    return {"path": path, "size": int(size or 0), "sha256": sha, "quant": quant_of(path.rsplit("/", 1)[-1]),
            "shard": shard_info(path), "kind": _kind(path)}


class HuggingFace:
    name = "huggingface"
    token_key = "HF_TOKEN"

    def __init__(self) -> None:
        self.base = os.environ.get("HF_ENDPOINT", "https://huggingface.co").rstrip("/")

    def token(self) -> str | None:
        return get_token(self.token_key) or get_token("HUGGING_FACE_HUB_TOKEN")

    def whoami(self, token: str | None = None) -> dict[str, Any]:
        tok = token or self.token()
        if not tok:
            raise HubError("not logged in to Hugging Face")
        d = get_json(f"{self.base}/api/whoami-v2", token=tok)
        auth = (d.get("auth") or {}).get("accessToken") or {}
        return {"provider": self.name, "user": d.get("name"), "type": d.get("type"),
                "orgs": [o.get("name") for o in d.get("orgs", [])][:20], "token_role": auth.get("role"),
                "token_name": auth.get("displayName")}

    def search(self, query: str, limit: int = 20, gguf_only: bool = True, sort: str = "downloads") -> list[dict]:
        q = {"search": query[:120], "limit": str(max(1, min(limit, 100))), "sort": sort, "direction": "-1",
             "full": "false"}
        if gguf_only:
            q["filter"] = "gguf"
        rows = get_json(f"{self.base}/api/models?{urllib.parse.urlencode(q)}", token=self.token())
        out = []
        for r in rows if isinstance(rows, list) else []:
            rid = r.get("id") or r.get("modelId") or ""
            if not REPO_RE.match(rid):
                continue
            out.append({"provider": self.name, "repo": rid, "downloads": r.get("downloads", 0),
                        "likes": r.get("likes", 0), "updated": r.get("lastModified"),
                        "tags": [t for t in r.get("tags", []) if isinstance(t, str)][:12],
                        "gated": bool(r.get("gated"))})
        return out

    def inspect(self, repo: str, revision: str = "main") -> dict[str, Any]:
        if not REPO_RE.match(repo):
            raise HubError("invalid repo id")
        rev_q = urllib.parse.quote(revision, safe="")
        info = get_json(f"{self.base}/api/models/{repo}/revision/{rev_q}", token=self.token())
        sha = info.get("sha") or revision
        tree = get_json(f"{self.base}/api/models/{repo}/tree/{sha}?recursive=1", token=self.token())
        files = []
        for t in tree if isinstance(tree, list) else []:
            if t.get("type") == "directory":
                continue
            lfs = t.get("lfs") or {}
            nf = _norm_file(t.get("path", ""), t.get("size"), lfs.get("oid") or lfs.get("sha256"))
            if nf:
                files.append(nf)
        card = info.get("cardData") or {}
        gg = info.get("gguf") or {}
        base_model = card.get("base_model")
        if isinstance(base_model, list):
            base_model = base_model[0] if base_model else None
        return {"provider": self.name, "repo": repo, "revision": sha, "gated": bool(info.get("gated")),
                "license": card.get("license"), "arch": gg.get("architecture"), "params": gg.get("total"),
                "ctx_max": gg.get("context_length"), "base_model": base_model,
                "pipeline": info.get("pipeline_tag"), "downloads": info.get("downloads"),
                "files": files, "quants": _summarize_files(files)}

    def file_url(self, repo: str, revision: str, path: str) -> str:
        return f"{self.base}/{repo}/resolve/{urllib.parse.quote(revision, safe='')}/{urllib.parse.quote(path)}"


class ModelScope:
    name = "modelscope"
    token_key = "MODELSCOPE_API_TOKEN"

    def __init__(self) -> None:
        self.base = os.environ.get("MODELSCOPE_ENDPOINT", "https://modelscope.cn").rstrip("/")

    def token(self) -> str | None:
        return get_token(self.token_key)

    def whoami(self, token: str | None = None) -> dict[str, Any]:
        tok = token or self.token()
        if not tok:
            raise HubError("not logged in to ModelScope")
        d = get_json(f"{self.base}/api/v1/login", method="POST", body={"AccessToken": tok})
        data = (d or {}).get("Data") or {}
        if not d.get("Success") and d.get("Code") != 200:
            raise HubError("ModelScope rejected the access token")
        return {"provider": self.name, "user": data.get("Username") or data.get("Name") or data.get("NickName"),
                "type": "user"}

    def search(self, query: str, limit: int = 20, gguf_only: bool = True, sort: str = "downloads") -> list[dict]:
        name = f"{query} GGUF" if gguf_only and "gguf" not in query.lower() else query
        body = {"PageSize": max(1, min(limit, 50)), "PageNumber": 1, "SortBy": "Default", "Target": "",
                "SingleCriterion": [], "Name": name[:120]}
        d = get_json(f"{self.base}/api/v1/dolphin/models", method="PUT", body=body, token=self.token())
        models = (((d or {}).get("Data") or {}).get("Model") or {}).get("Models") or []
        out = []
        for m in models:
            rid = f"{m.get('Path', '')}/{m.get('Name', '')}"
            if not REPO_RE.match(rid):
                continue
            if gguf_only and "gguf" not in rid.lower():
                continue
            out.append({"provider": self.name, "repo": rid, "downloads": m.get("Downloads", 0),
                        "likes": m.get("Stars", 0), "updated": m.get("LastUpdatedTime"),
                        "tags": [t for t in (m.get("Tags") or []) if isinstance(t, str)][:12], "gated": False})
        if sort == "downloads":
            out.sort(key=lambda r: -(r["downloads"] or 0))
        return out

    def inspect(self, repo: str, revision: str = "master") -> dict[str, Any]:
        if not REPO_RE.match(repo):
            raise HubError("invalid repo id")
        rev_q = urllib.parse.quote(revision, safe="")
        info = get_json(f"{self.base}/api/v1/models/{repo}", token=self.token())
        d = get_json(f"{self.base}/api/v1/models/{repo}/repo/files?Revision={rev_q}&Recursive=true",
                     token=self.token())
        files = []
        for f in ((d or {}).get("Data") or {}).get("Files") or []:
            if f.get("Type") == "tree":
                continue
            nf = _norm_file(f.get("Path", ""), f.get("Size"), f.get("Sha256"))
            if nf:
                files.append(nf)
        data = (info or {}).get("Data") or {}
        return {"provider": self.name, "repo": repo, "revision": revision, "gated": False,
                "license": data.get("License"), "arch": None, "params": None, "ctx_max": None,
                "base_model": None, "pipeline": None, "downloads": data.get("Downloads"),
                "files": files, "quants": _summarize_files(files)}

    def file_url(self, repo: str, revision: str, path: str) -> str:
        return f"{self.base}/models/{repo}/resolve/{urllib.parse.quote(revision, safe='')}/{urllib.parse.quote(path)}"


class IPFS:
    """Content-addressed transport. No search/accounts: catalog entries carry {cid, sha256}.

    Gateways are tried in order (local kubo first if configured). Integrity comes from the
    sha256 recorded in the profile — the gateway is untrusted.
    """
    name = "ipfs"
    token_key = ""

    def __init__(self) -> None:
        gw = os.environ.get("IPFS_GATEWAYS", "https://ipfs.io,https://dweb.link,https://w3s.link")
        self.gateways = [g.strip().rstrip("/") for g in gw.split(",") if g.strip()]

    def token(self) -> None:
        return None

    def whoami(self, token: str | None = None) -> dict[str, Any]:
        return {"provider": self.name, "user": None, "type": "anonymous"}

    def search(self, *a: Any, **k: Any) -> list[dict]:
        raise HubError("IPFS has no search; use catalog entries with a CID")

    def inspect(self, repo: str, revision: str = "") -> dict[str, Any]:
        raise HubError("IPFS entries are described by catalog/profile records (cid + sha256)")

    def file_url(self, cid: str, _revision: str = "", path: str = "") -> str:
        if not CID_RE.match(cid):
            raise HubError("invalid CID")
        return f"{self.gateways[0]}/ipfs/{cid}" + (f"?filename={urllib.parse.quote(path)}" if path else "")

    def file_urls(self, cid: str, path: str = "") -> list[str]:
        if not CID_RE.match(cid):
            raise HubError("invalid CID")
        return [f"{g}/ipfs/{cid}" for g in self.gateways]


PROVIDERS = {"huggingface": HuggingFace, "hf": HuggingFace, "modelscope": ModelScope, "ms": ModelScope,
             "ipfs": IPFS}


def get_provider(name: str):
    cls = PROVIDERS.get((name or "").lower())
    if not cls:
        raise HubError(f"unknown provider '{name}' (huggingface|modelscope|ipfs)")
    return cls()
