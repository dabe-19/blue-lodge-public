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
import fcntl
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
    for env_path in [
        _GEORGE_DIR / "secrets.env",
        _GEORGE_DIR / "endpoints.conf",
        _GEORGE_DIR / "configs" / "remote.conf",
        _GEORGE_DIR / "remote.conf",
        _REPO_ROOT / ".env",
    ]:
        if env_path.exists():
            for line in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
                line = line.strip()
                if line.startswith("export "):
                    line = line[7:].strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


_load_secrets_env()

_TIER1_URL = (os.environ.get("TIER1_URL") or os.environ.get("LLM_BASE_URL") or "http://127.0.0.1:8080").rstrip("/")
_TIER2_URL = (os.environ.get("TIER2_URL") or "http://127.0.0.1:18080").rstrip("/")
_TIER2_NAME = os.environ.get("TIER2_NAME") or os.environ.get("REMOTE_NODE_NAME") or "tier-2"
_TIER2_MODEL = os.environ.get("TIER2_MODEL") or "gemma-4-E4B"
_TIER2_HW = os.environ.get("TIER2_HARDWARE") or "RX 5700 XT (Vulkan)"
_LLM_BASE = _TIER1_URL
INFERENCE_MODE = os.environ.get("SDR_INFERENCE_MODE", "dedicated").strip().lower()
CAPTURE_MODE = os.environ.get("SDR_CAPTURE_MODE", "remote_ssh").strip().lower()

DEFAULT_ENDPOINTS = [
    os.environ.get("SDR_TRANSCRIPTION_ENDPOINT", ""),
    "http://127.0.0.1:18090/inference",
    "http://127.0.0.1:8090/inference",
]
MULTIMODAL_ENDPOINTS = [
    os.environ.get("SDR_MULTIMODAL_ENDPOINT", ""),
    f"{_LLM_BASE}/v1/chat/completions" if INFERENCE_MODE == "shared_local" else f"{_TIER2_URL}/v1/chat/completions",
    f"{_TIER2_URL}/v1/chat/completions",
] + ([f"{_LLM_BASE}/v1/chat/completions"] if INFERENCE_MODE == "shared_local" else [])
# Deduplicate while preserving order
MULTIMODAL_ENDPOINTS = list(dict.fromkeys([ep for ep in MULTIMODAL_ENDPOINTS if ep]))
DEFAULT_HOST = os.environ.get("SDR_GATEWAY_HOST") or _TIER2_NAME
_DEFAULT_SOURCE_WHISPER = f"{DEFAULT_HOST}:rx5700xt_vulkan:8090"
_DEFAULT_SOURCE_MM = f"{DEFAULT_HOST}:rx5700xt_vulkan:8090+e4b:8080"


# Sovereign IPC FIFO Priority Constants (aligned with lib/ipc/fifo_ipc.sh)
PRIO_INTERACTIVE_AUDIO = 100  # Discord voice messages, CLI --voice, file_read, non-SDR audio
PRIO_SDR_EMERGENCY = 70       # Emergency P25 radio dispatches
PRIO_SDR_RADIO = 50           # Routine background SDR radio spool transcriptions
_TIER1_MODEL = os.environ.get("TIER1_MODEL") or "qwen38-27b"

AUDIO_EXTENSIONS = {
    ".ogg", ".oga", ".opus", ".mp3", ".wav", ".m4a",
    ".flac", ".aac", ".wma", ".amr", ".caf", ".aiff",
}


def _slot_dir_for_tier(tier: int = 2, ipc_dir: Path | None = None) -> Path:
    base = ipc_dir or Path(os.environ.get("FIFO_IPC_DIR") or (_GEORGE_DIR / "ipc"))
    if int(tier) == 1:
        return base / "inference_slots" / "slot_0"
    return base / "inference_slots" / f"tier_{tier}"


def _pid_is_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def _has_higher_priority_waiter(
    tier: int = 2,
    my_priority: int = PRIO_SDR_RADIO,
    my_start_ts: int | None = None,
    my_pid: int | None = None,
    ipc_dir: Path | None = None,
) -> bool:
    """Return True if a higher-priority (or earlier equal-priority) live waiter is queued in FIFO `waiters/`."""
    slot_dir = _slot_dir_for_tier(tier, ipc_dir)
    waiters_dir = slot_dir / "waiters"
    if not waiters_dir.is_dir():
        return False
    pid = my_pid if my_pid is not None else os.getpid()
    try:
        for wf in list(waiters_dir.glob("*.wait")):
            parts = wf.stem.split("_", 2)
            if len(parts) < 3:
                continue
            try:
                w_prio = int(parts[0])
                w_ts = int(parts[1])
                w_pid = int(parts[2])
            except ValueError:
                continue
            if not _pid_is_alive(w_pid):
                try:
                    wf.unlink(missing_ok=True)
                except OSError:
                    pass
                continue
            if w_pid == pid:
                continue
            if w_prio > my_priority:
                return True
            if my_start_ts is not None and w_prio == my_priority and w_ts < my_start_ts:
                return True
    except Exception:
        pass
    return False


