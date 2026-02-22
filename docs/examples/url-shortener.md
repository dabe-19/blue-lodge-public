# Example: Building a URL Shortener API (Python)

This walkthrough shows Blue Lodge building a complete Python project — a URL shortener with a JSON file backend. Everything runs locally on your phone.

---

## 1. Scaffold the project

```
$ lodge /init shortener python
 ▸ Creating Python project with uv...
 ✓ Python sandbox ready
 ✓ CLAUDE.md initialized in .
 ✓ Project 'shortener' (Data Project) created at /home/user/shortener
```

## 2. Describe the task

```
$ cd shortener
$ lodge "Build a URL shortener HTTP API using only the stdlib. 
  POST /shorten with JSON body {url: string} returns {short: string, id: string}.
  GET /<id> redirects to the original URL.
  Store mappings in a urls.json file. Add a GET /stats endpoint."
```

## 3. Lodge plans the task

```
 ── Plan ────────────────────────────────────
   1. Create the HTTP server with routing
   2. Implement POST /shorten endpoint
   3. Implement GET /<id> redirect
   4. Add JSON file persistence
   5. Add GET /stats endpoint
   6. Create a test script
   7. Test the full flow
```

## 4. Lodge executes step by step

It generates and writes each file, runs commands, and verifies. Here's what the project looks like after:

```
shortener/
├── CLAUDE.md        # Lodge's memory of the project
├── main.py          # HTTP server (stdlib only)
├── urls.json        # URL mappings (auto-created)
├── test_api.sh      # Shell-based API tests
└── pyproject.toml   # Project config
```

### Generated `main.py` (excerpt):

```python
"""Minimal URL shortener — stdlib only, no dependencies."""
import json
import hashlib
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from typing import Any

DB_PATH = Path("urls.json")

def load_db() -> dict[str, Any]:
    if DB_PATH.exists():
        return json.loads(DB_PATH.read_text())
    return {"urls": {}, "stats": {"total_shortened": 0, "total_redirects": 0}}

def save_db(db: dict[str, Any]) -> None:
    DB_PATH.write_text(json.dumps(db, indent=2))

def make_short_id(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()[:8]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path == "/shorten":
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            url = body["url"]
            short_id = make_short_id(url)
            db = load_db()
            db["urls"][short_id] = url
            db["stats"]["total_shortened"] += 1
            save_db(db)
            self.send_json(201, {"short": f"/{short_id}", "id": short_id})
        else:
            self.send_json(404, {"error": "not found"})

    def do_GET(self) -> None:
        if self.path == "/stats":
            db = load_db()
            self.send_json(200, db["stats"])
        else:
            short_id = self.path.lstrip("/")
            db = load_db()
            if short_id in db["urls"]:
                db["stats"]["total_redirects"] += 1
                save_db(db)
                self.send_response(302)
                self.send_header("Location", db["urls"][short_id])
                self.end_headers()
            else:
                self.send_json(404, {"error": "not found"})
    # ...

if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), Handler)
    print("Serving on http://127.0.0.1:8080")
    server.serve_forever()
```

## 5. Testing

Lodge generates and runs tests:

```
$ lodge /test
 ▸ Running: bash test_api.sh
 POST /shorten → 201 ✓
 GET /abc123de → 302 ✓
 GET /stats → 200 ✓
 ✓ Tests passed
```

## 6. Iterate

```
$ lodge "add rate limiting — max 10 requests per minute per IP"
```

Lodge reads CLAUDE.md (knows the project structure), plans a 3-step change, and applies it.

## 7. Commit and push

```
$ lodge /commit
 ── Changes ─────────────────────────────────
  main.py | 45 ++++++++
  test_api.sh | 12 +++++
  2 files changed

 ◆ Generating commit message...
 ● Suggested: feat: add URL shortener API with JSON persistence and stats
 Use this message? [Y/n] y
 ✓ Committed!

$ lodge /push
 ▸ Pushing to origin/main...
 ✓ Pushed to origin/main
```

---

## Key Observations

- **No dependencies installed** — the URL shortener uses only Python stdlib
- **Lodge remembered context** — when adding rate limiting, it already knew the project structure from CLAUDE.md
- **7 steps completed** — each step was one LLM call, keeping token usage low
- **Total time** — ~5 minutes on Snapdragon 8 Elite with Qwen3-4B
