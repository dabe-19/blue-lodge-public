---
title: "Dataset Forge — Fine-Tuning on Real Agent Transcripts"
description: "Recipe-based SFT and DPO training dataset generator: creating specialized datasets from agent task transcripts, curriculum intake, benchmark guards, and contamination defense."
subsystem: "core"
tags:
  - dataset-forge
  - fine-tuning
  - sft
  - dpo
  - transcripts
  - benchmark-guard
okf_id: "urn:blue-lodge:doc:dataset-forge"
related:
  - "[[INDEX]]"
  - "[[TRAINING_RUN_MANAGER]]"
  - "[[MODELS]]"
  - "[[BLUE_LODGE_LORA_TUNING_PLAYBOOK]]"
  - "[[SOVEREIGN_FOUNDATION_MODEL_PLAYBOOK]]"
---

# Dataset Forge — learn fine-tuning on your own agent's homework

George writes a transcript of every task he runs. The Dataset Forge turns those transcripts into small,
focused training sets.

Nothing here needs a GPU until the final training step. Building, previewing and auditing datasets all
run on any machine with Python 3.

## The 60-second tour

```bash
lodge /train recipes                 # what each recipe teaches
lodge /train pantry                  # how many unique samples your transcripts can supply
lodge /train forge error-recovery 300
lodge /train audit                   # health check for every dataset in data/
```

In the web UI, open **Models → Fine-tune → Dataset Forge**:

1. Click **CHECK PANTRY**.
2. Tick the recipe cards you want.
3. Drag the sample slider.
4. Click **FORGE DATASET**.

The new files show up under *Your datasets*, and the kit generator can use them right away.

## Recipes

| Recipe | Teaches | Rejected side (for DPO) |
|---|---|---|
| `tool-syntax` | emit the exact next tool call | the same call broken on purpose: wrong tool, malformed JSON, missing or invented argument |
| `error-recovery` | after a tool error, change approach | re-sending the identical failing call |
| `failure-modes` | break out of a loop | the repeat George actually made (real failure data) |
| `context-discrimination` | answer the current request, not the previous one | acting on the stale topic |
| `multi-hop` | continue a long investigation using earlier observations | restarting with step 1 |
| `final-answer` | synthesise the reply from gathered evidence | none (SFT only) |
| `gitops` | file and git operations | a destructive variant (`--force`, `reset --hard`, `clean -fdx`) |

Use `mix` to blend all of them evenly.

## Where samples come from

- **Your transcripts** (always on): `.george/runs`, `.george/workspaces`, `.george/transcripts/*.md(.gz)`
  and the step log `trajectories.jsonl`. Secrets from your key files, common token formats and Discord
  ids are redacted by the same code as [export_lora_dataset.py](../scripts/training/export_lora_dataset.py).
- **Existing curricula in `data/training`** (opt-in: `--include-curricula`, or the checkbox in the UI).
  - Rows are adapted to the same shape.
  - Rows are deduplicated by prompt, with at most 2 variants per distinct prompt (`--curriculum-cap`).
    Several historical curricula repeat 11–30 prompts thousands of times. The cap stops those few prompts
    from dominating training.
  - Files that copy a benchmark (`*gpqa*`, `*arc*`, `*stem_agent*`, `*exploit*`) are treated as
    eval-only and never used.
- **Your local LLM** (opt-in: `--augment-llm`).
  - Writes a better "chosen" reply where only a template exists (loop breaking).
  - Paraphrases task prompts when real material runs out.
  - Every LLM-touched sample is labelled, so you can spot-check those first.

## The benchmark guard

The benchmark sets in `data/` are indexed before every build:

- ARC easy/challenge
- the ARC-AGI evaluation split
- GPQA
- IFEval
- agent_bench
- refusal

Any sample that shares a 12-word passage with a benchmark question, or exactly matches an ARC test grid,
is dropped. The manifest reports how many were removed. If you train on the test, your eval numbers stop
meaning anything. `/train audit` shows the same check (the `bench!` column) for every file in `data/`.

## What a build writes

`$GEORGE_DIR/datasets/forge_<focus>_<timestamp>/`:

