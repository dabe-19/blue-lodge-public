#!/bin/bash
# ── Test Suite: Advanced Event-Bus Triggers & OSINT Intelligence Pipeline ────

source "$(dirname "$0")/framework.sh"
LODGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

test_start "Advanced Event-Bus Triggers, Trading Bot, API Engine & SDR Pipeline"

describe "1. API Database & Event Trigger Building Engine"
  it "queries keyless APIs from sqlite catalog" && {
    out=$(python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --search "crypto" 2>&1)
    assert_ok $?
    assert_contains "$out" "KEYLESS APIS MATCHING"
  }

  it "lists preset trigger recipes" && {
    out=$(python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --presets 2>&1)
    assert_ok $?
    assert_contains "$out" "coinbase_btc"
    assert_contains "$out" "polymarket_active"
  }

  it "builds and deploys an autonomic trigger script" && {
    out=$(python3 "$LODGE_DIR/lib/tools/api_trigger_builder.py" --build-preset "coinbase_ada" 2>&1)
    assert_ok $?
    assert_contains "$out" "Deployed autonomic trigger script"
    [ -f "$GEORGE_DIR/cron_jobs/api_coinbase_ada.sh" ] || _test_fail "check failed at line $LINENO"
  }

describe "2. Sovereign Subagent & FIFO IPC Synthesis Pipeline"
  it "runs synthesis subagent adhering to OKF standards and IPC FIFO" && {
    out=$(bash "$LODGE_DIR/lib/agents/synthesis_worker.sh" '[{"category":"GRANT","title":"Test Grant","score":85,"amount":"$100K","deadline":"Rolling","url":"https://example.com"}]' 2>&1)
    assert_ok $?
    assert_contains "$out" "Executive Summary"
    # Verify subagent registered in .george/subagents.json
    grep -q "Synthesize Financial OSINT Signals" "$GEORGE_DIR/subagents.json" || _test_fail "check failed at line $LINENO"
  }

describe "3. Mock Trading Bot & Polymarket Simulator"
  it "fetches real keyless market prices for BTC and ADA" && {
    out=$(python3 -c "from lib.tools.trading_bot import fetch_crypto_prices; p = fetch_crypto_prices(); print(f'BTC:{p.get(\"BTC\")} ADA:{p.get(\"ADA\")}')" 2>&1)
    assert_ok $?
    assert_contains "$out" "BTC:"
    assert_contains "$out" "ADA:"
  }

  it "queries live Polymarket prediction markets" && {
    out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --markets 2>&1)
    assert_ok $?
    assert_contains "$out" "ACTIVE POLYMARKET PREDICTION MARKETS"
  }

  it "executes simulated crypto trade with position tracking" && {
    out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --trade BUY --asset BTC --amount 100.0 --rationale "Unit test trigger" 2>&1)
    assert_ok $?
    assert_contains "$out" '"status": "ok"'
    assert_contains "$out" '"asset": "BTC"'
  }

  it "places simulated Polymarket prediction bet" && {
    out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --bet-poly YES --amount 50.0 --rationale "Unit test bet" 2>&1)
    assert_ok $?
    assert_contains "$out" '"status": "ok"'
    assert_contains "$out" '"outcome": "YES"'
  }

  it "generates streaming 10-minute performance report with +/- P&L" && {
    out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --report 2>&1)
    assert_ok $?
    assert_contains "$out" "SOVEREIGN TRADING & INTEL REPORT"
    assert_contains "$out" "Portfolio Status:"
    assert_contains "$out" "STRATEGIC OSINT SYNTHESIS DOSSIER"
  }

describe "4. SDR Radio Lab & TrunkRecorder Hook"
  it "displays SDR hook status and configuration" && {
    out=$(python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --status 2>&1)
    assert_ok $?
    assert_contains "$out" "SOVEREIGN SDR RADIO LAB"
    assert_contains "$out" "Remote Gateway"
  }

  it "simulates P25 emergency call and emits event into bus" && {
    out=$(python3 "$LODGE_DIR/lib/tools/sdr_ingest.py" --simulate --emergency 2>&1)
    assert_ok $?
    assert_contains "$out" "Emergency: True"
    assert_contains "$out" "Ingested: 1 calls"
    [ -f "$LODGE_DIR/dossiers/sdr_osint.md" ] || _test_fail "check failed at line $LINENO"
    grep -q "EMERGENCY" "$LODGE_DIR/dossiers/sdr_osint.md" || _test_fail "check failed at line $LINENO"
  }

