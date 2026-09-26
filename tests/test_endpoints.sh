#!/bin/bash
# ── Tests for lib/endpoints.sh ───────────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/endpoints.sh"

test_start "lib/endpoints.sh — Multi-Tier Hardware Ladder & Cascading Fallback"

describe "endpoints_init configuration"
  it "loads tier defaults properly when no config exists" && {
    ENDPOINTS_CONF="/dev/null"
    unset TIER1_NAME TIER1_CONTEXT TIER3_NAME TIER0_NAME TIER2_NAME
    endpoints_init
    assert_eq "$TIER1_NAME" "cuda-workhorse"
    assert_eq "$TIER1_CONTEXT" "65536"
    assert_eq "$TIER3_NAME" "frontier-sovereign"
    assert_eq "$TIER0_NAME" "edge-mobile"
    assert_eq "$TIER2_NAME" "cuda-worker-gpu0"
  }

  it "allows environment overrides" && {
    ENDPOINTS_CONF="/dev/null"
    export TIER1_NAME="custom-cuda"
    endpoints_init
    assert_eq "$TIER1_NAME" "custom-cuda"
    # reset
    unset TIER1_NAME
    endpoints_init
    assert_eq "$TIER1_NAME" "cuda-workhorse"
  }

describe "endpoints_cascade"
  it "cascades to active local Tier 1 CUDA container by default" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    unset ACTIVE_TIER
    # Tier 3 disabled, Tier 1 enabled on active port 8080 (mocked probe)
    _ENDPOINT_PROBE_CACHE[1]="0:$(date +%s)"
    TIER3_ENABLED=0 TIER1_ENABLED=1 endpoints_cascade
    assert_ok $?
    assert_eq "$ACTIVE_TIER" "1"
    assert_eq "$ACTIVE_ENDPOINT_URL" "http://127.0.0.1:8080"
  }

  it "routes directly to Tier 2 worker when ACTIVE_TIER=2 is requested" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    export ACTIVE_TIER=2
    _ENDPOINT_PROBE_CACHE[2]="0:$(date +%s)"
    TIER3_ENABLED=0 TIER1_ENABLED=1 TIER2_ENABLED=1 endpoints_cascade
    assert_ok $?
    assert_eq "$ACTIVE_TIER" "2"
    assert_eq "$ACTIVE_ENDPOINT_URL" "http://127.0.0.1:18080"
    unset ACTIVE_TIER
  }

describe "endpoints_get_downward_inventory"
  it "returns empty array when at lowest active tier" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    # If parent tier is 1 and tier 2 / 0 are offline/disabled
    TIER2_ENABLED=0 TIER0_ENABLED=0
    inv=$(endpoints_get_downward_inventory 1)
    assert_eq "$inv" "[]"
  }

  it "returns lower tiers when downward nodes are available" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    # Mocking Tier 2 as reachable
    _ENDPOINT_PROBE_CACHE[2]="0:$(date +%s)"
    TIER2_ENABLED=1
    inv=$(endpoints_get_downward_inventory 1)
    assert_contains "$inv" "cuda-worker-gpu0"
    assert_contains "$inv" "champion-v5"
  }

describe "endpoints_get_tier_info"
  it "retrieves correct metadata by tier and field" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    assert_eq "$(endpoints_get_tier_info 1 NAME)" "cuda-workhorse"
    assert_eq "$(endpoints_get_tier_info 1 CONTEXT)" "65536"
    assert_eq "$(endpoints_get_tier_info 3 NAME)" "frontier-sovereign"
    assert_eq "$(endpoints_get_tier_info 2 NAME)" "cuda-worker-gpu0"
  }

describe "endpoints_status_table and endpoints_status_json"
  it "outputs status table with ladder tiers" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    out=$(endpoints_status_table)
    assert_contains "$out" "Inference Hardware Ladder"
    assert_contains "$out" "Tier 1"
    assert_contains "$out" "cuda-workhorse"
    assert_contains "$out" "Tier 2"
    assert_contains "$out" "cuda-worker-gpu0"
  }

  it "returns JSON array with tier status objects" && {
    ENDPOINTS_CONF="/dev/null"
    endpoints_init
    json=$(endpoints_status_json)
    echo "$json" | jq empty
    assert_ok $?
    t1_name=$(echo "$json" | jq -r '.[] | select(.tier == 1) | .name')
    assert_eq "$t1_name" "cuda-workhorse"
  }

test_end

