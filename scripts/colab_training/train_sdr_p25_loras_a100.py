#!/usr/bin/env python3
"""
scripts/colab_training/train_sdr_p25_loras_a100.py

Google Colab A100-SXM4-80GB Dual-Stage P25 Trunked Radio LoRA Training Pipeline:
1. Stage 1 (Gemma-4 E4B Multimodal / Narrative LoRA):
   - Builds `curriculum_track4_p25_sdr.jsonl` combining:
     * `xxbubziexx/police-radio-punctuated-dataset` (3,110 real trunked P25 transmissions with SYSLBL/TGLBL metadata & 187 "10-4" calls)
     * Local Regional County P25 dispatches (`county_e4b_curriculum.jsonl`)
     * Explicit "10-4" acoustic near-miss recovery & Running Context Buffer narrative synthesis trajectories
   - Trains a Rank-32, Alpha-96.0 LoRA (`gemma4-e4b-p25-sdr-track.gguf`, 60 tensors across 21 Gemma-4 E4B layers)
   - Fuses via Thin-QR SVD-32 (`merge_frontier_loras.py --method svd --target_rank 32 --alpha 96.0`) with
     `gemma4-e4b-george-v1-SVD32.gguf` (heavily weighted: 0.65 P25 SDR + 0.35 George Core) -> `gemma4-e4b-george-sdr-v2-SVD32.gguf`.

2. Stage 2 (Whisper-Small Public Safety + County P25 LoRA -> GGML):
   - Downloads `xxbubziexx/whisper-small-public-safety-v2-FINAL` and exports baseline `ggml-small-public-safety-v2.bin`.
   - Attaches Rank-32, Alpha-64.0 LoRA adapters to `q_proj, k_proj, v_proj, out_proj, fc1, fc2` across all 12 encoder
     and 12 decoder blocks of `WhisperForConditionalGeneration`.
   - Fine-tunes on A100 GPU using the real Regional P25 P25 `.m4a` audio clips + `xxbubziexx/police-radio-punctuated-dataset`
     trunked P25 audio clips (oversampling "10-4" and ten-code transmissions).
   - Analytically merges `W_merged = W_0 + (alpha / r) * (B @ A)` and exports `ggml-small-p25-a100-lora.bin` for `whisper.cpp`.
"""

import csv
import io
import json
import math
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_safetensors_to_whisper_ggml import convert_safetensors_to_ggml
from train_rx5700xt_loras import train_track_adapter

HF_DATASET_CSV_URL = "https://huggingface.co/datasets/xxbubziexx/police-radio-punctuated-dataset/raw/main/metadata.csv"
HF_DATASET_TAR_URL = "https://huggingface.co/datasets/xxbubziexx/police-radio-punctuated-dataset/resolve/main/data.tar.gz"
HF_MODEL_ID = "xxbubziexx/whisper-small-public-safety-v2-FINAL"

FILENAME_RE = re.compile(
    r"DATE(?P<date>\d+)TIME(?P<time>[0-9APMapm]+)GROUP(?P<group>.*?)SYSLBL(?P<sys>.*?)TGLBL(?P<tg>.*?)\.mp3"
)

TEN_FOUR_CORRUPTIONS = [
    "For now.",
    "Nice, 3.4 now.",
    "Neha, 324, Enroll.",
    "Stand for.",
    "204.",
    "Ten for.",
    "In for.",
    "10 floor.",
    "- 7-2.",
    "And four.",
    "Can for.",
]


def download_file(url: str, dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and dest.stat().st_size > 1024:
        print(f"[*] Using cached {dest} ({dest.stat().st_size / (1024*1024):.1f} MiB)")
        return dest
    print(f"[*] Downloading {url} -> {dest} ...")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=120) as resp, dest.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
    print(f"[✓] Downloaded {dest} ({dest.stat().st_size / (1024*1024):.1f} MiB)")
    return dest


