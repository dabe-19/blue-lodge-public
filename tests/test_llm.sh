#!/bin/bash
# ── Tests: lib/llm.sh ─────────────────────────────────────────
# LLM tests that don't require a running Ollama instance.
# Tests configuration, token estimation, and function structure.
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/llm.sh"

test_start "lib/llm.sh — LLM Interface"

# ── Configuration ──────────────────────────────────────────────
describe "Configuration defaults"

  it "OLLAMA_URL defaults to localhost" && {
    assert_eq "$OLLAMA_URL" "http://127.0.0.1:11434"
  }

  it "LODGE_MODEL defaults to blue-lodge" && {
    assert_eq "$LODGE_MODEL" "blue-lodge"
  }

  it "LLM_MAX_TOKENS defaults to 20480" && {
    assert_eq "$LLM_MAX_TOKENS" "20480"
  }

  it "LLM_ASK_TOKENS defaults to 20480" && {
    assert_eq "$LLM_ASK_TOKENS" "20480"
  }

  it "LLM_AGENT_TOKENS defaults to 20480" && {
    assert_eq "$LLM_AGENT_TOKENS" "20480"
  }

  it "LLM_STRATEGIST_TOKENS defaults to 512" && {
    assert_eq "$LLM_STRATEGIST_TOKENS" "512"
  }

  it "LLM_ROUTER_TOKENS defaults to 256" && {
    assert_eq "$LLM_ROUTER_TOKENS" "256"
  }

  it "LLM_BUDGET_TOKENS defaults to 1024" && {
    assert_eq "$LLM_BUDGET_TOKENS" "1024"
  }

  it "LLM_BUDGET_ASK defaults to 1024" && {
    assert_eq "$LLM_BUDGET_ASK" "1024"
  }

  it "LLM_BUDGET_AGENT defaults to 512" && {
    assert_eq "$LLM_BUDGET_AGENT" "512"
  }

  it "LLM_BUDGET_ROUTER defaults to 128" && {
    assert_eq "$LLM_BUDGET_ROUTER" "128"
  }

  it "LLM_BUDGET_JOURNAL defaults to 64" && {
    assert_eq "$LLM_BUDGET_JOURNAL" "64"
  }

  it "LLM_BUDGET_TOOL defaults to 256" && {
    assert_eq "$LLM_BUDGET_TOOL" "256"
  }

# ── Sampling parameters ───────────────────────────────────────
describe "Sampling parameter defaults"

  it "LLM_TEMPERATURE defaults to model registry value" && {
    # After models_init(), globals are set from the active model's registry.
    # Default primary is minist-inst: temp=0.15
    assert_eq "$LLM_TEMPERATURE" "0.15"
  }

  it "LLM_REPEAT_PENALTY defaults to model registry value" && {
    assert_eq "$LLM_REPEAT_PENALTY" "1.2"
  }

  it "LLM_PRESENCE_PENALTY defaults to model registry value" && {
    assert_eq "$LLM_PRESENCE_PENALTY" "0.3"
  }

  it "LLM_TEMP_ASK defaults to empty (inherits model)" && {
    assert_eq "$LLM_TEMP_ASK" ""
  }

  it "LLM_TEMP_AGENT defaults to empty (inherits model)" && {
    assert_eq "$LLM_TEMP_AGENT" ""
  }

  it "LLM_TEMP_ROUTER defaults to empty (inherits model)" && {
    assert_eq "$LLM_TEMP_ROUTER" ""
  }

  it "LLM_TEMP_JOURNAL defaults to empty (inherits model)" && {
    assert_eq "$LLM_TEMP_JOURNAL" ""
  }

  it "LLM_TEMP_TOOL defaults to empty (inherits model)" && {
    assert_eq "$LLM_TEMP_TOOL" ""
  }

  it "LLM_PRESENCE_ROUTER defaults to empty (inherits model)" && {
    assert_eq "$LLM_PRESENCE_ROUTER" ""
  }

  it "LLM_PRESENCE_JOURNAL defaults to empty (inherits model)" && {
    assert_eq "$LLM_PRESENCE_JOURNAL" ""
  }

describe "Sampling parameter resolver (_llm_build_opts)"

  it "_llm_build_opts is defined" && {
    declare -f _llm_build_opts &>/dev/null
    assert_ok $?
  }

  it "_llm_build_opts returns valid JSON" && {
    result=$(_llm_build_opts 512)
    echo "$result" | jq . &>/dev/null
    assert_ok $?
  }

  it "_llm_build_opts uses model defaults when no scenario set" && {
    unset LLM_SCENARIO
    result=$(_llm_build_opts 1024)
    temp=$(echo "$result" | jq -r '.temperature')
    # No scenario → uses model registry temp (minist-inst: 0.15)
    assert_eq "$temp" "0.15"
  }

  it "_llm_build_opts uses ask scenario (inherits model default)" && {
    LLM_SCENARIO=ask
    result=$(_llm_build_opts 512)
    unset LLM_SCENARIO
    temp=$(echo "$result" | jq -r '.temperature')
    # Ask has no override — falls through to model default 0.15
    assert_eq "$temp" "0.15"
  }

  it "_llm_build_opts uses router scenario (inherits model default)" && {
    LLM_SCENARIO=router
    result=$(_llm_build_opts 50)
    unset LLM_SCENARIO
    temp=$(echo "$result" | jq -r '.temperature')
    # Router has no override — inherits model default 0.15
    assert_eq "$temp" "0.15"
  }

  it "_llm_build_opts handles strategist scenario" && {
    LLM_SCENARIO=strategist
    result=$(_llm_build_opts 256)
    unset LLM_SCENARIO
    echo "$result" | jq . &>/dev/null
    assert_ok $?
  }

  it "_llm_build_opts includes num_predict in output" && {
    result=$(_llm_build_opts 256)
    np=$(echo "$result" | jq -r '.num_predict')
    assert_eq "$np" "256"
  }

  it "_llm_build_opts includes presence_penalty" && {
    LLM_SCENARIO=journal
    result=$(_llm_build_opts 512)
    unset LLM_SCENARIO
    pp=$(echo "$result" | jq -r '.presence_penalty')
    # Journal has no override — inherits model default (minist-inst: 0.3)
    [[ "$pp" == "0.3" ]]
    assert_ok $?
  }

  it "_llm_build_opts includes top_p from model registry" && {
    unset LLM_SCENARIO
    # Switch to granite4 which has top_p=1.0
    _saved_model="$LODGE_MODEL"
    LODGE_MODEL="blue-lodge-granite4:3b"
    _result=$(_llm_build_opts 512)
    LODGE_MODEL="$_saved_model"
    _tp=$(echo "$_result" | jq -r '.top_p')
    # jq <1.7 drops .0 from integers (1.0→1); normalize for comparison
    _tp=$(awk "BEGIN{printf \"%.1f\", $_tp}")
    assert_eq "$_tp" "1.0"
  }

  it "_llm_build_opts includes top_k from model registry" && {
    unset LLM_SCENARIO
    _saved_model="$LODGE_MODEL"
    LODGE_MODEL="blue-lodge-granite4:3b"
    _result=$(_llm_build_opts 512)
    LODGE_MODEL="$_saved_model"
    _tk=$(echo "$_result" | jq -r '.top_k')
    assert_eq "$_tk" "0"
  }

  it "_llm_build_opts includes min_p from model registry" && {
    unset LLM_SCENARIO
    _result=$(_llm_build_opts 512)
    _mp=$(echo "$_result" | jq -r '.min_p')
    # jq <1.7 drops .0 from integers (0.0→0); normalize for comparison
    _mp=$(awk "BEGIN{printf \"%.1f\", $_mp}")
    assert_eq "$_mp" "0.0"
  }

  it "thinking directive injected for strategist scenario" && {
    # Strategist gets thinking — safeguarded by LLM_STRATEGIST_TOKENS cap
    # and milestone cleanup. Only router is excluded.
    body=$(declare -f llm_generate)
    # The guard should NOT exclude strategist (only router)
    echo "$body" | grep -q 'LLM_SCENARIO.*router'
    assert_ok $?
    # Verify strategist is NOT in the exclusion condition
    ! echo "$body" | grep -q 'LLM_SCENARIO.*strategist'
    assert_ok $?
  }

