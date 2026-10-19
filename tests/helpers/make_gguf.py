#!/usr/bin/env python3
"""Write a tiny, valid GGUF header for tests: make_gguf.py OUT [--arch A] [--type T] [--layers N] [--ctx N]
[--pad BYTES] [--base-repo-url URL] [--no-template] [--temp F]"""
import argparse
import struct


def _s(x: str) -> bytes:
    b = x.encode()
    return struct.pack("<Q", len(b)) + b


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--arch", default="llama")
    ap.add_argument("--type", default="")
    ap.add_argument("--layers", type=int, default=4)
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--pad", type=int, default=200_000)
    ap.add_argument("--base-repo-url", default="")
    ap.add_argument("--no-template", action="store_true")
    ap.add_argument("--temp", type=float)
    a = ap.parse_args()
    kv = []

    def add(key: str, t: int, payload: bytes) -> None:
        kv.append(_s(key) + struct.pack("<I", t) + payload)

    add("general.architecture", 8, _s(a.arch))
    add("general.name", 8, _s("Fixture " + a.arch))
    if a.type:
        add("general.type", 8, _s(a.type))
    if a.type == "adapter":
        add("adapter.type", 8, _s("lora"))
        add("adapter.lora.alpha", 6, struct.pack("<f", 16.0))
    if a.base_repo_url:
        add("general.base_model.count", 4, struct.pack("<I", 1))
        add("general.base_model.0.repo_url", 8, _s(a.base_repo_url))
    if a.temp is not None:
        add("general.sampling.temp", 6, struct.pack("<f", a.temp))
    add(f"{a.arch}.block_count", 4, struct.pack("<I", a.layers))
    add(f"{a.arch}.embedding_length", 4, struct.pack("<I", 256))
    add(f"{a.arch}.attention.head_count", 4, struct.pack("<I", 4))
    add(f"{a.arch}.attention.head_count_kv", 4, struct.pack("<I", 2))
    add(f"{a.arch}.context_length", 4, struct.pack("<I", a.ctx))
    if not a.no_template:
        add("tokenizer.chat_template", 8, _s("{{ messages }}"))
    head = b"GGUF" + struct.pack("<IQQ", 3, 0, len(kv))
    with open(a.out, "wb") as f:
        f.write(head + b"".join(kv) + b"\x00" * a.pad)


if __name__ == "__main__":
    main()