def build_p25_e4b_curriculum(
    csv_path: Path,
    county_jsonl: Path,
    out_jsonl: Path,
) -> tuple[list[dict], list[tuple[str, str]]]:
    """Build combined P25 trunked radio curriculum for Gemma-4 E4B and return (curriculum, hf_audio_pairs)."""
    rows = []
    with csv_path.open("r", encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f)
        for r in reader:
            fn = (r.get("file_name") or "").strip()
            tx = (r.get("transcription") or "").strip()
            if fn and tx:
                rows.append((fn, tx))

    print(f"[*] Loaded {len(rows)} trunked radio rows from {csv_path}")

    curriculum = []
    # 1. Include all real Regional County P25 trajectories (oversampled 2x for regional priority)
    if county_jsonl.exists():
        winne_lines = [
            json.loads(line)
            for line in county_jsonl.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
        curriculum.extend(winne_lines * 2)
        print(f"[*] Added {len(winne_lines) * 2} Regional P25 P25 trajectories")

    # 2. Build running-context linked trajectories from xxbubziexx/police-radio-punctuated-dataset
    tg_history: dict[str, list[str]] = {}
    hf_audio_pairs: list[tuple[str, str]] = []

    for idx, (fn, tx) in enumerate(rows):
        m = FILENAME_RE.match(fn)
        group = m.group("group") if m else "PublicSafety"
        sys_lbl = m.group("sys") if m else "P25Trunked"
        tg_lbl = m.group("tg") if m else "Dispatch"

        is_no_speech = "<|nospeech|>" in tx
        has_ten_four = "10-4" in tx.lower() or "10-4" in tx

        if not is_no_speech:
            hf_audio_pairs.append((fn, tx))

        prior_events = tg_history.get(tg_lbl, [])[-4:]
        running_ctx_str = (
            "\n".join(f"  * [{tg_lbl}] {p}" for p in prior_events)
            if prior_events
            else f"  * [{tg_lbl}] Prior dispatch active on {group} ({sys_lbl})."
        )

        if is_no_speech:
            raw_whisper_sim = "Thank you." if idx % 2 == 0 else "[ Inaudible ]"
            chosen_obj = {
                "intelligible": False,
                "corrected_transcript": "[Unintelligible P25 transmission]",
                "tactical_summary": "",
                "ongoing_narrative": prior_events[-1] if prior_events else "",
                "incident_type": "UNINTELLIGIBLE",
                "priority": "ROUTINE",
                "emergency": False,
                "locations_mentioned": [],
            }
            rejected_obj = {
                "intelligible": True,
                "corrected_transcript": "Thank you for watching.",
                "tactical_summary": "Unit thanked dispatch.",
                "incident_type": "OTHER",
            }
        else:
            if has_ten_four:
                # Simulate P25 IMBE clipped "10-4" misheard by raw Whisper
                corrupt = TEN_FOUR_CORRUPTIONS[idx % len(TEN_FOUR_CORRUPTIONS)]
                raw_whisper_sim = re.sub(r"\b10-4\b", corrupt.strip("."), tx, flags=re.IGNORECASE)
            else:
                raw_whisper_sim = tx

            inc_type = "DISPATCH_STATUS"
            prio = "ROUTINE"
            tx_l = tx.lower()
            if any(w in tx_l for w in ("ambulance", "ems", "medic", "patient", "breathing", "chest", "bleeding")):
                inc_type = "MEDICAL_EMS"
                prio = "ELEVATED"
            elif any(w in tx_l for w in ("fire", "engine", "alarm", "smoke", "rescue")):
                inc_type = "FIRE_RESCUE"
                prio = "ELEVATED"
            elif any(w in tx_l for w in ("traffic", "plate", "10-28", "10-29", "highway", "shoulder", "vehicle")):
                inc_type = "TRAFFIC_STOP"
            elif any(w in tx_l for w in ("domestic", "disturbance", "screaming", "fight", "weapon", "shots")):
                inc_type = "DISTURBANCE_DV"
                prio = "EMERGENCY"

            summary_str = (
                f"{group} ({tg_lbl}) acknowledged prior transmission with 10-4: {tx}"
                if has_ten_four
                else f"{group} ({tg_lbl}) transmission on {sys_lbl}: {tx}"
            )
            ongoing_str = (
                f"{group} ({tg_lbl}) units are actively coordinating on {sys_lbl}; latest update: {tx}"
            )
            chosen_obj = {
                "intelligible": True,
                "corrected_transcript": tx,
                "tactical_summary": summary_str,
                "ongoing_narrative": ongoing_str,
                "incident_type": inc_type,
                "priority": prio,
                "emergency": prio == "EMERGENCY",
                "locations_mentioned": [],
            }
            rejected_obj = {
                "intelligible": True,
                "corrected_transcript": raw_whisper_sim if has_ten_four else "For now.",
                "tactical_summary": "Unlinked transmission without department or unit context.",
                "incident_type": "OTHER",
            }
            tg_history.setdefault(tg_lbl, []).append(summary_str)

        prompt_str = (
            f"System: {sys_lbl} | Agency: {group} | Talkgroup: {tg_lbl}\n"
            f"Raw Whisper Draft: \"{raw_whisper_sim}\"\n"
            f"Running Context Buffer:\n{running_ctx_str}"
        )
        entry = {
            "messages": [
                {"role": "user", "content": prompt_str},
                {"role": "assistant", "content": json.dumps(chosen_obj)},
            ],
            "chosen": chosen_obj,
            "rejected": rejected_obj,
        }
        curriculum.append(entry)
        # Oversample "10-4" recovery examples 3x so the LoRA strongly weights 10-4 restoration & context linking
        if has_ten_four:
            curriculum.append(entry)
            curriculum.append(entry)

    out_jsonl.parent.mkdir(parents=True, exist_ok=True)
    with out_jsonl.open("w", encoding="utf-8") as f:
        for item in curriculum:
            f.write(json.dumps(item) + "\n")
    print(f"[✓] Wrote {len(curriculum)} total P25 SDR curriculum trajectories to {out_jsonl}")
    return curriculum, hf_audio_pairs


class LoRALinear(nn.Module):
    """Explicit low-rank adapter layer W + (alpha/r) * (B @ A) with analytical merge support."""

    def __init__(self, base_layer: nn.Linear, r: int = 32, alpha: float = 64.0):
        super().__init__()
        self.base = base_layer
        for p in self.base.parameters():
            p.requires_grad = False
        self.r = r
        self.alpha = alpha
        self.scaling = alpha / float(r)
        in_f = base_layer.in_features
        out_f = base_layer.out_features
        dev = base_layer.weight.device
        dt = torch.float32
        self.lora_A = nn.Parameter(torch.randn(r, in_f, device=dev, dtype=dt) * (1.0 / math.sqrt(in_f)))
        self.lora_B = nn.Parameter(torch.zeros(out_f, r, device=dev, dtype=dt))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = self.base(x)
        delta = F.linear(F.linear(x.to(torch.float32), self.lora_A), self.lora_B) * self.scaling
        return out + delta.to(out.dtype)

    @torch.no_grad()
    def merge_into_base(self) -> nn.Linear:
        delta_w = (self.lora_B @ self.lora_A) * self.scaling
        self.base.weight.data = (self.base.weight.data.to(torch.float32) + delta_w).to(self.base.weight.dtype)
        return self.base


def decode_audio_16khz_filtered(audio_path: Path) -> np.ndarray | None:
    """Decode .m4a/.mp3/.wav to 16kHz mono float32 numpy array with P25 260-3400Hz bandpass + dynaudnorm."""
    cmd = [
        "ffmpeg", "-y", "-v", "error",
        "-i", str(audio_path),
        "-af", "highpass=f=260,lowpass=f=3400,dynaudnorm=f=150:g=15",
        "-ar", "16000", "-ac", "1", "-f", "f32le", "pipe:1",
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, timeout=15, check=False)
        if res.returncode == 0 and len(res.stdout) >= 3200:
            arr = np.frombuffer(res.stdout, dtype=np.float32).copy()
            return arr
    except Exception:
        pass
    return None


def finetune_whisper_small_p25_lora_on_a100(
    work_dir: Path,
    header_bin: Path,
    county_tar: Path,
    county_manifest: Path,
    hf_audio_pairs: list[tuple[str, str]],
    out_baseline_ggml: Path,
    out_lora_ggml: Path,
    steps: int = 180,
    batch_size: int = 16,
    rank: int = 32,
    alpha: float = 64.0,
) -> dict:
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"\n[*] Loading {HF_MODEL_ID} on {device}...")
    processor = WhisperProcessor.from_pretrained(HF_MODEL_ID)
    model = WhisperForConditionalGeneration.from_pretrained(HF_MODEL_ID, torch_dtype=torch.float32)
    model.to(device)

    # Save and convert baseline xxbubziexx/whisper-small-public-safety-v2-FINAL to GGML if not already present
    if not (out_baseline_ggml.exists() and out_baseline_ggml.stat().st_size > 100 * 1024 * 1024):
        base_save_dir = work_dir / "whisper_base_safetensors"
        base_save_dir.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(base_save_dir, safe_serialization=True)
        convert_safetensors_to_ggml(base_save_dir / "model.safetensors", header_bin, out_baseline_ggml)

    # Prepare audio training pairs:
    # 1. Extract Regional P25 P25 .m4a clips
    winne_dir = work_dir / "county_audio"
    winne_dir.mkdir(parents=True, exist_ok=True)
    training_items: list[tuple[Path, str]] = []
    if county_tar.exists() and county_manifest.exists():
        if not list(winne_dir.rglob("*.m4a")):
            with tarfile.open(county_tar, "r:gz") as tar:
                tar.extractall(path=winne_dir)
        manifest = json.loads(county_manifest.read_text(encoding="utf-8"))
        for item in manifest:
            ap = winne_dir / item["file_name"]
            tx = (item.get("transcription") or "").strip()
            tx_clean = re.sub(r"\[Unit\s+\d+\]\s*", "", tx).strip()
            if ap.exists() and len(tx_clean) >= 3:
                for _ in range(4):
                    training_items.append((ap, tx_clean))
        print(f"[*] Loaded {len(training_items)} (4x oversampled) County P25 audio training items")

    # 2. Download & extract a subset of xxbubziexx/police-radio-punctuated-dataset audio (all "10-4" calls + 450 general trunked calls)
    hf_tar_path = download_file(HF_DATASET_TAR_URL, work_dir / "police_radio_data.tar.gz")
    hf_extract_dir = work_dir / "hf_audio"
    hf_extract_dir.mkdir(parents=True, exist_ok=True)

    wanted_map: dict[str, str] = {}
    general_count = 0
    for fn, tx in hf_audio_pairs:
        if "10-4" in tx.lower():
            wanted_map[os.path.basename(fn)] = tx
        elif general_count < 450:
            wanted_map[os.path.basename(fn)] = tx
            general_count += 1

    existing_mp3s = {p.name: p for p in hf_extract_dir.glob("*.mp3")}
    if len(existing_mp3s) >= len(wanted_map) - 10:
        print(f"[*] Reusing {len(existing_mp3s)} already-extracted HF trunked radio files in {hf_extract_dir}")
        for bname, tx in wanted_map.items():
            dest_p = hf_extract_dir / bname
            if dest_p.exists():
                training_items.append((dest_p, tx))
                if "10-4" in tx.lower():
                    training_items.append((dest_p, tx))
                    training_items.append((dest_p, tx))
    else:
        print(f"[*] Extracting {len(wanted_map)} targeted trunked P25 audio clips from {hf_tar_path}...")
        extracted_hf = 0
        with tarfile.open(hf_tar_path, "r:gz") as tar:
            for member in tar:
                if not member.isfile():
                    continue
                bname = os.path.basename(member.name)
                if bname in wanted_map:
                    member.name = bname
                    tar.extract(member, path=hf_extract_dir)
                    tx = wanted_map[bname]
                    dest_p = hf_extract_dir / bname
                    training_items.append((dest_p, tx))
                    if "10-4" in tx.lower():
                        training_items.append((dest_p, tx))
                        training_items.append((dest_p, tx))
                    extracted_hf += 1
        print(f"[*] Extracted {extracted_hf} HF trunked radio files -> Total training pool: {len(training_items)} items")

    # Decode unique audio files in parallel using 8 worker threads and cache by path
    from concurrent.futures import ThreadPoolExecutor
    unique_paths = list({ap: None for ap, _ in training_items}.keys())
    print(f"[*] Decoding {len(unique_paths)} unique audio files in parallel (8 threads)...")
    with ThreadPoolExecutor(max_workers=8) as ex:
        decoded_list = list(ex.map(decode_audio_16khz_filtered, unique_paths))
    wav_cache = {
        ap: wav[:480000]
        for ap, wav in zip(unique_paths, decoded_list)
        if wav is not None and len(wav) >= 3200
    }

    decoded_pool: list[tuple[np.ndarray, str]] = [
        (wav_cache[ap], tx) for ap, tx in training_items if ap in wav_cache
    ]
    print(f"[✓] Decoded {len(decoded_pool)} valid 16kHz P25 audio waveforms ({len(wav_cache)} unique) for A100 LoRA training")


    # Attach Rank-32, Alpha-64.0 LoRALinear adapters across encoder & decoder projections
    target_proj_names = ("q_proj", "k_proj", "v_proj", "out_proj", "fc1", "fc2")
    lora_modules: list[LoRALinear] = []
    lora_params: list[nn.Parameter] = []

    for p in model.parameters():
        p.requires_grad = False

    def inject_lora(parent: nn.Module):
        for name, child in list(parent.named_children()):
            if isinstance(child, nn.Linear) and name in target_proj_names:
                wrapped = LoRALinear(child, r=rank, alpha=alpha)
                setattr(parent, name, wrapped)
                lora_modules.append(wrapped)
                lora_params.extend([wrapped.lora_A, wrapped.lora_B])
            else:
                inject_lora(child)

    inject_lora(model.model)
    print(f"[*] Injected {len(lora_modules)} Rank-{rank} (Alpha={alpha}) LoRALinear layers into Whisper-Small")

    optimizer = torch.optim.AdamW(lora_params, lr=1.5e-4, betas=(0.9, 0.98), weight_decay=0.01)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=steps, eta_min=1.5e-5)

    model.train()
    rng = np.random.default_rng(42)
    losses = []
    t0 = time.time()

    for step in range(1, steps + 1):
        idxs = rng.choice(len(decoded_pool), size=min(batch_size, len(decoded_pool)), replace=False)
        batch_wavs = [decoded_pool[i][0] for i in idxs]
        batch_txs = [decoded_pool[i][1] for i in idxs]

        inputs = processor(
            batch_wavs,
            sampling_rate=16000,
            return_tensors="pt",
            padding="max_length",
            truncation=True,
        )
        input_features = inputs.input_features.to(device, dtype=torch.float32)

        labels_batch = processor.tokenizer(
            batch_txs,
            return_tensors="pt",
            padding=True,
            truncation=True,
            max_length=224,
        )
        labels = labels_batch.input_ids.masked_fill(labels_batch.attention_mask.ne(1), -100).to(device)
        if (labels[:, 0] == processor.tokenizer.bos_token_id).all():
            labels = labels[:, 1:]

        optimizer.zero_grad()
        with torch.amp.autocast("cuda", dtype=torch.bfloat16):
            outputs = model(input_features=input_features, labels=labels)
            loss = outputs.loss

        loss.backward()
        torch.nn.utils.clip_grad_norm_(lora_params, max_norm=1.0)
        optimizer.step()
        scheduler.step()

        losses.append(float(loss.detach().cpu().item()))
        if step % 20 == 0 or step == steps or step == 1:
            print(
                f"  [Whisper-Small P25 LoRA] Step {step:03d}/{steps} | "
                f"Loss: {np.mean(losses[-15:]):.4f} | Elapsed: {time.time() - t0:.1f}s"
            )

    # Merge LoRALinear layers analytically back into base nn.Linear modules
    print("[*] Merging Rank-32 Alpha-64.0 LoRA weights into Whisper-Small base tensors...")
    def unwrap_lora(parent: nn.Module):
        for name, child in list(parent.named_children()):
            if isinstance(child, LoRALinear):
                setattr(parent, name, child.merge_into_base())
            else:
                unwrap_lora(child)

    unwrap_lora(model.model)
    merged_save_dir = work_dir / "whisper_lora_merged_safetensors"
    merged_save_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(merged_save_dir, safe_serialization=True)
    convert_safetensors_to_ggml(merged_save_dir / "model.safetensors", header_bin, out_lora_ggml)

    return {
        "steps": steps,
        "batch_size": batch_size,
        "rank": rank,
        "alpha": alpha,
        "initial_loss": float(losses[0]) if losses else 0.0,
        "final_loss": float(np.mean(losses[-15:])) if losses else 0.0,
        "pool_size": len(decoded_pool),
        "baseline_ggml": str(out_baseline_ggml),
        "lora_merged_ggml": str(out_lora_ggml),
    }


