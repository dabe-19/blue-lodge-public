## Full Report

### Layer: tests-specialist

### Files Touched
- `tests/test_models.sh` — Added model registration and vision capability assertions for `gemma4-e2b-inst` / `blue-lodge-gemma4-inst:2b` (lines 401-415, 520-527)
- `tests/test_llm.sh` — Added vision recognition assertions for `blue-lodge-gemma4-inst:2b` (lines 1212-1219)

### Diff Summary
```diff
# in tests/test_models.sh
+  it "gemma4-e2b-inst is registered with Gemma 4 base" && {
+    _entry=$(_models_lookup "gemma4-e2b-inst")
+    _models_parse_entry "$_entry"
+    assert_not_empty "$_entry"
+    echo "$_ME_BASE" | grep -q "gemma-4-E2B-it-qat-GGUF"
+    assert_ok $? "Gemma 4 E2B must use 2026 base"
+    assert_eq "$_ME_ROLE" "instruct"
+  }

+  it "gemma4-e2b-inst has vision support" && {
+    models_has_vision "blue-lodge-gemma4-inst:2b"
+    assert_ok $?
+  }

# in tests/test_llm.sh
+  it "models_has_vision recognizes gemma4-e2b-inst" && {
+    result=$(models_has_vision "blue-lodge-gemma4-inst:2b" && echo "yes" || echo "no")
+    assert_eq "$result" "yes"
+  }
```

### Commands Run
- None (terminal executions are forbidden for tests-specialist)

### Decisions & Alternatives
- Expanded coverage to fully assert registration, base image matching, and vision capabilities for the new default 2B model, keeping parity with the existing 4B test cases.

### Risks / Follow-ups
- None
