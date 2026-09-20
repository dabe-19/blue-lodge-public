#!/bin/bash
# ── Tests for lib/context_engine.sh ───────────────────────────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/context_engine.sh"

test_start "lib/context_engine.sh — Copilot-Style Dynamic Context Injection"

describe "context_engine_build structure"
  it "injects all 13 Copilot-style XML sections including sovereign_soul" && {
    ctx=$(context_engine_build "test goal" "$PWD" 1)
    assert_contains "$ctx" "<developer_instructions>"
    assert_contains "$ctx" "<sovereign_soul>"
    assert_contains "$ctx" "SOUL OF GEORGE"
    assert_contains "$ctx" "THE INVIOLABLE LANDMARKS"
    assert_contains "$ctx" "<tool_manifest>"
    assert_contains "$ctx" "<operational_protocol>"
    assert_contains "$ctx" "<agent_swarm_identities>"
    assert_contains "$ctx" "<runtime_environments>"
    assert_contains "$ctx" "<skills_and_instructions>"
    assert_contains "$ctx" "<crypto_and_services>"
    assert_contains "$ctx" "<mcp_knowledge_injection>"
    assert_contains "$ctx" "<project_memory_and_goals>"
    assert_contains "$ctx" "Semantic Memory Handles"
    assert_contains "$ctx" "mem:active_task"
    assert_contains "$ctx" "<semantic_recall_and_journal>"
    assert_contains "$ctx" "<reflexive_intelligence>"
    assert_contains "$ctx" "<active_environment>"
  }

  it "injects workspace and git telemetry in active_environment" && {
    ctx=$(context_engine_build "test goal" "$PWD" 1)
    assert_contains "$ctx" "Host System"
    assert_contains "$ctx" "Git State"
    assert_contains "$ctx" "Active Inference Tier"
    assert_contains "$ctx" "Hardware Fallback Ladder"
  }

  it "injects comprehensive 77-tool catalog in tool_manifest" && {
    ctx=$(context_engine_build "test goal" "$PWD" 1)
    assert_contains "$ctx" "77 native POSIX tools"
    assert_contains "$ctx" "bash_exec"
    assert_contains "$ctx" "file_edit"
    assert_contains "$ctx" "git_clone"
    assert_contains "$ctx" "backup_create"
    assert_contains "$ctx" "pgp_sign"
    assert_contains "$ctx" "gsuite_search"
    assert_contains "$ctx" "reflexive_status"
    assert_contains "$ctx" "wallet_status"
    assert_contains "$ctx" "service_list"
    assert_contains "$ctx" "sandbox_create"
    assert_contains "$ctx" "memory_get_section"
    assert_contains "$ctx" "model_param_set"
    assert_contains "$ctx" "mcp_server_status"
    assert_contains "$ctx" "email_send"
    assert_contains "$ctx" "slash_command_exec"
  }

describe "context_engine_debug_trace"
  it "generates telemetry table with token budget and character breakdown" && {
    trace_out=$(context_engine_debug_trace "test trace goal" "$PWD" 1)
    assert_contains "$trace_out" "George Developer Chat: Context Injection Trace"
    assert_contains "$trace_out" "Total Injected Characters"
    assert_contains "$trace_out" "Estimated Tokens"
    assert_contains "$trace_out" "Section Hierarchy Breakdown"
  }

test_end