class _IpcPrioritySlotLease:
    """Acquires a Tier inference slot via Sovereign FIFO Priority Waiters & Lease Preemption.

    Ensures Discord / interactive non-SDR audio transcriptions (`priority=100`) preempt
    background SDR radio transmissions (`priority=50`) and marks the tier's IPC credit
    channel busy during inference.
    """

    def __init__(
        self,
        task_name: str = "sdr_stage2_multimodal",
        priority: int = PRIO_SDR_RADIO,
        tier: int = 2,
        timeout: float = 45.0,
        ipc_dir: Path | None = None,
    ) -> None:
        self.task_name = task_name
        self.priority = int(priority)
        self.tier = int(tier)
        self.timeout = float(timeout)
        self.ipc_dir = ipc_dir or Path(os.environ.get("FIFO_IPC_DIR") or (_GEORGE_DIR / "ipc"))
        self.slot_dir = _slot_dir_for_tier(self.tier, self.ipc_dir)
        self.lease_file = self.slot_dir / "lease.json"
        self.lock_file = self.slot_dir / "lease.lock"
        self.waiters_dir = self.slot_dir / "waiters"
        self.chan_state_file = self.ipc_dir / "channels" / f"tier_{self.tier}_slot" / "state.json"
        self.waiter_file: Path | None = None
        self.acquired = False

    def _try_claim_locked(self, pid: int, start_ts: int) -> bool:
        now = int(time.time())
        if _has_higher_priority_waiter(
            tier=self.tier,
            my_priority=self.priority,
            my_start_ts=start_ts,
            my_pid=pid,
            ipc_dir=self.ipc_dir,
        ):
            return False

        if self.lease_file.exists():
            try:
                cur = json.loads(self.lease_file.read_text(encoding="utf-8"))
            except Exception:
                cur = {}
            cur_pid = int(cur.get("holder_pid") or 0)
            cur_prio = int(cur.get("priority") or 0)
            cur_task = str(cur.get("task_name") or "")
            acq_ts = int(cur.get("acquired_at") or 0)

            can_claim = False
            if cur_pid == pid or cur_task == self.task_name:
                can_claim = True
            elif not _pid_is_alive(cur_pid):
                can_claim = True
            elif self.priority > cur_prio:
                can_claim = True
            elif cur_prio < PRIO_INTERACTIVE_AUDIO and (now - acq_ts) > 120:
                can_claim = True

            if not can_claim:
                return False

        tmp_lease = self.lease_file.with_suffix(f".tmp.{pid}")
        tmp_lease.write_text(
            json.dumps({
                "holder_pid": pid,
                "priority": self.priority,
                "task_name": self.task_name,
                "acquired_at": now,
            }),
            encoding="utf-8",
        )
        os.replace(tmp_lease, self.lease_file)
        return True

    def __enter__(self) -> "_IpcPrioritySlotLease":
        try:
            self.slot_dir.mkdir(parents=True, exist_ok=True)
            self.waiters_dir.mkdir(parents=True, exist_ok=True)
            pid = os.getpid()
            start_ts = int(time.time())
            self.waiter_file = self.waiters_dir / f"{self.priority:03d}_{start_ts:010d}_{pid}.wait"
            try:
                self.waiter_file.write_text(f"{pid}|{self.priority}|{self.task_name}\n", encoding="utf-8")
            except OSError:
                pass

            deadline = time.monotonic() + max(0.5, self.timeout)
            while True:
                claimed = False
                try:
                    with open(self.lock_file, "a+", encoding="utf-8") as lf:
                        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
                        try:
                            claimed = self._try_claim_locked(pid, start_ts)
                        finally:
                            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
                except Exception:
                    claimed = self._try_claim_locked(pid, start_ts)

                if claimed:
                    self.acquired = True
                    if self.waiter_file and self.waiter_file.exists():
                        self.waiter_file.unlink(missing_ok=True)
                    if self.chan_state_file.exists():
                        now = int(time.time())
                        st = json.loads(self.chan_state_file.read_text(encoding="utf-8"))
                        st["credits"] = 0
                        st["backpressure"] = True
                        st["paused_by"] = pid
                        st["last_activity"] = now
                        tmp_st = self.chan_state_file.with_suffix(f".tmp.{pid}")
                        tmp_st.write_text(json.dumps(st), encoding="utf-8")
                        os.replace(tmp_st, self.chan_state_file)
                    break

                if time.monotonic() >= deadline:
                    if self.waiter_file and self.waiter_file.exists():
                        self.waiter_file.unlink(missing_ok=True)
                    break
                time.sleep(0.05)
        except Exception:
            pass
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        try:
            if self.waiter_file and self.waiter_file.exists():
                self.waiter_file.unlink(missing_ok=True)
            pid = os.getpid()
            if self.lease_file.exists():
                try:
                    with open(self.lock_file, "a+", encoding="utf-8") as lf:
                        fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
                        try:
                            cur = json.loads(self.lease_file.read_text(encoding="utf-8"))
                            cur_pid = int(cur.get("holder_pid") or 0)
                            cur_task = str(cur.get("task_name") or "")
                            if cur_pid == pid or cur_task == self.task_name or not _pid_is_alive(cur_pid):
                                self.lease_file.unlink(missing_ok=True)
                        finally:
                            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
                except Exception:
                    self.lease_file.unlink(missing_ok=True)
            if self.chan_state_file.exists():
                now = int(time.time())
                st = json.loads(self.chan_state_file.read_text(encoding="utf-8"))
                st["credits"] = int(st.get("window_size") or 1)
                st["backpressure"] = False
                st["paused_by"] = 0
                st["last_activity"] = now
                tmp_st = self.chan_state_file.with_suffix(f".tmp.{pid}")
                tmp_st.write_text(json.dumps(st), encoding="utf-8")
                os.replace(tmp_st, self.chan_state_file)
        except Exception:
            pass


