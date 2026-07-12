#!/bin/bash
# ── Tests: Web Fetch Cascade and /limits Integration ────────────
source "$(dirname "$0")/framework.sh"
source "$LODGE_DIR/lib/ui.sh"
source "$LODGE_DIR/lib/agent.sh"

test_start "Web Fetch Cascade and Limits"

describe "_agent_extract_urls_from_search"

  it "extracts up to 4 unique URLs and strips trailing punctuation/delimiters" && {
    mock_output="
[1] Content Update Notes - World of Warcraft - Blizzard Entertainment
    http://worldofwarcraft.blizzard.com/en-us/content-update-notes
    World of Warcraft is constantly being updated...

[2] Midnight Patch 12.1 News and Guides - Wowhead
    https://www.wowhead.com/ptr)
    Edit Mode, new Nameplate customization...

[3] 12.0.5 Content Update Notes - General Discussion
    https://us.forums.blizzard.com/en/wow/t/1205-content-update-notes/2292554]
    The 12.0.5 content update...

[4] Duplicate Blizzard link
    http://worldofwarcraft.blizzard.com/en-us/content-update-notes
    Duplicate link check...

[5] Fifth Link
    https://example.com/fifth
    Fifth URL to check cap...
"
    urls=$(_agent_extract_urls_from_search "$mock_output")
    
    count=$(echo "$urls" | wc -l)
    assert_eq "$count" "4"
    
    # Assert clean URL extraction
    echo "$urls" | grep -q "https://www.wowhead.com/ptr$"
    assert_ok $?
    
    echo "$urls" | grep -q "https://us.forums.blizzard.com/en/wow/t/1205-content-update-notes/2292554$"
    assert_ok $?

    # Verify duplicate is excluded
    dup_count=$(echo "$urls" | grep -F "http://worldofwarcraft.blizzard.com/en-us/content-update-notes" | wc -l)
    assert_eq "$dup_count" "1"
  }

describe "_is_junk_output"

  it "correctly identifies Cloudflare and HTTP errors as junk output" && {
    _is_junk_output "Access Denied (error 403)"
    assert_ok $?

    _is_junk_output "Checking your browser before accessing... Cloudflare"
    assert_ok $?

    _is_junk_output "503 Service Temporarily Unavailable"
    assert_ok $?

    # Should not classify clean content as junk
    _is_junk_output "The latest WoW patch notes contain Holy Shock improvements."
    assert_eq "$?" "1"
  }

describe "Cascade retry state file behavior"

  it "populates cascade queue file on successful search" && {
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/lodge-test-cascade.XXXXXX")
    export AGENT_TASK_WORKSPACE="$tmp_dir"
    
    # Run the logic that writes the queue file
    exit_code=0
    cmd="/web search wow patch notes"
    output="
[1] Blizzard
    https://news.blizzard.com/notes
[2] Wowhead
    https://wowhead.com/news
"
    _queue_file="$AGENT_TASK_WORKSPACE/web_fetch_queue.txt"
    
    if [[ "$cmd" == /web\ search\ * ]] && [ "$exit_code" -eq 0 ]; then
        if [ -n "${AGENT_TASK_WORKSPACE:-}" ]; then
            mkdir -p "$AGENT_TASK_WORKSPACE"
            _agent_extract_urls_from_search "$output" > "$_queue_file" 2>/dev/null
        fi
    fi

    assert_file_exists "$_queue_file"
    file_content=$(cat "$_queue_file")
    
    line_count=$(echo "$file_content" | wc -l)
    assert_eq "$line_count" "2"

    rm -rf "$tmp_dir"
  }
