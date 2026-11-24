# Sovereign P25 SDR Radio Lab — Operator & User Guide

> **Complete Architecture, Deployment Topologies, `trunk-recorder` 5.2.0 P25 CQPSK/LSM DSP Patch Reference, Two-Stage Whisper + Gemma-4 E4B LoRA Pipeline, RF Calibration, and Storage Lifecycle**

---

## 1. Overview

The **George Sovereign P25 SDR Radio Lab** turns a low-cost Software-Defined Radio (e.g., Airspy Mini / R2 or RTL-SDR v4) into an autonomous, real-time public safety and regional OSINT intelligence pipeline. It captures trunked **APCO Project 25 (P25 Phase 1 FDMA / CQPSK Simulcast)** radio systems, decodes IMBE/AMBE digital voice frames, transcribes and summarizes dispatch audio through a **two-stage domain-adapted AI pipeline**, links unit/department histories into a **Running Context Buffer**, and emits real-time telemetry to the George Sovereign Dashboard and 3-hour OSINT SitRep synthesizer.

```
[Wilson Directional 800 MHz Yagi + Coax]
                 │
                 ▼
      [Airspy Mini / R2 SDR] (6 MSPS @ 858.2125 MHz)
                 │
                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Capture Layer (`trunk-recorder` 5.2.0 + 5-Part P25 CQPSK/LSM Patch)     │
│  • Costas Loop ±15° Phase Clamp & β=0.0 Anti-Windup                     │
│  • 16-Path List-Viterbi (K=16) Trellis Decoder with CRC-16 Selection    │
│  • Per-Block TSBK Recovery & Back-to-Back Multi-Block Sync Window       │
│  • Widened 2700 Hz Channel Filter + Slow RMS AGC (attack=0.01)          │
│  • Outputs `.json` call telemetry + AAC `.m4a` (`compressWav: true`)     │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
          ┌──────────────────────┴──────────────────────┐
          │ `capture_mode: remote_ssh` OR `local_dir`   │
          ▼                                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Ingest, Running Context Buffer & Two-Stage AI Pipeline                  │
│  1. Audio Conditioning (`lib/tools/sdr_transcribe.py`):                 │
│     • FFmpeg P25 Bandpass (`260–3400 Hz`) + FFT Denoise (`afftdn=-25`)  │
│       + Dynamic Audio Normalization (`dynaudnorm=f=150:g=15`)           │
│     • Energy-guided silence splitting (>12s transmissions)              │
│  2. Stage 1 — Acoustic ASR (`whisper-server` :8090 / :18090):           │
│     • `ggml-small-p25-a100-lora.bin` (A100 Rank-32 LoRA merged into     │
│       `whisper-small-public-safety-v2-FINAL`)                           │
│  3. Stage 2 — Multimodal Audio + Running Context (`llama-server` :8080):│
│     • `gemma-4-E4B-it` + `gemma4-e4b-george-sdr-v2-SVD32.gguf` LoRA     │
│     • Injects last 2h of same-TGID, same-Unit-ID, and same-Freq calls   │
│     • Produces corrected transcript, 1-sentence tactical summary,       │
│       incident classification, emergency alert, and continuous narrative│
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ Storage, Live UI & OSINT SitRep Synthesis                               │
│  • SQLite (`sdr_intel.db`) — permanent searchable call & unit history   │
│  • Rolling Audio Retention — 24h edge `.m4a`, 7d archive `.m4a`,        │
│    immediate `.wav` deduplication (`--prune`)                           │
│  • Live Dashboard SSE Stream (`sdr_call_ingested` / `sdr_emergency`)    │
│  • 3-Hour OSINT SitRep Continuous Department & Unit Narratives          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Deployment Topologies & Endpoint Routing

The SDR Lab is packaged in [`deploy/sdr-lab/`](deploy/sdr-lab) and configured via [`.george/sdr/config.json`](.george/sdr/config.json) (or environment variables in [`.env.example`](deploy/sdr-lab/.env.example)) so it can be deployed in **three supported topologies**:

| Topology | `SDR_CAPTURE_MODE` | `SDR_INFERENCE_MODE` | Docker Compose Profile | Best For |
| :--- | :--- | :--- | :--- | :--- |
| **Mode A — Split Edge + Dedicated GPU Node** *(Reference Production)* | `remote_ssh` | `dedicated` | `--profile capture` *(on RF node)* + `--profile inference` *(on GPU node)* | Placing the SDR receiver near the antenna/coax feed (`sdr-server`) while offloading GPU inference to a dedicated workstation (`george-home` RX 5700 XT) and syncing to the George control node (`user`). |
| **Mode B — Local All-in-One / Host IPC Mode** | `local_dir` | `shared_local` *or* `ipc_bus` | `--profile capture` *(on main George host)* | Plugging the USB SDR dongle directly into the main George host. `sdr_ingest.py` reads `.m4a`/`.json` directly from `SDR_LOCAL_RECORDINGS` without SSH and shares the host's primary `llama-server` (`LLM_BASE_URL` `:8080`) or emits `sdr_ipc_call_staged` on `.george/ipc/event_bus.fifo`. |
| **Mode C — Standalone Containerized Appliance** | `local_dir` | `dedicated` | `--profile full` *(or `--profile standalone`)* | Turnkey single-command appliance deployment (`docker compose --profile full up -d`) bundling patched `trunk-recorder`, `rdio-scanner`, `sdr-pruner`, `whisper-sdr`, `gemma-e4b-sdr`, and `sdr-ingest-worker`. |

### 2.1 How the Model Endpoint Question is Resolved

In [`lib/tools/sdr_transcribe.py`](lib/tools/sdr_transcribe.py#L72-L162), endpoint selection is controlled by `SDR_INFERENCE_MODE`:

1. **`SDR_INFERENCE_MODE=dedicated`** *(Default)*:
   - **Stage 1 (Whisper ASR)**: Uses `SDR_TRANSCRIPTION_ENDPOINT` (`http://127.0.0.1:18090/inference` or `:8090/inference`) backed by a dedicated `whisper-server` instance running `ggml-small-p25-a100-lora.bin`.
   - **Stage 2 (Gemma-4 E4B Multimodal + Running Context)**: Uses `SDR_MULTIMODAL_ENDPOINT` (`http://127.0.0.1:18080/v1/chat/completions`), isolating high-volume radio bursts from any primary user chat workload.