class _Tier2IpcSlotLease(_IpcPrioritySlotLease):
    """Backward-compatible alias for Tier 2 IPC slot lease with configurable priority."""

    def __init__(
        self,
        task_name: str = "sdr_stage2_multimodal",
        priority: int = PRIO_SDR_RADIO,
        timeout: float = 45.0,
    ) -> None:
        super().__init__(task_name=task_name, priority=priority, tier=2, timeout=timeout)


def probe_tier1_audio_encoder(base_url: str | None = None, timeout: float = 2.0) -> dict[str, Any]:
    """Probe the Primary 27B model endpoint (`TIER1_URL`, default `:8080`) to check if it has an active audio encoder."""
    target_base = (base_url or _TIER1_URL or "http://127.0.0.1:8080").rstrip("/")
    forced_audio = os.environ.get("TIER1_AUDIO_ENABLED", "").strip().lower() in ("1", "true", "yes")
    model_name = _TIER1_MODEL
    online = False
    modalities: dict[str, Any] = {}
    audio_supported = forced_audio

    try:
        req = urllib.request.Request(f"{target_base}/props", headers={"User-Agent": "GeorgeSDR/2.0"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status == 200:
                online = True
                props = json.loads(resp.read().decode("utf-8", errors="replace"))
                if isinstance(props, dict):
                    modalities = dict(props.get("modalities") or {})
                    if bool(modalities.get("audio", False)):
                        audio_supported = True
                    mpath = str(props.get("model_path") or "").strip()
                    if mpath:
                        model_name = mpath
    except Exception:
        pass

    if not online:
        try:
            req_h = urllib.request.Request(f"{target_base}/health", headers={"User-Agent": "GeorgeSDR/2.0"})
            with urllib.request.urlopen(req_h, timeout=timeout) as resp_h:
                if resp_h.status == 200:
                    online = True
        except Exception:
            pass

    return {
        "base_url": target_base,
        "endpoint": f"{target_base}/v1/chat/completions",
        "model": model_name,
        "online": online,
        "audio_supported": bool(online and audio_supported),
        "modalities": modalities,
    }
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
    source_node: str = _DEFAULT_SOURCE_MM
    duration_secs: float = 0.0
    emergency: bool = False
    matched_keywords: list[str] = field(default_factory=list)
    timestamp: int = 0


def check_node_status() -> dict[str, Any]:
    """Check health and availability of the Whisper ASR server, Gemma-4 E4B multimodal server, and Tier 1 27B audio fallback."""
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

    t1_audio = probe_tier1_audio_encoder(_TIER1_URL)

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
                        f"{DEFAULT_HOST} · {_TIER2_HW} (Whisper P25-A100-LoRA + {_TIER2_MODEL})"
                        if mm_online
                        else f"{DEFAULT_HOST} · {_TIER2_HW} (Vulkan0 whisper-server P25-A100-LoRA)"
                    )
                    return {
                        "host": host,
                        "port": port,
                        "endpoint": endpoint,
                        "multimodal_endpoint": active_mm_ep,
                        "multimodal_online": mm_online,
                        "tier1_audio_fallback": t1_audio,
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
        "tier1_audio_fallback": t1_audio,
        "capture_mode": CAPTURE_MODE,
        "inference_mode": INFERENCE_MODE,
        "hardware": "AMD Radeon RX 5700 XT (8GB VRAM / Vulkan)",
        "online": False,
        "status": "OFFLINE",
        "details": "Whisper Vulkan node unreachable on :18090/:8090 (fallback active)",
    }


def is_audio_file(file_path: Path | str) -> bool:
    """Auto-detect whether a file is an audio recording via extension and MIME/stream inspection."""
    p = Path(file_path)
    if not p.is_file():
        return False
    ext = p.suffix.lower()
    if ext in AUDIO_EXTENSIONS:
        return True
    # Reject obvious image/text/document extensions immediately
    if ext in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".pdf", ".txt", ".md", ".json", ".csv", ".py", ".sh"}:
        return False
    try:
        proc = subprocess.run(
            ["file", "--mime-type", "-b", str(p)],
            capture_output=True, text=True, timeout=3,
        )
        mime = (proc.stdout or "").strip().lower()
        if mime.startswith("audio/") or mime in ("application/ogg", "video/ogg"):
            return True
    except Exception:
        pass
    if ext in (".webm", ".mp4", "") or not ext:
        try:
            proc_ff = subprocess.run(
                [
                    "ffprobe", "-v", "error", "-show_entries", "stream=codec_type",
                    "-of", "csv=p=0", str(p),
                ],
                capture_output=True, text=True, timeout=4,
            )
            streams = [s.strip().lower() for s in (proc_ff.stdout or "").splitlines() if s.strip()]
            if "audio" in streams and "video" not in streams:
                return True
        except Exception:
            pass
    return False


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
VOICE_AUDIO_FILTER = "dynaudnorm=f=150:g=15"


