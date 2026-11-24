import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from lib.tools import sdr_transcribe

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_is_audio_file_extensions(tmp_path):
    ogg = tmp_path / "voice-message.ogg"
    ogg.write_bytes(b"OggS\x00\x02")
    mp3 = tmp_path / "clip.mp3"
    mp3.write_bytes(b"ID3\x03\x00")
    png = tmp_path / "meme.png"
    png.write_bytes(b"\x89PNG\r\n\x1a\n")
    txt = tmp_path / "notes.txt"
    txt.write_text("hello world\n")

    assert sdr_transcribe.is_audio_file(ogg) is True
    assert sdr_transcribe.is_audio_file(mp3) is True
    assert sdr_transcribe.is_audio_file(png) is False
    assert sdr_transcribe.is_audio_file(txt) is False


def test_fifo_priority_waiter_detection_and_preemption(tmp_path, monkeypatch):
    monkeypatch.setenv("FIFO_IPC_DIR", str(tmp_path))

    # 1. Acquire Tier 2 slot as a low-priority SDR radio task (priority 50)
    low_lease = sdr_transcribe._IpcPrioritySlotLease(
        task_name="sdr_radio_bg",
        priority=sdr_transcribe.PRIO_SDR_RADIO,
        tier=2,
        timeout=2.0,
        ipc_dir=tmp_path,
    )
    low_lease.__enter__()
    try:
        assert low_lease.acquired is True
        # No higher-priority waiter yet
        assert sdr_transcribe._has_higher_priority_waiter(2, sdr_transcribe.PRIO_SDR_RADIO, ipc_dir=tmp_path) is False

        # 2. Simulate an interactive Discord voice transcription waiter (priority 100) from another live PID (parent)
        waiters_dir = tmp_path / "inference_slots" / "tier_2" / "waiters"
        waiters_dir.mkdir(parents=True, exist_ok=True)
        other_alive_pid = os.getppid()
        waiter_file = waiters_dir / f"100_0000000001_{other_alive_pid}.wait"
        waiter_file.write_text(f"{other_alive_pid}|100|discord_voice\n")
        try:
            assert sdr_transcribe._has_higher_priority_waiter(2, sdr_transcribe.PRIO_SDR_RADIO, ipc_dir=tmp_path) is True
            assert (
                sdr_transcribe._has_higher_priority_waiter(
                    2, sdr_transcribe.PRIO_INTERACTIVE_AUDIO, my_start_ts=0, ipc_dir=tmp_path
                )
                is False
            )
        finally:
            waiter_file.unlink(missing_ok=True)

        # 3. Verify a high-priority lease (100) preempts the lower-priority holder (50)
        high_lease = sdr_transcribe._IpcPrioritySlotLease(
            task_name="discord_voice_fg",
            priority=sdr_transcribe.PRIO_INTERACTIVE_AUDIO,
            tier=2,
            timeout=3.0,
            ipc_dir=tmp_path,
        )
        with high_lease:
            assert high_lease.acquired is True
            lease_data = json.loads((tmp_path / "inference_slots" / "tier_2" / "lease.json").read_text())
            assert lease_data["task_name"] == "discord_voice_fg"
            assert lease_data["priority"] == 100
    finally:
        low_lease.__exit__(None, None, None)


