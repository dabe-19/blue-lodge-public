## Full Report

### Layer: quartermaster

### Files Touched
- `install.sh` — Updated bootstrap installation scripts to switch default model from 4b to 2b and updated size descriptions/fallbacks (lines 105-106, 832-878)

### Diff Summary
```diff
# in install.sh
-export LODGE_MODEL_PRIMARY="blue-lodge-gemma4-inst:4b"
-export LODGE_MODEL_SECONDARY="blue-lodge-gemma4-inst:4b"
+export LODGE_MODEL_PRIMARY="blue-lodge-gemma4-inst:2b"
+export LODGE_MODEL_SECONDARY="blue-lodge-gemma4-inst:2b"

-# ── Default model: Gemma 4 E4B Instruct ───────────────────────
+# ── Default model: Gemma 4 E2B Instruct ───────────────────────

-    printf " ${BOLD}Gemma 4 E4B Instruct${RESET} is configured as the default model for George.\n"
+    printf " ${BOLD}Gemma 4 E2B Instruct${RESET} is configured as the default model for George.\n"

-            info "Creating model: $LODGE_MODEL_PRIMARY (first run downloads ~3 GB)..."
-            _key=$(_models_key_from_query "$LODGE_MODEL_PRIMARY" 2>/dev/null || echo "gemma4-e4b-inst")
+            info "Creating model: $LODGE_MODEL_PRIMARY (first run downloads ~1.6 GB)..."
+            _key=$(_models_key_from_query "$LODGE_MODEL_PRIMARY" 2>/dev/null || echo "gemma4-e2b-inst")

-            info "Creating primary model: $LODGE_MODEL_PRIMARY (first run downloads ~3 GB)..."
-            _key_primary=$(_models_key_from_query "$LODGE_MODEL_PRIMARY" 2>/dev/null || echo "gemma4-e4b-inst")
+            info "Creating primary model: $LODGE_MODEL_PRIMARY (first run downloads ~1.6 GB)..."
+            _key_primary=$(_models_key_from_query "$LODGE_MODEL_PRIMARY" 2>/dev/null || echo "gemma4-e2b-inst")

-            _key_secondary=$(_models_key_from_query "$LODGE_MODEL_SECONDARY" 2>/dev/null || echo "gemma4-e4b-inst")
+            _key_secondary=$(_models_key_from_query "$LODGE_MODEL_SECONDARY" 2>/dev/null || echo "gemma4-e2b-inst")
```

### Commands Run
- None

### Decisions & Alternatives
- Modified `install.sh` size hints to correctly reflect the ~1.6 GB footprint of the Gemma-4-E2B QAT model.

### Risks / Follow-ups
- None