def _load_sdr_local_context() -> dict[str, str]:
    for cand in (
        _GEORGE_DIR / "config" / "sdr_local_context.json",
        _REPO_ROOT / ".george" / "config" / "sdr_local_context.json",
        _REPO_ROOT / "configs" / "sdr_local_context.example.json",
    ):
        if cand.exists():
            try:
                return json.loads(cand.read_text(encoding="utf-8"))
            except Exception:
                pass
    return {}


_SDR_LOCAL_CTX = _load_sdr_local_context()
WHISPER_DOMAIN_PROMPT = _SDR_LOCAL_CTX.get(
    "whisper_prompt_vocab",
    "Dispatch, 10-4, copy, en route, on scene, clear, traffic stop, medical, ambulance, fire, rescue, sheriff, deputy, officer, sergeant, City Fire, County EMS, Metro PD, County Sheriff, Main Street, County Road, Highway 101, Memorial Hospital, squad, medic, engine.",
)
_SDR_UNIT_ID_PATTERNS = _SDR_LOCAL_CTX.get(
    "unit_id_patterns",
    "Dispatch consoles: 1001/1002; Metro PD squads: 21xx; County Sheriff deputies: 31xx; Fire/EMS apparatus: 51xx/61xx",
)
_SDR_REGIONAL_CONTEXT = _SDR_LOCAL_CTX.get(
    "regional_context_hint",
    "regional municipal context (Metro PD, County Sheriff, City Fire, County EMS, Main St, Highway 101, Memorial Hospital)",
)
_SDR_EXAMPLE_SUMMARY = _SDR_LOCAL_CTX.get(
    "example_tactical_summary",
    "Unit 2104 acknowledged (10-4) City Fire Dispatch's assignment to the medical call on Main St.",
)
WHISPER_VOICE_PROMPT = "Natural conversational voice message transcription with accurate punctuation."
_NON_SPEECH_PATTERN = re.compile(
    r"\[(?:BLANK_AUDIO|Silence|Music|Noise|Inaudible|phone ringing|bell ringing|chimes|beeping)\]"
    r"|\((?:blank audio|silence|music|noise|phone ringing|bell ringing|chimes|beeping|tone|tones|buzzing|static)\)",
    flags=re.IGNORECASE,
)