| File | Use |
|---|---|
| `sft_train.jsonl`, `sft_val.jsonl` | supervised fine-tuning (`{"messages", "tools"}`) |
| `dpo_train.jsonl`, `dpo_val.jsonl` | preference tuning (`{"prompt", "chosen", "rejected", "tools"}`) |
| `samples_meta.jsonl` | recipe, source session, provenance and split for every sample |
| `preview.md` | eight random samples rendered for humans — **read this first** |
| `manifest.json` | counts, shortfall, guard stats, token estimate |
| `README.md` | the lessons for the recipes you picked, plus next steps |

**Validation is split by session.** No episode appears in both train and val, so val loss measures
generalisation rather than memorisation.

**The forge never pads.** If you ask for 2,000 samples and only 400 unique ones exist, you get 400 plus a
shortfall note. Duplicates only teach the model to memorise.

## Train it

1. Generate a kit: Workbench → Fine-tune → *Generate a training kit*.
   - Method **SFT**, training set `…/sft_train.jsonl`, validation set `…/sft_val.jsonl`.
2. On your GPU box, run `./run.sh`. The kit needs torch, transformers, peft, trl and datasets in its own
   environment; Blue Lodge does not install them.
3. Optional: generate a second kit with method **DPO** and `…/dpo_train.jsonl`, and start it from the SFT
   adapter:
   ```bash
   python train_lora.py --config config.json --mode dpo --init-adapter ../<sft-kit>/output/adapter
   ```
4. Convert the adapter with llama.cpp's `convert_lora_to_gguf.py` and drop it in `adapters/`. It appears
   in My Library; attach it to a profile in Serve & Tune.

## Training runs (let the Lodge drive it)

A *run* trains several datasets at once ("tracks"), then fuses them into one GGUF adapter. It's the same kit
as above, but the Lodge handles GPUs, logs, conversion and merging for you.

```bash
/train template > my_run.json      # edit base model, paths, tracks
/train dry-run my_run.json         # checks training env, GPUs, datasets, converter; changes nothing
/train run my_run.json             # local: starts detached. Colab: writes a plan only
/train status my-run               # per-track loss / eval loss / DPO margin
/train runs                        # all runs
```

- **Tracks.**
  - Each track is one dataset and one method (`sft` or `dpo`) on one `gpu`.
  - Tracks on the same GPU run in sequence; tracks on different GPUs run in parallel.
  - Dataset ids are `exports:<forge dir>/<file>` (your forge builds) or `training:<file>` (`data/training`).
- **Training env.**
  - Set `train_python` (or `$BLUE_LODGE_TRAIN_PYTHON`) to a venv that has torch, transformers, peft, trl
    and datasets.
  - Free the GPU first. A model server holding most of the VRAM is the usual cause of out-of-memory errors.
- **Merge.**
  - When every track finishes, each adapter is converted with llama.cpp. This needs `llama_cpp_dir` and
    `base_hf_path`, a local HF copy of the base model.
  - The adapters are then fused by `scripts/colab_training/merge_frontier_loras.py` and written to
    `MODELS_DIR/adapters`.
  - `concat` is exact: the ranks add up. `svd` compresses to `target_rank`, which gives a smaller file but
    is lossy. Try both and compare.
- **Colab** (`"backend": "colab"`, up to one A100 per track).
  - `/train run` builds per-track bundles and a command plan, and stops there.
  - Add `--execute` to provision sessions. This costs compute units; check `/train credits` first.
  - `/train collect <run>` downloads finished adapters and deletes the sessions. A failed launch deletes its
    session immediately.
  - Afterwards, run `/train merge <run>`.

> The older `scripts/colab_training/train_multiturn_colab.py` is archived. Its loss never touched the
> model's outputs, so those runs didn't actually train. Its reward function is kept for reference.

## Experiments worth trying

- **One recipe, before and after.**
  - Forge 300 `error-recovery` samples and train.
  - Re-run the same handful of tasks with and without the adapter, and count blind retries in the
    transcripts.
- **SFT vs SFT→DPO.** Same data, two adapters. Does preferring "not the identical retry" beat merely
  imitating the recovery?
- **Data size curve.** Build 100 / 300 / 1,000 samples of one recipe. Plot val loss and real task success.
  Where does it flatten?
- **Curricula vs transcripts.** Build once with `--curricula-only` and once from transcripts only. Real
  episodes are messier; see which one transfers.

## Privacy

Datasets are built from what people said to George. Redaction removes secrets and Discord ids, but not
names, locations or file paths. Read `preview.md` and keep datasets and adapters private unless you have
checked them.
