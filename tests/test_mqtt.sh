#!/bin/bash
# ── Tests: lib/mqtt.sh ────────────────────────────────────────
# Unit tests for MQTT library. Mocks mosquitto_pub/mosquitto_sub
# so no real broker or mosquitto-clients is needed.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/mqtt.sh"

test_start "lib/mqtt.sh — MQTT Integration"

# ── Test infrastructure ────────────────────────────────────────
_MQTT_TEST_DIR=""
_MQTT_MOCK_BIN=""

_mqtt_test_setup() {
    _MQTT_TEST_DIR=$(test_tmpdir)
    _MQTT_MOCK_BIN="$_MQTT_TEST_DIR/bin"
    mkdir -p "$_MQTT_MOCK_BIN"

    # Point config/db to temp dir
    GEORGE_CONFIG_DIR="$_MQTT_TEST_DIR/config"
    MQTT_CONFIG="$GEORGE_CONFIG_DIR/mqtt.conf"
    MQTT_DB="$GEORGE_CONFIG_DIR/mqtt.db"
    mkdir -p "$GEORGE_CONFIG_DIR"

    # Write a test config
    MQTT_BROKER="test.broker.io"
    MQTT_PORT="1883"
    MQTT_CLIENT_ID="george-test"
    MQTT_PROTOCOL="5"
    MQTT_KEEPALIVE="60"
    MQTT_TLS="0"
    MQTT_CAFILE=""
    MQTT_CERTFILE=""
    MQTT_KEYFILE=""

    # Create mock mosquitto_pub that logs its args
    cat > "$_MQTT_MOCK_BIN/mosquitto_pub" << 'MOCK'
#!/bin/bash
echo "MOCK_PUB_ARGS: $*" >> "${MQTT_MOCK_LOG:-/tmp/mqtt_mock.log}"
exit 0
MOCK
    chmod +x "$_MQTT_MOCK_BIN/mosquitto_pub"

    # Create mock mosquitto_sub that returns canned messages
    cat > "$_MQTT_MOCK_BIN/mosquitto_sub" << 'MOCK'
#!/bin/bash
echo "MOCK_SUB_ARGS: $*" >> "${MQTT_MOCK_LOG:-/tmp/mqtt_mock.log}"
# Return a canned message
echo "${MQTT_MOCK_MESSAGE:-test-payload-42}"
exit 0
MOCK
    chmod +x "$_MQTT_MOCK_BIN/mosquitto_sub"

    export MQTT_MOCK_LOG="$_MQTT_TEST_DIR/mock.log"
    export MQTT_MOCK_MESSAGE="test-payload-42"

    # Put mocks at front of PATH
    export PATH="$_MQTT_MOCK_BIN:$PATH"
}

_mqtt_test_teardown() {
    rm -rf "$_MQTT_TEST_DIR" 2>/dev/null
    # Reset config globals
    MQTT_BROKER=""
    MQTT_PORT="1883"
    MQTT_CLIENT_ID=""
    MQTT_TLS="0"
    unset MQTT_USERNAME MQTT_PASSWORD 2>/dev/null
}

# ── mqtt_available ─────────────────────────────────────────────
describe "mqtt_available"

  it "returns true when mosquitto tools are in PATH" && {
    _mqtt_test_setup
    mqtt_available
    assert_ok $?
    _mqtt_test_teardown
  }

  it "returns false when mosquitto tools are missing" && {
    _mqa_old_path="$PATH"
    PATH="/usr/bin:/bin"
    mqtt_available
    _mqa_rc=$?
    PATH="$_mqa_old_path"
    assert_fail $_mqa_rc
  }

# ── mqtt_init / config loading ─────────────────────────────────
describe "mqtt_init"

  it "loads config from mqtt.conf" && {
    _mqtt_test_setup
    _mqtt_save_config
    # Reset and reload
    MQTT_BROKER=""
    MQTT_PORT=""
    mqtt_init
    assert_eq "$MQTT_BROKER" "test.broker.io"
    assert_eq "$MQTT_PORT" "1883"
    _mqtt_test_teardown
  }

  it "auto-generates client ID when empty" && {
    _mqtt_test_setup
    MQTT_CLIENT_ID=""
    mqtt_init
    assert_not_empty "$MQTT_CLIENT_ID"
    _mqtt_test_teardown
  }

  it "returns 0 when no config file exists" && {
    _mqtt_test_setup
    rm -f "$MQTT_CONFIG"
    MQTT_BROKER=""
    mqtt_init
    assert_ok $?
    _mqtt_test_teardown
  }