def _prepare_16khz_wav_bytes(
    audio_path: Path,
    start_sec: float | None = None,
    duration_sec: float | None = None,
    audio_filter: str = P25_AUDIO_FILTER,
) -> tuple[bytes, float]:
    """Convert any WAV/M4A/OGG/MP3 file (or segment) to normalized 16 kHz mono 16-bit PCM WAV bytes."""
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
        cmd.extend(["-i", str(audio_path)])
        if audio_filter:
            cmd.extend(["-af", audio_filter])
        cmd.extend(["-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(tmp_path)])
        proc = subprocess.run(cmd, capture_output=True, timeout=20)
        if proc.returncode == 0 and tmp_path.exists() and tmp_path.stat().st_size > 64:
            try:
                with wave.open(str(tmp_path), "rb") as wf:
                    seg_dur = round(wf.getnframes() / float(wf.getframerate() or 16000), 2)
                    if seg_dur > 0:
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


def _prepare_voice_16khz_wav_bytes(
    audio_path: Path,
    max_duration_sec: float | None = 180.0,
) -> tuple[bytes, float]:
    """Convert any general voice/audio file (.ogg, .mp3, .wav, .m4a, .flac, etc.) to full-bandwidth 16 kHz mono WAV."""
    return _prepare_16khz_wav_bytes(
        audio_path,
        start_sec=None,
        duration_sec=max_duration_sec,
        audio_filter=VOICE_AUDIO_FILTER,
    )


def _post_multipart_whisper(
    endpoint: str,
    wav_bytes: bytes,
    filename: str = "audio.wav",
    prompt: str = WHISPER_DOMAIN_PROMPT,
    priority: int = PRIO_SDR_RADIO,
    use_lease: bool = True,
) -> dict[str, Any]:
    """Send multipart/form-data POST to whisper.cpp whisper-server `/inference` under FIFO priority lease."""
    boundary = f"----GeorgeSDRBoundary{uuid.uuid4().hex}"
    body = io.BytesIO()

    def write_field(name: str, value: str) -> None:
        body.write(f"--{boundary}\r\n".encode("utf-8"))
        body.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"))
        body.write(f"{value}\r\n".encode("utf-8"))

    write_field("response_format", "json")
    write_field("temperature", "0.0")
    write_field("prompt", prompt)

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
    if use_lease:
        with _IpcPrioritySlotLease(task_name=f"whisper_{filename}", priority=priority, tier=2, timeout=30.0):
            with urllib.request.urlopen(req, timeout=20.0) as resp:
                return json.loads(resp.read().decode("utf-8", errors="replace"))
    with urllib.request.urlopen(req, timeout=20.0) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def _transcribe_whisper_segments(
    endpoint: str,
    audio_path: Path,
    full_wav_bytes: bytes,
    meta: dict[str, Any],
    total_duration: float,
    priority: int = PRIO_SDR_RADIO,
) -> str:
    """Transcribe multi-segment P25 calls per `freqList` transmission slice so initial paging tones never truncate speech."""
    freq_list = [x for x in (meta.get("freqList") or []) if isinstance(x, dict) and float(x.get("len", 0.0)) >= 0.55]
    src_list = [x for x in (meta.get("srcList") or []) if isinstance(x, dict)]

    # Use per-segment decoding whenever there are >=2 segments or the call is >12s
    if len(freq_list) >= 2:
        seg_parts: list[str] = []
        tone_only_parts: list[str] = []
        for idx, seg in enumerate(freq_list):
            if priority < PRIO_INTERACTIVE_AUDIO and _has_higher_priority_waiter(2, priority):
                time.sleep(0.25)
            pos = float(seg.get("pos", 0.0))
            length = float(seg.get("len", 0.0))
            unit_id = int(src_list[idx].get("src", 0)) if idx < len(src_list) else 0
            seg_wav, _ = _prepare_16khz_wav_bytes(audio_path, start_sec=pos, duration_sec=length)
            try:
                res_data = _post_multipart_whisper(
                    endpoint, seg_wav, filename=f"{audio_path.stem}_seg{idx}.wav", priority=priority
                )
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
    res_data = _post_multipart_whisper(endpoint, full_wav_bytes, filename=f"{audio_path.stem}.wav", priority=priority)
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
    priority: int = PRIO_SDR_RADIO,
) -> dict[str, Any] | None:
    """Feed 16 kHz WAV audio + TrunkRecorder metadata + Running Context Buffer + raw Whisper draft into Gemma-4 E4B on george-home (or Tier 1 27B audio fallback if Tier 2 is offline)."""
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
- System: {meta.get('system', 'regional_p25')}
- Talkgroup: {tg} ({tag} — {desc})
- Agency / Category: {group} ({group_tag})
- Voice Frequency: {freq_mhz} MHz
- Duration: {rf['duration_secs']:.1f}s ({max(1, len(units))} transmission segment(s), {len(unique_units)} unique radio unit(s))
- Radio Unit IDs: {units} ({_SDR_UNIT_ID_PATTERNS})
- RF Decode Quality: {rf['rf_quality']} (bit_errors={rf['error_count']}, spikes={rf['spike_count']})
- Raw Whisper ASR Draft (frequently mangles radio ten-codes & street names): "{raw_whisper}"

RUNNING CONTEXT BUFFER (Prior Linked Events for {tag}, Participating Units {unique_units}, and {freq_mhz} MHz):
{running_context}

Listen carefully to the attached P25 audio and combine it with the CALL METADATA, RUNNING CONTEXT BUFFER, and Raw Whisper Draft to produce an accurate transcription and a continuous operational narrative.
Rules:
1. RECOGNIZING "10-4" AND RADIO TEN-CODES: "10-4" (acknowledged/understood) is spoken constantly on P25 radio, especially in short 1s–3s responses after a dispatch or status check. Because the P25 IMBE vocoder clips the initial "t" at key-up, raw Whisper very frequently mishears "10-4" as "for now", "3.4 now", "204", "ten for", "in for", "can for", "10 floor", "104", "7-2", "time for", or "and four". Listen carefully to the two-syllable "ten-four" cadence in the audio and check the RUNNING CONTEXT BUFFER: when a speaker says "10-4" (e.g., "10-4", "10-4, en route", or "<unit>, 10-4"), always transcribe it accurately as "10-4".
2. COMPLETE MULTI-SEGMENT TRANSCRIPTION: Transcribe the ENTIRE radio communication across all segments and fix phonetic ASR errors using {_SDR_REGIONAL_CONTEXT}.
3. CONTINUOUS UNIT & DEPARTMENT NARRATIVE: Use the RUNNING CONTEXT BUFFER to understand what transpired with these units and this department prior to this call.
   - In "tactical_summary", write a 1–2 sentence summary of THIS transmission that explicitly connects it to the prior context (e.g., "{_SDR_EXAMPLE_SUMMARY}").
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

    candidate_targets: list[tuple[str, str, int]] = [
        (ep, "gemma-4-E4B", 2) for ep in MULTIMODAL_ENDPOINTS if ep
    ]
    t1_probe = probe_tier1_audio_encoder(_TIER1_URL)
    if t1_probe.get("audio_supported"):
        t1_ep = str(t1_probe["endpoint"])
        if not any(ep == t1_ep for ep, _, _ in candidate_targets):
            candidate_targets.append((t1_ep, str(t1_probe.get("model") or _TIER1_MODEL), 1))

    for endpoint, model_id, tier_num in candidate_targets:
        payload = {
            "model": model_id,
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
        try:
            req = urllib.request.Request(
                endpoint,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json", "User-Agent": "GeorgeSDR/2.0"},
            )
            with _IpcPrioritySlotLease(
                task_name=f"sdr_stage2_multimodal_t{tier_num}",
                priority=priority,
                tier=tier_num,
                timeout=timeout,
            ):
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
                    parsed["_source_tier"] = tier_num
                    _update_narrative_state(meta, rf, parsed)
                    return parsed
        except Exception as e:
            logger.warning(f"Multimodal refinement warning via {endpoint} (tier {tier_num}): {e}")
            continue
    return None


def transcribe_with_multimodal_encoder(
    wav_bytes: bytes,
    endpoint: str,
    model: str = "gemma-4-E4B",
    tier: int = 2,
    priority: int = PRIO_INTERACTIVE_AUDIO,
    raw_whisper: str = "",
    custom_prompt: str = "",
    timeout: float = 55.0,
) -> dict[str, Any] | None:
    """Transcribe or refine general voice/audio using a Multimodal Audio Encoder (Tier 2 Gemma-4 E4B or Tier 1 27B fallback)."""
    b64_audio = base64.b64encode(wav_bytes).decode("ascii")
    whisper_hint = (
        f'\nInitial Whisper ASR draft (use to assist, but fix any misheard words by listening directly to the audio): "{raw_whisper}"\n'
        if raw_whisper
        else ""
    )
    extra_q = (
        f'\nAlso answer this specific question about the audio in the "analysis" field: "{custom_prompt.strip()}"\n'
        if custom_prompt and custom_prompt.strip()
        else ""
    )
    prompt = (
        "Listen carefully to the attached voice/audio recording and produce an accurate, verbatim transcription of everything spoken."
        f"{whisper_hint}{extra_q}\n"
        "Rules:\n"
        "1. Transcribe the speaker's exact words naturally with proper punctuation.\n"
        "2. Only set \"intelligible\": false if the recording contains no discernible human speech (pure silence, static, or noise).\n"
        "3. Provide a concise 1-sentence \"summary\" of the message.\n\n"
        "Respond ONLY with valid JSON matching this schema:\n"
        "{\n"
        '  "intelligible": true,\n'
        '  "transcript": "Complete verbatim transcription of the spoken message",\n'
        '  "summary": "Concise 1-sentence summary of the voice message",\n'
        '  "analysis": "Optional answer if a specific question was asked, otherwise empty string"\n'
        "}"
    )
    payload = {
        "model": model,
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
        "max_tokens": 600,
    }
    try:
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "GeorgeSDR/2.0"},
        )
        with _IpcPrioritySlotLease(
            task_name=f"voice_multimodal_t{tier}",
            priority=priority,
            tier=tier,
            timeout=timeout,
        ):
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                res = json.loads(resp.read().decode("utf-8", errors="replace"))
        msg = res["choices"][0]["message"]
        raw_content = (msg.get("content") or msg.get("reasoning_content") or "").strip()
        m = re.search(r"\{.*\}", raw_content, flags=re.DOTALL)
        if m:
            parsed = json.loads(m.group(0))
            if isinstance(parsed, dict) and ("transcript" in parsed or "corrected_transcript" in parsed):
                tx = str(parsed.get("transcript") or parsed.get("corrected_transcript") or "").strip()
                parsed["transcript"] = tx
                return parsed
        elif raw_content:
            return {
                "intelligible": True,
                "transcript": raw_content,
                "summary": raw_content[:140],
                "analysis": "",
            }
    except Exception as e:
        logger.warning(f"Voice multimodal encoder warning via {endpoint} (tier {tier}): {e}")
    return None


