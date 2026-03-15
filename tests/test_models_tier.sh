#!/bin/bash
# ── Tests: Model Registry Tier Field ──────────────────────────
# Tests the tier field (field 17) extension to _MODELS_REGISTRY[].
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/models.sh"

test_start "lib/models.sh — Tier Field Extension"

# ── All entries have tier ──────────────────────────────────────
describe "_models_parse_entry tier field"

  it "parses edge tier from existing entry" && {
    _entry="${_MODELS_REGISTRY[0]}"
    _models_parse_entry "$_entry"
    assert_eq "$_ME_TIER" "edge"
  }

  it "parses central tier from central entry" && {
    _entry=$(_models_lookup "qwen3-8b-think")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_TIER" "central"
  }

  it "defaults to any for entries without tier" && {
    # Simulate old-format entry (16 fields, no tier)
    _old="test^test-name^test:1b^instruct^0^none^</s>^0.5^1.0^0.0^4096^1024^0.9^40^0.0^Test notes"
    _models_parse_entry "$_old"
    assert_eq "$_ME_TIER" "any"
  }

  it "all existing edges are edge tier" && {
    _all_ok=1
    for _entry in "${_MODELS_REGISTRY[@]}"; do
        _models_parse_entry "$_entry"
        # Edge models are <8B (key doesn't contain 8b/12b)
        case "$_ME_KEY" in
            *-8b*|*-12b*) continue ;;
            *)
                if [ "$_ME_TIER" != "edge" ]; then
                    _all_ok=0
                    break
                fi ;;
        esac
    done
    assert_eq "$_all_ok" "1"
  }

# ── Central tier models ───────────────────────────────────────
describe "central tier registry entries"

  it "qwen3-8b-think is in registry" && {
    _entry=$(_models_lookup "qwen3-8b-think")
    assert_not_empty "$_entry"
  }

  it "qwen3-8b-inst is in registry" && {
    _entry=$(_models_lookup "qwen3-8b-inst")
    assert_not_empty "$_entry"
  }

  it "llama31-8b is in registry" && {
    _entry=$(_models_lookup "llama31-8b")
    assert_not_empty "$_entry"
  }

  it "mistral-nemo-12b is in registry" && {
    _entry=$(_models_lookup "mistral-nemo-12b")
    assert_not_empty "$_entry"
  }

  it "central models have correct base_image format" && {
    _entry=$(_models_lookup "qwen3-8b-think")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_BASE" "qwen3:8b"
    _entry=$(_models_lookup "llama31-8b")
    _models_parse_entry "$_entry"
    assert_eq "$_ME_BASE" "llama3.1:8b"
  }

# ── Field integrity ───────────────────────────────────────────
describe "registry field integrity"

  it "all entries have 17 fields" && {
    _all_ok=1
    for _entry in "${_MODELS_REGISTRY[@]}"; do
        _count=$(echo "$_entry" | awk -F'^' '{print NF}')
        if [ "$_count" -ne 17 ]; then
            _all_ok=0
            break
        fi
    done
    assert_eq "$_all_ok" "1"
  }

  it "total registry has 22 entries (18 edge + 4 central)" && {
    assert_eq "${#_MODELS_REGISTRY[@]}" "22"
  }

test_end
