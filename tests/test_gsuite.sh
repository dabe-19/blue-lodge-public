#!/bin/bash
# ── Tests: lib/comms/gsuite.sh ──────────────────────────────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui/ui.sh"

# Create mock secrets functions for testing (no actual vault needed)
declare -A _MOCK_SECRETS=()

secrets_set() { _MOCK_SECRETS["$1"]="$2"; }
secrets_get() {
    val="${_MOCK_SECRETS[$1]:-}"
    [ -n "$val" ] && echo "$val" || return 1
}
secrets_exists() { [ -n "${_MOCK_SECRETS[$1]:-}" ]; }

source "$LODGE_DIR/lib/comms/gsuite.sh"

test_start "lib/comms/gsuite.sh — Google Workspace Integration"

# ── Availability ───────────────────────────────────────────────
describe "gsuite_available"

  it "returns true when curl and jq exist" && { gsuite_available; assert_ok $?; }

# ── API Endpoints ──────────────────────────────────────────────
describe "API Endpoints"

  it "GMAIL_API is correct" && assert_eq "$GMAIL_API" "https://gmail.googleapis.com/gmail/v1"
  it "DRIVE_API is correct" && assert_eq "$DRIVE_API" "https://www.googleapis.com/drive/v3"
  it "DOCS_API is correct" && assert_eq "$DOCS_API" "https://docs.googleapis.com/v1"
  it "GOOGLE_TOKEN_URL is correct" && assert_eq "$GOOGLE_TOKEN_URL" "https://oauth2.googleapis.com/token"
  it "GOOGLE_DEVICE_URL is correct" && assert_eq "$GOOGLE_DEVICE_URL" "https://oauth2.googleapis.com/device/code"

# ── Scopes ─────────────────────────────────────────────────────
describe "OAuth2 Scopes"

  it "includes Gmail scope" && assert_contains "$GOOGLE_SCOPES" "gmail.modify"
  it "includes Drive scope" && assert_contains "$GOOGLE_SCOPES" "drive"
  it "includes Docs scope" && assert_contains "$GOOGLE_SCOPES" "documents"

# ── Setup ──────────────────────────────────────────────────────
describe "gsuite_setup"

  it "stores client ID in secrets" && {
    _MOCK_SECRETS=()
    gsuite_setup "test_client_id" "test_client_secret" >/dev/null 2>&1
    stored=$(secrets_get "google_client_id")
    assert_eq "$stored" "test_client_id"
  }

  it "stores client secret in secrets" && {
    _MOCK_SECRETS=()
    gsuite_setup "test_client_id" "test_client_secret" >/dev/null 2>&1
    stored=$(secrets_get "google_client_secret")
    assert_eq "$stored" "test_client_secret"
  }

  it "returns error without arguments" && {
    _MOCK_SECRETS=()
    gsuite_setup "" "" >/dev/null 2>&1
    assert_fail $?
  }

# ── Authentication State ──────────────────────────────────────
describe "gsuite_is_authenticated"

  it "returns false when no token stored" && {
    _MOCK_SECRETS=()
    gsuite_is_authenticated
    assert_fail $?
  }

  it "returns true when token exists" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["google_access_token"]="fake_token"
    gsuite_is_authenticated
    assert_ok $?
  }

# ── Token Management ──────────────────────────────────────────
describe "_gsuite_get_token"

  it "returns token when valid and not expired" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["google_access_token"]="fresh_token_123"
    _MOCK_SECRETS["google_token_expiry"]="$(( $(date +%s) + 9999 ))"
    _MOCK_SECRETS["google_client_id"]="cid"
    _MOCK_SECRETS["google_client_secret"]="csecret"
    token=$(_gsuite_get_token 2>/dev/null)
    assert_eq "$token" "fresh_token_123"
  }

# ── Status ─────────────────────────────────────────────────────
describe "gsuite_status"

  it "runs without error" && {
    _MOCK_SECRETS=()
    gsuite_status >/dev/null 2>&1
    assert_ok $?
  }

  it "shows unconfigured state" && {
    _MOCK_SECRETS=()
    output=$(gsuite_status 2>/dev/null)
    assert_contains "$output" "No"
  }

  it "shows configured state" && {
    _MOCK_SECRETS=()
    _MOCK_SECRETS["google_client_id"]="test_id"
    output=$(gsuite_status 2>/dev/null)
    assert_contains "$output" "Yes"
  }

# ── Function Existence ─────────────────────────────────────────
describe "Function existence"

  it "gmail_list is defined" && assert_fn_defined "gmail_list"
  it "gmail_read is defined" && assert_fn_defined "gmail_read"
  it "gmail_send is defined" && assert_fn_defined "gmail_send"
  it "gmail_search is defined" && assert_fn_defined "gmail_search"
  it "drive_list is defined" && assert_fn_defined "drive_list"
  it "drive_download is defined" && assert_fn_defined "drive_download"
  it "drive_upload is defined" && assert_fn_defined "drive_upload"
  it "drive_search is defined" && assert_fn_defined "drive_search"
  it "docs_read is defined" && assert_fn_defined "docs_read"
  it "docs_create is defined" && assert_fn_defined "docs_create"

# ── Input Validation ──────────────────────────────────────────
describe "Input validation"

  it "gmail_read requires message ID" && { gmail_read "" >/dev/null 2>&1; assert_fail $?; }
  it "gmail_send requires all params" && { gmail_send "" "" "" >/dev/null 2>&1; assert_fail $?; }
  it "drive_download requires file ID" && { drive_download "" >/dev/null 2>&1; assert_fail $?; }
  it "drive_upload requires valid filepath" && { drive_upload "/nonexistent/file" >/dev/null 2>&1; assert_fail $?; }
  it "drive_search requires query" && { drive_search "" >/dev/null 2>&1; assert_fail $?; }
  it "docs_read requires doc ID" && { docs_read "" >/dev/null 2>&1; assert_fail $?; }
  it "docs_create requires title" && { docs_create "" >/dev/null 2>&1; assert_fail $?; }

test_end