2. **`SDR_INFERENCE_MODE=shared_local`**:
   - **Stage 1 (Whisper ASR)**: Uses local `whisper-server` on `:8090` (only ~480 MB VRAM—easily co-resident on a single GPU).
   - **Stage 2 (Gemma-4 E4B Multimodal + Running Context)**: Automatically routes to the host's primary `LLM_BASE_URL` (`http://127.0.0.1:8080/v1/chat/completions`). When the George host is already running `gemma-4-E4B-it` with `--mmproj` and `--lora models/adapters/gemma4-e4b-george-sdr-v2-SVD32.gguf`, **no second LLM server is required**.
3. **`SDR_INFERENCE_MODE=ipc_bus`**:
   - Stages each incoming radio capture into `.george/sdr/spool/` and emits an `sdr_ipc_call_staged` event envelope onto `.george/ipc/event_bus.fifo` so the George background daemon can schedule transcription between interactive agent turns without GPU contention.

---

## 3. Quickstart: Deploying Your Own SDR Lab

### Prerequisites
- **SDR Hardware**: Airspy Mini (6 MSPS), Airspy R2 (10 MSPS), or RTL-SDR Blog V4 (2.4 MSPS).
- **Antenna**: 800 MHz directional Yagi (e.g., Wilson 301111) or outdoor discone fed with low-loss coax (LMR-400 / RG-6 Quad Shield).
- **Host OS**: Linux (Ubuntu 22.04/24.04 or WSL2 with `usbipd` USB passthrough) with Docker Engine & Docker Compose v2.

### Step 1: Configure `.env` and `config.json`
```bash
cd deploy/sdr-lab
cp .env.example .env
cp config/config.template.json config/config.json
```
Edit `deploy/sdr-lab/config/config.json`:
- Set `"center"` to the midpoint of your local P25 system's frequency span (from [RadioReference.com](https://www.radioreference.com/)).
- Set `"control_channels"` to your site's primary and alternate control channels in Hz.
- Place your site's `talkgroups.csv` in `deploy/sdr-lab/config/talkgroups.csv`.