# ── _mqtt_require_config ──────────────────────────────────────
describe "_mqtt_require_config"

  it "succeeds when broker is configured and tools exist" && {
    _mqtt_test_setup
    _mqtt_require_config
    assert_ok $?
    _mqtt_test_teardown
  }

  it "fails when broker is empty" && {
    _mqtt_test_setup
    MQTT_BROKER=""
    _mqtt_require_config 2>/dev/null
    _mrc_rc=$?
    assert_fail $_mrc_rc
    _mqtt_test_teardown
  }

# ── _mqtt_build_args ──────────────────────────────────────────
describe "_mqtt_build_args"

  it "includes host, port, client ID" && {
    _mqtt_test_setup
    _mba_out=$(_mqtt_build_args)
    assert_contains "$_mba_out" "test.broker.io"
    assert_contains "$_mba_out" "1883"
    assert_contains "$_mba_out" "george-test"
    _mqtt_test_teardown
  }

  it "uses v5 protocol flag" && {
    _mqtt_test_setup
    MQTT_PROTOCOL="5"
    _mba_out=$(_mqtt_build_args)
    assert_contains "$_mba_out" "5"
    _mqtt_test_teardown
  }

  it "uses v311 protocol flag" && {
    _mqtt_test_setup
    MQTT_PROTOCOL="311"
    _mba_out=$(_mqtt_build_args)
    assert_contains "$_mba_out" "311"
    _mqtt_test_teardown
  }

  it "includes username when set via env" && {
    _mqtt_test_setup
    MQTT_USERNAME="testuser"
    MQTT_PASSWORD="testpass"
    _mba_out=$(_mqtt_build_args)
    assert_contains "$_mba_out" "testuser"
    assert_contains "$_mba_out" "testpass"
    unset MQTT_USERNAME MQTT_PASSWORD
    _mqtt_test_teardown
  }

  it "includes TLS cafile when TLS enabled" && {
    _mqtt_test_setup
    MQTT_TLS="1"
    MQTT_CAFILE="$_MQTT_TEST_DIR/ca.pem"
    touch "$MQTT_CAFILE"
    _mba_out=$(_mqtt_build_args)
    assert_contains "$_mba_out" "ca.pem"
    _mqtt_test_teardown
  }

  it "omits TLS flags when TLS disabled" && {
    _mqtt_test_setup
    MQTT_TLS="0"
    MQTT_CAFILE="/some/ca.pem"
    _mba_out=$(_mqtt_build_args)
    assert_not_contains "$_mba_out" "cafile"
    _mqtt_test_teardown
  }

# ── mqtt_publish ───────────────────────────────────────────────
describe "mqtt_publish"

  it "calls mosquitto_pub with correct topic and message" && {
    _mqtt_test_setup
    mqtt_publish "test/topic" "hello world" >/dev/null 2>&1
    _mp_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_mp_log" "MOCK_PUB_ARGS"
    assert_contains "$_mp_log" "-t test/topic"
    assert_contains "$_mp_log" "-m hello world"
    _mqtt_test_teardown
  }

  it "passes QoS flag" && {
    _mqtt_test_setup
    mqtt_publish "test/qos" "data" --qos 2 >/dev/null 2>&1
    _mp_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_mp_log" "-q 2"
    _mqtt_test_teardown
  }

  it "passes retain flag" && {
    _mqtt_test_setup
    mqtt_publish "test/retain" "sticky" --retain >/dev/null 2>&1
    _mp_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_mp_log" "-r"
    _mqtt_test_teardown
  }

  it "fails when topic is missing" && {
    _mqtt_test_setup
    mqtt_publish "" "msg" 2>/dev/null
    assert_fail $?
    _mqtt_test_teardown
  }

  it "fails when message is missing" && {
    _mqtt_test_setup
    mqtt_publish "test/topic" "" 2>/dev/null
    assert_fail $?
    _mqtt_test_teardown
  }

  it "returns 0 on success" && {
    _mqtt_test_setup
    mqtt_publish "test/ok" "payload" >/dev/null 2>&1
    assert_ok $?
    _mqtt_test_teardown
  }