# ── Per-scenario absolute override behavior ────────────────────
describe "Per-scenario overrides are absolute (not additive)"

  it "scenario override replaces model default (not added to it)" && {
    # minist-inst model default temp is 0.15
    # Setting LLM_TEMP_ASK=0.5 should yield temp=0.5, NOT 0.15+0.5
    LLM_TEMP_ASK=0.5
    LLM_SCENARIO=ask
    result=$(_llm_build_opts 512)
    unset LLM_SCENARIO
    LLM_TEMP_ASK=""  # restore
    temp=$(echo "$result" | jq -r '.temperature')
    assert_eq "$temp" "0.5"
  }

  it "empty scenario override inherits model default exactly" && {
    LLM_TEMP_AGENT=""
    LLM_SCENARIO=agent
    result=$(_llm_build_opts 512)
    unset LLM_SCENARIO
    temp=$(echo "$result" | jq -r '.temperature')
    # Should be model default (0.15), not some other value
    assert_eq "$temp" "0.15"
  }

# ── models_apply_defaults ─────────────────────────────────────
describe "models_apply_defaults"

  it "models_apply_defaults is defined" && {
    declare -f models_apply_defaults &>/dev/null
    assert_ok $?
  }

  it "models_apply_defaults sets globals from model registry" && {
    models_apply_defaults "blue-lodge-minist-inst:4b" 2>/dev/null
    assert_eq "$LLM_TEMPERATURE" "0.125"
    assert_eq "$LLM_REPEAT_PENALTY" "1.0"
    assert_eq "$LLM_PRESENCE_PENALTY" "0.0"
  }

  it "models_apply_defaults sets top_p/top_k/min_p globals" && {
    models_apply_defaults "blue-lodge-minist-inst:4b" 2>/dev/null
    assert_eq "$LLM_TOP_P" "0.9"
    assert_eq "$LLM_TOP_K" "40"
    assert_eq "$LLM_MIN_P" "0.0"
  }

  it "models_apply_defaults top_p/top_k track model switch" && {
    models_apply_defaults "blue-lodge-granite4:3b" 2>/dev/null
    assert_eq "$LLM_TOP_P" "1.0"
    assert_eq "$LLM_TOP_K" "0"
    # Restore
    models_apply_defaults "blue-lodge-minist-inst:4b" 2>/dev/null
  }

  it "models_apply_defaults clears per-scenario overrides" && {
    LLM_TEMP_ASK=0.9
    LLM_REPEAT_ROUTER=2.0
    LLM_PRESENCE_TOOL=1.5
    models_apply_defaults "blue-lodge-minist-inst:4b" 2>/dev/null
    assert_eq "$LLM_TEMP_ASK" ""
    assert_eq "$LLM_REPEAT_ROUTER" ""
    assert_eq "$LLM_PRESENCE_TOOL" ""
  }

  it "models_apply_defaults updates when switching to different model" && {
    models_apply_defaults "blue-lodge-minist-think:4b" 2>/dev/null
    assert_eq "$LLM_TEMPERATURE" "0.7"
    assert_eq "$LLM_REPEAT_PENALTY" "1.2"
    assert_eq "$LLM_PRESENCE_PENALTY" "0.3"
    # Restore to default model
    models_apply_defaults "blue-lodge-minist-inst:4b" 2>/dev/null
  }

  it "thinking directive skipped for router scenario" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'LLM_SCENARIO.*router'
    assert_ok $?
  }

  it "llm_generate has debug tty echo helper (_gen_tty)" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_gen_tty'
    assert_ok $?
  }

  it "LLM_TIMEOUT defaults to 600 (safety net)" && {
    assert_eq "$LLM_TIMEOUT" "600"
  }

  it "LLM_KEEP_ALIVE defaults to 30m" && {
    assert_eq "$LLM_KEEP_ALIVE" "30m"
  }

  it "LODGE_DEBUG defaults to 0" && {
    assert_eq "$LODGE_DEBUG" "0"
  }

