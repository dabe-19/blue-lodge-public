#!/usr/bin/env python3
"""Blue Lodge LoRA SFT kit — model-agnostic supervised fine-tuning.

Generated kits copy this file next to a config.json written by the Model Workbench (Train tab) or
`/models train-kit`. Run it in YOUR training environment (a CUDA box, Colab, a cloud GPU). Blue Lodge
itself never installs or runs these packages.

    pip install "torch>=2.3" "transformers>=4.45" "peft>=0.12" "trl>=0.11" "datasets>=2.20" accelerate
    pip install bitsandbytes   # optional, for load_in_4bit (QLoRA) on CUDA
    python train_lora.py --config config.json

Dataset rows may be any of:
    {"messages": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}], "tools": [...]}
    {"prompt": "...", "completion": "..."}   (or "response")
    {"instruction": "...", "input": "...", "output": "..."}
    {"text": "..."}

Output: ./output/adapter (PEFT LoRA). Convert it for llama.cpp with
    python llama.cpp/convert_lora_to_gguf.py output/adapter --base <local HF copy of base_model> --outtype f16
and move the .gguf into the adapters dir printed at the end. It then appears in the Library.
"""

from __future__ import annotations

import argparse
import json
import os
import sys


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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--dry-run", action="store_true", help="load data + tokenizer only; no training")
    ap.add_argument("--mode", choices=("sft", "dpo"), default=None,
                    help="sft (default) or dpo: rows {prompt:[msgs], chosen:[msg], rejected:[msg]} e.g. forge dpo_train.jsonl")
    ap.add_argument("--init-adapter", default=None, help="continue from an existing PEFT adapter (e.g. the SFT output)")
    a = ap.parse_args()
    cfg = json.load(open(a.config, encoding="utf-8"))
    mode = a.mode or cfg.get("mode", "sft")
    if mode == "dpo":
        return train_dpo(cfg, a)

    try:
        import torch
        from datasets import load_dataset
        from peft import LoraConfig
        from transformers import AutoModelForCausalLM, AutoTokenizer
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

    tok = AutoTokenizer.from_pretrained(cfg["base_model"], use_fast=True)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    def to_text(ex: dict) -> dict:
        m = _rows_to_messages(ex)
        if "text" in m:
            return {"text": m["text"]}
        return {"text": tok.apply_chat_template(m["messages"], tools=m["tools"], tokenize=False)}

    ds = ds.map(to_text, remove_columns=ds["train"].column_names)
    print(f"train rows: {len(ds['train'])}" + (f", val rows: {len(ds['validation'])}" if "validation" in ds else ""))
    if a.dry_run:
        print(ds["train"][0]["text"][:800])
        return 0

    kwargs = {"torch_dtype": torch.bfloat16 if torch.cuda.is_available() else torch.float32}
    if cfg.get("load_in_4bit") and torch.cuda.is_available():
        from transformers import BitsAndBytesConfig
        kwargs["quantization_config"] = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                                           bnb_4bit_compute_dtype=torch.bfloat16)
    model = AutoModelForCausalLM.from_pretrained(cfg["base_model"], device_map="auto", **kwargs)
    peft_cfg = LoraConfig(r=cfg["lora_r"], lora_alpha=cfg["lora_alpha"], lora_dropout=cfg["lora_dropout"],
                          target_modules="all-linear", task_type="CAUSAL_LM")
    args = SFTConfig(output_dir="output/checkpoints", num_train_epochs=cfg["epochs"],
                     learning_rate=cfg["learning_rate"], per_device_train_batch_size=cfg["batch_size"],
                     gradient_accumulation_steps=cfg["grad_accum"], max_seq_length=cfg["max_seq_len"],
                     dataset_text_field="text", logging_steps=5, save_strategy="epoch",
                     eval_strategy="epoch" if "validation" in ds else "no", bf16=torch.cuda.is_available(),
                     report_to=[])
    trainer = SFTTrainer(model=model, args=args, train_dataset=ds["train"], eval_dataset=ds.get("validation"),
                         peft_config=peft_cfg, processing_class=tok)
    trainer.train()
    trainer.model.save_pretrained("output/adapter")
    tok.save_pretrained("output/adapter")
    print("\nSaved PEFT adapter to output/adapter")
    print("Convert:  python <llama.cpp>/convert_lora_to_gguf.py output/adapter --base <local copy of "
          f"{cfg['base_model']}> --outtype f16 --outfile {cfg['name']}-lora.gguf")
    print(f"Then move {cfg['name']}-lora.gguf into {cfg['adapter_gguf_dir']} and attach it from the Model Workbench.")
    return 0