# ── mqtt_subscribe ─────────────────────────────────────────────
describe "mqtt_subscribe"

  it "calls mosquitto_sub with correct topic" && {
    _mqtt_test_setup
    mqtt_subscribe "sensors/#" >/dev/null 2>&1
    _ms_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_ms_log" "MOCK_SUB_ARGS"
    assert_contains "$_ms_log" "-t sensors/#"
    _mqtt_test_teardown
  }

  it "passes count and timeout flags" && {
    _mqtt_test_setup
    mqtt_subscribe "test/topic" --count 5 --timeout 30 >/dev/null 2>&1
    _ms_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_ms_log" "-C 5"
    assert_contains "$_ms_log" "-W 30"
    _mqtt_test_teardown
  }

  it "returns received messages" && {
    _mqtt_test_setup
    export MQTT_MOCK_MESSAGE="temperature=22.5"
    _ms_out=$(mqtt_subscribe "sensors/temp" 2>/dev/null)
    assert_contains "$_ms_out" "temperature=22.5"
    _mqtt_test_teardown
  }

  it "uses default count of 1" && {
    _mqtt_test_setup
    mqtt_subscribe "test/defaults" >/dev/null 2>&1
    _ms_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_ms_log" "-C 1"
    _mqtt_test_teardown
  }

  it "uses default timeout of 10" && {
    _mqtt_test_setup
    mqtt_subscribe "test/defaults" >/dev/null 2>&1
    _ms_log=$(cat "$MQTT_MOCK_LOG" 2>/dev/null)
    assert_contains "$_ms_log" "-W 10"
    _mqtt_test_teardown
  }

  it "fails when topic is missing" && {
    _mqtt_test_setup
    mqtt_subscribe "" 2>/dev/null
    assert_fail $?
    _mqtt_test_teardown
  }

# ── mqtt_setup ─────────────────────────────────────────────────
describe "mqtt_setup"

  it "parses broker:port from one-shot arg" && {
    _mqtt_test_setup
    mqtt_setup "mybroker.io:8883" >/dev/null 2>&1
    assert_eq "$MQTT_BROKER" "mybroker.io"
    assert_eq "$MQTT_PORT" "8883"
    _mqtt_test_teardown
  }

  it "defaults port to 1883 when no port given" && {
    _mqtt_test_setup
    mqtt_setup "simple.broker" >/dev/null 2>&1
    assert_eq "$MQTT_BROKER" "simple.broker"
    assert_eq "$MQTT_PORT" "1883"
    _mqtt_test_teardown
  }

  it "saves config file" && {
    _mqtt_test_setup
    mqtt_setup "save.test:9999" >/dev/null 2>&1
    assert_file_exists "$MQTT_CONFIG"
    _msu_content=$(cat "$MQTT_CONFIG")
    assert_contains "$_msu_content" "save.test"
    assert_contains "$_msu_content" "9999"
    _mqtt_test_teardown
  }

# ── mqtt_show_config ───────────────────────────────────────────
describe "mqtt_show_config"

  it "shows broker and port" && {
    _mqtt_test_setup
    _mqtt_save_config
    _msc_out=$(mqtt_show_config 2>&1)
    assert_contains "$_msc_out" "test.broker.io"
    assert_contains "$_msc_out" "1883"
    _mqtt_test_teardown
  }

  it "fails when not configured" && {
    _mqtt_test_setup
    rm -f "$MQTT_CONFIG"
    MQTT_BROKER=""
    # force re-check
    mqtt_show_config 2>/dev/null
    assert_fail $?
    _mqtt_test_teardown
  }