### Step 2: Launch Your Chosen Topology

#### Option 1 — Capture Node Only (`sdr-server` Edge Box)
```bash
docker compose -f deploy/sdr-lab/docker-compose.yml --profile capture up -d --build
```
This builds `trunk-recorder` 5.2.0 from source with our 5-part P25 CQPSK/LSM DSP patch applied automatically, launches `rdio-scanner` on `:3000`, and starts the `sdr-pruner` sidecar that removes raw `.wav` files after `.m4a` encoding and prunes `.m4a`/`.json` files older than 24 hours.

#### Option 2 — Local All-in-One on the George Host (`local_dir` + `shared_local`)
```bash
# 1. Start the local capture container writing to /var/lib/sdr/media
SDR_MEDIA_DIR=/var/lib/sdr/media \
  docker compose -f deploy/sdr-lab/docker-compose.yml --profile capture up -d --build

# 2. Run George SDR ingest in local_dir + shared_local mode (no SSH required)
SDR_CAPTURE_MODE=local_dir \
SDR_INFERENCE_MODE=shared_local \
SDR_LOCAL_RECORDINGS=/var/lib/sdr/media/winne_p25 \
SDR_LOCAL_TALKGROUPS_CSV=/opt/blue-lodge/deploy/sdr-lab/config/talkgroups.csv \
  python3 lib/tools/sdr_ingest.py --sync
```

#### Option 3 — Full Standalone Appliance (Capture + Dedicated GPU Inference + Ingest Worker)
```bash
docker compose -f deploy/sdr-lab/docker-compose.yml --profile full up -d --build
```

---

## 4. Technical Deep Dive: The 5-Part `trunk-recorder` P25 CQPSK/LSM DSP Patch

Standard `trunk-recorder` (v5.2.0, commit `0327e1f8`) struggles on real-world 800 MHz P25 Phase 1 Linear Simulcast Modulation (LSM / CQPSK) systems when received through consumer SDRs with thermal crystal drift or multipath phase distortion. We engineered a 5-part C++/GNURadio DSP patch located at [`patches/trunk-recorder-5.2.0-p25-lsm.patch`](patches/trunk-recorder-5.2.0-p25-lsm.patch) (automatically compiled by [`deploy/sdr-lab/Dockerfile.trunk-recorder`](deploy/sdr-lab/Dockerfile.trunk-recorder)):

### Patch 1 — Costas Loop Phase Clamp & $\beta=0$ Anti-Windup
- **File**: `lib/op25_repeater/lib/costas_loop_cc_impl.cc`
- **Problem**: On CQPSK simulcast channels, $\pm\frac{\pi}{4}$ and $\pm\frac{3\pi}{4}$ differential phase transitions cause the standard OP25 4th-order Costas loop to accumulate integral frequency windup (`d_freq`) and snap to $90^\circ$ phase ambiguity boundaries.
- **Fix**: Clamps maximum instantaneous phase excursion to `d_max_phase = M_PI / 12.0f` ($\pm 15^\circ$), forces `d_beta = 0.0f` and `d_freq = 0` inside the Costas loop (relying on the external FLL band-edge frequency lock loop for coarse carrier tracking), and applies `limit_phase()` after every sample update.

### Patch 2 — NID BCH Parity Bypass & Back-to-Back Multi-Block TSBK Frame Sync
- **Files**: `lib/op25_repeater/lib/p25_framer.cc`, `lib/op25_repeater/lib/p25_framer.h`
- **Problem**: P25 control channels transmit Trunking Signaling Blocks (`TSBK`, `duid == 7`) in bursts of 1 to 3 blocks separated by exactly 24 frame-sync symbols (`48 bits`). A single corrupted bit in the 64-bit Network ID (NID) BCH code causes standard OP25 to drop the entire trunking grant burst.
- **Fix**:
  1. Enables `DISABLE_NID_PARITY_CHECK` when BCH(63,16,23) fails on `duid == 7` so the downstream trellis + CRC-16 validator decides block validity rather than discarding the frame prematurely.
  2. Adds `since_tsdu_end` symbol counter (`p25_framer.h`): when `since_tsdu_end == 24`, the framer knows a back-to-back TSBK block is arriving and relaxes the 48-bit frame-sync Hamming distance threshold up to 16 bit errors.

