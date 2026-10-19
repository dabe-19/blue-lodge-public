#!/bin/bash
# ── Tests: lib/ui/popup.sh & Research Observability ──────────────
source "$(dirname "$0")/framework.sh"

_test_tmpdir=""

_setup_popup() {
    _test_tmpdir=$(test_tmpdir)
    export LODGE_DIR="$_test_tmpdir"
    mkdir -p "$_test_tmpdir/bin" "$_test_tmpdir/scripts" "$_test_tmpdir/.sandboxes"
    cp "$GEORGE_TEST_REPO/bin/wt_launch_minimized.exe" "$_test_tmpdir/bin/" 2>/dev/null || true
    cp "$GEORGE_TEST_REPO/scripts/monitor/research_live_monitor.sh" "$_test_tmpdir/scripts/" 2>/dev/null || true
    source "$GEORGE_TEST_REPO/lib/ui/popup.sh"
}

_teardown_popup() {
    rm -rf "$_test_tmpdir"
}

test_start "lib/ui/popup.sh & Research Observability"

describe "Popup GUI Detection & Control"

  it "disables popup when TERMINAL_POPUP_ENABLED is set to 0" && {
      _setup_popup
      export TERMINAL_POPUP_ENABLED=0
      if popup_is_gui_available; then
          assert_eq 1 0 "Expected popup_is_gui_available to fail when TERMINAL_POPUP_ENABLED=0"
      else
          assert_eq 0 0
      fi
      export TERMINAL_POPUP_ENABLED=1
      _teardown_popup
  }

  it "returns failure from popup_terminal_launch when GUI is unavailable" && {
      _setup_popup
      export TERMINAL_POPUP_ENABLED=0
      popup_terminal_launch "Test Title" "80,20" echo "test"
      res=$?
      assert_eq "$res" 1
      export TERMINAL_POPUP_ENABLED=1
      _teardown_popup
  }

describe "Native Minimized Launcher Binary"

  it "verifies bin/wt_launch_minimized.exe is compiled and executable" && {
      assert_file_exists "$GEORGE_TEST_REPO/bin/wt_launch_minimized.exe"
      [ -x "$GEORGE_TEST_REPO/bin/wt_launch_minimized.exe" ]
      assert_eq $? 0
  }

describe "Research Live Companion Monitor Script"

  it "verifies scripts/monitor/research_live_monitor.sh exists and is executable" && {
      assert_file_exists "$GEORGE_TEST_REPO/scripts/monitor/research_live_monitor.sh"
      [ -x "$GEORGE_TEST_REPO/scripts/monitor/research_live_monitor.sh" ]
      assert_eq $? 0
  }

  it "tracks phase progression in sandbox via research_set_phase" && {
      _setup_popup
      source "$GEORGE_TEST_REPO/lib/tools/research_graph.sh"
      sb="$_test_tmpdir/.sandboxes/test_sb"
      mkdir -p "$sb"
      research_set_phase "$sb" "Phase 1/5: ReAct Investigation"
      assert_file_exists "$sb/.phase"
      assert_eq "$(cat "$sb/.phase")" "Phase 1/5: ReAct Investigation"

      research_set_phase "$sb" "Phase 3/5: Dossier Synthesis"
      assert_eq "$(cat "$sb/.phase")" "Phase 3/5: Dossier Synthesis"
      _teardown_popup
  }

test_end