# ── SQLite: Topic Tracking ─────────────────────────────────────
describe "topic tracking"

  it "creates mqtt.db with correct schema" && {
    _mqtt_test_setup
    _mqtt_db_init
    assert_file_exists "$MQTT_DB"
    _mdb_tables=$(sqlite3 "$MQTT_DB" ".tables" 2>/dev/null)
    assert_contains "$_mdb_tables" "topics"
    assert_contains "$_mdb_tables" "messages"
    _mqtt_test_teardown
  }

  it "tracks a published topic" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_track_topic "home/lights" "publish"
    _mtt_row=$(sqlite3 "$MQTT_DB" "SELECT topic, direction FROM topics LIMIT 1;" 2>/dev/null)
    assert_contains "$_mtt_row" "home/lights"
    assert_contains "$_mtt_row" "publish"
    _mqtt_test_teardown
  }

  it "increments use_count on repeated topic access" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_track_topic "test/count" "publish"
    _mqtt_track_topic "test/count" "publish"
    _mqtt_track_topic "test/count" "subscribe"
    _mtc_count=$(sqlite3 "$MQTT_DB" "SELECT use_count FROM topics WHERE topic='test/count';" 2>/dev/null)
    assert_eq "$_mtc_count" "3"
    _mqtt_test_teardown
  }

  it "mqtt_topics lists tracked topics" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_track_topic "sensors/temp" "subscribe"
    _mqtt_track_topic "home/door" "publish"
    _mtt_out=$(mqtt_topics 2>/dev/null)
    assert_contains "$_mtt_out" "sensors/temp"
    assert_contains "$_mtt_out" "home/door"
    _mqtt_test_teardown
  }

# ── SQLite: Message History ────────────────────────────────────
describe "message history"

  it "logs a message" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_log_message "sensors/temp" "in" "22.5"
    _mmh_row=$(sqlite3 "$MQTT_DB" "SELECT payload FROM messages LIMIT 1;" 2>/dev/null)
    assert_eq "$_mmh_row" "22.5"
    _mqtt_test_teardown
  }

  it "mqtt_history returns recent messages" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_log_message "sensors/temp" "in" "22.5"
    _mqtt_log_message "sensors/temp" "in" "23.1"
    _mqtt_log_message "home/door" "out" "open"
    _mmh_out=$(mqtt_history "" 10 2>/dev/null)
    assert_contains "$_mmh_out" "22.5"
    assert_contains "$_mmh_out" "23.1"
    assert_contains "$_mmh_out" "open"
    _mqtt_test_teardown
  }

  it "mqtt_history filters by topic" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_log_message "sensors/temp" "in" "22.5"
    _mqtt_log_message "home/door" "out" "open"
    _mmh_out=$(mqtt_history "sensors/temp" 10 2>/dev/null)
    assert_contains "$_mmh_out" "22.5"
    assert_not_contains "$_mmh_out" "open"
    _mqtt_test_teardown
  }

  it "handles SQL-sensitive characters in payload" && {
    _mqtt_test_setup
    _mqtt_db_init
    _mqtt_log_message "test/escape" "in" "it's a \"test\" with 'quotes'"
    _mme_row=$(sqlite3 "$MQTT_DB" "SELECT payload FROM messages LIMIT 1;" 2>/dev/null)
    assert_contains "$_mme_row" "test"
    _mqtt_test_teardown
  }

  it "publish tracks topic and logs message" && {
    _mqtt_test_setup
    _mqtt_db_init
    mqtt_publish "integration/test" "hello" >/dev/null 2>&1
    _mpi_topic=$(sqlite3 "$MQTT_DB" "SELECT topic FROM topics LIMIT 1;" 2>/dev/null)
    assert_eq "$_mpi_topic" "integration/test"
    _mpi_msg=$(sqlite3 "$MQTT_DB" "SELECT payload FROM messages LIMIT 1;" 2>/dev/null)
    assert_eq "$_mpi_msg" "hello"
    _mqtt_test_teardown
  }

  it "subscribe tracks topic and logs received message" && {
    _mqtt_test_setup
    _mqtt_db_init
    export MQTT_MOCK_MESSAGE="sensor-data-99"
    mqtt_subscribe "sub/track" >/dev/null 2>&1
    _msi_topic=$(sqlite3 "$MQTT_DB" "SELECT topic FROM topics LIMIT 1;" 2>/dev/null)
    assert_eq "$_msi_topic" "sub/track"
    _msi_msg=$(sqlite3 "$MQTT_DB" "SELECT payload FROM messages LIMIT 1;" 2>/dev/null)
    assert_eq "$_msi_msg" "sensor-data-99"
    _mqtt_test_teardown
  }

test_end
