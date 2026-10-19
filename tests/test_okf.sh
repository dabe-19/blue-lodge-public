#!/bin/bash
# ── Tests for Google Open Knowledge Graph (OKF) Engine & Tools ────────

source "$(dirname "$0")/framework.sh"
source "$(dirname "$0")/../lib/knowledge/okf.sh"
source "$(dirname "$0")/../lib/ui/commands.sh"
source "$(dirname "$0")/../lib/tools/native_tools.sh"

test_start "Google Open Knowledge Graph (OKF) Engine & Tools"

describe "OKF Schema & Graph Validation"
  it "validates that okf/blue_lodge_graph.jsonld conforms to schema" && {
    out=$(okf_validate)
    assert_contains "$out" "OKF Graph structure & JSON-LD syntax: VALID"
  }

describe "OKF Search"
  it "searches modules by semantic keyword (ipc)" && {
    res=$(okf_search "ipc")
    assert_contains "$res" "fifo_ipc.sh"
    assert_contains "$res" "urn:blue-lodge:module:lib/ipc/fifo_ipc.sh"
  }

  it "searches in JSON mode" && {
    res_json=$(okf_search "ipc" --json)
    assert_contains "$res_json" '"@id": "urn:blue-lodge:module:lib/ipc/fifo_ipc.sh"'
  }

describe "OKF Query"
  it "queries module metadata, dependencies, and exports" && {
    qres=$(okf_query "fifo_ipc.sh")
    assert_contains "$qres" "fifo_ipc.sh"
    assert_contains "$qres" "SoftwareSourceCode"
    assert_contains "$qres" "ipc_channel_open"
    assert_contains "$qres" "urn:blue-lodge:subsystem:ipc"
  }

  it "queries subsystem metadata" && {
    subres=$(okf_query "urn:blue-lodge:subsystem:core")
    assert_contains "$subres" "Core Reasoning & Agent Loop"
  }

describe "OKF Standards"
  it "lists registered programming standards" && {
    std_list=$(okf_standards)
    assert_contains "$std_list" "fifo-async-ipc-flowcontrol"
    assert_contains "$std_list" "okf-directory-structure"
    assert_contains "$std_list" "telemetry-closed-loop-remediation"
  }

  it "retrieves detailed specification for fifo-async-ipc-flowcontrol" && {
    std_detail=$(okf_standards "fifo-async-ipc-flowcontrol")
    assert_contains "$std_detail" "FIFO Async IPC Flowcontrol & Garbage Collection Protocol"
    assert_contains "$std_detail" "Procedural Steps:"
  }

describe "OKF Slash Command Dispatch"
  it "executes /okf standards via slash command dispatcher" && {
    cmd_out=$(commands_dispatch "/okf standards" "$LODGE_DIR")
    assert_contains "$cmd_out" "Blue Lodge Architectural & Programming Standards"
  }

  it "executes /okf search via slash command dispatcher" && {
    cmd_out=$(commands_dispatch "/okf search vitals" "$LODGE_DIR")
    assert_contains "$cmd_out" "vitals.sh"
  }

describe "Native Tool Bridge Execution"
  it "dispatches okf_search through native_tools_dispatch" && {
    raw_payload='{"query":"phytology"}'
    tool_out=$(native_tools_dispatch "call_1" "okf_search" "$raw_payload" "$LODGE_DIR")
    assert_contains "$tool_out" "phytology.sh"
  }

  it "dispatches okf_query through native_tools_dispatch" && {
    raw_payload='{"target":"lib/core/react.sh"}'
    tool_out=$(native_tools_dispatch "call_2" "okf_query" "$raw_payload" "$LODGE_DIR")
    assert_contains "$tool_out" "react.sh"
    assert_contains "$tool_out" "SoftwareSourceCode"
  }

describe "OKF Tree Rendering"
  it "renders hierarchical knowledge tree for subsystems" && {
    tree_out=$(okf_tree "ipc")
    assert_contains "$tree_out" "Asynchronous FIFO IPC & Flow Control"
    assert_contains "$tree_out" "fifo_ipc.sh"
  }

test_end
