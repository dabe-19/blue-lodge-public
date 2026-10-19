#!/usr/bin/env python3
"""Sovereign SDR Audio Transcription & Multimodal Intelligence Engine for Blue Lodge.

Transcribes public safety P25 and analog audio WAV/M4A recordings captured by TrunkRecorder
into text and structured tactical summaries for intelligence synthesis and emergency alerting.

Architecture (Two-Stage RX 5700 XT Pipeline on `george-home`):
  - Stage 1 (Fast Acoustic Draft + Noise Gate):
    Remote whisper.cpp server (`SDR_TRANSCRIPTION_ENDPOINT`, default `http://127.0.0.1:18090/inference`)
    running `whisper-server` (`ggml-base.en.bin` on AMD Radeon RX 5700 XT Vulkan0).
    Evaluates `error_count` / `spike_count` and duration from TrunkRecorder metadata to filter out
    sub-second control bursts and unintelligible QPSK digital noise (`intelligible = False`).
  - Stage 2 (Gemma-4 E4B Multimodal Audio + Metadata + Whisper Refiner):
    Feeds the 16 kHz mono WAV audio (`input_audio`), the raw Whisper draft, and full TrunkRecorder
    metadata (talkgroup, department, category, frequency, duration, participating radio unit IDs,
    RF error metrics) directly into `george-home`'s Gemma-4 E4B multimodal encoder (`:18080/v1/chat/completions`)
    to produce a cleaned transcription (`corrected_transcript`), 1-sentence `tactical_summary`,
    `incident_type`, `priority`, and `locations_mentioned`.
  - Integration: Emits `sdr_transcription_complete` and `sdr_emergency` into the POSIX Event Bus FIFO.
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import logging
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import wave
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger("sdr_transcribe")
logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_GEORGE_DIR = Path(os.environ.get("GEORGE_DIR") or _REPO_ROOT / ".george")
_SDR_DIR = _GEORGE_DIR / "sdr"
_SDR_SPOOL = _SDR_DIR / "spool"
_SDR_ARCHIVE = _SDR_DIR / "archive"
_SDR_AUDIO = _SDR_DIR / "audio"
_SDR_DB_PATH = _SDR_DIR / "sdr_intel.db"
_SDR_NARRATIVE_FILE = _SDR_DIR / "narrative_state.json"
_DOSSIER_PATH = _REPO_ROOT / "dossiers" / "sdr_osint.md"
_EVENT_BUS_FIFO = _GEORGE_DIR / "ipc" / "event_bus.fifo"


def _load_secrets_env() -> None:
    for env_path in [_GEORGE_DIR / "secrets.env", _REPO_ROOT / ".env"]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_secrets_env()

_LLM_BASE = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8080").rstrip("/")
INFERENCE_MODE = os.environ.get("SDR_INFERENCE_MODE", "dedicated").strip().lower()
CAPTURE_MODE = os.environ.get("SDR_CAPTURE_MODE", "remote_ssh").strip().lower()

DEFAULT_ENDPOINTS = [
    os.environ.get("SDR_TRANSCRIPTION_ENDPOINT", ""),
    "http://127.0.0.1:18090/inference",
    "http://127.0.0.1:8090/inference",
]
MULTIMODAL_ENDPOINTS = [
    os.environ.get("SDR_MULTIMODAL_ENDPOINT", ""),
    f"{_LLM_BASE}/v1/chat/completions" if INFERENCE_MODE == "shared_local" else "http://127.0.0.1:18080/v1/chat/completions",
    "http://127.0.0.1:18080/v1/chat/completions",
] + ([f"{_LLM_BASE}/v1/chat/completions", "http://127.0.0.1:8080/v1/chat/completions"] if INFERENCE_MODE == "shared_local" else [])
# Deduplicate while preserving order
MULTIMODAL_ENDPOINTS = list(dict.fromkeys([ep for ep in MULTIMODAL_ENDPOINTS if ep]))
DEFAULT_HOST = os.environ.get("SDR_GATEWAY_HOST", "george-home")
EMERGENCY_KEYWORDS = [
    "swat", "shots fired", "mayday", "officer down", "pursuit",
    "structure fire", "hostage", "perimeter", "code red", "active shooter",
    "evacuation", "hazmat", "bomb threat", "officer in trouble", "10-33",
    "signal 100", "robbery", "weapon", "gunpoint", "overdose",
]


@dataclass
class TranscriptionResult:
    audio_file: str
    transcript: str
    raw_transcript: str = ""
    tactical_summary: str = ""
    incident_type: str = "DISPATCH_STATUS"
    priority: str = "ROUTINE"
    intelligible: bool = True
    locations_mentioned: list[str] = field(default_factory=list)
    source_node: str = "george-home:rx5700xt_vulkan:8090+e4b:8080"
    duration_secs: float = 0.0
    emergency: bool = False
    matched_keywords: list[str] = field(default_factory=list)
    timestamp: int = 0


def check_node_status() -> dict[str, Any]:
    """Check health and availability of the Whisper ASR server and Gemma-4 E4B multimodal server across deployment modes."""
    candidates = [ep for ep in DEFAULT_ENDPOINTS if ep]
    mm_online = False
    active_mm_ep = ""
    for mm_ep in MULTIMODAL_ENDPOINTS:
        try:
            parsed_mm = urllib.parse.urlparse(mm_ep)
            mm_health = f"http://{parsed_mm.hostname}:{parsed_mm.port or 18080}/health"
            req_mm = urllib.request.Request(mm_health, headers={"User-Agent": "GeorgeSDR/2.0"})
            with urllib.request.urlopen(req_mm, timeout=2.0) as resp_mm:
                if resp_mm.status == 200:
                    mm_online = True
                    active_mm_ep = mm_ep
                    break
        except Exception:
            continue

    for endpoint in candidates:
        parsed = urllib.parse.urlparse(endpoint)
        host = parsed.hostname or "127.0.0.1"
        port = parsed.port or 18090
        try:
            req = urllib.request.Request(f"http://{host}:{port}/health", headers={"User-Agent": "GeorgeSDR/2.0"})
            with urllib.request.urlopen(req, timeout=2.0) as resp:
                if resp.status == 200:
                    details = resp.read().decode("utf-8", errors="replace").strip()
                    hw_label = (
                        "george-home · RX 5700 XT (Whisper P25-A100-LoRA + Gemma-4 E4B SVD32)"
                        if mm_online
                        else "george-home · RX 5700 XT (Vulkan0 whisper-server P25-A100-LoRA)"
                    )
                    return {
                        "host": host,
                        "port": port,
                        "endpoint": endpoint,
                        "multimodal_endpoint": active_mm_ep,
                        "multimodal_online": mm_online,
                        "capture_mode": CAPTURE_MODE,
                        "inference_mode": INFERENCE_MODE,
                        "hardware": hw_label,
                        "online": True,
                        "status": "ONLINE",
                        "details": details,
                    }
        except Exception:
            continue

    fallback_ep = candidates[0] if candidates else "http://127.0.0.1:18090/inference"
    parsed = urllib.parse.urlparse(fallback_ep)
    return {
        "host": parsed.hostname or "127.0.0.1",
        "port": parsed.port or 18090,
        "endpoint": fallback_ep,
        "multimodal_endpoint": active_mm_ep,
        "multimodal_online": mm_online,
        "capture_mode": CAPTURE_MODE,
        "inference_mode": INFERENCE_MODE,
        "hardware": "AMD Radeon RX 5700 XT (8GB VRAM / Vulkan)",
        "online": False,
        "status": "OFFLINE",
        "details": "Whisper Vulkan node unreachable on :18090/:8090 (fallback active)",
    }


def emit_event(event_type: str, payload: dict[str, Any], source: str = "sdr_transcribe") -> bool:
    """Emit an event envelope into the Sovereign POSIX Event Bus FIFO."""
    script = 'LODGE_DIR="$1"; source "$LODGE_DIR/lib/ipc/event_bus.sh" 2>/dev/null && event_bus_emit "$2" "$3" "$4"'
    try:
        r = subprocess.run(
            ["bash", "-c", script, "_", str(_REPO_ROOT), event_type, json.dumps(payload), source],
            check=False, timeout=4.0, capture_output=True,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass

    if not _EVENT_BUS_FIFO.exists():
        return False
    ts = int(time.time())
    envelope = {
        "event_id": f"evt_{ts}_{os.getpid()}",
        "type": event_type,
        "source": source,
        "depth": 0,
        "timestamp": ts,
        "payload": payload,
    }
    try:
        fd = os.open(str(_EVENT_BUS_FIFO), os.O_WRONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(envelope) + "\n")
        return True
    except Exception:
        return False


def scan_emergency_keywords(text: str) -> list[str]:
    """Scan transcript for public safety emergency keywords."""
    found = []
    text_lower = text.lower()
    for kw in EMERGENCY_KEYWORDS:
        if re.search(r"\b" + re.escape(kw) + r"\b", text_lower):
            found.append(kw)
    return found


P25_AUDIO_FILTER = "highpass=f=260,lowpass=f=3400,afftdn=nf=-25,dynaudnorm=f=150:g=15"
WHISPER_DOMAIN_PROMPT = (
    "County Sheriff, County Sheriff, Metro Police, City Police, "
    "City Fire, County EMS, Fox Crossing PD, Neenah, Menasha, Calumet Street, "
    "County Road, US-41, WIS-441, Ascension St. Elizabeth, ThedaCare, squad, medic, engine."
)
_NON_SPEECH_PATTERN = re.compile(
    r"\[(?:BLANK_AUDIO|Silence|Music|Noise|Inaudible|phone ringing|bell ringing|chimes|beeping)\]"
    r"|\((?:blank audio|silence|music|noise|phone ringing|bell ringing|chimes|beeping|tone|tones|buzzing|static)\)",
    flags=re.IGNORECASE,
)


def _prepare_16khz_wav_bytes(
    audio_path: Path,
    start_sec: float | None = None,
    duration_sec: float | None = None,
) -> tuple[bytes, float]:
    """Convert any WAV/M4A file (or segment) to bandpass-filtered, denoised, normalized 16 kHz mono 16-bit PCM WAV bytes."""
    duration = 2.0
    try:
        if audio_path.suffix.lower() == ".wav" and start_sec is None and duration_sec is None:
            with wave.open(str(audio_path), "rb") as wf:
                frames = wf.getnframes()
                rate = wf.getframerate() or 8000
                duration = round(frames / float(rate), 2)
    except Exception:
        pass

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        cmd = ["ffmpeg", "-y", "-v", "error"]
        if start_sec is not None and start_sec > 0:
            cmd.extend(["-ss", f"{start_sec:.2f}"])
        if duration_sec is not None and duration_sec > 0:
            cmd.extend(["-t", f"{duration_sec:.2f}"])
        cmd.extend([
            "-i", str(audio_path),
            "-af", P25_AUDIO_FILTER,
            "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(tmp_path),
        ])
        proc = subprocess.run(cmd, capture_output=True, timeout=15)
        if proc.returncode == 0 and tmp_path.exists() and tmp_path.stat().st_size > 64:
            try:
                with wave.open(str(tmp_path), "rb") as wf:
                    seg_dur = round(wf.getnframes() / float(wf.getframerate() or 16000), 2)
                    if start_sec is None and duration_sec is None:
                        duration = seg_dur
            except Exception:
                pass
            return tmp_path.read_bytes(), duration
    except Exception:
        pass
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass

    return audio_path.read_bytes(), duration


def _post_multipart_whisper(endpoint: str, wav_bytes: bytes, filename: str = "audio.wav") -> dict[str, Any]:
    """Send multipart/form-data POST to whisper.cpp whisper-server `/inference`."""
    boundary = f"----GeorgeSDRBoundary{uuid.uuid4().hex}"
    body = io.BytesIO()

    def write_field(name: str, value: str) -> None:
        body.write(f"--{boundary}\r\n".encode("utf-8"))
        body.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        body.write(f"{value}\r\n".encode("utf-8"))

    write_field("response_format", "json")
    write_field("temperature", "0.0")
    write_field("prompt", WHISPER_DOMAIN_PROMPT)

    body.write(f"--{boundary}\r\n".encode("utf-8"))
    body.write(f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode("utf-8"))
    body.write(b"Content-Type: audio/wav\r\n\r\n")
    body.write(wav_bytes)
    body.write(b"\r\n")
    body.write(f"--{boundary}--\r\n".encode("utf-8"))

    payload = body.getvalue()
    req = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(payload)),
            "User-Agent": "GeorgeSDR/2.0",
        },
    )
    with urllib.request.urlopen(req, timeout=20.0) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def _transcribe_whisper_segments(
    endpoint: str,
    audio_path: Path,
    full_wav_bytes: bytes,
    meta: dict[str, Any],
    total_duration: float,
) -> str:
    """Transcribe multi-segment P25 calls per `freqList` transmission slice so initial paging tones never truncate speech."""
    freq_list = [x for x in (meta.get("freqList") or []) if isinstance(x, dict) and float(x.get("len", 0.0)) >= 0.55]
    src_list = [x for x in (meta.get("srcList") or []) if isinstance(x, dict)]

    # Use per-segment decoding whenever there are >=2 segments or the call is >12s
    if len(freq_list) >= 2:
        seg_parts: list[str] = []
        tone_only_parts: list[str] = []
        for idx, seg in enumerate(freq_list):
            pos = float(seg.get("pos", 0.0))
            length = float(seg.get("len", 0.0))
            unit_id = int(src_list[idx].get("src", 0)) if idx < len(src_list) else 0
            seg_wav, _ = _prepare_16khz_wav_bytes(audio_path, start_sec=pos, duration_sec=length)
            try:
                res_data = _post_multipart_whisper(endpoint, seg_wav, filename=f"{audio_path.stem}_seg{idx}.wav")
                raw_seg = (res_data.get("text") or "").strip()
                cleaned_seg = _NON_SPEECH_PATTERN.sub("", raw_seg).strip(" .,;-")
                if cleaned_seg and len(cleaned_seg) > 2:
                    prefix = f"[Unit {unit_id}] " if unit_id > 0 and len(freq_list) > 1 else ""
                    seg_parts.append(f"{prefix}{cleaned_seg}")
                elif raw_seg:
                    tone_only_parts.append(raw_seg)
            except Exception as e:
                logger.warning(f"Segment {idx} Whisper warning on {audio_path.name}: {e}")
        if seg_parts:
            return " ".join(seg_parts).strip()

    # Single-segment or fallback full-file Whisper transcription
    res_data = _post_multipart_whisper(endpoint, full_wav_bytes, filename=f"{audio_path.stem}.wav")
    raw_text = (res_data.get("text") or "").strip()
    return _NON_SPEECH_PATTERN.sub("", raw_text).strip()


def _extract_rf_metrics(meta: dict[str, Any]) -> dict[str, Any]:
    """Compute total error_count, spike_count, duration, and radio source IDs from TrunkRecorder JSON."""
    freq_list = meta.get("freqList") or []
    src_list = meta.get("srcList") or []
    err_total = sum(int(x.get("error_count", 0)) for x in freq_list if isinstance(x, dict)) if freq_list else int(meta.get("error_count", 0))
    spike_total = sum(int(x.get("spike_count", 0)) for x in freq_list if isinstance(x, dict)) if freq_list else int(meta.get("spike_count", 0))
    len_total = sum(float(x.get("len", 0.0)) for x in freq_list if isinstance(x, dict))
    if len_total <= 0:
        len_total = float(meta.get("duration_secs") or meta.get("call_length", 0) or max(0, int(meta.get("stop_time", 0)) - int(meta.get("start_time", 0))))
    unit_ids = [int(x.get("src")) for x in src_list if isinstance(x, dict) and int(x.get("src", -1)) > 0]
    if not unit_ids and meta.get("unit_ids"):
        unit_ids = [int(u) for u in meta["unit_ids"] if int(u) > 0]
    err_rate = err_total / max(0.5, len_total)
    if len_total < 0.8 or err_rate > 260:
        rf_quality = "GARBLED_QPSK"
    elif err_rate > 120:
        rf_quality = "MARGINAL_SNR"
    else:
        rf_quality = "CLEAN_DECODE"
    return {
        "error_count": err_total,
        "spike_count": spike_total,
        "duration_secs": round(len_total, 2),
        "unit_ids": unit_ids,
        "rf_quality": rf_quality,
        "freq_error": int(meta.get("freq_error", 0)),
    }


def _load_narrative_state() -> dict[str, Any]:
    if _SDR_NARRATIVE_FILE.exists():
        try:
            data = json.loads(_SDR_NARRATIVE_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                data.setdefault("by_talkgroup", {})
                data.setdefault("by_unit", {})
                return data
        except Exception:
            pass
    return {"by_talkgroup": {}, "by_unit": {}, "updated_at": 0}


def _save_narrative_state(state: dict[str, Any]) -> None:
    try:
        _SDR_NARRATIVE_FILE.parent.mkdir(parents=True, exist_ok=True)
        state["updated_at"] = int(time.time())
        _SDR_NARRATIVE_FILE.write_text(json.dumps(state, indent=2), encoding="utf-8")
    except Exception as e:
        logger.warning(f"Failed to save narrative state: {e}")


def _fmt_elapsed(delta_secs: int) -> str:
    if delta_secs < 60:
        return f"{max(1, delta_secs)}s ago"
    if delta_secs < 3600:
        return f"{delta_secs // 60}m {delta_secs % 60}s ago"
    return f"{delta_secs // 3600}h {(delta_secs % 3600) // 60}m ago"


def _build_running_context(meta: dict[str, Any], rf: dict[str, Any]) -> str:
    """Build a running context buffer from SQLite `sdr_intel.db` and `narrative_state.json`
    linked by Talkgroup (Department), Radio Unit IDs (across channels), and Voice Frequency.
    """
    call_id = str(meta.get("call_id") or "")
    tg = int(meta.get("talkgroup") or 0)
    tag = str(meta.get("talkgroup_tag") or f"TG-{tg}")
    call_ts = int(meta.get("start_time") or time.time())
    freq_val = float(meta.get("freq") or 0.0)
    freq_mhz = round(freq_val / 1e6, 4) if freq_val > 10000 else round(freq_val, 4)
    units = [int(u) for u in (rf.get("unit_ids") or []) if int(u) > 0]
    unique_units = list(dict.fromkeys(units))

    nav_state = _load_narrative_state()
    tg_nav = nav_state.get("by_talkgroup", {}).get(str(tg), {})
    sections: list[str] = []

    if tg_nav.get("ongoing_narrative"):
        sections.append(
            f"- Ongoing Department Narrative ({tag}): {tg_nav['ongoing_narrative']}"
        )

    unit_nav_lines: list[str] = []
    for uid in unique_units[:5]:
        u_entry = nav_state.get("by_unit", {}).get(str(uid))
        if u_entry and u_entry.get("unit_narrative"):
            unit_nav_lines.append(
                f"  * Unit {uid} (last on {u_entry.get('last_talkgroup_tag', tag)}): {u_entry['unit_narrative']}"
            )
    if unit_nav_lines:
        sections.append("- Active Unit Status Thread:\n" + "\n".join(unit_nav_lines))

    if not _SDR_DB_PATH.exists():
        return "\n".join(sections) if sections else "- No prior transmissions recorded yet in window."

    try:
        conn = sqlite3.connect(str(_SDR_DB_PATH), timeout=5.0)
        conn.row_factory = sqlite3.Row
        try:
            # 1. Recent Department / Talkgroup History (last 90 mins on this talkgroup)
            tg_rows = conn.execute(
                """
                SELECT call_id, start_time, freq_mhz, unit_ids_json, transcript, tactical_summary, locations_json
                FROM sdr_calls
                WHERE talkgroup = ? AND start_time <= ? AND start_time >= ?
                  AND call_id != ? AND intelligible = 1
                ORDER BY start_time DESC
                LIMIT 6
                """,
                (tg, call_ts, call_ts - 5400, call_id),
            ).fetchall()
            if tg_rows:
                tg_lines: list[str] = []
                for r in reversed(tg_rows):
                    dt = max(0, call_ts - int(r["start_time"]))
                    hm = time.strftime("%H:%M:%S", time.gmtime(int(r["start_time"])))
                    u_list = json.loads(r["unit_ids_json"] or "[]")
                    u_str = f"Units {list(dict.fromkeys(u_list))[:3]}" if u_list else "Unid"
                    tx_s = (r["transcript"] or "").strip()[:140]
                    sum_s = (r["tactical_summary"] or "").strip()[:140]
                    tg_lines.append(f"  * [{hm} | {_fmt_elapsed(dt)}] ({u_str}): \"{tx_s}\" -> {sum_s}")
                sections.append(f"- Recent Department Channel History ({tag}, chronological):\n" + "\n".join(tg_lines))

            # 2. Cross-Channel History for Participating Radio Unit IDs (last 2 hours across ANY channel/freq)
            if unique_units:
                placeholders = ",".join("?" for _ in unique_units[:6])
                u_rows = conn.execute(
                    f"""
                    SELECT DISTINCT c.call_id, c.start_time, c.talkgroup_tag, c.freq_mhz,
                           c.unit_ids_json, c.transcript, c.tactical_summary
                    FROM sdr_unit_sightings s
                    JOIN sdr_calls c ON c.call_id = s.call_id
                    WHERE s.unit_id IN ({placeholders})
                      AND c.start_time <= ? AND c.start_time >= ?
                      AND c.call_id != ? AND c.intelligible = 1
                    ORDER BY c.start_time DESC
                    LIMIT 6
                    """,
                    (*unique_units[:6], call_ts, call_ts - 7200, call_id),
                ).fetchall()
                if u_rows:
                    u_lines: list[str] = []
                    for r in reversed(u_rows):
                        dt = max(0, call_ts - int(r["start_time"]))
                        hm = time.strftime("%H:%M:%S", time.gmtime(int(r["start_time"])))
                        u_list = list(dict.fromkeys(json.loads(r["unit_ids_json"] or "[]")))[:3]
                        tx_s = (r["transcript"] or "").strip()[:120]
                        u_lines.append(
                            f"  * [{hm} | {_fmt_elapsed(dt)}] [{r['talkgroup_tag']} @ {r['freq_mhz']:.4f} MHz] "
                            f"Units {u_list}: \"{tx_s}\""
                        )
                    sections.append("- Prior Transmissions Involving These Specific Radio Unit(s):\n" + "\n".join(u_lines))

            # 3. Same Voice Frequency Activity (last 10 mins, helpful when mobile unit ID wasn't captured)
            if freq_mhz > 0:
                f_rows = conn.execute(
                    """
                    SELECT start_time, talkgroup_tag, unit_ids_json, transcript
                    FROM sdr_calls
                    WHERE ABS(freq_mhz - ?) < 0.001 AND start_time <= ? AND start_time >= ?
                      AND call_id != ? AND intelligible = 1
                    ORDER BY start_time DESC
                    LIMIT 3
                    """,
                    (freq_mhz, call_ts, call_ts - 600, call_id),
                ).fetchall()
                if f_rows:
                    f_lines: list[str] = []
                    for r in reversed(f_rows):
                        dt = max(0, call_ts - int(r["start_time"]))
                        u_list = list(dict.fromkeys(json.loads(r["unit_ids_json"] or "[]")))[:3]
                        f_lines.append(
                            f"  * [{_fmt_elapsed(dt)} on {freq_mhz:.4f} MHz · {r['talkgroup_tag']}] "
                            f"Units {u_list}: \"{(r['transcript'] or '').strip()[:100]}\""
                        )
                    sections.append(f"- Recent Activity on Same Voice Frequency ({freq_mhz:.4f} MHz):\n" + "\n".join(f_lines))
        finally:
            conn.close()
    except Exception as e:
        logger.debug(f"Running context query warning: {e}")

    return "\n".join(sections) if sections else "- No prior transmissions recorded in recent window."


def _update_narrative_state(meta: dict[str, Any], rf: dict[str, Any], parsed: dict[str, Any]) -> None:
    """Persist updated department and unit narrative threads after an intelligible E4B refinement."""
    if not parsed.get("intelligible", True):
        return
    tg = int(meta.get("talkgroup") or 0)
    tag = str(meta.get("talkgroup_tag") or f"TG-{tg}")
    desc = str(meta.get("talkgroup_description") or tag)
    group = str(meta.get("talkgroup_group") or "Regional")
    call_ts = int(meta.get("start_time") or time.time())
    units = list(dict.fromkeys(int(u) for u in (rf.get("unit_ids") or []) if int(u) > 0))
    locs = [str(x) for x in (parsed.get("locations_mentioned") or []) if x]
    tac_sum = str(parsed.get("tactical_summary") or "").strip()
    ongoing = str(parsed.get("ongoing_narrative") or tac_sum).strip()

    state = _load_narrative_state()
    tg_key = str(tg)
    prev_tg = state["by_talkgroup"].get(tg_key, {})
    prev_units = list(dict.fromkeys((prev_tg.get("active_units") or []) + units))[-12:]
    prev_locs = list(dict.fromkeys((prev_tg.get("active_locations") or []) + locs))[-10:]

    state["by_talkgroup"][tg_key] = {
        "talkgroup": tg,
        "talkgroup_tag": tag,
        "talkgroup_description": desc,
        "talkgroup_group": group,
        "ongoing_narrative": ongoing or prev_tg.get("ongoing_narrative", ""),
        "last_tactical_summary": tac_sum,
        "last_transcript": str(parsed.get("corrected_transcript") or "").strip(),
        "incident_type": str(parsed.get("incident_type") or "DISPATCH_STATUS"),
        "priority": str(parsed.get("priority") or "ROUTINE"),
        "active_units": prev_units,
        "active_locations": prev_locs,
        "updated_at": call_ts,
    }

    for uid in units:
        u_key = str(uid)
        prev_u = state["by_unit"].get(u_key, {})
        trail = list(prev_u.get("recent_events") or [])
        trail.append({
            "timestamp": call_ts,
            "talkgroup": tg,
            "talkgroup_tag": tag,
            "summary": tac_sum,
            "transcript": str(parsed.get("corrected_transcript") or "").strip()[:140],
            "locations": locs,
        })
        state["by_unit"][u_key] = {
            "unit_id": uid,
            "last_talkgroup": tg,
            "last_talkgroup_tag": tag,
            "unit_narrative": ongoing or tac_sum,
            "last_location": locs[-1] if locs else prev_u.get("last_location", ""),
            "recent_events": trail[-8:],
            "updated_at": call_ts,
        }

    _save_narrative_state(state)


def refine_with_gemma4_multimodal(
    wav_bytes: bytes,
    raw_whisper: str,
    meta: dict[str, Any],
    rf: dict[str, Any],
    timeout: float = 55.0,
) -> dict[str, Any] | None:
    """Feed 16 kHz WAV audio + TrunkRecorder metadata + Running Context Buffer + raw Whisper draft into Gemma-4 E4B on george-home."""
    b64_audio = base64.b64encode(wav_bytes).decode("ascii")
    tg = meta.get("talkgroup", 0)
    tag = meta.get("talkgroup_tag") or f"TG-{tg}"
    desc = meta.get("talkgroup_description") or tag
    group = meta.get("talkgroup_group") or "Regional P25"
    group_tag = meta.get("talkgroup_group_tag") or meta.get("category") or "Public Safety"
    freq_val = float(meta.get("freq", 0.0))
    freq_mhz = f"{freq_val / 1e6:.4f}" if freq_val > 10000 else f"{freq_val:.4f}"
    units = rf.get("unit_ids") or []
    unique_units = list(dict.fromkeys(units))
    running_context = _build_running_context(meta, rf)

    prompt = f"""You are an expert Public Safety Radio Intelligence Analyst listening to a P25 digital trunked radio recording from Regional Public Safety P25 (System 4E1).

