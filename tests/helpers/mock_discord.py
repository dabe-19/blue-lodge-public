#!/usr/bin/env python3
"""Minimal Discord REST mock for bridge tests (no network).

Usage: mock_discord.py <port_file> <config.json> <log.jsonl>

config.json:
  {"reactions": {"<message_id>": {"<emoji>": ["<user_id>", ...]}}}

Every request is appended to log.jsonl as {method, path, body}.
POST /channels/<c>/messages     -> {"id": "<incrementing snowflake>"}
PATCH /channels/<c>/messages/<m> -> {"id": "<m>"}
GET  .../reactions/<emoji>       -> [{"id": user}, ...] from config
"""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, CFG_FILE, LOG_FILE = sys.argv[1], sys.argv[2], sys.argv[3]
with open(CFG_FILE) as fh:
    CFG = json.load(fh)
NEXT_ID = [900000000000000001]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            return json.loads(raw or b"null")
        except ValueError:
            return raw.decode("utf-8", "replace")

    def _log(self, body):
        with open(LOG_FILE, "a") as fh:
            fh.write(json.dumps({"method": self.command, "path": self.path, "body": body,
                                 "auth": self.headers.get("Authorization", "")}) + "\n")

    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        self._log(self._body())
        mid = str(NEXT_ID[0])
        NEXT_ID[0] += 1
        self._send(200, {"id": mid})

    def do_PATCH(self):
        self._log(self._body())
        self._send(200, {"id": self.path.rstrip("/").split("/")[-1]})

    def do_GET(self):
        self._log(None)
        path = urllib.parse.urlparse(self.path).path
        parts = path.split("/")
        if "reactions" in parts:
            i = parts.index("reactions")
            mid = parts[i - 1]
            emoji = urllib.parse.unquote(parts[i + 1])
            users = CFG.get("reactions", {}).get(mid, {}).get(emoji, [])
            self._send(200, [{"id": u} for u in users])
            return
        self._send(404, {"message": "not found"})


srv = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as fh:
    fh.write(str(srv.server_address[1]))
srv.serve_forever()