def transcribe_voice_file(
    audio_path: Path | str,
    priority: int = PRIO_INTERACTIVE_AUDIO,
    source: str = "discord",
    custom_prompt: str = "",
) -> dict[str, Any]:
    """Transcribe a general voice message or non-SDR audio file (.ogg, .mp3, .wav, .m4a, .flac, etc.).

    - Uses the Sovereign FIFO Priority System: any non-SDR source (`discord`, `cli`, `file_read`, `sdr_listen`)
      runs at `priority >= 100` (`PRIO_INTERACTIVE_AUDIO`), preempting SDR radio transmissions (`priority = 50`).
    - When the SDR/Tier-2 server (`:18090` Whisper & `:18080` Gemma-4 E4B) is powered down, probes the
      Primary 27B model (`TIER1_URL/props`) and falls back to its audio encoder if `modalities.audio == true`.
    """
    p = Path(audio_path)
    ts = int(time.time())
    src_norm = (source or "discord").strip().lower()
    if src_norm in ("sdr", "sdr_spool", "trunk_recorder"):
        eff_prio = int(priority) if priority else PRIO_SDR_RADIO
    else:
        eff_prio = max(PRIO_INTERACTIVE_AUDIO, int(priority or PRIO_INTERACTIVE_AUDIO))

    if not p.is_file() or p.stat().st_size <= 32:
        return {
            "status": "error",
            "intelligible": False,
            "audio_path": str(p),
            "audio_file": p.name,
            "transcript": "",
            "raw_transcript": "",
            "summary": f"Audio file '{p.name}' is missing or empty.",
            "analysis": "",
            "source_node": "none",
            "source": source,
            "priority_num": eff_prio,
            "duration_secs": 0.0,
            "timestamp": ts,
        }

    wav_bytes, duration = _prepare_voice_16khz_wav_bytes(p)
    node_stat = check_node_status()
    raw_whisper = ""
    whisper_used = False

    # Stage 1: Fast Whisper ASR on Tier 2 (:18090 / :8090) if online
    if node_stat.get("online"):
        try:
            res_data = _post_multipart_whisper(
                node_stat["endpoint"],
                wav_bytes,
                filename=f"{p.stem}.wav",
                prompt=WHISPER_VOICE_PROMPT,
                priority=eff_prio,
            )
            raw_text = (res_data.get("text") or "").strip()
            raw_whisper = _NON_SPEECH_PATTERN.sub("", raw_text).strip()
            whisper_used = True
        except Exception as e:
            logger.warning(f"Voice Whisper Stage-1 warning on {p.name}: {e}")

    # Stage 2: Tier 2 Multimodal Audio Encoder (:18080 Gemma-4 E4B) if online
    mm_result: dict[str, Any] | None = None
    source_node = _DEFAULT_SOURCE_WHISPER if whisper_used else "offline"

    if node_stat.get("multimodal_online") and node_stat.get("multimodal_endpoint"):
        mm_result = transcribe_with_multimodal_encoder(
            wav_bytes=wav_bytes,
            endpoint=str(node_stat["multimodal_endpoint"]),
            model=_TIER2_MODEL,
            tier=2,
            priority=eff_prio,
            raw_whisper=raw_whisper,
            custom_prompt=custom_prompt,
        )
        if mm_result and mm_result.get("transcript"):
            source_node = _DEFAULT_SOURCE_MM if whisper_used else f"{DEFAULT_HOST}:e4b:18080"

    # Stage 3 Fallback: If SDR/Tier-2 server is powered down (no Whisper & no Tier-2 Multimodal),
    # probe the Primary 27B model (`TIER1_URL`) and use its audio encoder if `modalities.audio == true`.
    t1_info = node_stat.get("tier1_audio_fallback") or probe_tier1_audio_encoder(_TIER1_URL)
    if not mm_result and not raw_whisper:
        if t1_info.get("audio_supported"):
            t1_ep = str(t1_info["endpoint"])
            t1_model = str(t1_info.get("model") or _TIER1_MODEL)
            mm_result = transcribe_with_multimodal_encoder(
                wav_bytes=wav_bytes,
                endpoint=t1_ep,
                model=t1_model,
                tier=1,
                priority=eff_prio,
                raw_whisper="",
                custom_prompt=custom_prompt,
            )
            if mm_result and mm_result.get("transcript"):
                source_node = f"tier1_27b_audio:{t1_model}"

    if mm_result and mm_result.get("transcript"):
        transcript = str(mm_result["transcript"]).strip()
        intelligible = bool(mm_result.get("intelligible", True)) and bool(transcript)
        summary = str(mm_result.get("summary") or transcript[:160]).strip()
        analysis = str(mm_result.get("analysis") or "").strip()
        status_str = "ok"
    elif raw_whisper:
        transcript = raw_whisper
        intelligible = True
        summary = raw_whisper[:160]
        analysis = ""
        status_str = "ok"
    else:
        t1_model_label = str(t1_info.get("model") or _TIER1_MODEL)
        t1_has_audio = bool(t1_info.get("audio_supported", False))
        if not node_stat.get("online") and not node_stat.get("multimodal_online") and not t1_has_audio:
            status_str = "audio_encoder_offline"
            summary = (
                f"Audio file '{p.name}' ({duration:.1f}s) could not be transcribed because the SDR/Tier-2 audio "
                f"server is powered down and the primary 27B model ({t1_model_label}) does not have an audio encoder "
                f"enabled (modalities.audio=false)."
            )
        else:
            status_str = "unintelligible"
            summary = f"No intelligible speech detected in '{p.name}' ({duration:.1f}s)."
        transcript = ""
        intelligible = False
        analysis = ""

    out = {
        "status": status_str,
        "intelligible": intelligible,
        "audio_path": str(p.resolve()),
        "audio_file": p.name,
        "transcript": transcript,
        "raw_transcript": raw_whisper or transcript,
        "summary": summary,
        "analysis": analysis,
        "source_node": source_node,
        "source": source,
        "priority_num": eff_prio,
        "duration_secs": duration,
        "tier1_audio_supported": bool(t1_info.get("audio_supported", False)),
        "timestamp": ts,
    }
    if intelligible and transcript:
        emit_event(
            "voice_transcription_complete",
            {
                "audio_file": p.name,
                "audio_path": str(p.resolve()),
                "transcript": transcript,
                "summary": summary,
                "source": source,
                "priority_num": eff_prio,
                "source_node": source_node,
                "duration_secs": duration,
            },
        )
    return out


