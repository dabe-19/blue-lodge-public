"""Shared stdlib HTTP retry wrapper for Blue Lodge Python tools.

Retries HTTP 429 (honoring Retry-After header or JSON `.retry_after`) and transient
HTTP 502/503/504/529 or network timeouts with bounded exponential backoff.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
from typing import Any


def _parse_retry_after(exc: urllib.error.HTTPError, attempt: int, base_delay: float) -> float:
    if exc.headers:
        hdr = exc.headers.get("Retry-After")
        if hdr:
            try:
                return min(15.0, max(0.3, float(hdr)))
            except ValueError:
                pass
    try:
        raw = exc.read()
        # Restore body buffer so callers catching HTTPError on final failure can still call exc.read()
        exc.fp = None  # type: ignore[assignment]
        exc._cached_body = raw  # type: ignore[attr-defined]
        exc.read = lambda: raw  # type: ignore[method-assign]
        data = json.loads(raw.decode("utf-8", errors="ignore"))
        if isinstance(data, dict) and data.get("retry_after") is not None:
            return min(15.0, max(0.3, float(data["retry_after"])))
    except Exception:
        pass
    return min(8.0, base_delay * (2 ** attempt))


def urlopen_retry(
    req: urllib.request.Request | str,
    timeout: float = 15.0,
    max_retries: int | None = None,
    base_delay: float = 0.8,
) -> Any:
    """Drop-in replacement for `urllib.request.urlopen(req, timeout=...)` with 429/5xx retry."""
    retries = int(os.environ.get("GEORGE_HTTP_MAX_RETRIES", max_retries if max_retries is not None else 2))
    for attempt in range(retries + 1):
        try:
            return urllib.request.urlopen(req, timeout=timeout)  # nosec B310
        except urllib.error.HTTPError as exc:
            if exc.code in (429, 502, 503, 504, 529) and attempt < retries:
                time.sleep(_parse_retry_after(exc, attempt, base_delay))
                continue
            raise
        except urllib.error.URLError as exc:
            # Do not retry local connection refused in offline tests
            reason_str = str(getattr(exc, "reason", exc)).lower()
            if "connection refused" in reason_str or attempt >= retries:
                raise
            time.sleep(min(4.0, base_delay * (2 ** attempt)))