# ── Function existence ─────────────────────────────────────────
describe "Core LLM functions"

  it "llm_check is defined" && {
    declare -f llm_check &>/dev/null
    assert_ok $?
  }

  it "llm_is_loaded is defined" && {
    declare -f llm_is_loaded &>/dev/null
    assert_ok $?
  }

  it "llm_unload is defined" && {
    declare -f llm_unload &>/dev/null
    assert_ok $?
  }

  it "llm_cancel is defined" && {
    declare -f llm_cancel &>/dev/null
    assert_ok $?
  }

  it "llm_ensure is defined" && {
    declare -f llm_ensure &>/dev/null
    assert_ok $?
  }

  it "_llm_kill_ollama is defined" && {
    declare -f _llm_kill_ollama &>/dev/null
    assert_ok $?
  }

  it "llm_ensure prefers llamacpp over Ollama" && {
    _body=$(declare -f llm_ensure 2>/dev/null || echo "")
    # Must try llama-server BEFORE Ollama fallback
    _llamacpp_line=$(echo "$_body" | grep -n '_llm_start_llamacpp_server' | head -1 | cut -d: -f1)
    _ollama_line=$(echo "$_body" | grep -n 'ollama serve' | head -1 | cut -d: -f1)
    [ -n "$_llamacpp_line" ] && [ -n "$_ollama_line" ] && [ "$_llamacpp_line" -lt "$_ollama_line" ]
    assert_ok $? "llm_ensure must try llamacpp before Ollama"
  }

  it "llm_ensure kills Ollama when starting llamacpp" && {
    _body=$(declare -f llm_ensure 2>/dev/null || echo "")
    echo "$_body" | grep -q '_llm_kill_ollama'
    assert_ok $? "llm_ensure must call _llm_kill_ollama"
  }

  it "llm_ensure waits for loading llama-server (status 2)" && {
    _body=$(declare -f llm_ensure 2>/dev/null || echo "")
    echo "$_body" | grep -q 'loading model'
    assert_ok $? "llm_ensure must handle 'loading model' status"
  }

  it "_llm_start_llamacpp_server adopts existing healthy server" && {
    _body=$(declare -f _llm_start_llamacpp_server 2>/dev/null || echo "")
    echo "$_body" | grep -q 'adopted'
    assert_ok $? "start function must adopt existing healthy server"
  }

  it "_llm_start_llamacpp_server validates GPU layers on adopt" && {
    _body=$(declare -f _llm_start_llamacpp_server 2>/dev/null || echo "")
    echo "$_body" | grep -q 'LLAMA_CPP_GPU_LAYERS.*restarting'
    assert_ok $? "adopt must verify -ngl matches config, restart if mismatched"
  }

  it "_llm_start_llamacpp_server kills orphan processes" && {
    _body=$(declare -f _llm_start_llamacpp_server 2>/dev/null || echo "")
    echo "$_body" | grep -q 'orphan'
    assert_ok $? "start function must clean up orphan llama-server processes"
  }

  it "_llm_start_llamacpp_server disables Vulkan when GPU_LAYERS=0" && {
    _body=$(declare -f _llm_start_llamacpp_server 2>/dev/null || echo "")
    echo "$_body" | grep -q 'GGML_VK_VISIBLE_DEVICES'
    assert_ok $? "must set GGML_VK_VISIBLE_DEVICES to disable Vulkan init"
  }

  it "_llm_start_llamacpp_server checks log for unexpected GPU offload" && {
    _body=$(declare -f _llm_start_llamacpp_server 2>/dev/null || echo "")
    echo "$_body" | grep -q 'Unexpected GPU activity'
    assert_ok $? "must warn if GPU activity detected when GPU_LAYERS=0"
  }

# ── Ollama → OpenAI penalty conversion ─────────────────────────
describe "Repeat penalty → frequency penalty conversion"

  it "_llm_repeat_to_freq is defined" && {
    declare -f _llm_repeat_to_freq &>/dev/null
    assert_ok $?
  }

  it "repeat_penalty 1.0 → frequency_penalty 0.00" && {
    result=$(_llm_repeat_to_freq 1.0)
    assert_eq "$result" "0.00"
  }

  it "repeat_penalty 1.1 → frequency_penalty 0.20" && {
    result=$(_llm_repeat_to_freq 1.1)
    assert_eq "$result" "0.20"
  }

  it "repeat_penalty 1.2 → frequency_penalty 0.40" && {
    result=$(_llm_repeat_to_freq 1.2)
    assert_eq "$result" "0.40"
  }

  it "repeat_penalty 1.5 → frequency_penalty 1.00" && {
    result=$(_llm_repeat_to_freq 1.5)
    assert_eq "$result" "1.00"
  }

  it "repeat_penalty 2.0 clamped to 2.00" && {
    result=$(_llm_repeat_to_freq 2.0)
    assert_eq "$result" "2.00"
  }

  it "repeat_penalty 3.0 clamped to 2.00" && {
    result=$(_llm_repeat_to_freq 3.0)
    assert_eq "$result" "2.00"
  }

  it "_llm_build_llamacpp_payload uses converted frequency_penalty" && {
    _body=$(declare -f _llm_build_llamacpp_payload 2>/dev/null || echo "")
    echo "$_body" | grep -q '_llm_repeat_to_freq'
    assert_ok $? "must call _llm_repeat_to_freq for penalty conversion"
  }

  it "llm_chat llamacpp path uses converted frequency_penalty" && {
    _body=$(declare -f llm_chat 2>/dev/null || echo "")
    echo "$_body" | grep -q '_llm_repeat_to_freq'
    assert_ok $? "must call _llm_repeat_to_freq for penalty conversion"
  }

  it "_llm_build_llamacpp_payload forwards top_p" && {
    _body=$(declare -f _llm_build_llamacpp_payload 2>/dev/null || echo "")
    echo "$_body" | grep -q 'top_p'
    assert_ok $? "must include top_p in llamacpp payload"
  }

  it "_llm_build_llamacpp_payload forwards top_k" && {
    _body=$(declare -f _llm_build_llamacpp_payload 2>/dev/null || echo "")
    echo "$_body" | grep -q 'top_k'
    assert_ok $? "must include top_k in llamacpp payload"
  }

  it "_llm_build_llamacpp_payload forwards min_p" && {
    _body=$(declare -f _llm_build_llamacpp_payload 2>/dev/null || echo "")
    echo "$_body" | grep -q 'min_p'
    assert_ok $? "must include min_p in llamacpp payload"
  }

  it "llm_chat llamacpp path forwards top_p/top_k/min_p" && {
    _body=$(declare -f llm_chat 2>/dev/null || echo "")
    echo "$_body" | grep -q 'top_p' && echo "$_body" | grep -q 'top_k' && echo "$_body" | grep -q 'min_p'
    assert_ok $? "llm_chat llamacpp must forward top_p, top_k, min_p"
  }