def test_tier1_27b_audio_fallback_when_sdr_offline(tmp_path, monkeypatch):
    monkeypatch.setenv("FIFO_IPC_DIR", str(tmp_path))

    # Create a tiny valid 16kHz mono WAV file so ffmpeg conversion succeeds
    wav_path = tmp_path / "voice_test.wav"
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-hide_banner",
            "-loglevel",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=0.25",
            "-ar",
            "16000",
            "-ac",
            "1",
            str(wav_path),
        ],
        check=True,
    )

    state = {"audio_modality": True, "chat_calls": 0}

    class MockTier1Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_GET(self):
            if self.path == "/props":
                body = json.dumps(
                    {
                        "modalities": {
                            "vision": True,
                            "audio": state["audio_modality"],
                        }
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

        def do_POST(self):
            if self.path == "/v1/chat/completions":
                state["chat_calls"] += 1
                length = int(self.headers.get("Content-Length", "0"))
                _ = self.rfile.read(length)
                resp = {
                    "choices": [
                        {
                            "message": {
                                "content": json.dumps(
                                    {
                                        "intelligible": True,
                                        "transcript": "Hello George from the 27B fallback audio encoder.",
                                        "summary": "Operator greeted George via fallback encoder.",
                                    }
                                )
                            }
                        }
                    ]
                }
                body = json.dumps(resp).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()

    server = HTTPServer(("127.0.0.1", 0), MockTier1Handler)
    port = server.server_port
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        # Point SDR endpoints to closed ports (simulating george-home powered down)
        # and point _TIER1_URL to our mock Tier 1 server
        monkeypatch.setattr(sdr_transcribe, "DEFAULT_ENDPOINTS", ["http://127.0.0.1:19991/inference"])
        monkeypatch.setattr(sdr_transcribe, "MULTIMODAL_ENDPOINTS", ["http://127.0.0.1:19992/v1/chat/completions"])
        monkeypatch.setattr(sdr_transcribe, "_TIER1_URL", f"http://127.0.0.1:{port}")

        # Case A: Primary 27B model supports audio encoder -> fallback succeeds
        probe_a = sdr_transcribe.probe_tier1_audio_encoder(f"http://127.0.0.1:{port}")
        assert probe_a["audio_supported"] is True
        res = sdr_transcribe.transcribe_voice_file(
            wav_path,
            priority=sdr_transcribe.PRIO_INTERACTIVE_AUDIO,
            source="discord",
        )
        assert res["status"] == "ok"
        assert res["source_node"].startswith("tier1_27b_audio:")
        assert "Hello George from the 27B fallback audio encoder." in res["transcript"]
        assert state["chat_calls"] == 1

        # Case B: Primary 27B model does NOT have audio encoder loaded -> clean offline status
        state["audio_modality"] = False
        probe_b = sdr_transcribe.probe_tier1_audio_encoder(f"http://127.0.0.1:{port}")
        assert probe_b["audio_supported"] is False
        res_offline = sdr_transcribe.transcribe_voice_file(
            wav_path,
            priority=sdr_transcribe.PRIO_INTERACTIVE_AUDIO,
            source="discord",
        )
        assert res_offline["status"] == "audio_encoder_offline"
        assert "does not have an audio encoder enabled" in res_offline["summary"]
    finally:
        server.shutdown()


def test_discord_bridge_attachment_detection_and_coalescing(tmp_path):
    ogg_file = tmp_path / "voice-message.ogg"
    ogg_file.write_bytes(b"OggS\x00\x02")
    png_file = tmp_path / "screenshot.png"
    png_file.write_bytes(b"\x89PNG\r\n\x1a\n")
    script = f"""
    export LODGE_DIR="{REPO_ROOT}"
    source "{REPO_ROOT}/lib/comms/discord_bridge.sh"

    # 1. Test _discord_detect_attachment_kind
    k_ogg=$(_discord_detect_attachment_kind "{ogg_file}")
    k_png=$(_discord_detect_attachment_kind "{png_file}")
    [ "$k_ogg" = "audio" ] || {{ echo "Expected audio, got $k_ogg"; exit 1; }}
    [ "$k_png" = "image" ] || {{ echo "Expected image, got $k_png"; exit 1; }}

    # 2. Test _discord_pipe_next_group coalesces attachments across consecutive messages
    raw_json='[
      {{"id":"101","author":{{"id":"u1","username":"operator_test","bot":false}},"content":"","attachments":[{{"id":"a1","filename":"meme.png","url":"https://example.com/meme.png"}}]}},
      {{"id":"102","author":{{"id":"u1","username":"operator_test","bot":false}},"content":"what do you think of this?","attachments":[]}}
    ]'
    grp=$(_discord_pipe_next_group "$raw_json" "bot999" "100" "ch1" "1" "u1")
    att_count=$(printf '%s' "$grp" | jq '.msg.attachments | length')
    merged_content=$(printf '%s' "$grp" | jq -r '.content')
    [ "$att_count" = "1" ] || {{ echo "Expected 1 coalesced attachment, got $att_count"; exit 1; }}
    [ "$merged_content" = "what do you think of this?" ] || {{ echo "Unexpected content: $merged_content"; exit 1; }}
    echo "DISCORD_BRIDGE_OK"
    """
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    assert "DISCORD_BRIDGE_OK" in proc.stdout


def test_react_parallel_web_search_wave_failure_streak(tmp_path):
    script = f"""
    export LODGE_DIR="{REPO_ROOT}"
    source "{REPO_ROOT}/lib/core/react.sh"

    sess="{tmp_path}/sess"
    ws="{tmp_path}/ws"
    mkdir -p "$sess" "$ws"
    session_id="sess1"
    workdir="$ws"
    messages_file="$sess/messages.json"
    macro_file="$sess/macro_memory.json"
    echo '{{"status":"RUNNING"}}' > "$macro_file"
    echo '[]' > "$messages_file"
    thrashing_fail_tool="web_search"
    thrashing_target_streak=3
    thrashing_distinct_research_steers=0
    tool_exhausted=0

    # 4th consecutive failure on distinct web_search query should steer (not trip tool_exhausted)
    _react_handle_failure_streak "web_search" '{{"query":"query_four"}}' "Web search failed" >/dev/null 2>&1
    [ "$tool_exhausted" -eq 0 ] || {{ echo "Expected tool_exhausted=0 on 1st distinct research steer, got $tool_exhausted"; exit 1; }}
    [ "$thrashing_distinct_research_steers" -eq 1 ] || {{ echo "Expected steers=1, got $thrashing_distinct_research_steers"; exit 1; }}

    # After 2 distinct research steers, a subsequent failure trips tool_exhausted=1
    thrashing_distinct_research_steers=2
    _react_handle_failure_streak "web_search" '{{"query":"query_six"}}' "Web search failed" >/dev/null 2>&1
    [ "$tool_exhausted" -eq 1 ] || {{ echo "Expected tool_exhausted=1 after steers exhausted, got $tool_exhausted"; exit 1; }}
    echo "REACT_STREAK_OK"
    """
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    assert "REACT_STREAK_OK" in proc.stdout