CURRENT CALL METADATA:
- System: {meta.get('system', 'winne_p25')}
- Talkgroup: {tg} ({tag} — {desc})
- Agency / Category: {group} ({group_tag})
- Voice Frequency: {freq_mhz} MHz
- Duration: {rf['duration_secs']:.1f}s ({max(1, len(units))} transmission segment(s), {len(unique_units)} unique radio unit(s))
- Radio Unit IDs: {units} (Dispatch consoles: 7100001/7100002/7100004/7100005/4500015/4500016; Metro PD squads: 719xxxx; County Sheriff deputies: 7104xxx/811xxxx; Fox Crossing/Neenah/Menasha PD: 718xxxx/717xxxx; County Sheriff/Springfield: 458xxxx/450xxxx; Fire/EMS apparatus: 712xxxx/713xxxx)
- RF Decode Quality: {rf['rf_quality']} (bit_errors={rf['error_count']}, spikes={rf['spike_count']})
- Raw Whisper ASR Draft (frequently mangles radio ten-codes & street names): "{raw_whisper}"

RUNNING CONTEXT BUFFER (Prior Linked Events for {tag}, Participating Units {unique_units}, and {freq_mhz} MHz):
{running_context}

Listen carefully to the attached P25 audio and combine it with the CALL METADATA, RUNNING CONTEXT BUFFER, and Raw Whisper Draft to produce an accurate transcription and a continuous operational narrative.
Rules:
1. RECOGNIZING "10-4" AND RADIO TEN-CODES: "10-4" (acknowledged/understood) is spoken constantly on P25 radio, especially in short 1s–3s responses after a dispatch or status check. Because the P25 IMBE vocoder clips the initial "t" at key-up, raw Whisper very frequently mishears "10-4" as "for now", "3.4 now", "204", "ten for", "in for", "can for", "10 floor", "104", "7-2", "time for", or "and four". Listen carefully to the two-syllable "ten-four" cadence in the audio and check the RUNNING CONTEXT BUFFER: when a speaker says "10-4" (e.g., "10-4", "10-4, en route", or "<unit>, 10-4"), always transcribe it accurately as "10-4".
2. COMPLETE MULTI-SEGMENT TRANSCRIPTION: Transcribe the ENTIRE radio communication across all segments and fix phonetic ASR errors using Wisconsin context (Metro, Springfield, Neenah, Menasha, Fox Crossing, County, County, US-41, WIS-441, County Road, Calumet St, Ascension St. Elizabeth, ThedaCare).
3. CONTINUOUS UNIT & DEPARTMENT NARRATIVE: Use the RUNNING CONTEXT BUFFER to understand what transpired with these units and this department prior to this call.
   - In "tactical_summary", write a 1–2 sentence summary of THIS transmission that explicitly connects it to the prior context (e.g., "Unit 4589316 acknowledged (10-4) City Fire Dispatch's assignment to the medical call on E Calumet St.").
   - In "ongoing_narrative", write a 1–2 sentence cumulative storyline tracking what this department ({tag}) and its active units ({unique_units}) are currently doing across recent transmissions.