# ── Process lifecycle (curl PID tracking, FIFO cleanup) ────────
describe "llamacpp curl process lifecycle"

  it "_llm_kill_curl is defined" && {
    declare -f _llm_kill_curl &>/dev/null
    assert_ok $?
  }

  it "_llm_kill_curl kills orphan curls targeting v1/chat/completions" && {
    _body=$(declare -f _llm_kill_curl 2>/dev/null || echo "")
    echo "$_body" | grep -q 'v1/chat/completions'
    assert_ok $? "must pkill curls targeting llama-server endpoint"
  }

  it "llm_cancel delegates to _llm_kill_curl" && {
    _body=$(declare -f llm_cancel 2>/dev/null || echo "")
    echo "$_body" | grep -q '_llm_kill_curl'
    assert_ok $? "llm_cancel must use _llm_kill_curl"
  }

  it "llm_generate llamacpp path uses FIFO (not pipe) for curl" && {
    _body=$(declare -f llm_generate 2>/dev/null || echo "")
    echo "$_body" | grep -q 'mkfifo'
    assert_ok $? "must use mkfifo for curl → read loop decoupling"
  }

  it "llm_stream llamacpp path uses FIFO (not pipe) for curl" && {
    _body=$(declare -f llm_stream 2>/dev/null || echo "")
    echo "$_body" | grep -q 'mkfifo'
    assert_ok $? "must use mkfifo for curl → read loop decoupling"
  }

  it "llm_chat llamacpp path uses FIFO (not pipe) for curl" && {
    _body=$(declare -f llm_chat 2>/dev/null || echo "")
    echo "$_body" | grep -q 'mkfifo'
    assert_ok $? "must use mkfifo for curl → read loop decoupling"
  }

  it "llm_generate llamacpp path kills curl after read loop" && {
    _body=$(declare -f llm_generate 2>/dev/null || echo "")
    echo "$_body" | grep -q 'kill.*_bg_curl'
    assert_ok $? "must kill curl PID to close TCP connection"
  }

  it "llm_stream llamacpp path kills curl after read loop" && {
    _body=$(declare -f llm_stream 2>/dev/null || echo "")
    echo "$_body" | grep -q 'kill.*_bg_curl'
    assert_ok $? "must kill curl PID to close TCP connection"
  }

  it "llm_chat llamacpp path kills curl after read loop" && {
    _body=$(declare -f llm_chat 2>/dev/null || echo "")
    echo "$_body" | grep -q 'kill.*_bg_curl'
    assert_ok $? "must kill curl PID to close TCP connection"
  }

  it "llm_generate llamacpp path tracks _LLM_CURL_PID" && {
    _body=$(declare -f llm_generate 2>/dev/null || echo "")
    echo "$_body" | grep -q '_LLM_CURL_PID='
    assert_ok $? "must set _LLM_CURL_PID for signal handler cleanup"
  }

  it "llm_stream llamacpp path tracks _LLM_CURL_PID" && {
    _body=$(declare -f llm_stream 2>/dev/null || echo "")
    echo "$_body" | grep -q '_LLM_CURL_PID='
    assert_ok $? "must set _LLM_CURL_PID for signal handler cleanup"
  }

  it "llm_chat llamacpp path tracks _LLM_CURL_PID" && {
    _body=$(declare -f llm_chat 2>/dev/null || echo "")
    echo "$_body" | grep -q '_LLM_CURL_PID='
    assert_ok $? "must set _LLM_CURL_PID for signal handler cleanup"
  }

  it "llm_generate llamacpp path cleans up FIFO" && {
    _body=$(declare -f llm_generate 2>/dev/null || echo "")
    echo "$_body" | grep -q 'rm.*_fifo'
    assert_ok $? "must remove FIFO after use"
  }

  it "llm_create_model is defined" && {
    declare -f llm_create_model &>/dev/null
    assert_ok $?
  }

  it "llm_create_model uses registry lookup, not root Modelfile" && {
    _body=$(declare -f llm_create_model)
    assert_contains "$_body" "_models_lookup" "Should look up model in registry"
    assert_contains "$_body" "models_generate_modelfile" "Should generate per-model Modelfile"
  }

  it "llm_create_model falls back to root Modelfile for unknown models" && {
    _body=$(declare -f llm_create_model)
    assert_contains "$_body" "Modelfile" "Should have root Modelfile fallback"
    assert_contains "$_body" "not in registry" "Should warn about fallback"
  }

  it "llm_generate is defined" && {
    declare -f llm_generate &>/dev/null
    assert_ok $?
  }

  it "llm_stream is defined" && {
    declare -f llm_stream &>/dev/null
    assert_ok $?
  }

  it "llm_chat is defined" && {
    declare -f llm_chat &>/dev/null
    assert_ok $?
  }

  it "llm_ask is defined" && {
    declare -f llm_ask &>/dev/null
    assert_ok $?
  }

  it "llm_info is defined" && {
    declare -f llm_info &>/dev/null
    assert_ok $?
  }

# ── Token estimation ──────────────────────────────────────────
describe "llm_estimate_tokens"

  it "returns positive number for text" && {
    tokens=$(llm_estimate_tokens "Hello world, this is a test.")
    assert_gt "$tokens" 0
  }

  it "scales with text length" && {
    short_tokens=$(llm_estimate_tokens "short")
    long_tokens=$(llm_estimate_tokens "This is a much longer string that should produce more tokens than the short one above")
    assert_gt "$long_tokens" "$short_tokens"
  }

  it "returns 0 for empty string" && {
    tokens=$(llm_estimate_tokens "")
    assert_eq "$tokens" "0"
  }

# ── Cancellation state ────────────────────────────────────────
describe "Cancellation tracking"

  it "_LLM_ACTIVE starts at 0" && {
    assert_eq "$_LLM_ACTIVE" "0"
  }

  it "_LLM_CURL_PID starts empty" && {
    assert_empty "$_LLM_CURL_PID"
  }

  it "llm_cancel sets _LLM_ACTIVE to 0" && {
    _LLM_ACTIVE=1
    llm_cancel
    assert_eq "$_LLM_ACTIVE" "0"
  }

  it "llm_cancel clears _LLM_CURL_PID" && {
    _LLM_CURL_PID=""
    llm_cancel
    assert_empty "$_LLM_CURL_PID"
  }

