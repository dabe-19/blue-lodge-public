"""Shared plumbing for the George model hub (stdlib only).

Security invariants (tested in tests/test_model_hub.sh):
  * Only https to allow-listed hosts (MODEL_HUB_ALLOW_HTTP_HOSTS opens plain http for tests/local IPFS).
  * Redirects are followed manually; the Authorization header is dropped whenever the host changes,
    so a hub token is never sent to a CDN / third party.
  * Tokens are read from env or .george/keys.conf (0600) and never printed or returned by any CLI verb.
"""

from __future__ import annotations

import json
import os
import re
import stat
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

UA = "George-ModelHub/1.0 (+https://github.com/dabe-19/blue-lodge-public)"

# Exact hosts or suffixes (leading dot) allowed for any request, including redirect targets.
_ALLOWED = (
    "huggingface.co", ".huggingface.co", ".hf.co",                 # HF API + xet/CAS CDN
    "modelscope.cn", ".modelscope.cn", "modelscope.ai", ".modelscope.ai",
    ".aliyuncs.com",                                              # ModelScope OSS redirect targets
    "ipfs.io", "dweb.link", ".dweb.link", "cloudflare-ipfs.com", "w3s.link", ".w3s.link",
)

REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}/[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
CID_RE = re.compile(r"^(Qm[1-9A-HJ-NP-Za-km-z]{44}|b[a-z2-7]{58,})$")


class HubError(Exception):
    """User-facing error (message is safe to print)."""


def lodge_dir() -> Path:
    return Path(os.environ.get("LODGE_DIR") or Path(__file__).resolve().parents[3])


def george_dir() -> Path:
    return Path(os.environ.get("GEORGE_DIR") or lodge_dir() / ".george")


def _http_hosts() -> set[str]:
    return {h.strip().lower() for h in os.environ.get("MODEL_HUB_ALLOW_HTTP_HOSTS", "").split(",") if h.strip()}


def host_allowed(url: str) -> bool:
    p = urllib.parse.urlparse(url)
    host = (p.hostname or "").lower()
    if not host:
        return False
    if p.scheme == "http":
        port_host = f"{host}:{p.port}" if p.port else host
        return port_host in _http_hosts() or host in _http_hosts()
    if p.scheme != "https":
        return False
    extra = {h.strip().lower() for h in os.environ.get("MODEL_HUB_EXTRA_HOSTS", "").split(",") if h.strip()}
    if host in extra:
        return True
    return any(host == a or (a.startswith(".") and host.endswith(a)) for a in _ALLOWED)


# ── Tokens ─────────────────────────────────────────────────────────────────────

def keys_file() -> Path:
    return george_dir() / "keys.conf"


def get_token(name: str) -> str | None:
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
        return None
    v = os.environ.get(name)
    if v:
        return v.strip()
    try:
        for line in keys_file().read_text().splitlines():
            if line.startswith(name + "="):
                return line.split("=", 1)[1].strip() or None
    except OSError:
        pass
    return None


def set_token(name: str, value: str | None) -> None:
    """Persist (or remove when value is None) a token in keys.conf with 0600 perms."""
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
        raise HubError("invalid key name")
    if value is not None and (not value or any(ord(c) < 32 for c in value) or len(value) > 512):
        raise HubError("token rejected (empty, too long or contains control characters)")
    kf = keys_file()
    kf.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    if kf.exists():
        lines = [ln for ln in kf.read_text().splitlines() if not ln.startswith(name + "=")]
    if value is not None:
        lines.append(f"{name}={value}")
    tmp = kf.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, kf)
    os.chmod(kf, stat.S_IRUSR | stat.S_IWUSR)


def redact(text: str) -> str:
    """Strip anything token-shaped before it reaches logs/LLM context."""
    text = re.sub(r"\bhf_[A-Za-z0-9]{20,}\b", "hf_***", text)
    text = re.sub(r"(?i)(authorization:\s*bearer\s+)\S+", r"\1***", text)
    text = re.sub(r"(?i)(token[\"']?\s*[:=]\s*[\"']?)[A-Za-z0-9._-]{16,}", r"\1***", text)
    return text