### Patch 3 — List-Viterbi ($K=16$) Half-Rate Trellis Decoder with CRC-16 Path Selection
- **File**: `lib/op25_repeater/lib/p25p1_fdma.cc` (`block_deinterleave`)
- **Problem**: The upstream OP25 half-rate $(196\text{ bit} \to 96\text{ bit})$ trellis decoder uses a greedy 1-step lookahead minimum-distance state selector. Under simulcast multipath fading, a single symbol glitch picks the wrong trellis transition and fails the 16-bit TSBK CRC.
- **Fix**: Replaces the greedy decoder with a **4-state, $K=16$ parallel survivor List-Viterbi decoder** across all 49 dibit steps. At the end of the 49th symbol, it iterates through the top $K=16$ lowest-metric candidate paths in ascending path-cost order and selects the **first path that passes `crc16(cand_buf, 12) == 0`**. This increased our control channel decode rate from `<12 pkt/s` to **`33–40 TSBK/s` (90%+ decode efficiency)**.

### Patch 4 — Non-Fatal Multi-Block TSBK Continuation
- **File**: `lib/op25_repeater/lib/p25p1_fdma.cc` (line 217)
- **Problem**: Upstream `p25p1_fdma.cc` executes `if (crc16(...) != 0) return;` inside the multi-block TSBK loop, aborting the entire 3-block trunking packet if block 1 or 2 fails CRC.
- **Fix**: Changes `return;` to `continue;` so remaining valid TSBK blocks in the same TSDU burst are still decoded and dispatched.

### Patch 5 — Widened 2700 Hz Channelizer LPF & Slow RMS AGC
- **File**: `trunk-recorder/recorders/p25_recorder_impl.cc` / `xlat_channelizer.cc`
- **Problem**: A narrow 2400 Hz cutoff clips the outer edges of 4800-baud C4FM/CQPSK deviation under $\pm 500\text{ Hz}$ tuner drift, while fast RMS AGC (`attack=0.45`) distorts the CQPSK amplitude envelope.
- **Fix**: Widens the channelizer low-pass filter to `2700.0 Hz` (`600.0 Hz` transition width) and reduces `rms_agc` attack rate from `0.45` to `0.01`.

---

## 5. RF Calibration, Antenna Placement & Closed-Loop Drift Tracking

