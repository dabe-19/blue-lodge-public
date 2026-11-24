#!/usr/bin/env python3
"""Hermetic Hugging Face-compatible mock hub for tests/test_model_hub.sh.

usage: mock_hub.py <portfile> <logfile>
Repos:
  test/tiny-GGUF     two quants (Q4_K_M, Q8_0) + mmproj; real GGUF headers; Range support
  test/gated-GGUF    401 unless Authorization: Bearer hf_goodtoken
  test/badsha-GGUF   tree advertises a wrong sha256 (installer must reject)
  test/redirect-GGUF resolve 302 -> http://localhost:<port>/cdn/... (auth must be stripped)
Every request is logged as JSON {path, auth, range} (auth recorded as present/absent only).
"""

import hashlib
import json
import struct
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REV = "0123456789abcdef0123456789abcdef01234567"
GOOD_TOKEN = "hf_goodtoken0123456789abcdef"


def _s(x: str) -> bytes:
    b = x.encode()
    return struct.pack("<Q", len(b)) + b


def make_gguf(n_layer: int, pad: int) -> bytes:
    kv = []

    def add(key, t, payload):
        kv.append(_s(key) + struct.pack("<I", t) + payload)

    add("general.architecture", 8, _s("llama"))
    add("general.name", 8, _s("Tiny Test"))
    add("llama.block_count", 4, struct.pack("<I", n_layer))
    add("llama.embedding_length", 4, struct.pack("<I", 256))
    add("llama.attention.head_count", 4, struct.pack("<I", 4))
    add("llama.attention.head_count_kv", 4, struct.pack("<I", 2))
    add("llama.context_length", 4, struct.pack("<I", 8192))
    toks = b"".join(_s(f"tok{i}") for i in range(1000))
    add("tokenizer.ggml.tokens", 9, struct.pack("<IQ", 8, 1000) + toks)
    add("tokenizer.ggml.scores", 9, struct.pack("<IQ", 6, 1000) + b"\0" * 4000)
    add("tokenizer.chat_template", 8, _s("{{ messages }}"))
    head = b"GGUF" + struct.pack("<IQQ", 3, 0, len(kv))
    return head + b"".join(kv) + b"\x00" * pad


FILES = {
    "tiny-Q4_K_M.gguf": make_gguf(4, 300_000),
    "tiny-Q8_0.gguf": make_gguf(4, 600_000),
    "mmproj-tiny-F16.gguf": make_gguf(2, 50_000),
}
GEN_CFG = json.dumps({"temperature": 0.7, "top_p": 0.8, "top_k": 20, "repetition_penalty": 1.05}).encode()
DS_FILE = b"".join(json.dumps({"messages": [{"role": "user", "content": f"q{i}"},
                                            {"role": "assistant", "content": f"a{i}"}]}).encode() + b"\n"
                   for i in range(3))


def tree(repo: str):
    out = [{"type": "file", "path": "README.md", "size": 10, "lfs": None}]
    for name, data in FILES.items():
        sha = hashlib.sha256(data).hexdigest()
        if repo == "test/badsha-GGUF":
            sha = "f" * 64
        out.append({"type": "file", "path": name, "size": len(data), "lfs": {"oid": sha, "size": len(data)}})
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _log(self):
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "host": self.headers.get("Host"),
                                "auth": bool(self.headers.get("Authorization")),
                                "range": self.headers.get("Range")}) + "\n")

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        return self.headers.get("Authorization") == f"Bearer {GOOD_TOKEN}"

    def _bytes(self, data: bytes):
        rng = self.headers.get("Range")
        if rng and rng.startswith("bytes="):
            a, _, b = rng[6:].partition("-")
            a = int(a)
            b = int(b) if b else len(data) - 1
            b = min(b, len(data) - 1)
            if a >= len(data):
                self.send_response(416)
                self.end_headers()
                return
            chunk = data[a:b + 1]
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {a}-{b}/{len(data)}")
        else:
            chunk = data
            self.send_response(200)
        self.send_header("Content-Length", str(len(chunk)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        self.wfile.write(chunk)

    def do_GET(self):
        self._log()
        p = self.path.split("?")[0]
        if p == "/api/whoami-v2":
            if not self._authed():
                return self._json({"error": "Invalid credentials"}, 401)
            return self._json({"name": "tester", "type": "user", "orgs": [],
                               "auth": {"accessToken": {"role": "read", "displayName": "test"}}})
        if p == "/api/models":
            return self._json([{"id": "test/tiny-GGUF", "downloads": 10, "likes": 1, "tags": ["gguf"]},
                               {"id": "../evil", "downloads": 99}])
        # llama-server surface (for /models status)
        if p == "/health":
            return self._json({"status": "ok"})
        if p == "/props":
            return self._json({"model_path": "/models/active/current.gguf", "total_slots": 2,
                               "default_generation_settings": {"n_ctx": 4096},
                               "modalities": {"vision": True, "audio": False}, "build_info": "mock"})
        if p == "/v1/models":
            return self._json({"data": [{"id": "/models/active/current.gguf",
                                         "meta": {"n_ctx_train": 8192, "n_params": 1000, "size": 123}}]})
        # HF dataset repo
        if p == "/api/datasets/test/ds/tree/main":
            return self._json([{"type": "file", "path": "README.md", "size": 5},
                               {"type": "file", "path": "data/train.jsonl", "size": len(DS_FILE),
                                "lfs": {"oid": hashlib.sha256(DS_FILE).hexdigest(), "size": len(DS_FILE)}},
                               {"type": "file", "path": "small.jsonl", "size": len(DS_FILE)}])
        if p in ("/datasets/test/ds/resolve/main/data/train.jsonl", "/datasets/test/ds/resolve/main/small.jsonl"):
            return self._bytes(DS_FILE)
        parts = p.strip("/").split("/")
        if len(parts) >= 3 and parts[0] == "api" and parts[1] == "models":
            repo = "/".join(parts[2:4])
            if repo == "test/gated-GGUF" and not self._authed():
                return self._json({"error": "gated"}, 401)
            if len(parts) >= 6 and parts[4] == "revision":
                return self._json({"id": repo, "sha": REV, "gated": repo == "test/gated-GGUF",
                                   "cardData": {"license": "apache-2.0", "base_model": "test/tiny"},
                                   "gguf": {"architecture": "llama", "total": 1000000, "context_length": 8192}})
            if len(parts) >= 6 and parts[4] == "tree":
                return self._json(tree(repo))
        if len(parts) >= 5 and parts[2] == "resolve":
            repo = "/".join(parts[0:2])
            name = "/".join(parts[4:])
            if repo == "test/gated-GGUF" and not self._authed():
                return self._json({"error": "gated"}, 401)
            if name == "generation_config.json":
                return self._bytes(GEN_CFG)
            if repo == "test/redirect-GGUF":
                port = self.server.server_address[1]
                self.send_response(302)
                self.send_header("Location", f"http://localhost:{port}/cdn/{name}")
                self.end_headers()
                return
            if name in FILES:
                return self._bytes(FILES[name])
        if len(parts) == 2 and parts[0] == "cdn" and parts[1] in FILES:
            return self._bytes(FILES[parts[1]])
        self._json({"error": "not found"}, 404)


if __name__ == "__main__":
    portfile, LOG = sys.argv[1], sys.argv[2]
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    with open(portfile, "w") as f:
        f.write(str(srv.server_address[1]))
    srv.serve_forever()
