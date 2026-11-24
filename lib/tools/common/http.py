"""
Typed JSON HTTP helpers with bounded timeouts and optional retry/404 handling.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional

DEFAULT_USER_AGENT = "BlueLodge-Sovereign/2.0"


def http_get_json(
    url: str,
    headers: Optional[Dict[str, str]] = None,
    timeout: float = 15.0,
    allow_404: bool = False,
    retries: int = 0,
    retry_delay_s: float = 0.5,
) -> Any:
    """Perform an HTTP GET request and decode JSON response."""
    req_headers = {"User-Agent": DEFAULT_USER_AGENT, "Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    last_err: Optional[Exception] = None
    for attempt in range(max(1, retries + 1)):
        req = urllib.request.Request(url, headers=req_headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            if allow_404 and e.code == 404:
                return None
            last_err = e
            if e.code < 500 and e.code != 429:
                raise
        except Exception as e:
            last_err = e
        if attempt < retries:
            time.sleep(retry_delay_s * (attempt + 1))
    if last_err is not None:
        raise last_err
    return None


def http_post_json(
    url: str,
    payload: Any,
    headers: Optional[Dict[str, str]] = None,
    timeout: float = 20.0,
    retries: int = 0,
    retry_delay_s: float = 0.5,
) -> Any:
    """Perform an HTTP POST request with a JSON body and decode JSON response."""
    req_headers = {
        "User-Agent": DEFAULT_USER_AGENT,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if headers:
        req_headers.update(headers)
    body = json.dumps(payload).encode("utf-8") if not isinstance(payload, (bytes, bytearray)) else bytes(payload)
    last_err: Optional[Exception] = None
    for attempt in range(max(1, retries + 1)):
        req = urllib.request.Request(url, data=body, headers=req_headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            last_err = e
            if e.code < 500 and e.code != 429:
                raise
        except Exception as e:
            last_err = e
        if attempt < retries:
            time.sleep(retry_delay_s * (attempt + 1))
    if last_err is not None:
        raise last_err
    return None