4. Only set "intelligible": false and "incident_type": "UNINTELLIGIBLE" if the audio is pure digital noise, carrier key-up with no voice, or completely unintelligible static.

Respond ONLY with valid JSON matching this exact schema:
{{
  "intelligible": true,
  "corrected_transcript": "Cleaned and accurate transcript of what was said on the radio",
  "tactical_summary": "Context-linked 1-2 sentence summary of this transmission naming the agency, units, and how it connects to prior activity",
  "ongoing_narrative": "Cumulative 1-2 sentence storyline of the ongoing incident/activity for this department and units",
  "incident_type": "TRAFFIC_STOP | MEDICAL_EMS | FIRE_RESCUE | DISTURBANCE_DV | ACCIDENT_HAZARD | WARRANT_RECORDS | DISPATCH_STATUS | UNINTELLIGIBLE | OTHER",
  "priority": "ROUTINE | ELEVATED | EMERGENCY",
  "locations_mentioned": ["street, intersection, or landmark"]
}}"""

    payload = {
        "model": "gemma-4-E4B",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "input_audio", "input_audio": {"data": b64_audio, "format": "wav"}},
                    {"type": "text", "text": prompt},
                ],
            }
        ],
        "chat_template_kwargs": {"enable_thinking": False},
        "response_format": {"type": "json_object"},
        "temperature": 0.1,
        "max_tokens": 420,
    }

    for endpoint in [ep for ep in MULTIMODAL_ENDPOINTS if ep]:
        try:
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json", "User-Agent": "GeorgeSDR/2.0"},
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                res = json.loads(resp.read().decode("utf-8", errors="replace"))
            msg = res["choices"][0]["message"]
            raw_content = (msg.get("content") or msg.get("reasoning_content") or "").strip()
            m = re.search(r"\{.*\}", raw_content, flags=re.DOTALL)
            if m:
                parsed = json.loads(m.group(0))
                if isinstance(parsed, dict) and "corrected_transcript" in parsed:
                    tsum = str(parsed.get("tactical_summary") or "").strip()
                    if not tsum or "no tactical summary" in tsum.lower():
                        u_label = f"Units {', '.join(str(u) for u in unique_units[:3])}" if unique_units else "Radio Unit"
                        parsed["tactical_summary"] = (
                            f"{tag} ({desc}) radio communication ({u_label}, {rf['duration_secs']:.1f}s): "
                            f"\"{str(parsed.get('corrected_transcript') or '').strip()[:120]}\""
                        )
                    _update_narrative_state(meta, rf, parsed)
                    return parsed
        except Exception as e:
            logger.warning(f"Gemma-4 E4B multimodal refinement warning via {endpoint}: {e}")
            continue
    return None


def transcribe_audio_file(
    audio_path: Path,
    meta: dict[str, Any] | None = None,
    use_multimodal: bool = True,
) -> TranscriptionResult:
    """Transcribe a single WAV/M4A file via Two-Stage RX 5700 XT pipeline (Vulkan Whisper + Gemma-4 E4B Multimodal)."""
    ts = int(time.time())
    file_name = audio_path.name

    if meta is None:
        meta_path = audio_path.with_suffix(".json")
        if meta_path.exists():
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except Exception:
                meta = {}
        else:
            meta = {}

    rf = _extract_rf_metrics(meta)
    tag = meta.get("talkgroup_tag") or meta.get("talkgroup_description") or "P25 Channel"
    desc = meta.get("talkgroup_description") or tag
    units_str = f"Units {', '.join(str(u) for u in rf['unit_ids'][:4])}" if rf["unit_ids"] else "Unidentified Unit"

    if not audio_path.exists() or audio_path.stat().st_size <= 64:
        transcript = str(meta.get("transcript") or f"[SIMULATED TRANSCRIPT: {tag}] {units_str} status check, code 4.")
        emerg = bool(meta.get("emergency", 0)) or len(scan_emergency_keywords(transcript)) > 0
        return TranscriptionResult(
            audio_file=file_name,
            transcript=transcript,
            raw_transcript=transcript,
            tactical_summary=f"Simulated P25 transmission on {tag} ({desc}) involving {units_str}.",
            incident_type="DISPATCH_STATUS",
            priority="EMERGENCY" if emerg else "ROUTINE",
            intelligible=True,
            locations_mentioned=[],
            source_node="acoustic_simulation",
            duration_secs=max(1.0, rf["duration_secs"]),
            emergency=emerg,
            matched_keywords=scan_emergency_keywords(transcript),
            timestamp=ts,
        )

    wav_bytes, duration = _prepare_16khz_wav_bytes(audio_path)
    if rf["duration_secs"] > 0:
        duration = rf["duration_secs"]

    # Fast Noise Gate: sub-second digital control/key-up bursts
    if duration < 0.85:
        burst_msg = (
            f"[QPSK DIGITAL BURST / LOW SNR: {duration:.1f}s · {rf['error_count']} bit errors, "
            f"{rf['spike_count']} spikes on {tag} ({desc}) · {units_str}]"
        )
        return TranscriptionResult(
            audio_file=file_name,
            transcript=burst_msg,
            raw_transcript="",
            tactical_summary=f"Brief {duration:.1f}s P25 key-up / digital burst on {tag} ({units_str}).",
            incident_type="UNINTELLIGIBLE",
            priority="ROUTINE",
            intelligible=False,
            locations_mentioned=[],
            source_node="rf_noise_gate",
            duration_secs=duration,
            emergency=bool(meta.get("emergency", 0)),
            matched_keywords=[],
            timestamp=ts,
        )

    raw_whisper = ""
    node_stat = check_node_status()
    if node_stat["online"]:
        try:
            raw_whisper = _transcribe_whisper_segments(
                node_stat["endpoint"], audio_path, wav_bytes, meta, duration
            )
        except Exception as e:
            logger.warning(f"Remote RX 5700 XT Vulkan Whisper failed ({e})")

    # Check if Whisper produced any candidate speech or if the call is >= 0.9s (to catch 1s-2s "10-4" acknowledgments!)
    has_whisper_speech = bool(
        raw_whisper
        and len(raw_whisper) > 1
        and raw_whisper.lower() not in (".", "uh", "um")
    )

    if not has_whisper_speech and rf["rf_quality"] == "GARBLED_QPSK" and duration < 1.5:
        unintel_msg = (
            f"[UNINTELLIGIBLE P25 IMBE CARRIER: {duration:.1f}s · {rf['error_count']} errs on {tag} · {units_str}]"
        )
        return TranscriptionResult(
            audio_file=file_name,
            transcript=unintel_msg,
            raw_transcript=raw_whisper,
            tactical_summary=f"Unintelligible P25 carrier ({duration:.1f}s, {rf['error_count']} bit errors) on {tag} ({units_str}).",
            incident_type="UNINTELLIGIBLE",
            priority="ROUTINE",
            intelligible=False,
            locations_mentioned=[],
            source_node="george-home:rx5700xt_vulkan:8090",
            duration_secs=duration,
            emergency=bool(meta.get("emergency", 0)),
            matched_keywords=[],
            timestamp=ts,
        )

    # Stage 2: Gemma-4 E4B Multimodal Audio + Metadata + Running Context Buffer + Raw Whisper Fusion
    # Always run E4B for calls >= 0.9s so short "10-4" responses get audio+context inspection
    if use_multimodal and (has_whisper_speech or duration >= 0.9):
        e4b_wav_bytes = wav_bytes
        if duration > 28.0:
            freq_list = [x for x in (meta.get("freqList") or []) if isinstance(x, dict)]
            start_trim = 0.0
            if len(freq_list) >= 2 and float(freq_list[0].get("len", 0.0)) <= 6.0:
                start_trim = float(freq_list[1].get("pos", 0.0))
            e4b_wav_bytes, _ = _prepare_16khz_wav_bytes(audio_path, start_sec=start_trim, duration_sec=28.0)

        mm_res = refine_with_gemma4_multimodal(e4b_wav_bytes, raw_whisper, meta, rf)
        if mm_res:
            is_intel = bool(mm_res.get("intelligible", True))
            corr_tx = str(mm_res.get("corrected_transcript") or raw_whisper).strip()
            tac_sum = str(mm_res.get("tactical_summary") or "").strip()
            inc_type = str(mm_res.get("incident_type") or "DISPATCH_STATUS").strip().upper()
            prio = str(mm_res.get("priority") or "ROUTINE").strip().upper()
            locs = [str(x) for x in (mm_res.get("locations_mentioned") or []) if x]

            if not is_intel or inc_type == "UNINTELLIGIBLE" or not corr_tx:
                unintel_msg = (
                    f"[UNINTELLIGIBLE P25 IMBE CARRIER: {duration:.1f}s · {rf['error_count']} errs on {tag} · {units_str}]"
                )
                return TranscriptionResult(
                    audio_file=file_name,
                    transcript=unintel_msg,
                    raw_transcript=raw_whisper,
                    tactical_summary=tac_sum or f"Unintelligible P25 transmission on {tag} ({units_str}).",
                    incident_type="UNINTELLIGIBLE",
                    priority="ROUTINE",
                    intelligible=False,
                    locations_mentioned=[],
                    source_node="george-home:rx5700xt_vulkan:8090+e4b:8080",
                    duration_secs=duration,
                    emergency=bool(meta.get("emergency", 0)),
                    matched_keywords=[],
                    timestamp=ts,
                )

            combined_scan = f"{corr_tx} {tac_sum}"
            matched = scan_emergency_keywords(combined_scan)
            is_emerg = prio == "EMERGENCY" or len(matched) > 0 or bool(meta.get("emergency", 0))
            if is_emerg and prio == "ROUTINE":
                prio = "EMERGENCY"

            return TranscriptionResult(
                audio_file=file_name,
                transcript=corr_tx,
                raw_transcript=raw_whisper or corr_tx,
                tactical_summary=tac_sum,
                incident_type=inc_type,
                priority=prio,
                intelligible=True,
                locations_mentioned=locs,
                source_node="george-home:rx5700xt_vulkan:8090+e4b:8080",
                duration_secs=duration,
                emergency=is_emerg,
                matched_keywords=matched,
                timestamp=ts,
            )

    # Fallback if multimodal endpoint is busy/offline
    if has_whisper_speech:
        transcript = raw_whisper
        matched = scan_emergency_keywords(transcript)
        is_emerg = len(matched) > 0 or bool(meta.get("emergency", 0))
        return TranscriptionResult(
            audio_file=file_name,
            transcript=transcript,
            raw_transcript=raw_whisper,
            tactical_summary=f"{tag} ({desc}) transmission ({duration:.1f}s, {units_str}): {raw_whisper[:120]}",
            incident_type="DISPATCH_STATUS",
            priority="EMERGENCY" if is_emerg else "ROUTINE",
            intelligible=True,
            locations_mentioned=[],
            source_node="george-home:rx5700xt_vulkan:8090",
            duration_secs=duration,
            emergency=is_emerg,
            matched_keywords=matched,
            timestamp=ts,
        )

    fallback_msg = f"[RF TELEMETRY INTERCEPT: {duration:.1f}s · {rf['error_count']} errs on {tag} ({desc}) · {units_str}]"
    return TranscriptionResult(
        audio_file=file_name,
        transcript=fallback_msg,
        raw_transcript=raw_whisper,
        tactical_summary=f"Unintelligible RF carrier on {tag} ({duration:.1f}s).",
        incident_type="UNINTELLIGIBLE",
        priority="ROUTINE",
        intelligible=False,
        locations_mentioned=[],
        source_node="rf_telemetry_analyzer",
        duration_secs=duration,
        emergency=bool(meta.get("emergency", 0)),
        matched_keywords=[],
        timestamp=ts,
    )


def transcribe_spool(force_multimodal_upgrade: bool = False) -> list[dict[str, Any]]:
    """Transcribe all pending or un-upgraded recordings in the local spool and archive."""
    results = []
    _SDR_SPOOL.mkdir(parents=True, exist_ok=True)
    _SDR_ARCHIVE.mkdir(parents=True, exist_ok=True)

    target_files = list(_SDR_SPOOL.glob("*.json")) + sorted(_SDR_ARCHIVE.glob("*.json"), key=os.path.getmtime, reverse=True)[:45]
    seen_paths = set()

    for jf in target_files:
        if jf in seen_paths:
            continue
        seen_paths.add(jf)
        try:
            data = json.loads(jf.read_text(encoding="utf-8"))
            existing_tx = str(data.get("transcript") or "")
            node = str(data.get("transcription_node") or "")
            if (
                not force_multimodal_upgrade
                and existing_tx
                and not existing_tx.startswith("[TRANSCRIBING]")
                and "e4b:8080" in node
            ):
                continue
            if (
                not force_multimodal_upgrade
                and data.get("intelligible") is False
                and node in ("rf_noise_gate", "george-home:rx5700xt_vulkan:8090+e4b:8080")
            ):
                continue

            audio_name = data.get("audio_file") or f"{jf.stem}.wav"
            audio_path = jf.parent / audio_name
            if not audio_path.exists():
                for ext in (".wav", ".m4a"):
                    cand = jf.parent / f"{jf.stem}{ext}"
                    if cand.exists():
                        audio_path = cand
                        break

            res = transcribe_audio_file(audio_path, meta=data, use_multimodal=True)
            rf = _extract_rf_metrics(data)
            data["transcript"] = res.transcript
            data["raw_transcript"] = res.raw_transcript
            data["tactical_summary"] = res.tactical_summary
            data["incident_type"] = res.incident_type
            data["priority"] = res.priority
            data["intelligible"] = res.intelligible
            data["locations_mentioned"] = res.locations_mentioned
            data["transcription_node"] = res.source_node
            data["emergency"] = res.emergency or bool(data.get("emergency", False))
            data["error_count"] = rf["error_count"]
            data["spike_count"] = rf["spike_count"]
            data["rf_quality"] = rf["rf_quality"]
            data["unit_ids"] = rf["unit_ids"]

            jf.write_text(json.dumps(data, indent=2), encoding="utf-8")
            results.append(asdict(res))

            emit_event("sdr_transcription_complete", {
                "call_id": data.get("call_id", jf.stem),
                "audio_file": res.audio_file,
                "transcript": res.transcript,
                "raw_transcript": res.raw_transcript,
                "tactical_summary": res.tactical_summary,
                "incident_type": res.incident_type,
                "intelligible": res.intelligible,
                "source_node": res.source_node,
                "emergency": res.emergency,
                "rf_quality": rf["rf_quality"],
                "talkgroup": data.get("talkgroup_tag", "UNKNOWN"),
            })

            if res.emergency and res.intelligible:
                emit_event("sdr_emergency", {
                    "call_id": data.get("call_id", jf.stem),
                    "transcript": res.transcript,
                    "tactical_summary": res.tactical_summary,
                    "matched_keywords": res.matched_keywords,
                    "talkgroup": data.get("talkgroup_tag", "TACTICAL"),
                })

            if res.intelligible:
                _append_dossier(data, res)
        except Exception as e:
            logger.error(f"Error transcribing {jf}: {e}")

    return results


def _append_dossier(call_data: dict[str, Any], res: TranscriptionResult) -> None:
    """Append intelligible transcribed call to SDR OSINT dossier."""
    if not res.intelligible:
        return
    _DOSSIER_PATH.parent.mkdir(parents=True, exist_ok=True)
    ts_str = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(call_data.get("start_time") or res.timestamp))
    emerg_flag = "**[CRITICAL EMERGENCY BROADCAST]**" if res.emergency else f"[{res.incident_type} · {call_data.get('rf_quality', 'INTERCEPT')}]"
    freq_val = float(call_data.get("freq", 0.0))
    freq_mhz = f"{freq_val / 1e6:.4f}" if freq_val > 10000 else f"{freq_val}"

    entry = f"""