### 5.1 Finding Your SDR's True Crystal Offset (`error` in Hz)
Consumer TCXOs on Airspy and RTL-SDR units typically exhibit a static offset of `3.0–4.0 ppm` (`+2500` to `+3400 Hz` at `858 MHz`).
1. Run `python3 lib/tools/sdr_ingest.py --calibrate` (or check `freq_error` in recent `.json` call captures).
2. In [`lib/tools/sdr_ingest.py`](lib/tools/sdr_ingest.py#L1293-L1410), the **Closed-Loop Costas Drift Tracker** monitors the empirical median `freq_error` across clean calls (`COHORT_TARGET_FE_HZ = -536 Hz`, dead-band `[-680, -400] Hz`).
3. On our reference `sdr-server` with the **Wilson 301111 Directional Yagi**, `error: 3180` (`+3.71 ppm`) locks the County P25 control channel (`854.4625 MHz`) at **`33–40 TSBK/s`** (`82–100%` decode rate).

### 5.2 Diagnosing Signal Quality vs. Coax/Multipath
Every call is automatically graded in [`parse_call_json()`](lib/tools/sdr_ingest.py#L722-L729):
- `CLEAN_DECODE`: `error_count / duration <= 120 errors/sec`
- `MARGINAL_SNR`: `120 < error_count / duration <= 260 errors/sec`
- `GARBLED_QPSK`: `error_count / duration > 260 errors/sec` or sub-second digital key-up (`<0.8s`)

> [!TIP]
> **Hardware Checklist for Reducing `GARBLED_QPSK`:**
> 1. **Aiming the Directional Yagi**: Point the Wilson Yagi toward the nearest county simulcast tower with elements **vertically polarized** (800 MHz public safety is vertically polarized). Sometimes aiming $10^\circ\text{–}15^\circ$ off-axis nulls out a competing secondary simulcast tower and dramatically lowers CQPSK phase errors.
> 2. **Minimize M-to-F Coax Adapters**: Every adapter junction at `858 MHz` adds `0.3–1.0 dB` insertion loss and impedance reflections. Replace chained adapters with a single pigtail jumper (`N-Female to SMA-Male`).
> 3. **Avoid Front-End Overload**: With a directional Yagi, lower `lnaGain`/`mixGain`/`ifGain` to `12 / 12 / 12` so strong nearby cellular towers (`869–894 MHz`) do not desensitize the mixer.

---

## 6. Two-Stage Whisper + Gemma-4 E4B LoRA Pipeline & Running Context Buffer

### 6.1 Audio Conditioning & Silence Splitting (`lib/tools/sdr_transcribe.py`)
Before hitting the ASR model, [`_prepare_16khz_wav_bytes()`](lib/tools/sdr_transcribe.py#L220-L275) applies a specialized FFmpeg filter chain:
```text
highpass=f=260,lowpass=f=3400,afftdn=nf=-25,dynaudnorm=f=150:g=15
```
- Strips sub-audible P25 humming (`<260 Hz`) and high-frequency IMBE vocoder hiss (`>3400 Hz`).
- Applies `-25 dB` FFT spectral noise reduction (`afftdn`) and fast-window dynamic gain normalization (`dynaudnorm`) so quiet field portables and loud dispatch consoles have uniform amplitude.
- **Long-Call Silence Splitting**: Any transmission `>12.0s` (such as a 30-second multi-exchange call) is automatically split on inter-transmission silence gaps (`silencedetect=noise=-32dB:d=0.45`) into sequential sub-windows (`<=20s`), transcribed segment-by-segment, and stitched together so Whisper never truncates after the first pause.

### 6.2 Stage 1 & Stage 2 Domain-Adapted LoRA Models (Colab A100 Playbook)
Both inference stages run custom LoRA weights trained on an NVIDIA A100-SXM4-40GB via [`scripts/colab_training/train_sdr_p25_loras_a100.py`](scripts/colab_training/train_sdr_p25_loras_a100.py) (training metrics recorded in [`models/adapters/sdr_a100_training_summary.json`](models/adapters/sdr_a100_training_summary.json)):

1. **Stage 1 (`whisper-server` on `:8090`) — `ggml-small-p25-a100-lora.bin` (`465.03 MiB`)**:
   - Base model: `xxbubziexx/whisper-small-public-safety-v2-FINAL`.
   - Trained 192 Rank-32, Alpha-64.0 LoRA layers (`q_proj`, `k_proj`, `v_proj`, `out_proj`, `fc1`, `fc2`) across 1,491 real P25 waveforms (`xxbubziexx/police-radio-punctuated-dataset` + 4x oversampled County P25 `.m4a` clips), achieving `98.18%` token accuracy specifically weighted on brevity codes (`10-4`, `10-23`, `10-97`, `Code 4`, `Signal 100`).
2. **Stage 2 (`llama-server` on `:8080`) — `gemma4-e4b-george-sdr-v2-SVD32.gguf` (`23.07 MiB`)**:
   - Base model: `unsloth/gemma-4-E4B-it` (`Q4_K_XL` GGUF + `mmproj-F16.gguf`).
   - Trained a Rank-32, Alpha-96.0 (`3.0x` multiplier) P25 Radio Dispatch & Running-Context Narrative LoRA (`train_loss: 0.1456`) and fused it (`0.65` SDR weight / `0.35` George Core v1 weight) via exact SVD-32 factorization.

### 6.3 Running Context Buffer & Continuous 3-Hour OSINT Narrative
In [`_query_running_context()`](lib/tools/sdr_transcribe.py#L465-L535), before Gemma-4 E4B summarizes a call, it queries `sdr_intel.db` over a 2-hour lookback window for:
- Prior transmissions on the **same Talkgroup (`TGID`)**
- Prior transmissions involving any of the **same Radio Unit IDs (`srcList`)**—even if that unit switched from a Dispatch channel to a Tactical channel
- Prior transmissions on the **same RF Frequency**

This running context is injected directly into the Gemma-4 E4B prompt (`=== RUNNING CONTEXT BUFFER ===`), enabling the model to link unit movements across time and generate the **Department Operational Narratives** and **Cross-Channel Unit Timelines** in [`generate_osint_sdr_summary_markdown()`](lib/tools/sdr_ingest.py#L371-L578).

---

## 7. Storage Lifecycle & Automatic Pruning

Because `trunk-recorder` with `compressWav: true` produces both an AAC `.m4a` (`~5 KB/sec`) and an uncompressed `.wav` (`~16 KB/sec`), unpruned audio can consume `~1.0–1.5 GB/day`.

The lab enforces a three-tier retention policy via [`prune_sdr_storage()`](lib/tools/sdr_ingest.py#L1072-L1147) (executed automatically on every `--sync` and via cron):
1. **Immediate `.wav` Deduplication**: Deletes raw `.wav` files as soon as the `.m4a` file exists (cuts storage footprint by **76%**).
2. **24-Hour Edge Rolling Buffer (`sdr-server`)**: Retains `.m4a` and `.json` files on the capture node for 24 hours (`remote_retention_hours=24`).
3. **7-Day Local Audio Archive + Permanent SQLite Intelligence (`user`)**: Retains `.m4a` audio in `.george/sdr/archive/` for 7 days (`local_retention_days=7`), while **preserving 100% of transcripts, tactical summaries, unit IDs, and RF metrics permanently** in `.george/sdr/sdr_intel.db` (`~1.5 KB/call`, or `<150 MB/year`).

---

## 8. George Native Tools (`sdr_query` & `sdr_listen`) & Discord Integration

George has two dedicated OpenAI function-calling tools registered in [`data/schemas/native_tools.json`](data/schemas/native_tools.json#L3887-L3961) and wired into [`lib/tools/native_tools.sh`](lib/tools/native_tools.sh#L2282-L2313), [`lib/core/context_engine.sh`](lib/core/context_engine.sh#L94-L235), and [`lib/core/react.sh`](lib/core/react.sh#L922-L1032).

Because both tools are read-only and mounted in the `+sdr` bundle as well as the `social` and `social_untrusted` profiles, **any user in Discord** (not just operators) can ask George questions about daily radio activity, talkgroup/unit timelines, summary statistics, or ask him to listen to a specific `.m4a` transmission through his multimodal audio encoder.

### 8.1 `sdr_query` — SQLite Intelligence Query, Filtering & Summary Statistics
Implemented by [`query_sdr_database()`](lib/tools/sdr_ingest.py#L1685-L1995), `sdr_query` supports four output modes (`mode`) and rich filters:
- **Parameters**:
  - `mode`:
    - `"summary"` *(default)*: Combined statistical overview, department operational narratives, and matching call log.
    - `"stats"`: Detailed database statistics (total calls, cumulative duration, average CQPSK spike & decode error rates, hourly activity histogram, top talkgroups, top radio unit IDs, and frequency utilization).
    - `"calls"`: Chronological transmission log with `call_id`, timestamp, talkgroup, frequency, duration, radio unit IDs, tactical summary, and transcript.
    - `"unit_timeline"`: Cross-channel movement timeline tracking specific Radio Unit IDs across Dispatch and Tactical channels.
  - `hours`: Lookback window in hours (default `24`, max `720`).
  - `talkgroup`: Substring or numeric TGID filter (e.g., `"County EMS"`, `"Metro Fire"`, `"61615"`).
  - `unit_id`: Radio unit ID filter (e.g., `"7100001"`, `"6115208"`).
  - `category`: Agency category (`"FIRE_EMS"`, `"LAW_DISPATCH"`, `"LAW_TAC"`, `"PUBLIC_WORKS"`).
  - `search`: Full-text keyword search across transcripts, tactical summaries, and talkgroup names (e.g., `"10-4"`, `"chest pain"`, `"Main St"`).
  - `emergency_only`: Boolean filter for P25 emergency flag activations.
  - `limit`: Max transmissions returned (default `25`, max `100`).

### 8.2 `sdr_listen` — Multimodal Audio Encoder Deep-Listen (`.m4a` Consumption)
Implemented by [`listen_sdr_call()`](lib/tools/sdr_ingest.py#L1998-L2120) and [`analyze_audio_with_encoder()`](lib/tools/sdr_transcribe.py#L1034-L1145), `sdr_listen` allows George to consume any `.m4a` or `.wav` recording directly into his two-stage audio encoder:
- **Parameters**:
  - `call_id`: Call ID from `sdr_query` (e.g., `"61591-1792359429.476_857737500.0-call_966"`), `"latest"` for the most recent intelligible call, or a direct `.m4a` file path.
  - `prompt`: Optional custom inspection question for the Gemma-4 E4B multimodal audio encoder (e.g., `"What exact street address or cross-streets were spoken, what is the background noise, and did the unit say 10-4?"`).
- **How It Works**:
  1. Resolves the `.m4a` file locally in `.george/sdr/archive/` or `.george/sdr/spool/`, or fetches it on-demand via `scp` from `sdr-server` if still in the 24-hour edge buffer.
  2. Applies the `260–3400 Hz` P25 bandpass + `-25 dB` spectral denoise + dynamic gain normalizer to produce 16 kHz mono WAV bytes.
  3. Runs **Stage 1 Whisper P25-A100-LoRA (`:18090`)** (with long-call silence splitting) and **Stage 2 Gemma-4 E4B Multimodal (`:18080` `input_audio`)** injected with the 2-hour **Running Context Buffer** and the user's `prompt`.

---

## 9. CLI Reference & `/sdr` Slash Command

### 9.1 Interactive `/sdr` Lodge Slash Command
Inside George's interactive CLI (`./lodge`), use `/sdr`:
```text
/sdr status                       # Pipeline health, GPU endpoints & capture node status
/sdr stats [hours]                # Summary statistics (top talkgroups, units, hourly histogram)
/sdr query [args...]              # Filter calls (--talkgroup "County EMS" --hours 12 --search "10-4")
/sdr unit <unit_id> [hours]       # Cross-channel timeline for a specific radio unit ID
/sdr listen <call_id|latest> [q]  # Re-encode .m4a audio with Whisper + Gemma-4 E4B audio encoder
/sdr sync                         # Ingest new calls from sdr-server, transcribe & prune
/sdr prune [days]                 # Deduplicate .wav files and prune archives older than N days
/sdr sitrep [hours]               # Generate 3-hour OSINT SitRep Markdown with unit narratives
```

### 9.2 Direct Python CLI Reference
```bash
# Check overall SDR Lab health, active topology, GPU endpoints, and recent calls
python3 lib/tools/sdr_ingest.py --status

# Query & filter SDR database (modes: summary, stats, calls, unit_timeline)
python3 lib/tools/sdr_ingest.py --query --mode stats --hours 24
python3 lib/tools/sdr_ingest.py --query --talkgroup "County EMS" --hours 12
python3 lib/tools/sdr_ingest.py --query --mode unit_timeline --unit "7100001" --hours 24

# Consume an .m4a call into the Whisper + Gemma-4 E4B Multimodal Audio Encoder
python3 lib/tools/sdr_ingest.py --listen "latest" --prompt "Verify all unit numbers and addresses"

# Sync new calls, transcribe via Two-Stage Whisper + Gemma-4 E4B, calibrate, and prune
python3 lib/tools/sdr_ingest.py --sync

# Run storage deduplication and retention pruning manually
python3 lib/tools/sdr_ingest.py --prune --retention-days 7 --remote-retention-hours 24

# Generate the 3-Hour OSINT SitRep Markdown with Department & Unit Narratives
python3 lib/tools/sdr_ingest.py --osint-markdown

# Retrain or update the Whisper & Gemma-4 E4B LoRA adapters on Colab A100
python3 scripts/colab_training/train_sdr_p25_loras_a100.py
```