# ── Warmup function ───────────────────────────────────────────
describe "Model warmup"

  it "llm_warmup function exists" && {
    declare -f llm_warmup &>/dev/null
    assert_eq "$?" "0"
  }

  it "llm_warmup returns 0 when model already loaded" && {
    # Stub llm_is_loaded to return 0 (loaded)
    llm_is_loaded() { return 0; }
    llm_warmup
    assert_eq "$?" "0"
  }

  it "llm_warmup detects dpkg-tmp stale binary pattern" && {
    # The function body should contain dpkg-tmp detection logic
    _body=$(declare -f llm_warmup)
    assert_contains "$_body" "dpkg-tmp" "Should detect dpkg-tmp stale binary"
    assert_contains "$_body" "dpkg-new" "Should also detect dpkg-new variant"
  }

  it "llm_warmup attempts restart on dpkg-tmp error" && {
    _body=$(declare -f llm_warmup)
    assert_contains "$_body" "killall ollama" "Should kill stale Ollama process"
    assert_contains "$_body" "ollama serve" "Should restart Ollama"
  }

# ── OLLAMA_MODELS proot resolution ────────────────────────────
describe "OLLAMA_MODELS proot path"

  it "OLLAMA_MODELS is exported after sourcing llm.sh" && {
    # llm.sh was sourced at test start — OLLAMA_MODELS should be set
    assert_not_empty "$OLLAMA_MODELS" "OLLAMA_MODELS must be set"
  }

  it "OLLAMA_MODELS ends with .ollama/models" && {
    [[ "$OLLAMA_MODELS" == *".ollama/models" ]]
    assert_ok $? "OLLAMA_MODELS should end with .ollama/models"
  }

  it "llm.sh exports OLLAMA_MODELS (not just sets it)" && {
    # Check that it's exported, not just a shell variable
    _exports=$(grep 'export OLLAMA_MODELS' "$LODGE_DIR/lib/llm.sh")
    assert_not_empty "$_exports" "OLLAMA_MODELS should be exported"
  }

  it "_lodge_termux_home checks proot before HOME/.ollama/models" && {
    # Inside proot, /root/.ollama/models may exist but is wrong — must
    # check /data/data/com.termux first to avoid false positive
    _body=$(declare -f _lodge_termux_home)
    _termux_line=$(echo "$_body" | grep -n 'data/data/com.termux' | head -1 | cut -d: -f1)
    _home_line=$(echo "$_body" | grep -n 'HOME.*ollama' | head -1 | cut -d: -f1)
    [ -n "$_termux_line" ] && [ -n "$_home_line" ] && [ "$_termux_line" -lt "$_home_line" ]
    assert_ok $? "Termux path check must come before HOME check"
  }

# ── Debug instrumentation ─────────────────────────────────────
describe "Debug instrumentation"

  it "llm_debug_reset is defined" && {
    declare -f llm_debug_reset &>/dev/null
    assert_ok $?
  }

  it "llm_debug_summary is defined" && {
    declare -f llm_debug_summary &>/dev/null
    assert_ok $?
  }

  it "_llm_debug_print is defined" && {
    declare -f _llm_debug_print &>/dev/null
    assert_ok $?
  }

  it "llm_debug_reset creates debug directory" && {
    llm_debug_reset
    [ -d "$_LLM_DEBUG_DIR" ]
    assert_ok $?
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "llm_debug_reset clears previous call log" && {
    mkdir -p "$_LLM_DEBUG_DIR"
    echo "100 50" > "$_LLM_DEBUG_DIR/calls.log"
    llm_debug_reset
    [ ! -s "$_LLM_DEBUG_DIR/calls.log" ] || [ ! -f "$_LLM_DEBUG_DIR/calls.log" ]
    assert_ok $?
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "_llm_debug_end_timer writes to calls.log file" && {
    LODGE_DEBUG=1
    llm_debug_reset
    _LLM_DEBUG_CALL_START=$(date +%s%N 2>/dev/null || date +%s)
    _llm_debug_end_timer "test" "100" "50" 2>/dev/null
    [ -f "$_LLM_DEBUG_DIR/calls.log" ]
    assert_ok $?
    head -1 "$_LLM_DEBUG_DIR/calls.log" | grep -q "100 50"
    assert_ok $?
    LODGE_DEBUG=0
    rm -rf "$_LLM_DEBUG_DIR"
  }

  it "_llm_debug_print is silent when LODGE_DEBUG=0" && {
    LODGE_DEBUG=0
    output=$(_llm_debug_print "test" 2>&1)
    assert_empty "$output"
    LODGE_DEBUG=0  # restore
  }

  it "_LLM_DEBUG_TASK_START is set by llm_debug_reset" && {
    llm_debug_reset
    assert_match "$_LLM_DEBUG_TASK_START" "^[0-9]+$"
  }

# ── Thinking mode ─────────────────────────────────────────────
describe "Thinking mode configuration (thinking-only model)"

  it "LODGE_THINK defaults to 1" && {
    assert_eq "$LODGE_THINK" "1"
  }

  it "LODGE_THINK_STREAM defaults to 1" && {
    assert_eq "$LODGE_THINK_STREAM" "1"
  }

  it "llm_generate does NOT append /nothink or /think (thinking-only model)" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '/nothink'
    assert_eq $? 1
    echo "$body" | grep -q 'prompt=.*\/think'
    assert_eq $? 1
  }

  it "llm_stream does NOT append /nothink or /think (thinking-only model)" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '/nothink'
    assert_eq $? 1
    echo "$body" | grep -q 'prompt=.*\/think'
    assert_eq $? 1
  }

  it "llm_generate uses stream:true internally (thinking-model fix)" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'stream: true'
    assert_ok $?
    # Must NOT use stream: false (causes exit 28 with thinking models)
    echo "$body" | grep -q 'stream: false'
    assert_eq $? 1
  }

  it "llm_generate strips think tokens via </think> marker" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '</think>'
    assert_ok $?
    echo "$body" | grep -q '_think_pending'
    assert_ok $?
  }

  it "llm_generate displays think content when LODGE_THINK=1" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'LODGE_THINK.*LODGE_THINK_STREAM'
    assert_ok $?
    echo "$body" | grep -q 'think_token'
    assert_ok $?
  }

  it "llm_stream detects <think> dynamically (_in_think_block starts at 0)" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_in_think_block=0'
    assert_ok $?
    echo "$body" | grep -q '_can_think=0'
    assert_ok $?
    echo "$body" | grep -q '<think>'
    assert_ok $?
  }

  it "llm_stream transitions at </think> marker" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_in_think_block=0'
    assert_ok $?
    echo "$body" | grep -q '</think>'
    assert_ok $?
  }

  it "llm_chat uses stream:true internally (thinking-model fix)" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q 'stream: true'
    assert_ok $?
    echo "$body" | grep -q 'stream: false'
    assert_eq $? 1
  }

  it "llm_stream shows bright thinking header when LODGE_THINK_STREAM=2" && {
    body=$(declare -f _llm_think_color)
    echo "$body" | grep -q 'LODGE_THINK_STREAM.*-eq 2'
    assert_ok $?
    body=$(declare -f llm_stream)
    echo "$body" | grep -q 'thinking'
    assert_ok $?
  }

