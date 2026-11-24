---
title: "Model Workbench — Local GGUF Library, Fit Table & Serving Guide"
description: "Complete guide to the Blue Lodge Model Workbench: model-agnostic GGUF library, hardware fit tables, draft/approve/activate lifecycle, adapter attachment, and model copilot."
subsystem: "core"
tags:
  - models
  - model-workbench
  - gguf
  - fit-table
  - llama-server
  - adapters
okf_id: "urn:blue-lodge:doc:models"
related:
  - "[[INDEX]]"
  - "[[DATASET_FORGE]]"
  - "[[TRAINING_RUN_MANAGER]]"
  - "[[INSTRUMENT_RACK]]"
  - "[[INFERENCE_FABRIC]]"
  - "[[TUNING]]"
---

# Model Workbench

Blue Lodge does not ship a model list. Your library is whatever GGUF files you put in `MODELS_DIR`
(default `~/models`). The Workbench helps you find, download, check, serve, tune and fine-tune your own
models. It does not decide which model you should run.

You can use it from three places. All of them call the same backend (`lib/tools/model_hub_cli.py`):

| Surface | How to open it |
| --- | --- |
| Web UI | The **Models** button in the george-web header opens the Model Workbench |
| REPL / shell | `/models …` inside `lodge`, or `lodge /models …` |
| George (agent) | `hub_*` native tools: `hub_library`, `hub_hw_probe`, `hub_search`, `hub_inspect`, `hub_quant_fit`, `hub_profile_draft`, `hub_profiles` |

> [!IMPORTANT]
> Nothing gets downloaded, served or deleted unless you approve it. Every download is checked against
> its sha256. A profile only serves after you approve it, and that approval is tied to the exact file
> hashes. If you attach an adapter or change the files, the profile needs approval again.

---

## 1. The web Workbench at a glance

```
┌ Now serving ─────────────────────────────────────────────────────────────┐
│ real model + real context, read live from llama-server /props            │
│ [your presets, if you defined any]                                        │
├ Model Copilot ───────────────────────────────────────────────────────────┤
│ textarea that grows as you type: "what fits on my 2x24GB for coding?"     │
├ Jobs tray: downloads / imports in progress, with cancel + clear ─────────┤
├ Tabs ────────────────────────────────────────────────────────────────────┤
│ My Library │ Discover & Download │ Serve & Tune │ Fine-tune               │
├ Activity log ────────────────────────────────────────────────────────────┤
```

- **Now serving** asks each configured llama-server endpoint (`TIER*_URL` in `.george/endpoints.conf`)
  for `/health` and `/props`. It shows the model and context size that are actually loaded, not a label.
- **Model Copilot** (`/models ask`) lets George look at your library and hardware, research online and
  draft a profile for you to review. Questions can be up to 4000 characters. The answer area scrolls.
- **Jobs** lists background downloads and local imports, with progress, cancel and clear.

### My Library

Your library holds a card for every GGUF found under `MODELS_DIR`. The scan does not follow symlinks
and has a depth limit. Each file is sorted by its GGUF metadata, not by a list we maintain:

| Kind | Detected when |
| --- | --- |
| `model` | any full model |
| `adapter` | `general.type == "adapter"` (LoRA) or architecture `controlvector` |
| `mmproj` | `general.type == "mmproj"` or architecture `clip` (vision/audio projector) |
| `draft` | file name starts with `mtp-` or contains `draft` (speculative decoding head) |

Each card shows the file name, architecture, parameter count, quant, size, trained context, and whether
the model is currently served or used by a profile. Card actions:

- **Serve…** opens a fit check. It gives the maximum context for each KV cache type on your GPUs and
  lets you pick an optional projector or draft. **Import** then pins the file as a profile (local
  files are sha256-hashed in the background and appear in Jobs).
- **Attach…** (adapters only) attaches a LoRA or control vector to a profile, with a scale.
- **Details** shows the full metadata, path and sha256.
- **Delete** is a two-click confirmation. It refuses to delete a file a profile still uses, unless you
  open the force-delete sheet.

Metadata and hashes are cached in `.george/models/library_cache.json`, keyed by path, size and mtime.
Re-scans are cheap, and a file that changed is always read again.

### Discover & Download

1. Search Hugging Face, ModelScope or both. You can sort by downloads, likes, recent changes or trending.
   The keyword chips are just search shortcuts; they are not recommendations.
2. Open a repo to see its **fit table**. For every quant it shows file size, VRAM needed at your
   chosen context and KV type, and whether it fits.
3. **Draft** creates a profile in `.george/models/profiles/<name>.json` with the pinned file list and hashes.
4. **Approve** the draft after checking it, then **Install**. Downloads can resume, are verified by
   sha256 and appear in the Jobs tray.

