"""Minimal GGUF metadata reader over local files or HTTP Range (no full download).

Reads only the KV metadata section (tensor infos are skipped), which carries everything the
fit calculator needs: architecture, block_count, embedding/head dims, context length, file type.
"""

from __future__ import annotations

import struct
from typing import Any, Callable

from .common import HubError, fetch_range

_FIXED = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}
_FMT = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}
MAX_META_BYTES = 64 * 1024 * 1024
MAX_KV = 4096


class _Reader:
    def __init__(self, fetch: Callable[[int, int], bytes], chunk: int = 1 << 20):
        self.fetch, self.chunk = fetch, chunk
        self.buf, self.base, self.pos = b"", 0, 0

    def _ensure(self, n: int) -> None:
        while self.pos + n > self.base + len(self.buf):
            if self.base + len(self.buf) >= MAX_META_BYTES:
                raise HubError("GGUF metadata exceeds 64 MiB; refusing")
            start = self.base + len(self.buf)
            more = self.fetch(start, start + max(self.chunk, n) - 1)
            if not more:
                raise HubError("unexpected end of GGUF data")
            # drop consumed prefix to keep memory bounded
            drop = self.pos - self.base
            self.buf = self.buf[drop:] + more
            self.base += drop

    def read(self, n: int) -> bytes:
        self._ensure(n)
        off = self.pos - self.base
        self.pos += n
        return self.buf[off:off + n]

    def skip(self, n: int) -> None:
        # Large skips (fixed-size arrays) may jump past the buffer without fetching.
        end = self.base + len(self.buf)
        if self.pos + n <= end:
            self.pos += n
        else:
            self.pos += n
            self.base, self.buf = self.pos, b""

    def u32(self) -> int:
        return struct.unpack("<I", self.read(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.read(8))[0]

    def string(self, limit: int = 1 << 20) -> str:
        n = self.u64()
        if n > limit:
            raise HubError("GGUF string too long")
        return self.read(n).decode("utf-8", "replace")


def _value(r: _Reader, t: int, keep_arrays: bool) -> Any:
    if t in _FMT:
        return struct.unpack(_FMT[t], r.read(_FIXED[t]))[0]
    if t == 8:
        return r.string()
    if t == 9:
        et, n = r.u32(), r.u64()
        if n > 50_000_000:
            raise HubError("GGUF array too large")
        if et in _FIXED:
            if keep_arrays and n <= 4096:
                return [struct.unpack(_FMT[et], r.read(_FIXED[et]))[0] for _ in range(n)]
            r.skip(_FIXED[et] * n)
            return {"array_len": n}
        if et == 8:
            for _ in range(n):
                r.skip(r.u64())
            return {"array_len": n}
        raise HubError(f"unsupported nested GGUF array type {et}")
    raise HubError(f"unknown GGUF value type {t}")


def read_metadata(fetch: Callable[[int, int], bytes]) -> dict[str, Any]:
    r = _Reader(fetch)
    if r.read(4) != b"GGUF":
        raise HubError("not a GGUF file")
    version = r.u32()
    if version not in (2, 3):
        raise HubError(f"unsupported GGUF version {version}")
    n_tensors, n_kv = r.u64(), r.u64()
    if n_kv > MAX_KV:
        raise HubError("too many GGUF metadata keys")
    meta: dict[str, Any] = {"gguf.version": version, "gguf.tensor_count": n_tensors}
    for _ in range(n_kv):
        key = r.string(limit=1024)
        t = r.u32()
        keep = key.endswith((".head_count_kv", ".head_count", "sliding_window_pattern", ".swa_layers"))
        meta[key] = _value(r, t, keep)
    return meta


def read_local(path: str) -> dict[str, Any]:
    with open(path, "rb") as f:
        def fetch(a: int, b: int) -> bytes:
            f.seek(a)
            return f.read(b - a + 1)
        return read_metadata(fetch)


def read_remote(url: str, token: str | None = None) -> dict[str, Any]:
    return read_metadata(lambda a, b: fetch_range(url, a, b, token=token))


def _scalar(v: Any) -> int | None:
    if isinstance(v, list):
        return max(v) if v else None
    return int(v) if isinstance(v, (int, float)) else None


def model_dims(meta: dict[str, Any]) -> dict[str, Any]:
    """Extract the architecture numbers the fit calculator needs."""
    arch = meta.get("general.architecture") or "unknown"
    g = lambda k: meta.get(f"{arch}.{k}")  # noqa: E731
    n_embd = _scalar(g("embedding_length"))
    n_head = _scalar(g("attention.head_count"))
    n_head_kv = _scalar(g("attention.head_count_kv")) or n_head
    key_len = _scalar(g("attention.key_length"))
    val_len = _scalar(g("attention.value_length"))
    head_dim = key_len or (n_embd // n_head if n_embd and n_head else None)
    swa = _scalar(g("attention.sliding_window"))
    full_attn_interval = _scalar(g("full_attention_interval"))
    ssm = any(k.startswith(f"{arch}.ssm.") for k in meta)
    return {
        "arch": arch,
        "name": meta.get("general.name"),
        "size_label": meta.get("general.size_label"),
        "file_type": meta.get("general.file_type"),
        "n_layer": _scalar(g("block_count")),
        "n_embd": n_embd,
        "n_head": n_head,
        "n_head_kv": n_head_kv,
        "head_dim_k": head_dim,
        "head_dim_v": val_len or head_dim,
        "ctx_train": _scalar(g("context_length")),
        "n_vocab": (meta.get("tokenizer.ggml.tokens") or {}).get("array_len") if isinstance(
            meta.get("tokenizer.ggml.tokens"), dict) else None,
        "sliding_window": swa,
        "full_attention_interval": full_attn_interval,
        "hybrid_ssm": ssm,
        "expert_count": _scalar(g("expert_count")),
        "expert_used_count": _scalar(g("expert_used_count")),
        "split_count": meta.get("split.count"),
        "has_chat_template": "tokenizer.chat_template" in meta,
    }