def transcribe_audio_file(
    audio_path: Path,
    meta: dict[str, Any] | None = None,
    use_multimodal: bool = True,
    priority: int | None = None,
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

    sdr_prio = (
        int(priority)
        if priority is not None
        else (PRIO_SDR_EMERGENCY if meta.get("emergency") else PRIO_SDR_RADIO)
    )

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
                node_stat["endpoint"], audio_path, wav_bytes, meta, duration, priority=sdr_prio
            )
        except Exception as e:
            logger.warning(f"Remote RX 5700 XT Vulkan Whisper failed ({e})")

    # Check if Whisper produced any candidate speech or if the call is >= 0.9s (to catch 1s-2s "10-4" acknowledgments!)
    has_whisper_speech = bool(
        raw_whisper
        and len(raw_whisper) > 1
        and raw_whisper.lower() not in (".", "uh", "um")
    )

    is_backlog_call = (ts - int(meta.get("start_time") or ts)) > 1800
    if not has_whisper_speech and ((rf["rf_quality"] == "GARBLED_QPSK" and duration < 1.5) or (is_backlog_call and duration < 2.2)):
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
            source_node=_DEFAULT_SOURCE_WHISPER,
            duration_secs=duration,
            emergency=bool(meta.get("emergency", 0)),
            matched_keywords=[],
            timestamp=ts,
        )

    # Yield before Stage 2 if a higher-priority (e.g. Discord priority=100) waiter is queued
    if sdr_prio < PRIO_INTERACTIVE_AUDIO and _has_higher_priority_waiter(2, sdr_prio):
        time.sleep(0.3)

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

        mm_res = refine_with_gemma4_multimodal(e4b_wav_bytes, raw_whisper, meta, rf, priority=sdr_prio)
        if mm_res:
            is_intel = bool(mm_res.get("intelligible", True))
            corr_tx = str(mm_res.get("corrected_transcript") or raw_whisper).strip()
            tac_sum = str(mm_res.get("tactical_summary") or "").strip()
            inc_type = str(mm_res.get("incident_type") or "DISPATCH_STATUS").strip().upper()
            prio = str(mm_res.get("priority") or "ROUTINE").strip().upper()
            locs = [str(x) for x in (mm_res.get("locations_mentioned") or []) if x]
            src_node = (
                f"tier1_27b_audio:{_TIER1_MODEL}"
                if mm_res.get("_source_tier") == 1
                else _DEFAULT_SOURCE_MM
            )

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
                    source_node=src_node,
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
                source_node=src_node,
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
            source_node=_DEFAULT_SOURCE_WHISPER,
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
        if _has_higher_priority_waiter(2, PRIO_SDR_RADIO):
            time.sleep(0.35)
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
                and (node in ("rf_noise_gate", _DEFAULT_SOURCE_MM) or node.endswith(":rx5700xt_vulkan:8090+e4b:8080"))
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
- **System / Frequency:** `{call_data.get('system', 'regional_p25')}` | `{freq_mhz} MHz` (Err: `{call_data.get('error_count', 0)}`, Spikes: `{call_data.get('spike_count', 0)}`)
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

    # Auto-detect non-SDR general voice/audio files (e.g. Discord .ogg/.mp3 or files outside .george/sdr without P25 metadata)
    is_sdr_call = bool(
        meta.get("talkgroup")
        or meta.get("freq")
        or meta.get("freqList")
        or str(_SDR_DIR) in str(audio_path.resolve())
    )
    if not is_sdr_call:
        v_res = transcribe_voice_file(
            audio_path,
            priority=PRIO_INTERACTIVE_AUDIO,
            source="encoder_tool",
            custom_prompt=custom_prompt,
        )
        return {
            "status": v_res["status"],
            "audio_path": v_res["audio_path"],
            "audio_file": v_res["audio_file"],
            "call_id": audio_path.stem,
            "talkgroup": 0,
            "talkgroup_tag": "VOICE_MEDIA",
            "talkgroup_description": f"General Audio / Voice Recording ({v_res['source']})",
            "talkgroup_group": "Voice",
            "freq_mhz": 0.0,
            "duration_secs": v_res["duration_secs"],
            "rf_quality": "FULL_BANDWIDTH_AUDIO",
            "unit_ids": [],
            "intelligible": v_res["intelligible"],
            "incident_type": "VOICE_MESSAGE",
            "priority": f"INTERACTIVE (FIFO prio={v_res['priority_num']})",
            "emergency": False,
            "transcript": v_res["transcript"],
            "raw_transcript": v_res["raw_transcript"],
            "tactical_summary": v_res["summary"],
            "locations_mentioned": [],
            "running_context": "",
            "custom_prompt": custom_prompt,
            "custom_analysis": v_res.get("analysis", ""),
            "source_node": v_res["source_node"],
        }

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
    parser.add_argument("--voice", help="Path to general voice/audio file (.ogg, .mp3, .wav, .m4a, .flac) for high-priority full-bandwidth transcription")
    parser.add_argument("--priority", type=int, default=PRIO_INTERACTIVE_AUDIO, help="IPC FIFO priority for --voice (default: 100 interactive, vs 50 for SDR radio)")
    parser.add_argument("--source", default="discord", help="Audio ingress source label (e.g. discord, cli, file_read, sdr)")
    parser.add_argument("--prompt", default="", help="Optional question/prompt for the Multimodal audio encoder when using --file or --voice")
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

    if args.voice:
        v_res = transcribe_voice_file(
            Path(args.voice),
            priority=args.priority,
            source=args.source,
            custom_prompt=args.prompt,
        )
        if args.json:
            print(json.dumps(v_res, indent=2))
        else:
            if v_res.get("transcript"):
                print(v_res["transcript"])
            else:
                print(v_res.get("summary") or f"[Unintelligible audio: {v_res.get('audio_file')}]")
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
