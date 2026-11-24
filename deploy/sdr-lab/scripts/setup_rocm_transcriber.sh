#!/bin/bash
# ── Setup AMD Radeon RX 5700 XT Audio Transcription Server ────────────────────
# Run on the target host (192.168.1.20 / george-home):
#
# Hardware: AMD Radeon RX 5700 XT (Navi 10 / RDNA1 / 8GB VRAM)
# Engine:   whisper.cpp built with Vulkan support (-DWHISPER_VULKAN=ON)
# Port:     8090
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

INSTALL_DIR="/opt/whisper-sdr"
MODEL_NAME="ggml-small.en.bin"
PORT=8090

echo "[1/4] Installing system dependencies (Vulkan SDK, build tools)..."
sudo apt-get update
sudo apt-get install -y git build-essential cmake libvulkan-dev vulkan-tools curl

echo "[2/4] Cloning whisper.cpp and compiling with Vulkan acceleration..."
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"

if [ ! -d "$INSTALL_DIR/whisper.cpp" ]; then
    git clone https://github.com/ggerganov/whisper.cpp.git "$INSTALL_DIR/whisper.cpp"
fi

cd "$INSTALL_DIR/whisper.cpp"
mkdir -p build && cd build
cmake -DWHISPER_VULKAN=ON -DCMAKE_BUILD_TYPE=Release ..
cmake --build . --config Release -j"$(nproc)"

echo "[3/4] Downloading Whisper model ($MODEL_NAME)..."
cd "$INSTALL_DIR/whisper.cpp"
bash ./models/download-ggml-model.sh small.en

echo "[4/4] Creating systemd service unit (/etc/systemd/system/whisper-sdr.service)..."
cat << EOF | sudo tee /etc/systemd/system/whisper-sdr.service
[Unit]
Description=Whisper SDR Audio Transcription Server (AMD RX 5700 XT Vulkan)
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/whisper.cpp
ExecStart=$INSTALL_DIR/whisper.cpp/build/bin/whisper-server -m $INSTALL_DIR/whisper.cpp/models/$MODEL_NAME --port $PORT --host 0.0.0.0
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable whisper-sdr.service
sudo systemctl restart whisper-sdr.service

echo ""
echo "[OK] AMD Radeon RX 5700 XT Audio Transcription Server configured!"
echo "Status check: sudo systemctl status whisper-sdr.service"
echo "Test endpoint: curl http://127.0.0.1:$PORT/health"
