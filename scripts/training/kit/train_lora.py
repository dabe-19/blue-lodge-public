#!/usr/bin/env python3
"""Blue Lodge LoRA SFT / DPO training kit — model-agnostic, checkpoint-resumable, Unsloth-optional,
and capable of exporting GGUF LoRA adapters right on the training GPU (e.g. Google Colab A100/G4/H100).

Dataset rows may be any of:
    {"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}], "tools": [...]}
    {"prompt": [...], "chosen": [...], "rejected": [...], "tools": [...]}   (DPO mode)
    {"prompt": "...", "completion": "..."}   (or "response")
    {"instruction": "...", "input": "...", "output": "..."}
    {"text": "..."}
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import urllib.request


def _rows_to_messages(ex: dict) -> dict:
    if ex.get("messages"):
        return {"messages": ex["messages"], "tools": ex.get("tools") or None}
    if ex.get("conversations"):
        role = {"human": "user", "gpt": "assistant", "system": "system"}
        msgs = [{"role": role.get(m.get("from"), m.get("from")), "content": m.get("value", "")} for m in ex["conversations"]]
        return {"messages": msgs, "tools": None}
    if "prompt" in ex:
        return {"messages": [{"role": "user", "content": ex["prompt"]},
                             {"role": "assistant", "content": ex.get("completion") or ex.get("response") or ""}],
                "tools": None}
    if "instruction" in ex:
        user = ex["instruction"] + (("\n\n" + ex["input"]) if ex.get("input") else "")
        return {"messages": [{"role": "user", "content": user}, {"role": "assistant", "content": ex.get("output", "")}],
                "tools": None}
    return {"text": ex.get("text", "")}


def _find_latest_checkpoint(ckpt_dir: str | None) -> str | None:
    if not ckpt_dir or not os.path.isdir(ckpt_dir):
        return None
    cands = []
    for p in glob.glob(os.path.join(ckpt_dir, "checkpoint-*")):
        m = re.search(r"checkpoint-(\d+)$", p)
        if m and os.path.isdir(p):
            cands.append((int(m.group(1)), p))
    if not cands:
        return None
    cands.sort(key=lambda x: x[0])
    return cands[-1][1]


def _resolve_resume(arg_val: str | None, ckpt_dir: str) -> str | None:
    if not arg_val:
        return None
    if arg_val == "latest":
        return _find_latest_checkpoint(ckpt_dir)
    return arg_val if os.path.isdir(arg_val) else None


def _export_adapter_gguf(adapter_dir: str, base_model: str, out_gguf: str, base_local_path: str | None = None) -> bool:
    """Convert saved PEFT adapter to GGUF right on the training host (works on Colab without local 60 GB HF weights)."""
    conv = None
    for cand in (
        os.environ.get("LLAMA_CPP_DIR") and os.path.join(os.environ["LLAMA_CPP_DIR"], "convert_lora_to_gguf.py"),
        "/opt/llama.cpp/convert_lora_to_gguf.py",
        "/content/convert_lora_to_gguf.py",
        os.path.expanduser("~/llama.cpp/convert_lora_to_gguf.py"),
    ):
        if cand and os.path.isfile(cand):
            conv = cand
            break

    if not conv:
        # Lightweight download of official stock llama.cpp convert_lora_to_gguf.py (~40 KB)
        dl_path = os.path.join(os.path.dirname(os.path.abspath(out_gguf)), "convert_lora_to_gguf.py")
        url = "https://raw.githubusercontent.com/ggml-org/llama.cpp/master/convert_lora_to_gguf.py"
        try:
            print(f"[*] Fetching stock llama.cpp convert_lora_to_gguf.py -> {dl_path}...")
            urllib.request.urlretrieve(url, dl_path)
            conv = dl_path
        except Exception as e:
            print(f"[!] Could not fetch convert_lora_to_gguf.py: {e}", file=sys.stderr)
            return False

    argv = [sys.executable, conv, adapter_dir, "--outtype", "f16", "--outfile", out_gguf]
    if base_local_path and os.path.isfile(os.path.join(base_local_path, "config.json")):
        argv += ["--base", base_local_path]
    else:
        argv += ["--base-model-id", base_model]

    print(f"[*] Exporting GGUF LoRA adapter: {' '.join(argv)}")
    r = subprocess.run(argv, capture_output=True, text=True, check=False)
    if r.returncode == 0 and os.path.isfile(out_gguf):
        print(f"[✓] Exported GGUF adapter -> {out_gguf} ({os.path.getsize(out_gguf) / (1024*1024):.1f} MiB)")
        return True
    print(f"[!] In-place GGUF export failed (adapter PEFT still saved cleanly): {(r.stderr or r.stdout)[-500:]}", file=sys.stderr)
    return False


def _load_model_and_tokenizer(cfg: dict, torch, init_adapter: str | None):
    hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or None
    base_src = cfg.get("base_local_path") or cfg["base_model"]
    use_unsloth = bool(cfg.get("use_unsloth", False)) and torch.cuda.is_available()

    if use_unsloth:
        try:
            from unsloth import FastLanguageModel
            print(f"[*] Loading {base_src} via Unsloth FastLanguageModel (4-bit={bool(cfg.get('load_in_4bit', True))})...")
            model, tok = FastLanguageModel.from_pretrained(
                model_name=base_src,
                max_seq_length=int(cfg.get("max_seq_len", 4096)),
                dtype=None,
                load_in_4bit=bool(cfg.get("load_in_4bit", True)),
                token=hf_token,
            )
            if init_adapter:
                from peft import PeftModel
                model = PeftModel.from_pretrained(model, init_adapter, is_trainable=True)
            else:
                model = FastLanguageModel.get_peft_model(
                    model,
                    r=int(cfg["lora_r"]),
                    lora_alpha=int(cfg["lora_alpha"]),
                    lora_dropout=float(cfg.get("lora_dropout", 0.0)),
                    target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
                    use_gradient_checkpointing="unsloth",
                )
            if tok.pad_token is None:
                tok.pad_token = tok.eos_token
            return model, tok, True
        except Exception as e:
            print(f"[!] Unsloth unavailable or failed ({e}); falling back to standard Transformers + PEFT QLoRA.")

    from transformers import AutoModelForCausalLM, AutoTokenizer
    tok = AutoTokenizer.from_pretrained(base_src, use_fast=True, token=hf_token)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    kwargs = {"torch_dtype": torch.bfloat16 if torch.cuda.is_available() else torch.float32}
    if hf_token:
        kwargs["token"] = hf_token
    if cfg.get("load_in_4bit") and torch.cuda.is_available():
        from transformers import BitsAndBytesConfig
        kwargs["quantization_config"] = BitsAndBytesConfig(
            load_in_4bit=True, bnb_4bit_quant_type="nf4", bnb_4bit_compute_dtype=torch.bfloat16,
            bnb_4bit_use_double_quant=True,
        )
    model = AutoModelForCausalLM.from_pretrained(base_src, device_map="auto", **kwargs)
    model.config.use_cache = False
    if init_adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, init_adapter, is_trainable=True)
    return model, tok, False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--dry-run", action="store_true", help="load data + tokenizer only; no training")
    ap.add_argument("--mode", choices=("sft", "dpo"), default=None)
    ap.add_argument("--init-adapter", default=None, help="continue from an existing PEFT adapter")
    ap.add_argument("--resume-from-checkpoint", default=None, help="'latest' or path to checkpoint-N dir")
    ap.add_argument("--checkpoint-dir", default=None, help="override checkpoint directory (e.g. Google Drive path)")
    ap.add_argument("--export-gguf", default=None, help="also export adapter GGUF to this path after training")
    a = ap.parse_args()
    cfg = json.load(open(a.config, encoding="utf-8"))
    mode = a.mode or cfg.get("mode", "sft")
    if mode == "dpo":
        return train_dpo(cfg, a)

    try:
        import torch
        from datasets import load_dataset
        from peft import LoraConfig
        from transformers import AutoTokenizer
        from trl import SFTConfig, SFTTrainer
    except ImportError as e:
        print(f"missing training dependency: {e}\nInstall: pip install torch transformers peft trl datasets accelerate",
              file=sys.stderr)
        return 2

    files = {"train": cfg["train_file"]}
    if cfg.get("val_file"):
        files["validation"] = cfg["val_file"]
    ext = os.path.splitext(cfg["train_file"])[1].lstrip(".").replace("jsonl", "json")
    ds = load_dataset(ext, data_files=files)

    hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or None
    base_src = cfg.get("base_local_path") or cfg["base_model"]

    if a.dry_run:
        tok = AutoTokenizer.from_pretrained(base_src, use_fast=True, token=hf_token)
        if tok.pad_token is None:
            tok.pad_token = tok.eos_token
        def _fmt(ex: dict) -> dict:
            m = _rows_to_messages(ex)
            return {"text": m["text"]} if "text" in m else {"text": tok.apply_chat_template(m["messages"], tools=m["tools"], tokenize=False)}
        ds = ds.map(_fmt, remove_columns=ds["train"].column_names)
        print(f"train rows: {len(ds['train'])}" + (f", val rows: {len(ds['validation'])}" if "validation" in ds else ""))
        print(ds["train"][0]["text"][:800])
        return 0

    model, tok, used_unsloth = _load_model_and_tokenizer(cfg, torch, a.init_adapter)

    def to_text(ex: dict) -> dict:
        m = _rows_to_messages(ex)
        if "text" in m:
            return {"text": m["text"]}
        return {"text": tok.apply_chat_template(m["messages"], tools=m["tools"], tokenize=False)}

    ds = ds.map(to_text, remove_columns=ds["train"].column_names)
    print(f"train rows: {len(ds['train'])}" + (f", val rows: {len(ds['validation'])}" if "validation" in ds else ""))

    ckpt_dir = a.checkpoint_dir or cfg.get("checkpoint_dir") or "output/checkpoints"
    os.makedirs(ckpt_dir, exist_ok=True)
    resume_path = _resolve_resume(a.resume_from_checkpoint or cfg.get("resume_from_checkpoint"), ckpt_dir)
    if resume_path:
        print(f"[*] Resuming SFT training from checkpoint: {resume_path}")

    peft_cfg = None if (used_unsloth or a.init_adapter) else LoraConfig(
        r=cfg["lora_r"], lora_alpha=cfg["lora_alpha"], lora_dropout=cfg["lora_dropout"],
        target_modules="all-linear", task_type="CAUSAL_LM",
    )
    save_steps = int(cfg.get("save_steps", 40))
    args = SFTConfig(
        output_dir=ckpt_dir, num_train_epochs=cfg["epochs"],
        learning_rate=cfg["learning_rate"], per_device_train_batch_size=cfg["batch_size"],
        gradient_accumulation_steps=cfg["grad_accum"], max_seq_length=cfg["max_seq_len"],
        dataset_text_field="text", logging_steps=5,
        save_strategy="steps", save_steps=save_steps, save_total_limit=3,
        eval_strategy="epoch" if "validation" in ds else "no",
        bf16=torch.cuda.is_available(), gradient_checkpointing=not used_unsloth,
        report_to=[],
    )
    trainer = SFTTrainer(
        model=model, args=args, train_dataset=ds["train"], eval_dataset=ds.get("validation"),
        peft_config=peft_cfg, processing_class=tok,
    )
    trainer.train(resume_from_checkpoint=resume_path)
    os.makedirs("output/adapter", exist_ok=True)
    trainer.model.save_pretrained("output/adapter")
    tok.save_pretrained("output/adapter")
    print("\nSaved PEFT adapter to output/adapter")

    export_gguf = a.export_gguf or cfg.get("export_gguf")
    if export_gguf:
        _export_adapter_gguf("output/adapter", cfg["base_model"], export_gguf, cfg.get("base_local_path"))
    return 0


def train_dpo(cfg: dict, a) -> int:
    """Direct Preference Optimisation: teach the model to prefer `chosen` over `rejected` for the same prompt."""
    try:
        import torch
        from datasets import load_dataset
        from peft import LoraConfig
        from transformers import AutoTokenizer
        from trl import DPOConfig, DPOTrainer
    except ImportError as e:
        print(f"missing training dependency: {e}\nInstall: pip install torch transformers peft trl datasets accelerate",
              file=sys.stderr)
        return 2

    files = {"train": cfg["train_file"]}
    if cfg.get("val_file"):
        files["validation"] = cfg["val_file"]
    ds = load_dataset("json", data_files=files)
    hf_token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN") or None
    base_src = cfg.get("base_local_path") or cfg["base_model"]

    if a.dry_run:
        tok = AutoTokenizer.from_pretrained(base_src, use_fast=True, token=hf_token)
        if tok.pad_token is None:
            tok.pad_token = tok.eos_token
    else:
        model, tok, used_unsloth = _load_model_and_tokenizer(cfg, torch, a.init_adapter)

    def to_pref(ex: dict) -> dict:
        tools = ex.get("tools") or None
        prompt = tok.apply_chat_template(ex["prompt"], tools=tools, tokenize=False, add_generation_prompt=True)
        full_c = tok.apply_chat_template(ex["prompt"] + ex["chosen"], tools=tools, tokenize=False)
        full_r = tok.apply_chat_template(ex["prompt"] + ex["rejected"], tools=tools, tokenize=False)
        return {
            "prompt": prompt,
            "chosen": full_c[len(prompt):] if full_c.startswith(prompt) else full_c,
            "rejected": full_r[len(prompt):] if full_r.startswith(prompt) else full_r,
        }

    ds = ds.map(to_pref, remove_columns=ds["train"].column_names)
    print(f"DPO pairs: {len(ds['train'])}" + (f", val: {len(ds['validation'])}" if "validation" in ds else ""))
    if a.dry_run:
        r = ds["train"][0]
        print("PROMPT tail:", r["prompt"][-400:], "\nCHOSEN:", r["chosen"][:300], "\nREJECTED:", r["rejected"][:300])
        return 0

    ckpt_dir = a.checkpoint_dir or cfg.get("checkpoint_dir") or "output/dpo_checkpoints"
    os.makedirs(ckpt_dir, exist_ok=True)
    resume_path = _resolve_resume(a.resume_from_checkpoint or cfg.get("resume_from_checkpoint"), ckpt_dir)
    if resume_path:
        print(f"[*] Resuming DPO training from checkpoint: {resume_path}")

    peft_cfg = None if (used_unsloth or a.init_adapter) else LoraConfig(
        r=cfg["lora_r"], lora_alpha=cfg["lora_alpha"], lora_dropout=cfg["lora_dropout"],
        target_modules="all-linear", task_type="CAUSAL_LM",
    )
    save_steps = int(cfg.get("save_steps", 40))
    args = DPOConfig(
        output_dir=ckpt_dir, num_train_epochs=cfg["epochs"],
        learning_rate=min(float(cfg["learning_rate"]), 5e-5), per_device_train_batch_size=cfg["batch_size"],
        gradient_accumulation_steps=cfg["grad_accum"], max_length=cfg["max_seq_len"],
        beta=float(cfg.get("dpo_beta", 0.1)), logging_steps=5,
        save_strategy="steps", save_steps=save_steps, save_total_limit=3,
        eval_strategy="epoch" if "validation" in ds else "no",
        bf16=torch.cuda.is_available(), gradient_checkpointing=not used_unsloth,
        report_to=[],
    )
    trainer = DPOTrainer(
        model=model, ref_model=None, args=args, train_dataset=ds["train"],
        eval_dataset=ds.get("validation"), processing_class=tok, peft_config=peft_cfg,
    )
    trainer.train(resume_from_checkpoint=resume_path)
    os.makedirs("output/adapter", exist_ok=True)
    trainer.model.save_pretrained("output/adapter")
    tok.save_pretrained("output/adapter")
    print("\nSaved DPO-tuned PEFT adapter to output/adapter (watch rewards/margins: they should rise).")

    export_gguf = a.export_gguf or cfg.get("export_gguf")
    if export_gguf:
        _export_adapter_gguf("output/adapter", cfg["base_model"], export_gguf, cfg.get("base_local_path"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