# ── HTTP ──────────────────────────────────────────────────────────────────────

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a: Any, **k: Any) -> None:  # noqa: D401
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def open_url(url: str, *, token: str | None = None, method: str = "GET", data: bytes | None = None,
             headers: dict[str, str] | None = None, timeout: float = 30.0, max_redirects: int = 6):
    """Open a URL with manual redirect handling. Returns the final response object."""
    hdrs = {"User-Agent": UA, **(headers or {})}
    origin_host = urllib.parse.urlparse(url).hostname
    for _ in range(max_redirects + 1):
        if not host_allowed(url):
            raise HubError(f"blocked host: {urllib.parse.urlparse(url).hostname or url[:40]}")
        h = dict(hdrs)
        if token and urllib.parse.urlparse(url).hostname == origin_host:
            h["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            resp = _OPENER.open(req, timeout=timeout)
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308):
                loc = e.headers.get("Location")
                if not loc:
                    raise HubError(f"redirect without location ({e.code})") from None
                url = urllib.parse.urljoin(url, loc)
                if e.code == 303:
                    method, data = "GET", None
                continue
            if e.code in (401, 403):
                raise HubError(f"HTTP {e.code}: authentication required or access not granted (gated repo?)") from None
            if e.code == 404:
                raise HubError("HTTP 404: not found") from None
            if e.code == 429:
                raise HubError("HTTP 429: rate limited by hub; try later or log in") from None
            raise HubError(f"HTTP {e.code}") from None
        except urllib.error.URLError as e:
            raise HubError(f"network error: {e.reason}") from None
        return resp
    raise HubError("too many redirects")


def get_json(url: str, *, token: str | None = None, method: str = "GET", body: Any = None,
             timeout: float = 30.0) -> Any:
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Accept": "application/json"}
    if data is not None:
        hdrs["Content-Type"] = "application/json"
    with open_url(url, token=token, method=method, data=data, headers=hdrs, timeout=timeout) as r:
        raw = r.read(20 * 1024 * 1024)
    try:
        return json.loads(raw)
    except ValueError:
        raise HubError("hub returned non-JSON response") from None


def fetch_range(url: str, start: int, end: int, *, token: str | None = None, timeout: float = 30.0) -> bytes:
    """Fetch bytes [start, end] inclusive. Tolerates servers that ignore Range (reads/discards)."""
    with open_url(url, token=token, headers={"Range": f"bytes={start}-{end}"}, timeout=timeout) as r:
        want = end - start + 1
        if r.status == 206:
            return r.read(want)
        # 200: server ignored Range — skip to start (bounded) then read.
        if start > 64 * 1024 * 1024:
            raise HubError("server does not support range requests")
        skipped = 0
        while skipped < start:
            chunk = r.read(min(1 << 20, start - skipped))
            if not chunk:
                return b""
            skipped += len(chunk)
        return r.read(want)


def safe_relpath(p: str) -> bool:
    if not p or p.startswith(("/", "\\")) or "\x00" in p or len(p) > 300:
        return False
    parts = re.split(r"[\\/]", p)
    return all(x not in ("", ".", "..") for x in parts)


def quant_of(filename: str) -> str | None:
    m = re.search(r"(?i)(?:^|[-_.])((?:UD-)?(?:IQ[1-4]_[A-Z0-9_]+|Q[2-8]_[A-Z0-9_]+|Q[2-8]_0|Q8_0|BF16|F16|F32|MXFP4|TQ[12]_0|PTQ1_0))(?=[-_.]|\.gguf$)", filename)
    return m.group(1).upper() if m else None


def shard_info(filename: str) -> tuple[int, int] | None:
    m = re.search(r"-(\d{5})-of-(\d{5})\.gguf$", filename)
    return (int(m.group(1)), int(m.group(2))) if m else None
