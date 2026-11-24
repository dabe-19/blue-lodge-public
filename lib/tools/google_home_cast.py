#!/usr/bin/env python3
"""
George: Sovereign Local Neural TTS & Google Home CastV2 Broadcast Engine
Synthesizes high-clarity speech on CPU via Piper ONNX (0 MB GPU VRAM impact)
with 4 selectable Male & Female voices (alan, ryan, amy, alba), enforces the
shared Discord/Escalation quiet-hours policy, and broadcasts over local LAN
Google CastV2 (8009/tcp) to Google Home / Nest speakers and displays.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import math
import os
import socket
import ssl
import struct
import sys
import time
import urllib.request
import uuid as uuid_mod
import wave
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

_REPO_ROOT = Path(__file__).resolve().parents[2]
_VENV_PY = _REPO_ROOT / ".venv" / "bin" / "python"
if __name__ == "__main__" and _VENV_PY.exists() and Path(sys.executable).resolve() != _VENV_PY.resolve():
    os.execv(str(_VENV_PY), [str(_VENV_PY), *sys.argv])
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

LODGE_DIR = Path(os.environ.get("LODGE_DIR", _REPO_ROOT))
GEORGE_DIR = Path(os.environ.get("GEORGE_DIR", LODGE_DIR / ".george"))
TTS_MODELS_DIR = GEORGE_DIR / "models" / "tts"
if not TTS_MODELS_DIR.exists() and (LODGE_DIR / ".george" / "models" / "tts").exists():
    TTS_MODELS_DIR = LODGE_DIR / ".george" / "models" / "tts"
CAST_AUDIO_DIR = GEORGE_DIR / "state" / "cast_audio"
CAST_HISTORY_FILE = GEORGE_DIR / "state" / "cast_history.jsonl"
CAST_CONFIG_FILE = GEORGE_DIR / "state" / "cast_config.json"
CAST_SPEAKERS_CFG_FILE = GEORGE_DIR / "config" / "cast_speakers.json"


def _load_speaker_inventory_config() -> Dict[str, Any]:
    for cand in (
        CAST_SPEAKERS_CFG_FILE,
        LODGE_DIR / ".george" / "config" / "cast_speakers.json",
        LODGE_DIR / "configs" / "cast_speakers.example.json",
    ):
        if cand.exists():
            try:
                return json.loads(cand.read_text(encoding="utf-8"))
            except Exception:
                pass
    return {}


_SPEAKER_INV_CFG = _load_speaker_inventory_config()

# Known Google Home / Cast devices loaded from .george/config/cast_speakers.json (or example fallback)
KNOWN_SPEAKERS: List[Dict[str, Any]] = _SPEAKER_INV_CFG.get(
    "known_speakers",
    [
        {
            "id": "kitchen",
            "name": "Kitchen Display 1",
            "hostname": "google-nest-hub-max.lan",
            "ip": "192.168.1.50",
            "mac": "aa:bb:cc:dd:ee:10",
            "model": "Google Nest Hub Max",
            "default": True,
        },
        {
            "id": "bedroom",
            "name": "Bedroom speaker",
            "hostname": "google-nest-mini.lan",
            "ip": "192.168.1.51",
            "mac": "aa:bb:cc:dd:ee:11",
            "model": "Google Nest Mini",
            "default": True,
        },
    ],
)

TTS_ENGINES: Dict[str, Dict[str, Any]] = {
    "kokoro": {
        "id": "kokoro",
        "label": "Kokoro-82M FP32 (StyleTTS2 24kHz — Studio Prosody, Auto-Fallback to Piper)",
        "model_file": "kokoro-v1.0.onnx",
        "voices_file": "voices-v1.0.bin",
        "sample_rate": 24000,
    },
    "kokoro_int8": {
        "id": "kokoro_int8",
        "label": "Kokoro-82M INT8 (89MB Compact CPU Mode, Auto-Fallback to Piper)",
        "model_file": "kokoro-v1.0.int8.onnx",
        "voices_file": "voices-v1.0.bin",
        "sample_rate": 24000,
    },
    "piper": {
        "id": "piper",
        "label": "Piper VITS ONNX (60MB Ultra-Fast Lightweight Fallback)",
        "model_file": "en_US-norman-medium.onnx",
        "voices_file": "",
        "sample_rate": 22050,
    },
}

VOICES: Dict[str, Dict[str, Any]] = {
    "washington": {
        "id": "washington",
        "model": "en_US-norman-medium.onnx",
        "kokoro_voice": "blend:am_michael:0.65,bm_george:0.35",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.95,
        "label": "Washington (18th-Century Statesman Baritone — George Default)",
        "gender": "male",
        "accent": "en_US",
    },
    "bm_george": {
        "id": "bm_george",
        "model": "en_GB-alan-medium.onnx",
        "kokoro_voice": "bm_george",
        "kokoro_lang": "en-gb",
        "kokoro_speed": 0.96,
        "label": "George (Classic British Statesman Baritone — Kokoro Native)",
        "gender": "male",
        "accent": "en_GB",
    },
    "bryce": {
        "id": "bryce",
        "model": "en_US-bryce-medium.onnx",
        "kokoro_voice": "am_michael",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.96,
        "label": "Bryce / Michael (Deep Resonant American Baritone)",
        "gender": "male",
        "accent": "en_US",
    },
    "am_fenrir": {
        "id": "am_fenrir",
        "model": "en_US-bryce-medium.onnx",
        "kokoro_voice": "am_fenrir",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.96,
        "label": "Fenrir (Commanding Deep American Orator)",
        "gender": "male",
        "accent": "en_US",
    },
    "alan": {
        "id": "alan",
        "model": "en_GB-alan-medium.onnx",
        "kokoro_voice": "bm_fable",
        "kokoro_lang": "en-gb",
        "kokoro_speed": 0.97,
        "label": "Alan / Fable (British Gentleman Narrator)",
        "gender": "male",
        "accent": "en_GB",
    },
    "ryan": {
        "id": "ryan",
        "model": "en_US-ryan-medium.onnx",
        "kokoro_voice": "am_adam",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.98,
        "label": "Ryan / Adam (Warm Modern American Male)",
        "gender": "male",
        "accent": "en_US",
    },
    "amy": {
        "id": "amy",
        "model": "en_US-amy-medium.onnx",
        "kokoro_voice": "af_heart",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.98,
        "label": "Amy / Heart (Expressive American Female — Grade A)",
        "gender": "female",
        "accent": "en_US",
    },
    "af_bella": {
        "id": "af_bella",
        "model": "en_US-amy-medium.onnx",
        "kokoro_voice": "af_bella",
        "kokoro_lang": "en-us",
        "kokoro_speed": 0.98,
        "label": "Bella (Warm Narrator American Female)",
        "gender": "female",
        "accent": "en_US",
    },
    "alba": {
        "id": "alba",
        "model": "en_GB-alba-medium.onnx",
        "kokoro_voice": "bf_emma",
        "kokoro_lang": "en-gb",
        "kokoro_speed": 0.98,
        "label": "Alba / Emma (Expressive British Female)",
        "gender": "female",
        "accent": "en_GB",
    },
}

VOICE_ALIASES: Dict[str, str] = {
    "washington": "washington",
    "george": "washington",
    "george_washington": "washington",
    "norman": "washington",
    "default": "washington",
    "statesman": "washington",
    "bm_george": "bm_george",
    "british_george": "bm_george",
    "bryce": "bryce",
    "am_michael": "bryce",
    "michael": "bryce",
    "deep_male": "bryce",
    "am_fenrir": "am_fenrir",
    "fenrir": "am_fenrir",
    "alan": "alan",
    "bm_fable": "alan",
    "fable": "alan",
    "british": "alan",
    "british_male": "alan",
    "uk_male": "alan",
    "ryan": "ryan",
    "am_adam": "ryan",
    "adam": "ryan",
    "male": "washington",
    "us_male": "washington",
    "american_male": "washington",
    "amy": "amy",
    "af_heart": "amy",
    "heart": "amy",
    "female": "amy",
    "us_female": "amy",
    "american_female": "amy",
    "af_bella": "af_bella",
    "bella": "af_bella",
    "alba": "alba",
    "bf_emma": "alba",
    "emma": "alba",
    "british_female": "alba",
    "uk_female": "alba",
    "scottish": "alba",
    "scottish_female": "alba",
}


def get_lan_ip() -> str:
    env_ip = os.environ.get("GEORGE_LAN_IP", "").strip()
    if env_ip:
        return env_ip
    cfg_ip = str(_SPEAKER_INV_CFG.get("lan_ip") or "").strip()
    if cfg_ip:
        return cfg_ip
    return "192.168.1.10"


def stage_audio_to_lan_relay(wav_path: Path) -> str:
    """Stage synthesized WAV to optional LAN HTTP relay so speakers bypass host/WSL2 firewall."""
    import subprocess
    filename = wav_path.name
    relay_host = os.environ.get("GEORGE_CAST_RELAY_SSH", str(_SPEAKER_INV_CFG.get("relay_ssh") or "")).strip()
    relay_ip = os.environ.get("GEORGE_CAST_RELAY_IP", str(_SPEAKER_INV_CFG.get("relay_ip") or "")).strip()
    relay_port = os.environ.get("GEORGE_CAST_RELAY_PORT", str(_SPEAKER_INV_CFG.get("relay_port") or "3000")).strip()
    relay_dir = os.environ.get("GEORGE_CAST_RELAY_DIR", str(_SPEAKER_INV_CFG.get("relay_remote_dir") or "")).strip()
    if relay_host and relay_ip and relay_dir:
        try:
            with open(wav_path, "rb") as f:
                r = subprocess.run(
                    [
                        "ssh",
                        "-o", "BatchMode=yes",
                        "-o", "ConnectTimeout=3",
                        relay_host,
                        f"cat > {relay_dir}/{filename}",
                    ],
                    stdin=f,
                    capture_output=True,
                    timeout=6.0,
                )
            if r.returncode == 0:
                return f"http://{relay_ip}:{relay_port}/api/cast/audio/{filename}"
        except Exception:
            pass
    web_port = os.environ.get("GEORGE_WEB_PORT", "3000")
    fallback_ip = str(_SPEAKER_INV_CFG.get("fallback_host_ip") or get_lan_ip()).strip()
    return f"http://{fallback_ip}:{web_port}/api/cast/audio/{filename}"


def resolve_voice(voice_key: Optional[str]) -> Dict[str, Any]:
    if not voice_key:
        cfg = load_cast_config()
        voice_key = cfg.get("default_voice", "washington")
    k = str(voice_key).strip().lower().replace("-", "_").replace(" ", "_")
    mapped = VOICE_ALIASES.get(k, "washington")
    return VOICES.get(mapped, VOICES["washington"])


def resolve_engine(engine_key: Optional[str] = None) -> str:
    if not engine_key or str(engine_key).strip().lower() in ("", "default", "auto"):
        cfg = load_cast_config()
        engine_key = cfg.get("default_engine", "kokoro")
    k = str(engine_key).strip().lower().replace("-", "_").replace(" ", "_")
    aliases = {
        "kokoro": "kokoro",
        "kokoro_onnx": "kokoro",
        "kokoro_82m": "kokoro",
        "kokoro_fp32": "kokoro",
        "fp32": "kokoro",
        "styletts2": "kokoro",
        "kokoro_int8": "kokoro_int8",
        "kokoro_82m_int8": "kokoro_int8",
        "kokoro_lite": "kokoro_int8",
        "int8": "kokoro_int8",
        "piper": "piper",
        "piper_tts": "piper",
        "piper_onnx": "piper",
        "vits": "piper",
        "fallback": "piper",
    }
    return aliases.get(k, "kokoro")


def get_available_engines() -> List[Dict[str, Any]]:
    engines_out: List[Dict[str, Any]] = []
    for eng_id, meta in TTS_ENGINES.items():
        model_path = TTS_MODELS_DIR / meta["model_file"]
        voices_path = (TTS_MODELS_DIR / meta["voices_file"]) if meta.get("voices_file") else None
        installed = model_path.exists() and (voices_path is None or voices_path.exists())
        size_bytes = model_path.stat().st_size if model_path.exists() else 0
        if voices_path and voices_path.exists():
            size_bytes += voices_path.stat().st_size
        engines_out.append({
            "id": eng_id,
            "label": meta["label"],
            "sample_rate": meta["sample_rate"],
            "installed": installed,
            "size_mb": round(size_bytes / (1024 * 1024), 1) if size_bytes else 0.0,
            "fallback_engine": "piper" if eng_id != "piper" else None,
        })
    return engines_out


def load_cast_config() -> Dict[str, Any]:
    default_cfg = {
        "default_engine": "kokoro",
        "default_voice": "washington",
        "default_speakers": ["Kitchen Display 1", "Bedroom speaker"],
        "speech_speed": 0.96,
        "chime_enabled": True,
    }
    if CAST_CONFIG_FILE.exists():
        try:
            data = json.loads(CAST_CONFIG_FILE.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                default_cfg.update(data)
        except Exception:
            pass
    return default_cfg


def save_cast_config(updates: Dict[str, Any]) -> Dict[str, Any]:
    cfg = load_cast_config()
    cfg.update(updates)
    CAST_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CAST_CONFIG_FILE.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return cfg


def get_quiet_hours_info() -> Dict[str, Any]:
    try:
        from lib.comms import escalation
        return escalation.quiet_hours_status()
    except Exception:
        return {
            "enabled": True,
            "active": False,
            "start": "22:00",
            "end": "07:00",
            "tz": "America/Chicago",
        }


def is_quiet_hours_active() -> bool:
    try:
        from lib.comms import escalation
        return bool(escalation.in_quiet_hours())
    except Exception:
        return False


def _generate_chime_pcm(sample_rate: int) -> bytes:
    """Generate a gentle 2-tone harmonic chime (A4 -> E5) so speakers wake cleanly."""
    notes = [(440.0, 0.14), (659.25, 0.22), (0.0, 0.14)]
    frames = bytearray()
    for freq, dur in notes:
        n_samples = int(sample_rate * dur)
        for i in range(n_samples):
            if freq == 0.0:
                val = 0
            else:
                t = i / sample_rate
                env = math.exp(-t * 10.0) * min(1.0, i / (sample_rate * 0.01))
                wave_v = 0.7 * math.sin(2.0 * math.pi * freq * t) + 0.3 * math.sin(4.0 * math.pi * freq * t)
                val = int(max(-32767, min(32767, wave_v * env * 9500)))
            frames.extend(struct.pack("<h", val))
    return bytes(frames)


def _normalize_text_for_speech(text: str) -> str:
    """Clean markdown, Roman numeral titles, and hyphenated handles for clear neural phonemization."""
    import re

    cleaned = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    cleaned = re.sub(r"\*([^*]+)\*", r"\1", cleaned)
    cleaned = re.sub(r"`([^`]+)`", r"\1", cleaned)
    cleaned = re.sub(r"^\s*[-•*]\s+", "", cleaned, flags=re.MULTILINE)

    # Expand Roman numeral suffixes after capitalized words (e.g. "Ambassador II" -> "Ambassador Two")
    roman_map = {"II": "Two", "III": "Three", "IV": "Four", "VI": "Six", "VII": "Seven", "VIII": "Eight"}
    cleaned = re.sub(
        r"\b([A-Z][a-zA-Z]+)\s+(II|III|IV|VI|VII|VIII)\b",
        lambda m: f"{m.group(1)} {roman_map.get(m.group(2), m.group(2))}",
        cleaned,
    )

    # Normalize em-dashes and ellipses into clean punctuation pauses
    cleaned = re.sub(r"\s*(?:—|–|--+)\s*", ", ", cleaned)
    cleaned = re.sub(r"\.\.\.+|…", ". ", cleaned)
    return cleaned.strip()


def _group_sentences_for_kokoro(text: str) -> List[Tuple[str, float]]:
    """
    Group prose into Goldilocks 1-2 sentence breath units (~65-185 chars) for Kokoro-82M.
    Kokoro natively models internal commas, colons, and semicolons via IPA punctuation tokens,
    while explicit inter-group breath pauses keep multi-paragraph broadcasts natural and unhurried.
    """
    import re

    cleaned = _normalize_text_for_speech(text)
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n+", cleaned) if p.strip()]
    groups: List[Tuple[str, float]] = []

    for p_idx, para in enumerate(paragraphs):
        para_flat = re.sub(r"\s+", " ", para).strip()
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", para_flat) if s.strip()]
        accum: List[str] = []
        for s in sentences:
            if s[-1] not in ".!?":
                s = s + "."
            accum.append(s)
            curr_len = sum(len(x) for x in accum) + max(0, len(accum) - 1)
            if curr_len >= 75:
                groups.append((" ".join(accum), 0.36))
                accum = []
        if accum:
            if groups and sum(len(x) for x in accum) < 28:
                prev_txt, _ = groups[-1]
                groups[-1] = (f"{prev_txt} {' '.join(accum)}", 0.38)
            else:
                groups.append((" ".join(accum), 0.38))

        if groups and p_idx < len(paragraphs) - 1:
            last_txt, last_p = groups[-1]
            groups[-1] = (last_txt, max(last_p, 0.58))

    return groups or [(cleaned or text.strip(), 0.38)]


def _segment_text_with_prosody(text: str) -> List[Tuple[str, float]]:
    """
    Break input prose into sentences with punctuation-calibrated breath pauses for Piper fallback.
    Returns list of (sentence_text, pause_seconds_after_sentence).
    """
    import re

    cleaned = _normalize_text_for_speech(text)
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n+", cleaned) if p.strip()]
    segments: List[Tuple[str, float]] = []

    for p_idx, para in enumerate(paragraphs):
        para_flat = re.sub(r"\s+", " ", para).strip()
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", para_flat) if s.strip()]
        for s in sentences:
            if s[-1] not in ".!?":
                s += "."
            segments.append((s, 0.38))
        if segments and p_idx < len(paragraphs) - 1:
            last_txt, last_p = segments[-1]
            segments[-1] = (last_txt, max(last_p, 0.58))

    return segments or [(cleaned or text.strip(), 0.38)]


_KOKORO_CACHE: Dict[str, Any] = {}


def _get_kokoro_instance(engine_id: str) -> Any:
    if engine_id in _KOKORO_CACHE:
        return _KOKORO_CACHE[engine_id]
    from kokoro_onnx import Kokoro

    eng_meta = TTS_ENGINES.get(engine_id, TTS_ENGINES["kokoro"])
    model_path = TTS_MODELS_DIR / eng_meta["model_file"]
    voices_path = TTS_MODELS_DIR / eng_meta["voices_file"]
    if not model_path.exists():
        raise FileNotFoundError(f"Kokoro model file not found at {model_path}")
    if not voices_path.exists():
        raise FileNotFoundError(f"Kokoro voices file not found at {voices_path}")

    instance = Kokoro(str(model_path), str(voices_path))
    _KOKORO_CACHE[engine_id] = instance
    return instance


def _resolve_kokoro_voice_style(kokoro_inst: Any, voice_spec: str) -> Any:
    import numpy as np

    if not voice_spec.startswith("blend:"):
        return voice_spec
    blend_body = voice_spec[len("blend:"):]
    style_acc = None
    total_w = 0.0
    for part in blend_body.split(","):
        name, w_str = part.split(":")
        w = float(w_str)
        vec = np.asarray(kokoro_inst.get_voice_style(name.strip()), dtype=np.float32)
        style_acc = vec * w if style_acc is None else (style_acc + vec * w)
        total_w += w
    if style_acc is not None and total_w > 0:
        return (style_acc / total_w).astype(np.float32)
    return "bm_george"


def _synthesize_with_kokoro(
    text: str,
    voice_meta: Dict[str, Any],
    engine_id: str,
    speed_override: Optional[float] = None,
) -> Tuple[bytes, int]:
    """Synthesize 24kHz float32 audio with Kokoro-82M StyleTTS2 ONNX on CPU."""
    import numpy as np

    kokoro_inst = _get_kokoro_instance(engine_id)
    voice_spec = voice_meta.get("kokoro_voice", "bm_george")
    voice_style = _resolve_kokoro_voice_style(kokoro_inst, voice_spec)
    lang = voice_meta.get("kokoro_lang", "en-us")
    cfg_speed = float(load_cast_config().get("speech_speed", 0.96) or 0.96)
    base_speed = float(voice_meta.get("kokoro_speed", cfg_speed) or cfg_speed)
    speed = float(speed_override) if speed_override is not None else base_speed
    speed = max(0.75, min(1.30, speed))

    groups = _group_sentences_for_kokoro(text)
    float_segments: List[np.ndarray] = []
    sr = 24000

    for seg_text, pause_s in groups:
        samples, seg_sr = kokoro_inst.create(
            seg_text,
            voice=voice_style,
            speed=speed,
            lang=lang,
            trim=True,
            sentence_pause=0.34,
            clause_pause=0.15,
        )
        sr = int(seg_sr or 24000)
        if samples is not None and len(samples) > 0:
            seg = np.asarray(samples, dtype=np.float32).copy()
            fade_n = max(1, int(sr * 0.005))
            if seg.size > 2 * fade_n:
                seg[:fade_n] *= np.linspace(0.0, 1.0, fade_n, dtype=np.float32)
                seg[-fade_n:] *= np.linspace(1.0, 0.0, fade_n, dtype=np.float32)
            float_segments.append(seg)
        if pause_s > 0:
            float_segments.append(np.zeros(int(sr * pause_s), dtype=np.float32))

    if not float_segments:
        return b"", sr

    full_float = np.concatenate(float_segments)
    peak = float(np.max(np.abs(full_float)))
    if peak > 1e-6:
        full_float = (full_float / peak) * 0.90
    speech_pcm = np.clip(full_float * 32767.0, -32768, 32767).astype(np.int16).tobytes()
    return speech_pcm, sr


def _synthesize_with_piper(
    text: str,
    voice_meta: Dict[str, Any],
    speed_override: Optional[float] = None,
) -> Tuple[bytes, int]:
    """Synthesize 22.05kHz audio with Piper VITS ONNX as lightweight CPU fallback."""
    import numpy as np
    from piper.voice import PiperVoice
    try:
        from piper.config import SynthesisConfig
    except Exception:
        SynthesisConfig = None

    model_path = TTS_MODELS_DIR / voice_meta["model"]
    if not model_path.exists():
        raise FileNotFoundError(f"TTS voice model not found at {model_path}")

    prosody_profiles = {
        "washington": (1.08, 0.64, 0.76),
        "bm_george":  (1.06, 0.65, 0.78),
        "bryce":      (1.08, 0.64, 0.76),
        "am_fenrir":  (1.08, 0.64, 0.76),
        "alan":       (1.05, 0.65, 0.78),
        "ryan":       (1.06, 0.65, 0.78),
        "amy":        (1.05, 0.65, 0.78),
        "af_bella":   (1.05, 0.65, 0.78),
        "alba":       (1.05, 0.65, 0.78),
    }
    l_scale, n_scale, nw_scale = prosody_profiles.get(voice_meta["id"], (1.06, 0.65, 0.78))
    if speed_override is not None and float(speed_override) > 0:
        l_scale = round(1.0 / max(0.75, min(1.30, float(speed_override))), 3)

    voice = PiperVoice.load(str(model_path), use_cuda=False)
    sr = int(voice.config.sample_rate)
    syn_cfg = (
        SynthesisConfig(
            length_scale=l_scale,
            noise_scale=n_scale,
            noise_w_scale=nw_scale,
            normalize_audio=False,
        )
        if SynthesisConfig is not None
        else None
    )

    clauses = _segment_text_with_prosody(text)
    float_segments: List[np.ndarray] = []
    fade_samples = max(1, int(sr * 0.005))

    for clause_text, pause_s in clauses:
        for chunk in (voice.synthesize(clause_text, syn_config=syn_cfg) if syn_cfg is not None else voice.synthesize(clause_text)):
            arr = getattr(chunk, "audio_float_array", None)
            if arr is None:
                pcm_b = getattr(chunk, "audio_int16_bytes", b"")
                if pcm_b:
                    arr = np.frombuffer(pcm_b, dtype=np.int16).astype(np.float32) / 32767.0
            if arr is not None and arr.size > 0:
                seg = arr.astype(np.float32).copy()
                if seg.size > 2 * fade_samples:
                    seg[:fade_samples] *= np.linspace(0.0, 1.0, fade_samples, dtype=np.float32)
                    seg[-fade_samples:] *= np.linspace(1.0, 0.0, fade_samples, dtype=np.float32)
                float_segments.append(seg)
        if pause_s > 0:
            float_segments.append(np.zeros(int(sr * pause_s), dtype=np.float32))

    if not float_segments:
        return b"", sr

    full_float = np.concatenate(float_segments)
    peak = float(np.max(np.abs(full_float)))
    if peak > 1e-6:
        full_float = (full_float / peak) * 0.90
    speech_pcm = np.clip(full_float * 32767.0, -32768, 32767).astype(np.int16).tobytes()
    return speech_pcm, sr


def synthesize_tts_wav(
    text: str,
    voice_key: Optional[str] = None,
    chime: bool = True,
    engine_key: Optional[str] = None,
    speed: Optional[float] = None,
) -> Tuple[Path, Dict[str, Any]]:
    """
    Synthesize text to a WAV/M4A file using Kokoro-82M ONNX (primary) with automatic
    fallback to Piper VITS ONNX if Kokoro is unavailable or too heavy for the device.
    """
    voice_meta = resolve_voice(voice_key)
    requested_engine = resolve_engine(engine_key)
    active_engine = requested_engine
    fallback_used = False
    fallback_reason: Optional[str] = None

    CAST_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    speed_tag = f"{float(speed):.2f}" if speed is not None else "cfg"
    digest = hashlib.sha256(
        f"v3:{requested_engine}:{voice_meta['id']}:{speed_tag}:{int(chime)}:{text}".encode("utf-8")
    ).hexdigest()[:16]
    filename = f"tts_{requested_engine}_{voice_meta['id']}_{digest}.wav"
    out_path = CAST_AUDIO_DIR / filename

    t0 = time.time()
    if not out_path.exists() or out_path.stat().st_size < 256:
        speech_pcm = b""
        sr = 24000
        if requested_engine in ("kokoro", "kokoro_int8"):
            try:
                speech_pcm, sr = _synthesize_with_kokoro(
                    text, voice_meta, engine_id=requested_engine, speed_override=speed
                )
            except Exception as exc:
                fallback_used = True
                fallback_reason = f"{type(exc).__name__}: {exc}"
                active_engine = "piper"
                speech_pcm, sr = _synthesize_with_piper(
                    text, voice_meta, speed_override=speed
                )
        else:
            active_engine = "piper"
            speech_pcm, sr = _synthesize_with_piper(
                text, voice_meta, speed_override=speed
            )

        prefix_pcm = _generate_chime_pcm(sr) if chime else b""
        # Append 1.0s trailing silence so Cast receiver buffer never clips the final sentence
        tail_pcm = b"\x00\x00" * int(sr * 1.0)
        with wave.open(str(out_path), "wb") as out_wf:
            out_wf.setnchannels(1)
            out_wf.setsampwidth(2)
            out_wf.setframerate(sr)
            out_wf.writeframes(prefix_pcm + speech_pcm + tail_pcm)

    m4a_filename = f"tts_{active_engine}_{voice_meta['id']}_{digest}.m4a"
    m4a_path = CAST_AUDIO_DIR / m4a_filename
    if not m4a_path.exists() or m4a_path.stat().st_size < 256:
        import subprocess
        # Transparent broadcast mastering chain preserving full 2-8kHz consonant articulation:
        # 1. highpass=f=65: remove sub-bass rumble on smart speakers
        # 2. loudnorm=I=-15:TP=-1.5:LRA=9: EBU R128 loudness normalization without crushing dynamics
        af_chain = "highpass=f=65,loudnorm=I=-15:TP=-1.5:LRA=9"
        try:
            subprocess.run(
                [
                    "ffmpeg",
                    "-y",
                    "-i", str(out_path),
                    "-af", af_chain,
                    "-c:a", "aac",
                    "-b:a", "128k",
                    "-ar", "44100",
                    "-ac", "2",
                    "-movflags", "+faststart",
                    str(m4a_path),
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30.0,
                check=True,
            )
        except Exception:
            m4a_path = out_path
            m4a_filename = filename

    synth_ms = int((time.time() - t0) * 1000)
    with wave.open(str(out_path), "rb") as wf:
        duration_s = round(wf.getnframes() / float(wf.getframerate() or 24000), 2)

    active_path = m4a_path if m4a_path.exists() else out_path
    engine_meta = TTS_ENGINES.get(active_engine, TTS_ENGINES["kokoro"])
    return active_path, {
        "filename": active_path.name,
        "wav_filename": filename,
        "m4a_filename": m4a_filename if m4a_path.exists() else filename,
        "content_type": "audio/mp4" if active_path.suffix == ".m4a" else "audio/wav",
        "engine": active_engine,
        "requested_engine": requested_engine,
        "engine_label": engine_meta["label"],
        "fallback_used": fallback_used,
        "fallback_reason": fallback_reason,
        "voice": voice_meta["id"],
        "voice_label": voice_meta["label"],
        "synth_ms": synth_ms,
        "duration_s": duration_s,
        "size_bytes": active_path.stat().st_size,
    }


def _probe_cast_speaker(sp: Dict[str, Any]) -> Dict[str, Any]:
    ip = sp["ip"]
    info = dict(sp)
    info["online"] = False
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.35)
            if s.connect_ex((ip, 8009)) == 0:
                info["online"] = True
    except Exception:
        pass
    if info["online"]:
        for url in (f"http://{ip}:8008/setup/eureka_info", f"https://{ip}:8443/setup/eureka_info"):
            try:
                ctx = ssl._create_unverified_context() if url.startswith("https") else None
                req = urllib.request.Request(url, headers={"User-Agent": "George-Cast-Discovery"})
                with urllib.request.urlopen(req, timeout=0.6, context=ctx) as resp:
                    data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                    if data.get("name"):
                        info["name"] = data["name"]
                    info["build_version"] = data.get("build_version")
                    break
            except Exception:
                pass
    return info


def discover_speakers() -> List[Dict[str, Any]]:
    cfg = load_cast_config()
    default_names = {s.lower() for s in cfg.get("default_speakers", ["Kitchen Display 1", "Bedroom speaker"])}
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(_probe_cast_speaker, KNOWN_SPEAKERS))
    for r in results:
        r["default"] = (
            r["name"].lower() in default_names
            or r["id"].lower() in default_names
            or r["ip"] in default_names
        )
    return results


def resolve_target_speakers(target: Optional[str]) -> List[Dict[str, Any]]:
    speakers = discover_speakers()
    online = [s for s in speakers if s.get("online")]
    pool = online if online else speakers

    if not target or str(target).strip().lower() in ("", "default", "defaults"):
        defaults = [s for s in pool if s.get("default")]
        return defaults if defaults else pool[:2]

    raw = str(target).strip()
    if raw.lower() in ("all", "everywhere", "whole_house", "house", "*"):
        return [s for s in pool if s["id"] != "basement_tv"] or pool

    tokens = [t.strip().lower() for t in raw.split(",") if t.strip()]
    matched: List[Dict[str, Any]] = []
    seen_ips = set()
    for tok in tokens:
        for s in pool:
            if s["ip"] in seen_ips:
                continue
            if (
                tok == s["ip"].lower()
                or tok == s["id"].lower()
                or tok == s["name"].lower()
                or tok in s["name"].lower()
                or tok in s["hostname"].lower()
            ):
                matched.append(s)
                seen_ips.add(s["ip"])
    if not matched and len(tokens) == 1 and tokens[0].startswith("192.168."):
        matched.append({
            "id": "custom",
            "name": f"Speaker ({tokens[0]})",
            "hostname": tokens[0],
            "ip": tokens[0],
            "model": "Google Cast Device",
            "online": True,
        })
    return matched


def _cast_url_to_speaker(
    sp: Dict[str, Any],
    audio_url: str,
    title: str,
    volume: Optional[float] = None,
    wait_duration: float = 0.0,
) -> Dict[str, Any]:
    import pychromecast

    ip = sp["ip"]
    t0 = time.time()
    cast = None
    try:
        host_tuple = (
            ip,
            8009,
            uuid_mod.uuid5(uuid_mod.NAMESPACE_DNS, ip),
            sp.get("model") or "Google Nest",
            sp.get("name") or ip,
        )
        cast = pychromecast.get_chromecast_from_host(host_tuple, tries=2, timeout=3.0)
        cast.wait(timeout=4.0)
        if volume is not None and 0.0 <= float(volume) <= 1.0:
            cast.set_volume(float(volume))
            time.sleep(0.15)
        content_type = "audio/mp4" if audio_url.endswith(".m4a") else ("audio/mpeg" if audio_url.endswith(".mp3") else "audio/wav")
        mc = cast.media_controller
        mc.play_media(
            audio_url,
            content_type,
            title=title[:80],
            stream_type="BUFFERED",
        )
        mc.block_until_active(timeout=5.0)
        player_state = "UNKNOWN"
        idle_reason = None
        saw_playing = False
        hold_budget = min(max(float(wait_duration or 0.0), 4.0), 300.0)
        deadline = time.time() + hold_budget
        while time.time() < deadline:
            time.sleep(0.5)
            player_state = getattr(mc.status, "player_state", "UNKNOWN") or "UNKNOWN"
            idle_reason = getattr(mc.status, "idle_reason", None)
            if player_state in ("PLAYING", "BUFFERING"):
                saw_playing = True
            elif saw_playing and player_state == "IDLE" and idle_reason == "FINISHED":
                break
        return {
            "speaker": sp.get("name", ip),
            "ip": ip,
            "status": "playing" if (saw_playing or player_state in ("PLAYING", "BUFFERING") or idle_reason == "FINISHED") else player_state.lower(),
            "player_state": "FINISHED" if idle_reason == "FINISHED" else player_state,
            "elapsed_ms": int((time.time() - t0) * 1000),
        }
    except Exception as e:
        return {
            "speaker": sp.get("name", ip),
            "ip": ip,
            "status": "error",
            "error": f"{type(e).__name__}: {e}",
            "elapsed_ms": int((time.time() - t0) * 1000),
        }
    finally:
        if cast is not None:
            try:
                cast.disconnect(timeout=1.0)
            except Exception:
                pass


def set_speaker_volume(target: str, volume: float) -> Dict[str, Any]:
    import pychromecast

    vol = max(0.0, min(1.0, float(volume)))
    targets = resolve_target_speakers(target)
    results = []
    for sp in targets:
        ip = sp["ip"]
        cast = None
        try:
            host_tuple = (
                ip,
                8009,
                uuid_mod.uuid5(uuid_mod.NAMESPACE_DNS, ip),
                sp.get("model") or "Google Nest",
                sp.get("name") or ip,
            )
            cast = pychromecast.get_chromecast_from_host(host_tuple, tries=2, timeout=3.0)
            cast.wait(timeout=3.0)
            cast.set_volume(vol)
            results.append({"speaker": sp.get("name", ip), "ip": ip, "volume": vol, "status": "ok"})
        except Exception as e:
            results.append({"speaker": sp.get("name", ip), "ip": ip, "status": "error", "error": str(e)})
        finally:
            if cast is not None:
                try:
                    cast.disconnect(timeout=1.0)
                except Exception:
                    pass
    return {"status": "ok", "results": results}


def broadcast_speech(
    text: str,
    target: Optional[str] = None,
    voice: Optional[str] = None,
    volume: Optional[float] = None,
    force: bool = False,
    title: str = "Brother George Broadcast",
    dry_run: bool = False,
    engine: Optional[str] = None,
    speed: Optional[float] = None,
) -> Dict[str, Any]:
    clean_text = (text or "").strip()
    if not clean_text:
        return {"status": "error", "message": "text must not be empty"}

    qh = get_quiet_hours_info()
    if is_quiet_hours_active() and not force:
        record = {
            "ts": int(time.time()),
            "status": "deferred_quiet_hours",
            "text": clean_text,
            "target": target or "default",
            "voice": voice or "washington",
            "engine": resolve_engine(engine),
            "quiet_hours": qh,
        }
        _append_history(record)
        return {
            "status": "deferred_quiet_hours",
            "message": f"Broadcast suppressed by active Quiet Hours ({qh.get('start')}–{qh.get('end')} {qh.get('tz')}). Pass force=true for urgent announcements.",
            "quiet_hours": qh,
        }

    wav_path, tts_meta = synthesize_tts_wav(
        clean_text,
        voice_key=voice,
        chime=True,
        engine_key=engine,
        speed=speed,
    )
    if dry_run:
        web_port = os.environ.get("GEORGE_WEB_PORT", "3000")
        return {
            "status": "dry_run",
            "engine": tts_meta["engine"],
            "requested_engine": tts_meta["requested_engine"],
            "engine_label": tts_meta["engine_label"],
            "fallback_used": tts_meta["fallback_used"],
            "fallback_reason": tts_meta.get("fallback_reason"),
            "voice": tts_meta["voice"],
            "voice_label": tts_meta["voice_label"],
            "filename": tts_meta["filename"],
            "audio_url": f"http://127.0.0.1:{web_port}/api/cast/audio/{tts_meta['filename']}",
            "duration_s": tts_meta["duration_s"],
            "synth_ms": tts_meta["synth_ms"],
            "wav_size_bytes": wav_path.stat().st_size if wav_path.exists() else 0,
        }

    audio_url = stage_audio_to_lan_relay(wav_path)

    targets = resolve_target_speakers(target)
    if not targets:
        return {"status": "error", "message": f"No Google Home speakers matched target '{target}'"}

    hold_secs = float(tts_meta.get("duration_s") or 8.0) + 5.0
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(targets)) as ex:
        futures = [
            ex.submit(_cast_url_to_speaker, sp, audio_url, title, volume, hold_secs)
            for sp in targets
        ]
        deliveries = [f.result() for f in futures]

    ok_count = sum(1 for d in deliveries if d.get("status") == "playing")
    status = "ok" if ok_count > 0 else "error"
    record = {
        "ts": int(time.time()),
        "status": status,
        "text": clean_text,
        "engine": tts_meta["engine"],
        "requested_engine": tts_meta["requested_engine"],
        "engine_label": tts_meta["engine_label"],
        "fallback_used": tts_meta["fallback_used"],
        "fallback_reason": tts_meta.get("fallback_reason"),
        "voice": tts_meta["voice"],
        "voice_label": tts_meta["voice_label"],
        "filename": tts_meta["filename"],
        "audio_url": audio_url,
        "duration_s": tts_meta["duration_s"],
        "synth_ms": tts_meta["synth_ms"],
        "target": target or "default",
        "deliveries": deliveries,
    }
    _append_history(record)
    return record


def _append_history(entry: Dict[str, Any]) -> None:
    try:
        CAST_HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(CAST_HISTORY_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def get_cast_status() -> Dict[str, Any]:
    cfg = load_cast_config()
    speakers = discover_speakers()
    recent: List[Dict[str, Any]] = []
    if CAST_HISTORY_FILE.exists():
        try:
            lines = CAST_HISTORY_FILE.read_text(encoding="utf-8").splitlines()
            for ln in reversed(lines[-25:]):
                if ln.strip():
                    recent.append(json.loads(ln))
        except Exception:
            pass
    return {
        "status": "ok",
        "lan_ip": get_lan_ip(),
        "config": cfg,
        "engines": get_available_engines(),
        "voices": list(VOICES.values()),
        "speakers": speakers,
        "quiet_hours": get_quiet_hours_info(),
        "recent_broadcasts": recent,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Sovereign Google Home CastV2 & Kokoro-82M / Piper TTS Engine")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("status", help="Show speakers, engines, voices, quiet hours, and recent broadcasts")
    sub.add_parser("discover", help="Discover Google Home / Cast devices on the LAN")

    p_speak = sub.add_parser("speak", help="Synthesize and broadcast speech to Google Home speaker(s)")
    p_speak.add_argument("text", help="Text to speak")
    p_speak.add_argument("--target", default="default", help="Speaker name, IP, 'default' (Kitchen + Bedroom), or 'all'")
    p_speak.add_argument("--voice", default=None, help="Voice ID: washington, bm_george, bryce, am_fenrir, alan, ryan, amy, af_bella, alba")
    p_speak.add_argument("--engine", default=None, help="TTS Engine ID: kokoro (FP32 24kHz), kokoro_int8 (89MB INT8), or piper (VITS fallback)")
    p_speak.add_argument("--speed", type=float, default=None, help="Optional speech speed multiplier (0.75 to 1.30, default 0.96)")
    p_speak.add_argument("--volume", type=float, default=None, help="Optional speaker volume (0.0 to 1.0)")
    p_speak.add_argument("--force", action="store_true", help="Bypass quiet hours for urgent or test broadcasts")
    p_speak.add_argument("--title", default="Brother George Broadcast", help="Cast media title")
    p_speak.add_argument("--dry-run", action="store_true", help="Synthesize WAV/M4A only without casting to speakers")

    p_vol = sub.add_parser("volume", help="Set speaker volume")
    p_vol.add_argument("--target", default="default", help="Speaker name or IP")
    p_vol.add_argument("--level", type=float, required=True, help="Volume level (0.0 to 1.0)")

    p_cfg = sub.add_parser("config", help="Update default TTS engine, voice, speed, or speakers")
    p_cfg.add_argument("--default-engine", default=None, help="Default TTS engine: kokoro, kokoro_int8, or piper")
    p_cfg.add_argument("--default-voice", default=None)
    p_cfg.add_argument("--default-speakers", default=None, help="Comma-separated speaker names")
    p_cfg.add_argument("--speech-speed", type=float, default=None, help="Default speech speed (0.75 to 1.30)")

    args = parser.parse_args()
    if args.cmd == "discover":
        print(json.dumps({"status": "ok", "speakers": discover_speakers()}, indent=2))
    elif args.cmd == "speak":
        res = broadcast_speech(
            text=args.text,
            target=args.target,
            voice=args.voice,
            volume=args.volume,
            force=args.force,
            title=args.title,
            dry_run=args.dry_run,
            engine=args.engine,
            speed=args.speed,
        )
        print(json.dumps(res, indent=2))
        if res.get("status") == "error":
            sys.exit(1)
    elif args.cmd == "volume":
        print(json.dumps(set_speaker_volume(args.target, args.level), indent=2))
    elif args.cmd == "config":
        updates: Dict[str, Any] = {}
        if args.default_engine:
            updates["default_engine"] = resolve_engine(args.default_engine)
        if args.default_voice:
            updates["default_voice"] = resolve_voice(args.default_voice)["id"]
        if args.default_speakers:
            updates["default_speakers"] = [s.strip() for s in args.default_speakers.split(",") if s.strip()]
        if args.speech_speed is not None:
            updates["speech_speed"] = max(0.75, min(1.30, float(args.speech_speed)))
        print(json.dumps({"status": "ok", "config": save_cast_config(updates)}, indent=2))
    else:
        print(json.dumps(get_cast_status(), indent=2))


if __name__ == "__main__":
    main()