def _load_model(cfg: dict, torch, init_adapter: str | None):
    from transformers import AutoModelForCausalLM
    kwargs = {"torch_dtype": torch.bfloat16 if torch.cuda.is_available() else torch.float32}
    if cfg.get("load_in_4bit") and torch.cuda.is_available():
        from transformers import BitsAndBytesConfig
        kwargs["quantization_config"] = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_quant_type="nf4",
                                                           bnb_4bit_compute_dtype=torch.bfloat16)
    model = AutoModelForCausalLM.from_pretrained(cfg["base_model"], device_map="auto", **kwargs)
    if init_adapter:
        from peft import PeftModel
        model = PeftModel.from_pretrained(model, init_adapter, is_trainable=True)
    return model


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
    tok = AutoTokenizer.from_pretrained(cfg["base_model"], use_fast=True)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token

    def to_pref(ex: dict) -> dict:
        tools = ex.get("tools") or None
        prompt = tok.apply_chat_template(ex["prompt"], tools=tools, tokenize=False, add_generation_prompt=True)
        full_c = tok.apply_chat_template(ex["prompt"] + ex["chosen"], tools=tools, tokenize=False)
        full_r = tok.apply_chat_template(ex["prompt"] + ex["rejected"], tools=tools, tokenize=False)
        return {"prompt": prompt, "chosen": full_c[len(prompt):] if full_c.startswith(prompt) else full_c,
                "rejected": full_r[len(prompt):] if full_r.startswith(prompt) else full_r}

    ds = ds.map(to_pref, remove_columns=ds["train"].column_names)
    print(f"DPO pairs: {len(ds['train'])}" + (f", val: {len(ds['validation'])}" if "validation" in ds else ""))
    if a.dry_run:
        r = ds["train"][0]
        print("PROMPT tail:", r["prompt"][-400:], "\nCHOSEN:", r["chosen"][:300], "\nREJECTED:", r["rejected"][:300])
        return 0
    model = _load_model(cfg, torch, a.init_adapter)
    peft_cfg = None if a.init_adapter else LoraConfig(r=cfg["lora_r"], lora_alpha=cfg["lora_alpha"],
                                                      lora_dropout=cfg["lora_dropout"], target_modules="all-linear",
                                                      task_type="CAUSAL_LM")
    args = DPOConfig(output_dir="output/dpo_checkpoints", num_train_epochs=cfg["epochs"],
                     learning_rate=min(float(cfg["learning_rate"]), 5e-5), per_device_train_batch_size=cfg["batch_size"],
                     gradient_accumulation_steps=cfg["grad_accum"], max_length=cfg["max_seq_len"],
                     beta=float(cfg.get("dpo_beta", 0.1)), logging_steps=5, save_strategy="epoch",
                     eval_strategy="epoch" if "validation" in ds else "no", bf16=torch.cuda.is_available(),
                     report_to=[])
    trainer = DPOTrainer(model=model, ref_model=None, args=args, train_dataset=ds["train"],
                         eval_dataset=ds.get("validation"), processing_class=tok, peft_config=peft_cfg)
    trainer.train()
    trainer.model.save_pretrained("output/adapter")
    tok.save_pretrained("output/adapter")
    print("\nSaved DPO-tuned PEFT adapter to output/adapter (watch rewards/margins: they should rise).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
