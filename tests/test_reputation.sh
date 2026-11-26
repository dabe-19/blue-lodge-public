#!/bin/bash
# ── Tests: Entity Judgment & Reputation Ledger ───────────────────────

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LODGE_DIR="$(cd "$TEST_DIR/.." && pwd)"

source "$TEST_DIR/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
source "$LODGE_DIR/lib/agents/reputation.sh" 2>/dev/null || true

TEST_TMP=$(mktemp -d /tmp/george-reputation-test-XXXXXX)
export GEORGE_CONFIG_DIR="$TEST_TMP/.george"
export GEORGE_DIR="$GEORGE_CONFIG_DIR"
export REPUTATION_DB="$GEORGE_DIR/reputation.db"

cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

test_start "George Entity Judgment Ledger & Reputation Engine"

describe "reputation_init"

it "creates sqlite database and schema cleanly" && {
    reputation_init
    assert_file_exists "$REPUTATION_DB"
    tables=$(sqlite3 "$REPUTATION_DB" ".tables")
    assert_contains "$tables" "reputation"
}

describe "reputation_get and default tier"

it "initializes unknown user with 10 points and Stranger tier" && {
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "10|Stranger"
}

describe "reputation_add and tier progression"

it "increments score and promotes to Brother at 25 points" && {
    reputation_add "user_101" 15 "valid_bug_report" "Alice"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "25|Brother"
}

it "promotes to Master Mason at 50 points" && {
    reputation_add "user_101" 25 "approved_pr" "Alice"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "50|Master Mason"
}

it "demotes to Cowan when score drops below 0" && {
    reputation_add "user_bad" -15 "jailbreak_attempt" "Eve"
    data=$(reputation_get "user_bad" "Eve")
    score=$(echo "$data" | cut -d'|' -f1)
    tier=$(echo "$data" | cut -d'|' -f2)
    assert_eq "$tier" "Cowan"
}

describe "reputation_format_status"

it "formats Masonic judgment report with score and unlocked features" && {
    status_str=$(reputation_format_status "user_101" "Alice")
    assert_contains "$status_str" "George's Judgment Ledger"
    assert_contains "$status_str" "50 points"
    assert_contains "$status_str" "Master Mason"
    assert_contains "$status_str" "Elevated agency"
}

describe "reputation SQL safety (injection hardening)"

it "does not let a crafted username self-promote to Master Mason" && {
    evil="x', 'discord', 999, 'Master Mason', 0, 0); --"
    reputation_get "998877665544" "$evil" >/dev/null
    data=$(reputation_get "998877665544" "whatever")
    assert_eq "$data" "10|Stranger"
}

it "stores usernames containing apostrophes verbatim" && {
    reputation_get "123456789012" "O'Brien" >/dev/null
    stored=$(sqlite3 "$REPUTATION_DB" "SELECT username FROM reputation WHERE user_id = '123456789012';")
    assert_eq "$stored" "O'Brien"
}

it "rejects user_ids containing quotes or SQL metacharacters" && {
    reputation_get "1' OR '1'='1" "Mallory" >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1"
    cnt=$(sqlite3 "$REPUTATION_DB" "SELECT count(*) FROM reputation WHERE username = 'Mallory';")
    assert_eq "$cnt" "0"
}

it "rejects non-integer score deltas" && {
    reputation_add "user_101" "5; DROP TABLE reputation" "x" "Alice" >/dev/null 2>&1
    rc=$?
    assert_eq "$rc" "1"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "50|Master Mason"
}

describe "reputation audit ledger, customizable themes, anti-farming & moderator floor"

it "records every score change in reputation_events audit ledger" && {
    ev_cnt=$(sqlite3 "$REPUTATION_DB" "SELECT count(*) FROM reputation_events WHERE user_id = 'user_101';")
    assert_eq "$ev_cnt" "2"
    last_reason=$(sqlite3 "$REPUTATION_DB" "SELECT reason FROM reputation_events WHERE user_id = 'user_101' ORDER BY id DESC LIMIT 1;")
    assert_eq "$last_reason" "approved_pr"
}

