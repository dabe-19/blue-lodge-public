"""Challenge handling for George's fetch path (ported from PoshTracker's scraper.py).

Only *legitimate, non-interactive* challenges are solved:
  * Reddit's JS proof-of-work interstitial (`(async e=>e+e)("seed")` + jsc_token form):
    solution = seed + seed, submitted back with an Android Chrome fingerprint; the
    resulting session cookie is kept in a per-user cookie jar and reused.
Real CAPTCHAs / Cloudflare Turnstile are NOT solved — they are detected and reported so
callers can fall back to the search snippet (PoshTracker's "snippet rescue").

Feature flag: the PoW solve step is DISABLED by default. Enable it on an operator box with
GEORGE_REDDIT_CHALLENGE_SOLVER=1 (env or .george/features.conf — see feature_flags.py).
When disabled, reddit-json still performs a plain fetch and simply gives up on an interstitial.

CLI:
  challenge_solver.py reddit-json <url>     → JSON body on stdout (rc 0) or rc 1
  challenge_solver.py detect <status> < html → reason on stdout, rc 0 if blocked
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from pathlib import Path

ANDROID_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/133.0.0.0 Mobile Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
    "Sec-Ch-Ua": '"Not(A:Brand";v="99", "Google Chrome";v="133", "Chromium";v="133"',
    "Sec-Ch-Ua-Mobile": "?1",
    "Sec-Ch-Ua-Platform": '"Android"',
    "Sec-Fetch-Dest": "document",
    "Sec-Fetch-Mode": "navigate",
    "Sec-Fetch-Site": "none",
    "Sec-Fetch-User": "?1",
    "Upgrade-Insecure-Requests": "1",
}

_BLOCK_STATUS = {401, 403, 407, 429, 451, 503, 520, 521, 522, 523, 525, 530, 999}
_TIER1 = ("cf-chl-bypass", "cf-chl-widget", "challenge-platform", "_cf_chl_opt", "verify you are human",
          "just a moment...", "enable javascript and cookies", "please wait for verification",
          "checking your browser", "security verification", "human verification", "robot check",
          "vercel security checkpoint", "datadome", "perimeterx")
_TIER2 = ("captcha", "request blocked", "bot detection", "incapsula")
_REDDIT_RX = re.compile(r"^https://(www\.|old\.|new\.)?reddit\.com/", re.I)


def detect_challenge(status: int, body: str) -> str:
    """Return a block reason ('' when the page looks like real content)."""
    if status in _BLOCK_STATUS:
        return f"HTTP_{status}_BLOCK"
    low = body.lower()
    if any(m in low for m in _TIER1):
        return "HTML_CHALLENGE_OR_CAPTCHA"
    if len(body) < 25000 and any(m in low for m in _TIER2):
        return "HTML_CHALLENGE_OR_CAPTCHA"
    return ""


def _jar() -> Path:
    base = Path(os.environ.get("GEORGE_DIR") or Path(__file__).resolve().parents[2] / ".george")
    p = base / "state" / "reddit_cookies.jar"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def _curl(url: str, headers: dict[str, str], jar: Path, timeout: float = 10.0) -> tuple[int, str]:
    if not shutil.which("curl"):
        return 0, ""
    cmd = ["curl", "-sL", "--compressed", "--max-time", str(int(timeout)), "--proto", "=https",
           "-b", str(jar), "-c", str(jar), "-w", "\nHTTP_STATUS:%{http_code}\n"]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 3).stdout
    except (OSError, subprocess.SubprocessError):
        return 0, ""
    if "HTTP_STATUS:" not in out:
        return 0, out
    body, code = out.rsplit("HTTP_STATUS:", 1)
    try:
        return int(code.strip()), body
    except ValueError:
        return 0, body


def solver_enabled() -> bool:
    try:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from feature_flags import flag
    except ImportError:
        return os.environ.get("GEORGE_REDDIT_CHALLENGE_SOLVER", "0") == "1"
    return flag("GEORGE_REDDIT_CHALLENGE_SOLVER", False)


def solve_reddit_js_challenge(html_body: str, original_url: str, jar: Path) -> bool:
    if not solver_enabled():
        return False
    token = re.search(r'name="jsc_token"\s+value="([^"]+)"', html_body)
    seed = re.search(r'\(async\s*e=>e\+e\)\("([^"]+)"\)', html_body)
    if not (token and seed) or not _REDDIT_RX.match(original_url):
        return False
    parsed = urllib.parse.urlparse(original_url)
    params = {"solution": seed.group(1) * 2, "js_challenge": "1", "jsc_token": token.group(1),
              "jsc_orig_r": parsed.path or "/"}
    url = f"https://{parsed.netloc}{parsed.path}?{urllib.parse.urlencode(params)}"
    status, _ = _curl(url, {**ANDROID_HEADERS, "Referer": original_url}, jar)
    return status in (200, 302)


def fetch_reddit_json(url: str) -> str | None:
    """Fetch a reddit .json URL; on a JS PoW interstitial, solve it once and retry."""
    if not _REDDIT_RX.match(url):
        return None
    jar = _jar()
    hdrs = {**ANDROID_HEADERS, "Accept": "application/json"}
    for attempt in range(2):
        status, body = _curl(url, hdrs, jar)
        try:
            json.loads(body)
            return body
        except ValueError:
            pass
        if attempt == 0 and "js_challenge" in body and "jsc_token" in body:
            html_url = re.sub(r"\.json$", "", url.split("?")[0]) or url
            if not solve_reddit_js_challenge(body, html_url, jar):
                return None
            continue
        if attempt == 0 and not body:
            # warm a session on the HTML page (may itself carry the challenge)
            st, page = _curl(re.sub(r"\.json$", "", url), ANDROID_HEADERS, jar)
            if "js_challenge" in page and "jsc_token" in page:
                solve_reddit_js_challenge(page, re.sub(r"\.json$", "", url), jar)
            continue
        return None
    return None


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == "reddit-json":
        body = fetch_reddit_json(argv[1])
        if body is None:
            return 1
        sys.stdout.write(body)
        return 0
    if len(argv) >= 2 and argv[0] == "detect":
        try:
            status = int(argv[1])
        except ValueError:
            status = 0
        reason = detect_challenge(status, sys.stdin.read())
        print(reason)
        return 0 if reason else 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