### {emerg_flag} Call `{call_data.get('call_id', res.audio_file)}`
- **Timestamp:** {ts_str}
- **System / Frequency:** `{call_data.get('system', 'winne_p25')}` | `{freq_mhz} MHz` (Err: `{call_data.get('error_count', 0)}`, Spikes: `{call_data.get('spike_count', 0)}`)
- **Talkgroup / Department:** `{call_data.get('talkgroup', '0')}` — **{call_data.get('talkgroup_tag', 'GENERAL')}** ({call_data.get('talkgroup_description', '')} · {call_data.get('talkgroup_group', '')})
- **Units:** `{call_data.get('unit_ids', [])}` | **Audio:** `{res.audio_file}` ({res.duration_secs}s · `{res.source_node}`)
- **Tactical Summary:** {res.tactical_summary}
- **Cleaned Transcript (Gemma-4 E4B Multimodal):**
> "{res.transcript}"
"""
    if res.raw_transcript and res.raw_transcript != res.transcript:
        entry += f"- **Raw Whisper Draft:** `{res.raw_transcript}`\n"
    if res.locations_mentioned:
        entry += f"- **Locations Mentioned:** `{', '.join(res.locations_mentioned)}`\n"
    if res.matched_keywords:
        entry += f"- **Emergency Triggers Detected:** `{', '.join(res.matched_keywords)}`\n"

    with open(_DOSSIER_PATH, "a", encoding="utf-8") as df:
        df.write(entry + "\n---\n")


def analyze_audio_with_encoder(
    audio_path: Path,
    meta: dict[str, Any] | None = None,
    custom_prompt: str = "",
) -> dict[str, Any]:
    """
    Consume a WAV/M4A/MP3 audio file into both the Whisper P25-A100-LoRA ASR encoder and
    the Gemma-4 E4B Multimodal audio encoder (`input_audio` WAV base64) with Running Context Buffer.
    Optionally answers a custom operator/Discord question (`custom_prompt`) about the audio.
    """
    meta = dict(meta or {})
    if not meta:
        cand_json = audio_path.with_suffix(".json")
        if cand_json.exists():
            try:
                meta = json.loads(cand_json.read_text(encoding="utf-8"))
            except Exception:
                meta = {}

    rf = _extract_rf_metrics(meta)
    tx_res = transcribe_audio_file(audio_path, meta=meta, use_multimodal=True)
    running_context = _build_running_context(meta, rf) if meta else ""

    custom_analysis = ""
    if custom_prompt and custom_prompt.strip():
        try:
            wav_bytes, dur = _prepare_16khz_wav_bytes(audio_path)
            if wav_bytes:
                b64_audio = base64.b64encode(wav_bytes).decode("ascii")
                tg = meta.get("talkgroup", 0)
                tag = meta.get("talkgroup_tag") or f"TG-{tg}"
                desc = meta.get("talkgroup_description") or tag
                units = rf.get("unit_ids") or []
                q_prompt = (
                    f"You are listening to P25 trunked radio audio file '{audio_path.name}' "
                    f"(Talkgroup: {tg} / {tag} — {desc}, Units: {units}, Duration: {dur:.1f}s).\n"
                    f"Stage-1 Whisper Draft: \"{tx_res.raw_transcript}\"\n"
                    f"Stage-2 Refined Transcript: \"{tx_res.transcript}\"\n"
                    f"Tactical Summary: \"{tx_res.tactical_summary}\"\n"
                    f"Running Context:\n{running_context}\n\n"
                    f"User Question / Analysis Request: {custom_prompt.strip()}\n\n"
                    f"Listen directly to the audio and provide a concise, accurate, evidence-based answer."
                )
                payload = {
                    "model": "gemma-4-E4B",
                    "messages": [
                        {
                            "role": "user",
                            "content": [
                                {"type": "input_audio", "input_audio": {"data": b64_audio, "format": "wav"}},
                                {"type": "text", "text": q_prompt},
                            ],
                        }
                    ],
                    "chat_template_kwargs": {"enable_thinking": False},
                    "temperature": 0.15,
                    "max_tokens": 500,
                }
                for mm_ep in MULTIMODAL_ENDPOINTS:
                    if not mm_ep:
                        continue
                    try:
                        req = urllib.request.Request(
                            mm_ep,
                            data=json.dumps(payload).encode("utf-8"),
                            headers={"Content-Type": "application/json", "User-Agent": "GeorgeSDR/2.0"},
                            method="POST",
                        )
                        with urllib.request.urlopen(req, timeout=55.0) as resp:
                            if resp.status == 200:
                                rj = json.loads(resp.read().decode("utf-8", errors="replace"))
                                custom_analysis = (
                                    rj.get("choices", [{}])[0].get("message", {}).get("content", "") or ""
                                ).strip()
                                if custom_analysis:
                                    break
                    except Exception:
                        continue
        except Exception as e:
            logger.debug(f"Custom prompt audio analysis warning: {e}")

    return {
        "status": "ok",
        "audio_path": str(audio_path.resolve()),
        "audio_file": audio_path.name,
        "call_id": meta.get("call_id") or audio_path.stem,
        "talkgroup": meta.get("talkgroup", 0),
        "talkgroup_tag": meta.get("talkgroup_tag", ""),
        "talkgroup_description": meta.get("talkgroup_description", ""),
        "talkgroup_group": meta.get("talkgroup_group", ""),
        "freq_mhz": round(float(meta.get("freq", 0.0)) / 1e6, 4) if float(meta.get("freq", 0.0)) > 10000 else float(meta.get("freq", 0.0)),
        "duration_secs": tx_res.duration_secs or rf.get("duration_secs", 0.0),
        "rf_quality": rf.get("rf_quality", "CLEAN_DECODE"),
        "unit_ids": rf.get("unit_ids", []),
        "intelligible": tx_res.intelligible,
        "incident_type": tx_res.incident_type,
        "priority": tx_res.priority,
        "emergency": tx_res.emergency,
        "transcript": tx_res.transcript,
        "raw_transcript": tx_res.raw_transcript,
        "tactical_summary": tx_res.tactical_summary,
        "locations_mentioned": tx_res.locations_mentioned,
        "running_context": running_context,
        "custom_prompt": custom_prompt,
        "custom_analysis": custom_analysis,
        "source_node": tx_res.source_node,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="SDR Audio Transcription & Multimodal Intelligence Engine")
    parser.add_argument("--file", help="Path to single WAV/M4A audio file")
    parser.add_argument("--prompt", default="", help="Optional question/prompt for the Gemma-4 E4B audio encoder when using --file")
    parser.add_argument("--spool", action="store_true", help="Transcribe all pending calls in spool and recent archive")
    parser.add_argument("--upgrade-archive", action="store_true", help="Upgrade recent archived calls with Gemma-4 E4B multimodal refinement")
    parser.add_argument("--node-status", action="store_true", help="Check RX 5700 XT Vulkan whisper-server & E4B multimodal status")
    parser.add_argument("--json", action="store_true", help="Output JSON results")
    args = parser.parse_args()

    if args.node_status:
        stat = check_node_status()
        if args.json:
            print(json.dumps(stat, indent=2))
        else:
            print(f"Transcription Node: {stat['hardware']}")
            print(f"Status:            {stat['status']}")
            print(f"Endpoint:          {stat['endpoint']}")
            print(f"Details:           {stat['details']}")
        return

    if args.file:
        if args.prompt:
            res_dict = analyze_audio_with_encoder(Path(args.file), custom_prompt=args.prompt)
            if args.json:
                print(json.dumps(res_dict, indent=2))
            else:
                print(f"File:             {res_dict['audio_path']}")
                print(f"Source:           {res_dict['source_node']}")
                print(f"Tactical Summary: {res_dict['tactical_summary']}")
                print(f"Cleaned Tx:       {res_dict['transcript']}")
                print(f"Encoder Answer:   {res_dict['custom_analysis']}")
            return
        res = transcribe_audio_file(Path(args.file))
        if args.json:
            print(json.dumps(asdict(res), indent=2))
        else:
            print(f"File:             {res.audio_file}")
            print(f"Source:           {res.source_node}")
            print(f"Intelligible:     {res.intelligible} ({res.incident_type} / {res.priority})")
            print(f"Tactical Summary: {res.tactical_summary}")
            print(f"Cleaned Tx:       {res.transcript}")
            print(f"Raw Whisper:      {res.raw_transcript}")
        return

    if args.spool or args.upgrade_archive:
        res_list = transcribe_spool(force_multimodal_upgrade=args.upgrade_archive)
        if args.json:
            print(json.dumps({"status": "ok", "transcribed_count": len(res_list), "transcriptions": res_list}, indent=2))
        else:
            print(f"[OK] Transcribed/refined {len(res_list)} audio call(s).")
        return

    parser.print_help()


if __name__ == "__main__":
    main()