# ── Model Families ─────────────────────────────────────────────
describe "Model family system"

  it "_MODELS_FAMILIES has 7 families" && {
    assert_eq "${#_MODELS_FAMILIES[@]}" "7"
  }

  it "models_family_list returns all family names" && {
    fams=$(models_family_list)
    assert_contains "$fams" "qwen"
    assert_contains "$fams" "llama"
    assert_contains "$fams" "granite"
    assert_contains "$fams" "ministral"
    assert_contains "$fams" "gemma"
    assert_contains "$fams" "qwen35"
    assert_contains "$fams" "phi4"
  }

  it "_models_family_lookup finds qwen family" && {
    entry=$(_models_family_lookup "qwen")
    assert_ok $?
    assert_contains "$entry" "qwen3-think"
    assert_contains "$entry" "qwen3-inst"
  }

  it "_models_family_lookup fails for unknown family" && {
    _models_family_lookup "unknown" 2>/dev/null
    assert_fail $?
  }

  it "_models_family_keys returns correct keys for qwen" && {
    entry=$(_models_family_lookup "qwen")
    keys=$(_models_family_keys "$entry")
    assert_contains "$keys" "qwen3-think"
    assert_contains "$keys" "qwen3-inst"
  }

  it "_models_family_keys returns correct keys for granite" && {
    entry=$(_models_family_lookup "granite")
    keys=$(_models_family_keys "$entry")
    assert_contains "$keys" "granite4"
    assert_contains "$keys" "granite4-h"
    assert_contains "$keys" "granite4-preview"
  }

  it "models_create_family rejects unknown family" && {
    models_create_family "bogus" 2>/dev/null
    assert_fail $?
  }

  it "stop tokens with pipe chars parse correctly (delimiter fix)" && {
    # This was the root cause of 'invalid float value [im_end]' —
    # IFS='|' split <|im_end|> into 3 fields, corrupting everything.
    models_info "qwen3-think"
    assert_eq "$_ME_STOP" '<|im_end|>' "qwen3-think stop token"
    assert_eq "$_ME_TEMP" "0.6" "qwen3-think temp (not 'im_end')"

    models_info "granite4"
    assert_eq "$_ME_STOP" '<|end_of_text|>' "granite4 stop token"
    assert_eq "$_ME_TEMP" "0.0" "granite4 temp"

    models_info "llama32"
    assert_eq "$_ME_STOP" '<|eot_id|>' "llama32 stop token"

    models_info "minist-think"
    assert_eq "$_ME_STOP" '</s>' "ministral stop token"
  }

  it "granite4 is instruct (not thinking)" && {
    models_info "granite4"
    assert_eq "$_ME_ROLE" "instruct" "granite4 role"
    assert_eq "$_ME_THINKS" "0" "granite4 has_thinking"
  }

  it "granite4-preview is the thinking variant" && {
    models_info "granite4-preview"
    assert_ok $?
    assert_eq "$_ME_BASE" "ibm/granite4.0-preview:tiny" "granite4-preview base"
    assert_eq "$_ME_ROLE" "thinking" "granite4-preview role"
    assert_eq "$_ME_THINKS" "1" "granite4-preview has_thinking"
  }

  it "granite4-h registry entry exists and uses 3b-h base" && {
    models_info "granite4-h"
    assert_ok $?
    assert_eq "$_ME_BASE" "granite4:3b-h"
    assert_eq "$_ME_ROLE" "instruct" "granite4-h role"
  }

  it "response tag stripping is in llm_generate" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '<response>'
    assert_ok $?
    echo "$body" | grep -q 'response>/}'
    assert_ok $?
  }

  it "response tag stripping is in llm_stream" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '<response>'
    assert_ok $?
    echo "$body" | grep -q 'response>/}'
    assert_ok $?
  }

  it "each family key maps to a valid registry entry" && {
    for fam in "${_MODELS_FAMILIES[@]}"; do
      _fam_keys="${fam##*|}"
      for key in $_fam_keys; do
        _models_lookup "$key" >/dev/null
        assert_ok $? "registry lookup failed for $key"
      done
    done
  }