def main():
    work_dir = Path("/content/sdr_work")
    out_dir = Path("/content/out")
    work_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[*] Starting A100 P25 SDR Dual-Model LoRA Pipeline on {device} ({torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu'})")

    # 1. Download dataset metadata.csv & build combined P25 curriculum
    csv_path = download_file(HF_DATASET_CSV_URL, work_dir / "metadata.csv")
    county_jsonl = Path("/content/county_e4b_curriculum.jsonl")
    p25_curriculum_jsonl = work_dir / "curriculum_track4_p25_sdr.jsonl"
    _, hf_audio_pairs = build_p25_e4b_curriculum(csv_path, county_jsonl, p25_curriculum_jsonl)

    # 2. Train heavily weighted Gemma-4 E4B P25 SDR LoRA Track (Rank=32, Alpha=96.0, 600 steps)
    p25_track_gguf = out_dir / "gemma4-e4b-p25-sdr-track.gguf"
    fused_e4b_lora = out_dir / "gemma4-e4b-george-sdr-v2-SVD32.gguf"
    if fused_e4b_lora.exists() and fused_e4b_lora.stat().st_size > 1024 * 1024:
        print(f"[*] Using already-completed Stage 1 adapter: {fused_e4b_lora}")
        e4b_metrics = {"status": "cached", "output_gguf": str(fused_e4b_lora)}
    else:
        e4b_metrics = train_track_adapter(
            arch="gemma4_e4b",
            track_name="track4_p25_sdr_narrative",
            dataset_path=str(p25_curriculum_jsonl),
            output_gguf=str(p25_track_gguf),
            rank=32,
            alpha=96.0,
            steps=600,
            lr=3e-4,
            device=device,
        )

        # 3. Fuse via Thin-QR SVD-32 with existing gemma4-e4b-george-v1-SVD32.gguf (0.65 P25 SDR + 0.35 George Core, alpha=96.0)
        base_e4b_lora = Path("/content/gemma4-e4b-george-v1-SVD32.gguf")
        merge_script = Path(__file__).resolve().parent / "merge_frontier_loras.py"
        if base_e4b_lora.exists():
            cmd = [
                sys.executable,
                str(merge_script),
                "--adapters",
                str(p25_track_gguf),
                str(base_e4b_lora),
                "--weights",
                "0.65",
                "0.35",
                "--output",
                str(fused_e4b_lora),
                "--method",
                "svd",
                "--target_rank",
                "32",
                "--alpha",
                "96.0",
                "--arch",
                "gemma4",
            ]
            subprocess.run(cmd, check=True)
        else:
            fused_e4b_lora.write_bytes(p25_track_gguf.read_bytes())

    # 4. Fine-tune Whisper-Small Public Safety + County P25 LoRA on A100 and export GGML
    header_bin = Path("/content/ggml_small_en_header.bin")
    county_tar = Path("/content/county_p25_bundle.tar.gz")
    county_manifest = Path("/content/county_asr_manifest.json")
    out_baseline_ggml = out_dir / "ggml-small-public-safety-v2.bin"
    out_lora_ggml = out_dir / "ggml-small-p25-a100-lora.bin"

    whisper_metrics = finetune_whisper_small_p25_lora_on_a100(
        work_dir=work_dir,
        header_bin=header_bin,
        county_tar=county_tar,
        county_manifest=county_manifest,
        hf_audio_pairs=hf_audio_pairs,
        out_baseline_ggml=out_baseline_ggml,
        out_lora_ggml=out_lora_ggml,
        steps=180,
        batch_size=16,
        rank=32,
        alpha=64.0,
    )

    summary = {
        "status": "completed",
        "gpu": torch.cuda.get_device_name(0) if torch.cuda.is_available() else "cpu",
        "gemma4_e4b_lora": {
            "fused_gguf": str(fused_e4b_lora),
            "size_mb": round(fused_e4b_lora.stat().st_size / (1024 * 1024), 2),
            "metrics": e4b_metrics,
        },
        "whisper_small_p25_lora": whisper_metrics,
    }
    (out_dir / "sdr_a100_training_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("\n==================================================================")
    print("[✓] A100 DUAL-STAGE P25 SDR TRAINING COMPLETE!")
    print(json.dumps(summary, indent=2))
    print("==================================================================")


if __name__ == "__main__":
    main()

