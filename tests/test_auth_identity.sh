#!/bin/bash
# ── Tests for Sovereign Identity, RBAC Permissioning & UUID Linkage ──

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/core/auth.sh"

test_start "Sovereign Identity, RBAC & UUID Linkage Engine"

describe "UUIDv4 Generator"
  it "generates compliant RFC 4122 UUIDv4 strings" && {
    u1=$(uuid_generate)
    u2=$(uuid_generate)
    [ -n "$u1" ]
    [ -n "$u2" ]
    [ "$u1" != "$u2" ]
    assert_ok $? "generated UUIDs must be non-empty and unique"
    echo "$u1" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
    assert_ok $? "UUID must match RFC 4122 version 4 pattern"
  }

describe "RBAC Role & Capability Engine"
  it "verifies admin role has full super-operator permissions" && {
    auth_role_has_cap "admin" "shell:exec"
    assert_ok $? "admin must have shell:exec"
    auth_role_has_cap "admin" "workspace:write"
    assert_ok $? "admin must have workspace:write"
    auth_role_has_cap "admin" "ipc:admin"
    assert_ok $? "admin must have ipc:admin"
  }

  it "verifies operator, agent, and guest permissions boundaries" && {
    auth_role_has_cap "operator" "agent:spawn"
    assert_ok $? "operator must have agent:spawn"
    ! auth_role_has_cap "agent" "agent:spawn"
    assert_ok $? "agent must not have agent:spawn"
    auth_role_has_cap "agent" "workspace:read"
    assert_ok $? "agent must have workspace:read"
    ! auth_role_has_cap "guest" "workspace:write"
    assert_ok $? "guest must not have workspace:write"
  }

describe "User Management & Authentication"
  it "creates, retrieves, and verifies user tokens" && {
    tmp_auth=$(mktemp -d /tmp/george_auth_test_XXXXXX)
    AUTH_DIR="$tmp_auth"
    auth_init "$tmp_auth"

    tok=$(auth_user_create "agent-worker-1" "agent")
    [ -n "$tok" ]
    assert_ok $? "user creation must return token"

    u_info=$(auth_user_get "agent-worker-1")
    assert_contains "$u_info" '"role":"agent"'

    v_res=$(auth_verify_token "$tok")
    assert_contains "$v_res" "agent-worker-1"

    auth_check_permission "$tok" "workspace:read"
    assert_ok $? "token lookup must allow workspace:read for agent"

    ! auth_check_permission "$tok" "shell:exec"
    assert_ok $? "agent token must be denied shell:exec"

    rm -rf "$tmp_auth"
  }

describe "Multi-Entity UUID Linkage Graph"
  it "links and queries session, task, agent, PID, channel, and user" && {
    tmp_auth=$(mktemp -d /tmp/george_auth_test_XXXXXX)
    AUTH_DIR="$tmp_auth"
    auth_init "$tmp_auth"

    s_id="sess_$(uuid_generate)"
    t_id="$(uuid_generate)"
    a_id="subagent_123"
    c_id="channel_999"
    my_pid=$$

    identity_link "$s_id" "$t_id" "$a_id" "$my_pid" "$c_id" "george-operator" >/dev/null

    by_pid=$(identity_lookup_by_pid "$my_pid")
    assert_contains "$by_pid" "$t_id"
    assert_contains "$by_pid" "$s_id"

    by_chan=$(identity_lookup_by_channel "$c_id")
    assert_contains "$by_chan" "$a_id"

    by_task=$(identity_lookup_by_task "$t_id")
    assert_contains "$by_task" "$my_pid"

    identity_unlink "$t_id"
    after_unlink=$(identity_lookup_by_task "$t_id")
    [ -z "$after_unlink" ]
    assert_ok $? "unlinked entity must not be found"

    rm -rf "$tmp_auth"
  }

test_end