Gated or private repos need an account token. Open *Accounts* (or run `/models login huggingface`).
Tokens are written to `.george/keys.conf` (mode 0600) and are never shown again.

### Serve & Tune

- **Profiles** lists every profile with its state (draft → approved → installed → active).
- **Activate** starts llama-server for a profile, either in docker or natively (`LLAMA_SERVER_BIN`).
  **Rollback** undoes the last activation.
- **Tune** edits the profile's `server` block (`ctx`, `n_gpu_layers`, `cache_type_k/v`, `flash_attn`,
  `parallel`, …) and its `sampling` block (`temperature`, `top_p`, `top_k`, `min_p`,
  `repeat_penalty`, `presence_penalty`). George's REPL reads the active profile's sampling values for
  every request. If no profile applies, it falls back to `MODELS_DEFAULT_*` (see
  [ENVIRONMENT_VARIABLES.md](ENVIRONMENT_VARIABLES.md)).
- **Adapters** attaches or detaches LoRA and control-vector GGUFs. These are passed to llama-server
  as `--lora` / `--lora-scaled` / `--control-vector-scaled`, and they reset approval.
- **Presets** is optional, for operators only (see §4).

### Fine-tune

Blue Lodge **does not train models**. Training needs a GPU training stack that the lodge does not
ship. The Fine-tune tab prepares everything around training:

1. **Datasets** lists files in `data/training/` and George's exported runs in `.george/datasets/`.
2. **Pull dataset** fetches one file from a Hugging Face dataset repo (sha256-checked when the hub gives a hash).
3. **Export George runs** turns George's successful runs into train/val JSONL
   (`scripts/training/export_lora_dataset.py`).
3b. **Dataset Forge** cuts focused SFT + DPO datasets out of George's transcripts (and optionally the
   curricula in `data/training`): error recovery, loop breaking, context discrimination, multi-hop,
   tool syntax, gitops, final answers. Choose the recipes and sample count; benchmark questions in
   `data/` are filtered out automatically. CLI: `/train recipes | pantry | forge | audit`.
   Guide: [DATASET_FORGE.md](DATASET_FORGE.md).
4. **Training kit** writes a self-contained LoRA kit (config, script and README) for **any** base
   model you name, into `.george/training/kits/<name>/`. Method **SFT** or **DPO** (preference pairs
   from the forge). Run it in your own environment (local GPU,
   Colab, cloud). Convert the adapter to GGUF and put it in `MODELS_DIR/adapters/`. It then appears
   in the library, ready to attach.

---

## 2. `/models` command reference

```text
/models                                  same as /models library
/models library                          every GGUF on disk (models, adapters, projectors, drafts)
/models fit-local <file> [--ctx N] [--kv f16|q8_0|q4_0] [--mmproj F] [--draft F]
/models import <file> [--name N] [--ctx N] [--kv K] [--mmproj F] [--draft F] [--approve]
/models delete-file <file> [--force]

/models ask <question>                   Model Copilot
/models hw                               GPUs / VRAM / RAM / disk probe
/models search <q> [--provider huggingface|modelscope|all] [--sort downloads|likes|lastModified|trending]
/models quants <provider> <repo> [--ctx N] [--kv K]
/models fit <provider> <repo> <quant> [--ctx N] [--with-mmproj] [--with-draft]
/models draft <provider> <repo> <quant> [--ctx N] [--name N] [--with-mmproj] [--with-draft]
/models approve <name>   /models install <name>   /models progress <name>   /models cancel <name>
/models jobs                             downloads / imports in progress
/models login|logout <huggingface|modelscope>   /models accounts   /models disk

/models profiles   /models show <name>
/models activate <name> [--dry-run]      /models rollback   /models status
/models tune <name> '<json>'             e.g. '{"server":{"ctx":32768,"cache_type_k":"q8_0"},"sampling":{"temperature":0.7}}'
/models attach <name> lora|control_vector <file.gguf> [--scale S]
/models detach <name> <file.gguf>        /models remove <name> [--delete-files]
/models presets [id]

/models datasets   /models dataset-pull <repo> <file>   /models export-runs [--since YYYY-MM-DD]
/models train-kit '{"name":"…","base_model":"…","train":"training:…"}'   /models kits

/models spec [on|off|tokens N|draft <path|clear>]   llama.cpp speculative decoding (REPL only)
```

The old hand-picked menu commands (`/models list|select|single|dual|param`, `/models switch`,
`/models download`) have been removed. If you type one, the REPL tells you which command replaces it.

### Speculative decoding (MTP / draft models)