# ── Bracket think-tag normalization ───────────────────────────
describe "Bracket think-tag normalization ([THINK], [THOUGHT], case variants)"

  it "token-level normalization converts [THINK] to <think>" && {
    _tok='[THINK]hello[/THINK]'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>hello</think>"
  }

  it "token-level normalization converts [THOUGHT] to <think>" && {
    _tok='[THOUGHT]reasoning here[/THOUGHT]answer'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>reasoning here</think>answer"
  }

  it "token-level normalization converts [thought] (lowercase) to <think>" && {
    _tok='[thought]internal[/thought]response'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>internal</think>response"
  }

  it "token-level normalization converts [think] (lowercase) to <think>" && {
    _tok='[think]pondering[/think]answer'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>pondering</think>answer"
  }

  it "buffer normalization handles split [THINK] across tokens" && {
    _buf=""
    _buf+="[THI"
    _buf+="NK]reasoning"
    _llm_normalize_think _buf
    assert_eq "$_buf" "<think>reasoning"
  }

  it "buffer normalization handles split [/THINK] across tokens" && {
    _buf=""
    _buf+="done[/THI"
    _buf+="NK]answer"
    _llm_normalize_think _buf
    assert_eq "$_buf" "done</think>answer"
  }

  it "buffer normalization handles split [THOUGHT] across tokens" && {
    _buf=""
    _buf+="[THOU"
    _buf+="GHT]reasoning"
    _llm_normalize_think _buf
    assert_eq "$_buf" "<think>reasoning"
  }

  it "buffer normalization handles split [/THOUGHT] across tokens" && {
    _buf=""
    _buf+="done[/THOU"
    _buf+="GHT]answer"
    _llm_normalize_think _buf
    assert_eq "$_buf" "done</think>answer"
  }

  it "mixed bracket/angle tags both normalize to angle format" && {
    _tok='[THINK]internal</think>response'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>internal</think>response"
  }

  it "mixed [THOUGHT] and <think> tags normalize correctly" && {
    _tok='[THOUGHT]internal</think>response'
    _llm_normalize_think _tok
    assert_eq "$_tok" "<think>internal</think>response"
  }

  it "_llm_normalize_think function exists and handles all variants" && {
    body=$(declare -f _llm_normalize_think)
    echo "$body" | grep -qF 'THINK'
    assert_ok $?
    echo "$body" | grep -qF 'THOUGHT'
    assert_ok $?
    echo "$body" | grep -qF 'thought'
    assert_ok $?
    echo "$body" | grep -qF 'think'
    assert_ok $?
  }

  it "llm_generate function body contains normalize_think call" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_llm_normalize_think'
    assert_ok $?
  }

  it "llm_stream function body contains normalize_think call" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_llm_normalize_think'
    assert_ok $?
  }

  it "llm_chat function body contains normalize_think call" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q '_llm_normalize_think'
    assert_ok $?
  }

  it "milestone cleanup strips [THINK]...[/THINK] blocks" && {
    _ms='[THINK]internal reasoning[/THINK]Do the task'
    _ms=$(echo "$_ms" | sed 's/\[THINK\][^[]*\[\/THINK\]//gI')
    _ms=$(echo "$_ms" | sed 's/\[\/?THINK\]//gI')
    _ms=$(echo "$_ms" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    assert_eq "$_ms" "Do the task"
  }

  it "milestone cleanup strips [THOUGHT]...[/THOUGHT] blocks" && {
    _ms='[THOUGHT]internal reasoning[/THOUGHT]Do the task'
    _ms=$(echo "$_ms" | sed 's/\[THOUGHT\][^[]*\[\/THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed 's/\[\/?THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    assert_eq "$_ms" "Do the task"
  }

  it "milestone cleanup strips [thought]...[/thought] (lowercase)" && {
    _ms='[thought]internal reasoning[/thought]Do the task'
    _ms=$(echo "$_ms" | sed 's/\[THOUGHT\][^[]*\[\/THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed 's/\[\/?THOUGHT\]//gI')
    _ms=$(echo "$_ms" | sed '/^[[:space:]]*$/d' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    assert_eq "$_ms" "Do the task"
  }

# ── Chat template / Jinja2 engine ─────────────────────────────
describe "Chat template — GGUF-embedded Jinja2 via --jinja"

  it "_models_find_ollama_template is defined" && {
    declare -f _models_find_ollama_template &>/dev/null
    assert_ok $? "_models_find_ollama_template must exist"
  }

  it "_models_chat_template_name is defined (legacy/reference)" && {
    declare -f _models_chat_template_name &>/dev/null
    assert_ok $? "_models_chat_template_name must exist"
  }

  it "_models_resolve_chat_template is defined (legacy/reference)" && {
    declare -f _models_resolve_chat_template &>/dev/null
    assert_ok $? "_models_resolve_chat_template must exist"
  }

  it "_llm_start_llamacpp_server accepts optional template file as third arg" && {
    _body=$(declare -f _llm_start_llamacpp_server)
    echo "$_body" | grep -q 'chat_template_file'
    assert_ok $? "Must accept chat_template_file parameter"
  }

  it "_llm_start_llamacpp_server always passes --jinja" && {
    _body=$(declare -f _llm_start_llamacpp_server)
    echo "$_body" | grep -q '\-\-jinja'
    assert_ok $? "Must include --jinja flag for GGUF-embedded templates"
  }

  it "_llm_start_llamacpp_server supports --chat-template-file for overrides" && {
    _body=$(declare -f _llm_start_llamacpp_server)
    echo "$_body" | grep -q '\-\-chat-template-file'
    assert_ok $? "Must support --chat-template-file for explicit template override"
  }

  it "_models_chat_template_name still maps Ministral → mistral-v7" && {
    _result=$(_models_chat_template_name "hf.co/unsloth/Ministral-3-3B-Instruct-2512-GGUF:UD-Q5_K_XL")
    assert_eq "$_result" "mistral-v7"
  }

  it "_models_chat_template_name still maps Qwen3 → chatml" && {
    _result=$(_models_chat_template_name "hf.co/unsloth/Qwen3-4B-Thinking-2507-GGUF:UD-Q5_K_XL")
    assert_eq "$_result" "chatml"
  }

  it "_models_chat_template_name still maps Llama 3.2 → llama3" && {
    _result=$(_models_chat_template_name "llama3.2:3b")
    assert_eq "$_result" "llama3"
  }

  it "_models_chat_template_name still maps Granite → granite" && {
    _result=$(_models_chat_template_name "granite4:3b")
    assert_eq "$_result" "granite"
  }

  it "auto-start path uses --jinja (not template name resolution)" && {
    _body=$(declare -f llm_ensure 2>/dev/null || echo "")
    # The auto-start path should call _llm_start_llamacpp_server WITHOUT
    # _models_resolve_chat_template — --jinja handles it automatically.
    echo "$_body" | grep -q '_llm_start_llamacpp_server'
    assert_ok $? "Auto-start (llm_ensure) must call _llm_start_llamacpp_server"
  }

  it "model switch path does not resolve template names" && {
    _switch_code=$(grep -B2 -A2 '_llm_start_llamacpp_server.*_gguf' "$LODGE_DIR/lib/models.sh" | head -10)
    # Should NOT contain _models_resolve_chat_template in the launch path
    ! echo "$_switch_code" | grep -q '_models_resolve_chat_template'
    assert_ok $? "Model switch should rely on --jinja, not per-model template mapping"
  }

# ── Vision projector (mmproj) ──────────────────────────────────
describe "Vision projector (mmproj) support"

  it "_models_find_ollama_mmproj is defined" && {
    declare -f _models_find_ollama_mmproj &>/dev/null
    assert_ok $? "_models_find_ollama_mmproj must exist"
  }

  it "_models_resolve_mmproj is defined" && {
    declare -f _models_resolve_mmproj &>/dev/null
    assert_ok $? "_models_resolve_mmproj must exist"
  }

  it "_models_find_ollama_mmproj looks for projector layer" && {
    _body=$(declare -f _models_find_ollama_mmproj)
    echo "$_body" | grep -q 'application/vnd.ollama.image.projector'
    assert_ok $? "Must look for projector mediaType in manifest"
  }

  it "_models_resolve_mmproj tries base and name" && {
    _body=$(declare -f _models_resolve_mmproj)
    echo "$_body" | grep -q '_models_find_ollama_mmproj'
    assert_ok $? "Must call _models_find_ollama_mmproj"
  }

  it "llama-server launch includes mmproj hook" && {
    _body=$(declare -f _llm_start_llamacpp_server)
    echo "$_body" | grep -q 'mmproj'
    assert_ok $? "Launch args must include mmproj support"
  }

  it "models_has_vision recognizes minist-inst" && {
    result=$(models_has_vision "blue-lodge-minist-inst:4b" && echo "yes" || echo "no")
    assert_eq "$result" "yes"
  }

  it "models_has_vision rejects non-vision models" && {
    result=$(models_has_vision "blue-lodge-minist-think:4b" && echo "yes" || echo "no")
    assert_eq "$result" "no"
  }

# ── reasoning_content support (llama-server) ──────────────────
describe "reasoning_content support"

  it "llm_generate extracts reasoning_content from SSE chunks" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'reasoning_content'
    assert_ok $? "llm_generate must handle reasoning_content field"
  }

  it "llm_stream extracts reasoning_content from SSE chunks" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q 'reasoning_content'
    assert_ok $? "llm_stream must handle reasoning_content field"
  }

  it "reasoning_content opens think banner when detected" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_think_banner_open.*_can_think'
    assert_ok $? "Must open think banner for reasoning_content"
  }

  it "reasoning_content closes banner when switching to content" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_in_think_block.*_think_banner_open'
    assert_ok $? "Must close banner transitioning from reasoning to content"
  }

# ── Provider harness intercept ─────────────────────────────────
describe "Provider harness bypass"

  it "llm_check returns 0 when GEORGE_PROVIDER is set" && {
    GEORGE_PROVIDER="google"
    llm_check
    _trc=$?
    GEORGE_PROVIDER=""
    assert_eq "$_trc" "0"
  }

  it "llm_ensure returns 0 when GEORGE_PROVIDER is set" && {
    GEORGE_PROVIDER="google"
    llm_ensure
    _trc=$?
    GEORGE_PROVIDER=""
    assert_eq "$_trc" "0"
  }

  it "llm_generate has provider intercept" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q 'GEORGE_PROVIDER'
    assert_ok $? "llm_generate must check GEORGE_PROVIDER"
  }

  it "llm_stream has provider intercept" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q 'GEORGE_PROVIDER'
    assert_ok $? "llm_stream must check GEORGE_PROVIDER"
  }

  it "llm_chat has provider intercept" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q 'GEORGE_PROVIDER'
    assert_ok $? "llm_chat must check GEORGE_PROVIDER"
  }

  it "llm_generate intercept uses _provider_call_with_backoff" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_provider_call_with_backoff.*GEORGE_PROVIDER'
    assert_ok $? "intercept must route through backoff wrapper"
  }

  it "llm_stream intercept uses _provider_stream_with_backoff" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_provider_stream_with_backoff.*GEORGE_PROVIDER'
    assert_ok $? "intercept must route through streaming backoff wrapper"
  }

  it "llm_chat intercept uses _provider_call_with_backoff" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q '_provider_call_with_backoff.*GEORGE_PROVIDER'
    assert_ok $? "intercept must route through backoff wrapper"
  }

