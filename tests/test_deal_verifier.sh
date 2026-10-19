#!/bin/bash
# ── Test Suite: Agentic Deal Verification Graph & Forensic Auditing ──

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test_start "Sovereign Agentic Deal Verification Graph & Forensic Auditing"

TEST_TMP=$(mktemp -d -t george-deal-verifier-test-XXXXXX)
trap 'rm -rf "$TEST_TMP"' EXIT

TEST_DB="$TEST_TMP/test_events.db"

# Initialize test database
python3 "$LODGE_DIR/lib/tools/event_store.py" --init --db-path "$TEST_DB" >/dev/null 2>&1

describe "1. Forensic Trap Detection: Parts & Defective Units"
  it "rejects broken / for-parts compute listings" && {
    html='<html><head><title>EVGA GeForce RTX 3090 FTW3 24GB</title></head><body><h1>EVGA GeForce RTX 3090</h1><div class="x-item-condition-text">For parts or not working</div><p>Card gives Code 43 error and black screen artifacting. Selling as-is for parts or repair.</p><span class="price">$499.00</span></body></html>'
    mock_file="$TEST_TMP/parts_trap.html"
    echo "$html" > "$mock_file"

    res=$(python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --model "GeForce RTX 3090" --price 499.0 --url "https://ebay.com/itm/defective3090" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_authentic": false'
    assert_contains "$res" '"verdict": "PARTS_OR_DEFECTIVE"'
  }

describe "2. Forensic Trap Detection: Accessory & Empty Box Traps"
  it "rejects empty box and shroud listings" && {
    html='<html><head><title>GeForce RTX 3090 Original Retail Box Only</title></head><body><h1>GeForce RTX 3090 Box</h1><div class="x-item-condition-text">Used</div><p>Empty packaging box only. NO GPU or silicon included. Great for display or resale value.</p><span class="price">$50.00</span></body></html>'
    mock_file="$TEST_TMP/box_trap.html"
    echo "$html" > "$mock_file"

    res=$(python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --model "GeForce RTX 3090" --price 50.0 --url "https://ebay.com/itm/box_trap" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_authentic": false'
    assert_contains "$res" '"verdict": "ACCESSORY_TRAP"'
  }

describe "3. Forensic Trap Detection: Off-Platform Scam Solicitations"
  it "rejects off-platform contact and payment requests" && {
    html='<html><head><title>NVIDIA GeForce RTX 4090 24GB Founders Edition</title></head><body><h1>RTX 4090 Brand New</h1><div class="x-item-condition-text">Brand New</div><p>Do NOT pay on eBay! Contact me directly on WhatsApp at +1-555-0199 or telegram: @gpu_direct to complete transaction via Zelle.</p><span class="price">$850.00</span></body></html>'
    mock_file="$TEST_TMP/scam_trap.html"
    echo "$html" > "$mock_file"

    res=$(python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --model "GeForce RTX 4090" --price 850.0 --url "https://ebay.com/itm/scam_trap" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_authentic": false'
    assert_contains "$res" '"verdict": "SCAM_SUSPECTED"'
  }

describe "4. Forensic Trap Detection: Auction Starting Bids"
  it "rejects low starting bids masquerading as Buy It Now deals" && {
    html='<html><head><title>NVIDIA RTX 4090 24GB Gaming GPU</title></head><body><h1>RTX 4090</h1><div class="x-item-condition-text">Used</div><div>Starting bid: $200.00 (14 bids, 3 days left). Reserve not met. Place bid now.</div></body></html>'
    mock_file="$TEST_TMP/auction_trap.html"
    echo "$html" > "$mock_file"

    res=$(python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --model "GeForce RTX 4090" --price 200.0 --url "https://ebay.com/itm/auction_trap" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_authentic": false'
    assert_contains "$res" '"verdict": "AUCTION_NOT_BIN"'
  }

describe "5. Authentic Compute Listing Verification"
  it "verifies and approves authentic functional hardware" && {
    html='<html><head><title>SK Hynix 64GB DDR5-5600 ECC RDIMM Server Memory Module</title></head><body><h1>SK Hynix 64GB DDR5 ECC RDIMM</h1><div class="x-item-condition-text">Used</div><span class="seller-feedback">1420 feedback, 99.8% positive</span><p>Working pull from decommissioned Dell PowerEdge server. Tested working, passes memtest86+ with zero errors. Fixed price Buy It Now.</p><span class="price">$119.00</span></body></html>'
    mock_file="$TEST_TMP/authentic_rdimm.html"
    echo "$html" > "$mock_file"

    res=$(python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --model "64GB DDR5 ECC Registered RDIMM" --price 119.0 \
      --url "https://ebay.com/itm/authentic_rdimm" --json 2>&1)
    assert_ok $?
    assert_contains "$res" '"is_authentic": true'
    assert_contains "$res" '"verdict": "AUTHENTIC"'
  }

describe "6. SQLite Persistence & Active Deals Filtering"
  it "updates deal alert status and excludes rejected deals from active views" && {
    # 1. Insert a candidate deal alert using evaluate_compute_listing engine
    eval_out=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" \
      --eval-compute --title "EVGA GeForce RTX 3090 FTW3 24GB" --price 499.0 \
      --url "https://ebay.com/itm/fake3090" --json 2>&1)
    deal_id=$(echo "$eval_out" | jq -r '.alert_id')
    [ "$deal_id" -gt 0 ] || _test_fail "check failed at line $LINENO"

    # 2. Verify it is visible before verification
    pre_deals=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --deals 2>&1)
    assert_contains "$pre_deals" "GeForce RTX 3090"

    # 3. Run verification with defective mock HTML
    mock_file="$TEST_TMP/parts_trap.html"
    python3 "$LODGE_DIR/lib/tools/deal_verifier.py" --db-path "$TEST_DB" \
      --mock-html "$mock_file" --deal-id "$deal_id" >/dev/null 2>&1
    assert_ok $?

    # 4. Confirm verification status in SQLite
    status=$(sqlite3 "$TEST_DB" "SELECT verification_status, verification_verdict FROM compute_deal_alerts WHERE id = $deal_id;")
    assert_contains "$status" "REJECTED|PARTS_OR_DEFECTIVE"

    # 5. Confirm that query_active_deals now EXCLUDES this rejected deal
    post_deals=$(python3 "$LODGE_DIR/lib/tools/event_store.py" --db-path "$TEST_DB" --deals 2>&1)
    [ -n "$post_deals" ] || _test_fail "check failed at line $LINENO"
    if echo "$post_deals" | grep -q "fake3090"; then
      _test_fail "rejected deal still listed as active"
    fi
  }

describe "7. Subagent Worker & Shell CLI"
  it "runs deal_verifier_worker.sh lifecycle" && {
    worker_out=$(bash "$LODGE_DIR/lib/agents/deal_verifier_worker.sh" all 2>&1)
    assert_ok $?
    [ -f "${GEORGE_DIR:-$LODGE_DIR/.george}/subagents.json" ] || _test_fail "check failed at line $LINENO"
  }

  it "executes /events audit and reports forensic records" && {
    audit_out=$(bash "$LODGE_DIR/commands/events.sh" audit 2>&1)
    assert_ok $?
    assert_contains "$audit_out" "FORENSIC DEAL VERIFICATIONS AUDIT LOG"
  }

describe "8. Report Hyperlinks & Clickable Listings"
  it "generates clickable hyperlinks in trading bot reports" && {
    report_out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --report 2>&1)
    assert_ok $?
    # Ensure markdown hyperlink pattern [Hardware](url) is present if compute deals exist
    if echo "$report_out" | grep -q "\[COMPUTE\]"; then
      assert_contains "$report_out" "https://"
    fi
  }

test_end