describe "5. Event Bus Chaining & Reactors"
  it "has active registered reactors for trading, pricing, and RSS" && {
    # Seed the sandbox registry (never inspect live reactors from tests).
    ( source "$LODGE_DIR/lib/ipc/event_bus.sh" >/dev/null 2>&1
      reactor_add rx_trading_crypto finance_crypto_signal ".*" "true" >/dev/null 2>&1
      reactor_add rx_coinbase_btc crypto_price_tick ".*" "true" >/dev/null 2>&1 )
    out=$(bash "$LODGE_DIR/commands/react.sh" list 2>&1)
    assert_ok $?
    assert_contains "$out" "rx_trading_crypto"
    assert_contains "$out" "rx_coinbase_btc"
  }

describe "6. Production Migration Secrets & System Daemonization"
  if [ "${GEORGE_TEST_ALLOW_LIVE_STATE:-0}" != "1" ]; then
    it "maintains secrets template and secure active secrets.env (0600)" && skip "deployment check (set GEORGE_TEST_ALLOW_LIVE_STATE=1)"
    it "verifies event_router entrypoint and systemd unit" && skip "deployment check (set GEORGE_TEST_ALLOW_LIVE_STATE=1)"
  else
  it "maintains secrets template and secure active secrets.env (0600)" && {
    [ -f "$LODGE_DIR/configs/secrets.env.example" ] || _test_fail "check failed at line $LINENO"
    [ -f "$GEORGE_DIR/secrets.env" ] || _test_fail "check failed at line $LINENO"
    perms=$(stat -c "%a" "$GEORGE_DIR/secrets.env" 2>/dev/null || stat -f "%OLp" "$GEORGE_DIR/secrets.env" 2>/dev/null)
    [ "$perms" = "600" ] || _test_fail "check failed at line $LINENO"
    grep -q "searxng_url: http://127.0.0.1:8081" "$GEORGE_DIR/osint_watchers.yaml" || _test_fail "check failed at line $LINENO"
  }

  it "verifies event_router entrypoint and systemd unit" && {
    out=$(bash "$LODGE_DIR/lib/tools/event_router.sh" status 2>&1)
    assert_ok $?
    assert_contains "$out" "EVENT_BUS_FIFO"
    [ -f "$LODGE_DIR/deploy/systemd/george-event-router.service" ] || _test_fail "check failed at line $LINENO"
    [ -f "$HOME/.config/systemd/user/george-event-router.service" ] || _test_fail "check failed at line $LINENO"
  }
  fi

describe "7. SDR Audio Transcription & RX 5700 XT Node"
  it "checks AMD Radeon RX 5700 XT transcription node status" && {
    out=$(SDR_TRANSCRIPTION_ENDPOINT=http://192.168.1.20:8090/inference python3 "$LODGE_DIR/lib/tools/sdr_transcribe.py" --node-status --json 2>&1)
    assert_ok $?
    assert_contains "$out" "AMD Radeon RX 5700 XT"
    assert_contains "$out" "192.168.1.20"
  }

  it "executes audio transcription pipeline and emits event" && {
    out=$(python3 "$LODGE_DIR/lib/tools/sdr_transcribe.py" --spool --json 2>&1)
    assert_ok $?
    assert_contains "$out" "transcribed_count"
  }

describe "8. Discord & Autonomic Synthesis Message Verification"
  it "includes OKF subagents over POSIX FIFOs statement in streaming report" && {
    out=$(python3 "$LODGE_DIR/lib/tools/trading_bot.py" --report 2>&1)
    assert_ok $?
    assert_contains "$out" "Autonomous OKF subagents run over POSIX FIFOs"
    assert_contains "$out" "dossiers/finance_intel.md"
  }

test_end
