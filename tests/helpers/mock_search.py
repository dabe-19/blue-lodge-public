#!/usr/bin/env python3
"""Mock search backends for tests: SearXNG (/search), Brave (/brave/web|news/search),
Serper (/serper/search|news), DDG lite (/ddg/).

Usage: mock_search.py <port_file> <config.json> <requests.jsonl>
config.json (re-read on every request):
  {"searxng": {"status": 200, "body": {...}}, "brave": {...}, "serper": {...}, "ddg": {"status":200,"html":"..."}}
"""
import json
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT_FILE, CFG, LOG = sys.argv[1], sys.argv[2], sys.argv[3]


def _cfg():
    try:
        with open(CFG, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _route(self):
        p = urllib.parse.urlparse(self.path)
        if p.path.startswith("/search"):
            return "searxng"
        if p.path.startswith("/brave/"):
            return "brave"
        if p.path.startswith("/serper/"):
            return "serper"
        if p.path.startswith("/ddg"):
            return "ddg"
        return "unknown"

    def _handle(self, method):
        route = self._route()
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        p = urllib.parse.urlparse(self.path)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps({"route": route, "method": method, "path": p.path,
                                "query": dict(urllib.parse.parse_qsl(p.query)), "body": body,
                                "auth": self.headers.get("X-Subscription-Token") or self.headers.get("X-API-KEY") or ""}) + "\n")
        spec = _cfg().get(route, {"status": 503, "body": {}})
        self.send_response(int(spec.get("status", 200)))
        if route == "ddg":
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(spec.get("html", "").encode())
        else:
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(spec.get("body", {})).encode())

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE, "w", encoding="utf-8") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
