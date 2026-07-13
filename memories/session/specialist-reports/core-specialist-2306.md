## Full Report

### Layer: core-specialist

### Files Touched
- `lib/models.sh` — Updated default model slots to 2b and curated presentation order (lines 23-78, 929)
- `lib/llm.sh` — Dynamically default speculative MTP decoding to enabled for gemma4-e2b-inst (lines 795-803)
- `lib/api.sh` — Added e2b support in the Unsloth QAT profile family override check (lines 390-394)

### Diff Summary
```diff
# in lib/models.sh
-LODGE_MODEL_PRIMARY="${LODGE_MODEL_PRIMARY:-blue-lodge-gemma4-inst:4b}"
-LODGE_MODEL_SECONDARY="${LODGE_MODEL_SECONDARY:-blue-lodge-gemma4-inst:4b}"
+LODGE_MODEL_PRIMARY="${LODGE_MODEL_PRIMARY:-blue-lodge-gemma4-inst:2b}"
+LODGE_MODEL_SECONDARY="${LODGE_MODEL_SECONDARY:-blue-lodge-gemma4-inst:2b}"

 _MODELS_CURATED_ORDER=(
-    "gemma4-e4b-inst"
+    "gemma4-e2b-inst"
     ...
-    "gemma4-e2b-inst"
+    "gemma4-e4b-inst"
     ...
 )

-                echo "blue-lodge-gemma4-inst:4b"
+                echo "blue-lodge-gemma4-inst:2b"

# in lib/llm.sh
-    if [ "${LLAMA_CPP_SPEC_MTP:-0}" = "1" ]; then
+    local _spec_mtp="${LLAMA_CPP_SPEC_MTP:-}"
+    if [ -z "$_spec_mtp" ]; then
+        if [[ "${LODGE_MODEL:-}" == "gemma4-e2b-inst" ]]; then
+            _spec_mtp=1
+        else
+            _spec_mtp=0
+        fi
+    fi
+
+    if [ "$_spec_mtp" = "1" ]; then

# in lib/api.sh
-    if [[ "$ref_lc" == *"unsloth"* ]] && [[ "$ref_lc" == *"gemma"* ]] && [[ "$ref_lc" == *"e4b"* ]] && [[ "$ref_lc" == *"qat"* ]]; then
+    if [[ "$ref_lc" == *"unsloth"* ]] && [[ "$ref_lc" == *"gemma"* ]] && ( [[ "$ref_lc" == *"e4b"* ]] || [[ "$ref_lc" == *"e2b"* ]] ) && [[ "$ref_lc" == *"qat"* ]]; then
```

### Commands Run
- None (terminal executions are forbidden for core-specialist)

### Decisions & Alternatives
- Swapped curated ordering of `gemma4-e2b-inst` and `gemma4-e4b-inst` to represent `e2b` as the new curated default presentation.
- Dynamically enabled MTP when `LLAMA_CPP_SPEC_MTP` is unset/empty and the model is `gemma4-e2b-inst`, rather than hardcoding it universally, to respect user overrides.

### Risks / Follow-ups
- `install.sh` bootstrap edits should be handled next by `quartermaster` as they involve bootstrap script definitions.
