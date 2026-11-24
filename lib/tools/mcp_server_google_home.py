#!/usr/bin/env python3
"""
George: Sovereign Google Home CastV2 & Multi-Voice Neural TTS MCP Server
Speaks JSON-RPC 2.0 over stdio to provide George with local Google Home
discovery, multi-voice neural speech synthesis (alan, ryan, amy, alba),
volume control, and quiet-hours aware home broadcasting.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if _VENV_PY.exists() and Path(sys.executable).resolve() != _VENV_PY.resolve():
    os.execv(str(_VENV_PY), [str(_VENV_PY), *sys.argv])
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.tools import google_home_cast as ghc

TOOLS_SCHEMA = [
    {
        "name": "google_home_discover",
        "description": "Discover all online Google Home, Nest Mini, Nest Hub, and Cast speakers/displays on the local LAN, along with available neural TTS voices and quiet-hours status.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "google_home_speak",
        "description": "Broadcast a spoken message over the local Google Home / Nest speaker network using local neural Text-to-Speech (Kokoro-82M StyleTTS2 24kHz on CPU with automatic fallback to Piper VITS ONNX). Defaults to broadcasting on Kitchen Display 1 and Bedroom speaker while respecting Discord/Escalation quiet hours unless force=true.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {
                    "type": "string",
                    "description": "The exact message to speak out loud over the Google Home speaker(s).",
                },
                "target": {
                    "type": "string",
                    "description": "Target speaker(s): 'default' (Kitchen Display 1 + Bedroom speaker), 'all' (whole house), or comma-separated room names/IPs ('kitchen', 'bedroom', 'den', 'basement_tv').",
                },
                "voice": {
                    "type": "string",
                    "description": "Selectable voice ID: 'washington' (18th-Century Statesman Baritone, George default), 'bm_george' (Classic British Statesman Baritone), 'bryce' (Deep American Baritone), 'am_fenrir' (Commanding American Orator), 'alan' (British Gentleman Narrator), 'ryan' (Modern American Male), 'amy' (American Female), 'af_bella' (Warm American Female), or 'alba' (British Female).",
                },
                "engine": {
                    "type": "string",
                    "description": "Optional TTS engine override: 'kokoro' (Kokoro-82M FP32 24kHz, default), 'kokoro_int8' (89MB INT8 CPU mode), or 'piper' (lightweight VITS fallback).",
                },
                "volume": {
                    "type": "number",
                    "description": "Optional speaker volume from 0.0 to 1.0 before speaking.",
                },
                "force": {
                    "type": "boolean",
                    "description": "Set true only for urgent alerts or explicit operator-requested broadcasts during quiet hours.",
                },
            },
            "required": ["text"],
        },
    },
    {
        "name": "google_home_volume",
        "description": "Set the volume (0.0 to 1.0) on one or more Google Home / Nest speakers.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "target": {
                    "type": "string",
                    "description": "Speaker name ('kitchen', 'bedroom', 'den', 'default', or 'all').",
                },
                "level": {
                    "type": "number",
                    "description": "Volume level between 0.0 and 1.0.",
                },
            },
            "required": ["target", "level"],
        },
    },
]


def handle_tool(name: str, args: dict) -> str:
    if name == "google_home_discover":
        return json.dumps(ghc.get_cast_status(), indent=2)
    elif name == "google_home_speak":
        res = ghc.broadcast_speech(
            text=str(args.get("text", "")),
            target=args.get("target", "default"),
            voice=args.get("voice"),
            engine=args.get("engine"),
            volume=args.get("volume"),
            force=bool(args.get("force", False)),
        )
        return json.dumps(res, indent=2)
    elif name == "google_home_volume":
        res = ghc.set_speaker_volume(
            target=str(args.get("target", "default")),
            volume=float(args.get("level", 0.5)),
        )
        return json.dumps(res, indent=2)
    else:
        raise ValueError(f"Unknown tool: {name}")


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue

        req_id = req.get("id")
        method = req.get("method")

        if method == "initialize":
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "george-cast", "version": "1.0"},
                },
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        elif method == "tools/list":
            resp = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": TOOLS_SCHEMA},
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()
        elif method == "tools/call":
            params = req.get("params", {})
            tname = params.get("name", "")
            targs = params.get("arguments", {}) or {}
            try:
                out = handle_tool(tname, targs)
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"content": [{"type": "text", "text": out}]},
                }
            except Exception as e:
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32000, "message": str(e)},
                }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()

