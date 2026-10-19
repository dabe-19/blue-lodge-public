#!/bin/bash
# ── Tests: Sovereign Public APIs Catalog & FTS5 Discovery Engine ──
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"
source "$LODGE_DIR/lib/tools/native_tools.sh"

test_start "Sovereign Public APIs Catalog & FTS5 Discovery Suite"

# ── 1. Database Integrity & Size ──────────────────────────────
describe "Public APIs SQLite FTS5 database integrity"

  it "verifies database exists and passes PRAGMA integrity_check" && {
    _db="$LODGE_DIR/data/catalog/public_apis.sqlite"
    [ -f "$_db" ]
    assert_ok $? "public_apis.sqlite must exist on disk"

    _check=$(sqlite3 "$_db" "PRAGMA integrity_check;" 2>/dev/null)
    assert_eq "$_check" "ok" "SQLite database integrity check must return 'ok'"
  }

  it "contains indexed APIs and active FTS5 table" && {
    _db="$LODGE_DIR/data/catalog/public_apis.sqlite"
    _total=$(sqlite3 "$_db" "SELECT count(*) FROM apis;" 2>/dev/null)
    _fts_total=$(sqlite3 "$_db" "SELECT count(*) FROM apis_fts;" 2>/dev/null)
    [ "$_total" -ge 1000 ]
    assert_ok $? "Catalog must contain over 1,000 public APIs (actual: $_total)"
    assert_eq "$_total" "$_fts_total" "FTS5 table count must match primary apis table count"
  }

# ── 2. Python Backend Queries & Keyless Prioritization ────────
describe "Python Backend Search & Keyless Prioritization"

  it "prioritizes keyless / zero-auth APIs in search results" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _first_is_keyless=$("$_py_bin" -c "
from lib.tools.public_apis_backend import search_apis
hits = search_apis('weather', limit=1)
if hits and hits[0].get('is_keyless') == 1:
    print('yes')
else:
    print('no')
" 2>/dev/null)
    assert_eq "$_first_is_keyless" "yes" "First weather API result must be keyless"
  }

  it "filters strictly by category when requested" && {
    _py_bin="python3"
    [ -x "$LODGE_DIR/.venv/bin/python" ] && _py_bin="$LODGE_DIR/.venv/bin/python"
    _cats=$("$_py_bin" -c "
from lib.tools.public_apis_backend import search_apis
hits = search_apis('rates', category='Currency Exchange', limit=3)
all_curr = all(h.get('category') == 'Currency Exchange' for h in hits)
print('valid' if all_curr and len(hits) > 0 else 'invalid')
" 2>/dev/null)
    assert_eq "$_cats" "valid" "All returned items must belong to Currency Exchange category"
  }

# ── 3. Slash Command (/api) ───────────────────────────────────
describe "Slash Command (/api) interface"

  it "executes /api search for geocoding" && {
    _out=$(bash "$LODGE_DIR/commands/api.sh" search "geocoding" 2>/dev/null)
    assert_contains "$_out" "Geocoding" "/api search must return geocoding category results"
    assert_contains "$_out" "KEYLESS" "/api search must include keyless indicators"
  }

  it "executes /api categories and lists categories" && {
    _out=$(bash "$LODGE_DIR/commands/api.sh" categories 2>/dev/null)
    assert_contains "$_out" "Weather" "/api categories must include Weather"
    assert_contains "$_out" "Finance" "/api categories must include Finance"
  }

# ── 4. Native Tool Dispatch (api_search) ──────────────────────
describe "Native tool dispatch for api_search"

  it "dispatches api_search via native_tools_dispatch" && {
    _args='{"query":"blockchain cryptocurrency","limit":2}'
    _out=$(native_tools_dispatch "call_api_test" "api_search" "$_args" 2>/dev/null)
    assert_contains "$_out" "tool_call_id" "native_tools_dispatch must return valid tool call envelope"
    assert_contains "$_out" "api_search" "Envelope must specify tool name api_search"
  }

# ── 5. Web SQLite Route Integration ───────────────────────────
describe "Web SQLite route compatibility"

  it "executes query directly on public_apis.sqlite via sqlite3 CLI" && {
    _db="$LODGE_DIR/data/catalog/public_apis.sqlite"
    _query="SELECT a.name, a.category, a.description FROM apis a JOIN apis_fts f ON a.id = f.rowid WHERE apis_fts MATCH 'weather*' LIMIT 1;"
    _out=$(sqlite3 -json "$_db" "$_query" 2>/dev/null)
    assert_contains "$_out" "weather" "FTS match query must return weather record"
  }

test_end
