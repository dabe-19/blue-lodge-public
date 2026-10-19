#!/bin/bash
# ── Test Suite: Global Rolling Event Store, FTS5 Search & Compute Alpha Engine ──

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test_start "Global Rolling Event Store, FTS5 Search & Compute Deals Architecture"

TEST_TMP=$(mktemp -d -t george-event-store-test-XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_DB="$TEST_TMP/test_events.db"

describe "1. Database Schema & WAL Engine Initialization"
  it "initializes tables, indexes, and seeded contracts" && {
    out=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --init --db-path "$TEST_DB" 2>&1)
    assert_ok $?
    assert_contains "$out" "Sovereign Event Store & Hardware Taxonomy initialized"
    [ -f "$TEST_DB" ] || _test_fail "check failed at line $LINENO"

    # Check WAL mode
    journal_mode=$(sqlite3 "$TEST_DB" "PRAGMA journal_mode;")
    [ "$journal_mode" = "wal" ] || _test_fail "check failed at line $LINENO"

    # Check contracts seeded
    contracts_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM event_contracts;")
    [ "$contracts_count" -ge 8 ] || _test_fail "check failed at line $LINENO"

    # Check hardware specs seeded
    specs_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM compute_hardware_specs;")
    [ "$specs_count" -ge 10 ] || _test_fail "check failed at line $LINENO"
  }

describe "2. Event Logging & FTS5 Full-Text Search"
  it "logs event and indexes payload into FTS5" && {
    payload='{"gpu_model": "RTX 3090 FTW3", "seller": "alpha_compute_vendor", "price": 499.0}'
    python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" \
      --log-event --event-id "evt_test_search_1" --event-type "compute_listing_seen" \
      --source "test_suite" --payload "$payload" >/dev/null 2>&1
    assert_ok $?

    # Verify event exists in events table
    cnt=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM events WHERE event_id = 'evt_test_search_1';")
    [ "$cnt" -eq 1 ] || _test_fail "check failed at line $LINENO"

    # Search via FTS5
    search_out=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --search "alpha_compute_vendor" 2>&1)
    assert_ok $?
    assert_contains "$search_out" "Found 1 events matching 'alpha_compute_vendor'"
    assert_contains "$search_out" "evt_test_search_1"
  }

  it "logs reaction outcomes with exit codes and execution latency" && {
    python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" \
      --log-reaction --reactor-id "rx_test_unit" --event-id "evt_test_search_1" \
      --event-type "compute_listing_seen" --action-cmd "echo test" \
      --status "EXECUTED" --exit-code 0 --duration-ms 12.5 >/dev/null 2>&1
    assert_ok $?

    cnt=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM reactions WHERE reactor_id = 'rx_test_unit';")
    [ "$cnt" -eq 1 ] || _test_fail "check failed at line $LINENO"
  }

describe "3. Compute Deal Valuation & Unit Economics"
  it "filters out sub-floor accessory listings (box only, cooler)" && {
    res=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" \
      --eval-compute --title "EVGA RTX 3090 BOX ONLY EMPTY" --price 45.0 --json 2>&1)
    assert_ok $?
    [ "$res" = "null" ] || _test_fail "check failed at line $LINENO"
  }

  it "identifies and grades STEAL deal with unit economics" && {
    # DDR5 64GB ECC RDIMM at $110 (baseline FMV $185 -> ~40% discount -> STEAL)
    res=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" \
      --eval-compute --title "Samsung 64GB DDR5 4800MHz ECC RDIMM Server Memory" \
      --price 110.0 --url "https://ebay.com/itm/test_ddr5" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_deal": true'
    assert_contains "$res" '"deal_grade": "STEAL"'

    # Verify unit cost is calculated: $110 / 64GB = ~$1.72/GB
    assert_contains "$res" '"unit_cost": 1.72'

    # Verify deal is recorded in compute_deal_alerts
    active_deals=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --deals 2>&1)
    assert_ok $?
    assert_contains "$active_deals" "STEAL"
  }

describe "4. 90-Day Rolling Retention & VACUUM Compaction"
  it "prunes expired records older than retention threshold" && {
    # Insert an old event from 120 days ago
    old_ts=$(($(date +%s) - (120 * 86400)))
    sqlite3 "$TEST_DB" "INSERT INTO events (event_id, event_type, source, depth, payload, timestamp, created_at) VALUES ('evt_ancient', 'system_telemetry', 'test', 0, '{}', $old_ts, $old_ts);"
    
    pre_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM events WHERE event_id = 'evt_ancient';")
    [ "$pre_count" -eq 1 ] || _test_fail "check failed at line $LINENO"

    # Run pruner with 90 days retention
    prune_out=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --prune --retention-days 90 2>&1)
    assert_ok $?
    assert_contains "$prune_out" "Pruned records older than 90 days"

    post_count=$(sqlite3 "$TEST_DB" "SELECT COUNT(*) FROM events WHERE event_id = 'evt_ancient';")
    [ "$post_count" -eq 0 ] || _test_fail "check failed at line $LINENO"
  }

  it "compacts database via VACUUM" && {
    compact_out=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --compact 2>&1)
    assert_ok $?
    assert_contains "$compact_out" "Database compacted"
  }

describe "5. Shell CLI Integration (/events, /osint deals, /react events)"
  it "executes /events status and /events contracts" && {
    status_out=$(bash "$LODGE_DIR/commands/events.sh" status 2>&1)
    assert_ok $?
    assert_contains "$status_out" "SOVEREIGN EVENT STORE & COMPUTE TELEMETRY DATABASE"

    contracts_out=$(bash "$LODGE_DIR/commands/events.sh" contracts 2>&1)
    assert_ok $?
    assert_contains "$contracts_out" "compute_deal_alert"
  }

  it "executes /osint deals and /osint hardware" && {
    deals_out=$(bash "$LODGE_DIR/commands/osint.sh" deals 2>&1)
    assert_ok $?
    assert_contains "$deals_out" "ACTIVE COMPUTE ALPHA"

    hw_out=$(bash "$LODGE_DIR/commands/osint.sh" hardware 2>&1)
    assert_ok $?
    assert_contains "$hw_out" "COMPUTE HARDWARE BENCHMARK"
  }

  it "routes /react events to event store" && {
    react_events_out=$(bash "$LODGE_DIR/commands/react.sh" events status 2>&1)
    assert_ok $?
    assert_contains "$react_events_out" "SOVEREIGN EVENT STORE"
  }

describe "6. Autonomic Cron Compaction Script"
  it "executes events_compaction.sh without errors" && {
    comp_cron_out=$(bash "$LODGE_DIR/.george/cron_jobs/events_compaction.sh" 2>&1)
    assert_ok $?
    [ -f "$LODGE_DIR/.george/cron_jobs/events_compaction.log" ] || _test_fail "check failed at line $LINENO"
    grep -q "Running rolling event store 90-day retention prune" "$LODGE_DIR/.george/cron_jobs/events_compaction.log" || _test_fail "check failed at line $LINENO"
  }

test_end