# ── FIFO safety (iSH pipe fallback) ───────────────────────────
describe "_llm_is_fifo_safe"

  it "returns true (0) on non-iSH platforms" && {
    (LODGE_PLATFORM="linux"; _llm_is_fifo_safe)
    assert_ok $? "Linux should be FIFO-safe"
  }

  it "returns false (1) on iSH platform" && {
    (LODGE_PLATFORM="ish"; _llm_is_fifo_safe)
    assert_fail $? "iSH should NOT be FIFO-safe"
  }

  it "returns true when LODGE_PLATFORM is empty" && {
    (LODGE_PLATFORM=""; _llm_is_fifo_safe)
    assert_ok $? "empty platform should default to FIFO-safe"
  }

  it "returns true for macOS" && {
    (LODGE_PLATFORM="macos"; _llm_is_fifo_safe)
    assert_ok $? "macOS should be FIFO-safe"
  }

  it "returns true for termux" && {
    (LODGE_PLATFORM="termux"; _llm_is_fifo_safe)
    assert_ok $? "termux should be FIFO-safe"
  }

describe "FIFO/pipe dispatch in LLM functions"

  it "llm_generate has _use_fifo conditional" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_use_fifo'
    assert_ok $? "llm_generate must have _use_fifo dispatch"
  }

  it "llm_stream has _use_fifo conditional" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_use_fifo'
    assert_ok $? "llm_stream must have _use_fifo dispatch"
  }

  it "llm_chat has _use_fifo conditional" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q '_use_fifo'
    assert_ok $? "llm_chat must have _use_fifo dispatch"
  }

  it "llm_generate checks _llm_is_fifo_safe" && {
    body=$(declare -f llm_generate)
    echo "$body" | grep -q '_llm_is_fifo_safe'
    assert_ok $? "llm_generate must check _llm_is_fifo_safe"
  }

  it "llm_stream checks _llm_is_fifo_safe" && {
    body=$(declare -f llm_stream)
    echo "$body" | grep -q '_llm_is_fifo_safe'
    assert_ok $? "llm_stream must check _llm_is_fifo_safe"
  }

  it "llm_chat checks _llm_is_fifo_safe" && {
    body=$(declare -f llm_chat)
    echo "$body" | grep -q '_llm_is_fifo_safe'
    assert_ok $? "llm_chat must check _llm_is_fifo_safe"
  }

  it "llm_generate has pipe-mode curl fallback" && {
    grep -q 'Pipe mode' "$LODGE_DIR/lib/llm.sh"
    assert_ok $? "lib/llm.sh must have pipe-mode fallback comment"
  }

  it "llm_stream has pipe-mode curl fallback" && {
    grep -q '_llm_stream_sse_loop' "$LODGE_DIR/lib/llm.sh"
    assert_ok $? "lib/llm.sh must have _llm_stream_sse_loop function"
  }

  it "llm_chat has pipe-mode curl fallback" && {
    grep -q '_llm_chat_sse_loop' "$LODGE_DIR/lib/llm.sh"
    assert_ok $? "lib/llm.sh must have _llm_chat_sse_loop function"
  }

test_end