it "switches theme presets cleanly and syncs existing DB tier labels" && {
    reputation_apply_preset "standard"
    data=$(reputation_get "user_101" "Alice")
    assert_eq "$data" "50|Steward"
    qdata=$(reputation_get "user_bad" "Eve")
    assert_eq "$(echo "$qdata" | cut -d'|' -f2)" "Quarantined"
    reputation_apply_preset "masonic"
    data_back=$(reputation_get "user_101" "Alice")
    assert_eq "$data_back" "50|Master Mason"
}

it "supports renaming a custom role and updating its threshold" && {
    reputation_set_tier_name "tier_2" "Fellowcraft"
    reputation_set_threshold "tier_2" 20
    reputation_add "user_custom" 10 "bonus" "Bob" >/dev/null
    data=$(reputation_get "user_custom" "Bob")
    assert_eq "$data" "20|Fellowcraft"
    # Restore masonic defaults for subsequent tests
    reputation_apply_preset "masonic"
    reputation_set_threshold "tier_2" 25
}

it "enforces 10-minute passive cooldown and +3/day passive cap" && {
    reputation_get "user_farm" "Farmer" >/dev/null
    reputation_can_reward_passive "user_farm"
    assert_eq "$?" "0"
    reputation_add "user_farm" 1 "constructive_turn" "Farmer" "system:discord" >/dev/null
    # Immediate second reward blocked by 600s cooldown
    reputation_can_reward_passive "user_farm"
    assert_eq "$?" "1"
    # Backdate 3 passive events within last 24h (outside 600s cooldown) -> daily cap (+3/day) blocks 4th
    now=$(date +%s)
    sqlite3 "$REPUTATION_DB" "UPDATE reputation_events SET created_at = $((now - 7200)) WHERE user_id = 'user_farm';"
    sqlite3 "$REPUTATION_DB" "INSERT INTO reputation_events (user_id, username, platform, delta, old_score, new_score, old_tier, new_tier, reason, actor, created_at) VALUES ('user_farm', 'Farmer', 'discord', 1, 11, 12, 'Stranger', 'Stranger', 'constructive_turn', 'system:discord', $((now - 5400)));"
    sqlite3 "$REPUTATION_DB" "INSERT INTO reputation_events (user_id, username, platform, delta, old_score, new_score, old_tier, new_tier, reason, actor, created_at) VALUES ('user_farm', 'Farmer', 'discord', 1, 12, 13, 'Stranger', 'Stranger', 'constructive_turn', 'system:discord', $((now - 3600)));"
    reputation_can_reward_passive "user_farm"
    assert_eq "$?" "1"
}

it "defaults moderator floor to tier_1, respects discord_role_floors, and keeps tier_0 quarantine paramount" && {
    reputation_get "user_mod" "ModAlice" >/dev/null
    eff=$(reputation_effective_tier_id "user_mod" "" 1)
    assert_eq "$eff" "tier_1"
    # Map custom role 'elder' -> tier_2 via reputation_policy_save
    updated_p=$(reputation_load_policy | jq '.discord_role_floors["elder"] = "tier_2"')
    reputation_policy_save "$updated_p"
    eff2=$(reputation_effective_tier_id "user_mod" "elder" 0)
    assert_eq "$eff2" "tier_2"
    # Quarantine ALWAYS overrides role floor
    reputation_quarantine "user_mod" "ModAlice" "policy_breach" "operator" >/dev/null
    eff3=$(reputation_effective_tier_id "user_mod" "elder" 1)
    assert_eq "$eff3" "tier_0"
}

it "supports /rep CLI subcommands (grant, quarantine, reset, history, theme)" && {
    out=$(bash "$LODGE_DIR/commands/rep.sh" grant "user_cli" 20 "cli_test" 2>&1)
    assert_contains "$out" "30|Brother"
    out_h=$(bash "$LODGE_DIR/commands/rep.sh" history "user_cli" 2>&1)
    assert_contains "$out_h" "cli_test"
    out_r=$(bash "$LODGE_DIR/commands/rep.sh" reset "user_cli" 2>&1)
    assert_contains "$out_r" "Reset user_cli"
    out_t=$(bash "$LODGE_DIR/commands/rep.sh" theme show 2>&1)
    assert_contains "$out_t" '"theme": "masonic"'
}

test_end
