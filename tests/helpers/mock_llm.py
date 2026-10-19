#!/usr/bin/env python3
"""Scripted OpenAI-compatible mock LLM for hermetic React-loop tests.

Usage: mock_llm.py <port_file> <script.json> [log.jsonl]

script.json: {"turns": [{"content": "...", "tool_calls": [...]}, ...],
              "aux": "text returned for requests without a tools[] schema"}
Requests that carry a `tools` array consume the next scripted turn (the last
turn repeats once exhausted). Other requests (planners, classifiers,
summarisers) get `aux`. Binds 127.0.0.1 on an ephemeral port and writes it to
<port_file>.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT_FILE, SCRIPT = sys.argv[1], sys.argv[2]
LOG = sys.argv[3] if len(sys.argv) > 3 else None
with open(SCRIPT, encoding="utf-8") as fh:
    CFG = json.load(fh)
TURNS = CFG.get("turns") or [{"content": "done"}]
AUX = CFG.get("aux", "OK")
_lock = threading.Lock()
_idx = {"n": 0}


def _next_turn():
    with _lock:
        i = min(_idx["n"], len(TURNS) - 1)
        _idx["n"] += 1
        return TURNS[i]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):  # silence
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/health"):
            return self._json(200, {"status": "ok"})
        if self.path.startswith("/v1/models"):
            return self._json(200, {"data": [{"id": "mock"}]})
        if self.path.startswith("/props"):
            return self._json(200, {"default_generation_settings": {"n_ctx": 32768}})
        return self._json(404, {"error": "nf"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            req = {}
        if req.get("tools"):
            turn = _next_turn()
        elif req.get("grammar") and CFG.get("grammar"):
            # grammar-constrained calls (evaluator / advisor) consume CFG["grammar"] in order
            with _lock:
                g = CFG["grammar"]
                gi = min(_idx.setdefault("g", 0), len(g) - 1)
                _idx["g"] += 1
            turn = {"content": g[gi] if isinstance(g[gi], str) else json.dumps(g[gi])}
        else:
            turn = {"content": AUX}
        if LOG:
            with _lock, open(LOG, "a", encoding="utf-8") as fh:
                fh.write(json.dumps({"path": self.path, "has_tools": bool(req.get("tools")),
                                     "stream": bool(req.get("stream")), "grammar": req.get("grammar"),
                                     "temperature": req.get("temperature"), "turn": turn}) + "\n")
        msg = {"role": "assistant", "content": turn.get("content")}
        if turn.get("tool_calls"):
            msg["tool_calls"] = turn["tool_calls"]
        usage = {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}
        if not req.get("stream"):
            return self._json(200, {"id": "mock", "object": "chat.completion", "model": "mock",
                                    "choices": [{"index": 0, "message": msg,
                                                 "finish_reason": "tool_calls" if turn.get("tool_calls") else "stop"}],
                                    "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def chunk(delta, finish=None, extra=None):
            obj = {"id": "mock", "object": "chat.completion.chunk", "model": "mock",
                   "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            if extra:
                obj.update(extra)
            self.wfile.write(b"data: " + json.dumps(obj).encode() + b"\n\n")

        chunk({"role": "assistant"})
        if turn.get("content"):
            chunk({"content": turn["content"]})
        for i, tc in enumerate(turn.get("tool_calls") or []):
            chunk({"tool_calls": [dict(tc, index=i)]})
        chunk({}, "tool_calls" if turn.get("tool_calls") else "stop")
        self.wfile.write(b"data: " + json.dumps({"id": "mock", "choices": [], "usage": usage}).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE, "w", encoding="utf-8") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