`/models spec` controls `LLAMA_CPP_SPEC_MTP`, `LLAMA_CPP_SPEC_DRAFT_N_MAX` and `LLAMA_CPP_DRAFT_MODEL`
in `.george/lodge.conf`. For hub profiles, the better option is to pin a draft file (`--draft` /
`--with-draft`), so it is hashed and served together with the model. Changes take effect the next time
llama-server launches (`/models activate <name>`).

---

## 3. Profiles on disk

```
.george/models/
├── profiles/<name>.json      pinned files (role, path, sha256), server + sampling blocks, approval hash
├── active_profile.json       what /models activate last started (used for sampling lookups)
├── library_cache.json        GGUF metadata + digest cache
├── downloads/                partial downloads (resumable)
└── presets.json              optional, operator-only launch presets (never committed)
```

Profile names must match `^[a-z0-9][a-z0-9._-]{1,63}$`. File paths must stay inside `MODELS_DIR`.

---

## 4. Operator presets (optional)

Some operators run their own stacks, such as a forked llama.cpp build, an experimental GGUF or a
split-GPU layout with a separate vision worker. Blue Lodge does not ship assumptions about any of
these. Instead, copy [`config/models/presets.example.json`](../config/models/presets.example.json) to
`.george/models/presets.json`:

```json
{ "presets": [ { "id": "my-stack", "label": "My custom stack",
  "description": "State the real context your script configures.",
  "script": "scripts/inference/my_stack.sh", "args": ["start"], "status_args": ["status"] } ] }
```

- `script` must be under `scripts/` in the lodge. `args` are plain tokens (no shell). It runs with argv only.
- Presets show up as buttons under **Now serving** and as `/models presets <id>`.
- Labels and descriptions are yours. **Now serving** always shows the real context from llama-server.

---

## 5. HTTP API (george-web)

GET routes are read-only. Every non-GET `/api/hub/*` and `/api/training/*` call needs the session
token (`X-Lodge-Token` header). Remote devices also need a paired device token.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/api/hub/library` | Local library scan |
| DELETE | `/api/hub/library/file?file=…&force=false` | Delete a GGUF from disk |
| GET | `/api/hub/fit-local?file=…&ctx=…&kv=…` | Fit check for a local file |
| POST | `/api/hub/import-local` | Pin a local file as a profile (background job) |
| GET | `/api/hub/hw` · `/search` · `/inspect` · `/quants` | Hardware probe and hub discovery |
| POST | `/api/hub/draft` | Draft a profile from a hub repo/quant |
| GET | `/api/hub/profiles` · `/profile/:name` | List / show profiles |
| POST | `/api/hub/profile/:name/{approve,install,cancel,activate,tune,attach,detach}` | Profile lifecycle |
| GET | `/api/hub/profile/:name/progress` | Download progress |
| DELETE | `/api/hub/profile/:name` | Remove a profile |
| POST | `/api/hub/rollback` | Undo the last activation |
| GET / POST | `/api/hub/jobs` · `/api/hub/jobs/:name/clear` | Background jobs |
| GET | `/api/hub/server` | Live llama-server status |
| GET / POST | `/api/hub/presets` · `/api/hub/presets/:id/run` | Operator presets |
| GET | `/api/hub/datasets` · `/api/hub/datasets/files` | Local datasets / HF dataset file listing |
| POST | `/api/hub/datasets/pull` · `/api/hub/datasets/export-runs` | Fetch a dataset / export George runs |
| GET / POST | `/api/hub/train/kits` · `/api/hub/train/kit` | Training kits |
| GET / POST | `/api/hub/accounts` · `/login` · `/logout` | Hub accounts (tokens go to `keys.conf`, 0600) |
| POST / GET | `/api/hub/ask` · `/api/hub/ask/:id` | Model Copilot |

Removed: `/api/hub/catalog` and `/api/models/{list,download,dataset/download,datasets,switch,status}`.

---

## 6. Security notes

- Subprocesses use argv only, never `bash -c` with user input. Relative paths are checked to stay inside
  `MODELS_DIR`, `data/training`, `.george/datasets` or `scripts/`.
- Downloads use HTTPS only, from allowed hosts (`MODEL_HUB_EXTRA_HOSTS` and
  `MODEL_HUB_ALLOW_HTTP_HOSTS` are opt-in), are sha256-verified, and are written to a temp file then
  renamed into place.
- Approval is tied to the profile's content hash. Changing files or adapters resets it.
- The web UI never uses `innerHTML`, `alert` or `confirm`. Destructive actions use two-click
  confirmation buttons.

See also: [TUNING.md](TUNING.md) (sampling per scenario), [INFERENCE_FABRIC.md](INFERENCE_FABRIC.md)
(endpoints/tiers), [BLUE_LODGE_LORA_TUNING_PLAYBOOK.md](BLUE_LODGE_LORA_TUNING_PLAYBOOK.md) (training).
