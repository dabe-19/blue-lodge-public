#!/usr/bin/env bash
# ── Sovereign Local Neural TTS Bootstrap (Kokoro-82M StyleTTS2 + Piper VITS ONNX) ──
# Ensures .venv packages and .george/models/tts/ ONNX voice models are installed.
set -euo pipefail

LODGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEORGE_DIR="${GEORGE_DIR:-$LODGE_DIR/.george}"
TTS_DIR="$GEORGE_DIR/models/tts"
mkdir -p "$TTS_DIR"

# 1. Ensure .venv Python dependencies for Kokoro-82M, Piper VITS, and Google CastV2
if [ -x "$LODGE_DIR/.venv/bin/python" ]; then
    if ! "$LODGE_DIR/.venv/bin/python" -c "import kokoro_onnx, piper, pychromecast, soundfile, onnxruntime" >/dev/null 2>&1; then
        echo "[+] Installing Kokoro-82M, Piper ONNX & CastV2 packages into .venv..."
        "$LODGE_DIR/.venv/bin/pip" install --quiet kokoro-onnx piper-tts pychromecast soundfile onnxruntime scipy numpy
    fi
fi

# 2. Ensure Kokoro-82M v1.0 ONNX models (FP32 + INT8 + voices-v1.0.bin)
KOKORO_BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
for f in kokoro-v1.0.onnx kokoro-v1.0.int8.onnx voices-v1.0.bin; do
    if [ ! -s "$TTS_DIR/$f" ]; then
        echo "[+] Downloading Kokoro-82M model asset: $f..."
        curl -fL --retry 3 -o "$TTS_DIR/$f" "$KOKORO_BASE/$f"
    fi
done

# 3. Ensure Piper VITS ONNX fallback voices
PIPER_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0"
declare -A PIPER_VOICES=(
    ["en_US-bryce-medium"]="en/en_US/bryce/medium/en_US-bryce-medium"
    ["en_US-norman-medium"]="en/en_US/norman/medium/en_US-norman-medium"
    ["en_GB-alan-medium"]="en/en_GB/alan/medium/en_GB-alan-medium"
    ["en_US-ryan-medium"]="en/en_US/ryan/medium/en_US-ryan-medium"
    ["en_US-amy-medium"]="en/en_US/amy/medium/en_US-amy-medium"
    ["en_GB-alba-medium"]="en/en_GB/alba/medium/en_GB-alba-medium"
)

for v in "${!PIPER_VOICES[@]}"; do
    rel="${PIPER_VOICES[$v]}"
    for ext in ".onnx" ".onnx.json"; do
        if [ ! -s "$TTS_DIR/${v}${ext}" ]; then
            echo "[+] Downloading Piper ONNX voice: ${v}${ext}..."
            curl -fL --retry 3 -o "$TTS_DIR/${v}${ext}" "$PIPER_BASE/${rel}${ext}"
        fi
    done
done

echo "[✓] Sovereign Neural TTS models verified in $TTS_DIR"

