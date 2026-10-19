#!/bin/bash
# ── Tests: remediation harness regressions (rem_1791146144_401) ─────
# 1. Workspace path rebasing must be idempotent when LODGE_DIR is a sandbox.
# 2. The milestone evaluator must see the agent's own conclusions.
source "$(dirname "$0")/framework.sh"

test_start "Remediation Harness Regressions"

describe "_nt_rebase_ws_paths (bash_exec)"

  eval "$(sed -n '/^_nt_rebase_ws_paths()/,/^}/p' "$GEORGE_TEST_REPO/lib/tools/native_tools.sh")"
  T="/home/op/blue-lodge/.sandboxes/remediation_rem_1"

  it "rebases repo paths onto the sandbox" && {
      assert_eq "$(_nt_rebase_ws_paths 'cat /home/op/blue-lodge/lib/a.sh' "$T")" "cat $T/lib/a.sh"
      assert_eq "$(_nt_rebase_ws_paths 'ls ~/blue-lodge/tests' "$T")" "ls $T/tests"
  }

  it "never nests a sandbox path inside itself" && {
      assert_eq "$(_nt_rebase_ws_paths "cd $T && find ." "$T")" "cd $T && find ."
      once=$(_nt_rebase_ws_paths "ls $T/.george" "$T")
      assert_eq "$(_nt_rebase_ws_paths "$once" "$T")" "ls $T/.george"
  }

  it "leaves text without repo paths untouched" && {
      assert_eq "$(_nt_rebase_ws_paths 'echo hi | wc -c' "$T")" "echo hi | wc -c"
  }

describe "python arg repair rebasing"

  it "keeps sandbox paths and rebases repo paths" && {
      py=$(sed -n '/^_ws_re = re.compile/,/^    return m.group(0)/p' "$GEORGE_TEST_REPO/lib/tools/native_tools.sh")
      out=$(TWS="$T" python3 -c "
import re, os
target_ws = os.environ['TWS']
$py
print(_ws_re.sub(_rebase, 'cd $T/x && cat /home/op/blue-lodge/lib/a.sh'))
")
      assert_eq "$out" "cd $T/x && cat $T/lib/a.sh"
  }

describe "react_eval_milestone evidence"

  it "includes recent assistant reasoning as AGENT CONCLUSIONS" && {
      d=$(test_tmpdir)
      jq -n '[{role:"user",content:"go"},
              {role:"assistant",content:"",reasoning_content:"Root cause: TASK_STALL emits no action in sentinel_probe line 246"},
              {role:"tool",content:"ok"}]' > "$d/messages.json"
      source "$GEORGE_TEST_REPO/lib/core/react_evaluator.sh"
      react_llm_json() { printf '%s' "$2" > "$d/user_prompt.txt"; echo '{"verdict":"COMPLETE","reason":"r","next_action":"n"}'; }
      out=$(react_eval_milestone "$d" 1 "Diagnose the failure" "goal" "tool digest")
      assert_contains "$out" "COMPLETE"
      assert_contains "$(cat "$d/user_prompt.txt")" "AGENT CONCLUSIONS"
      assert_contains "$(cat "$d/user_prompt.txt")" "TASK_STALL emits no action"
      unset -f react_llm_json
      rm -rf "$d"
  }

describe "file_edit never pastes edit instructions into the file"

  source "$GEORGE_TEST_REPO/lib/tools/native_tools.sh" >/dev/null 2>&1

  it "rejects a multi-line sed edit and leaves the script unchanged" && {
      d=$(test_tmpdir)
      printf '#!/bin/bash\nf() {\n    local anomalies=()\n    local actions_needed=()\n}\n' > "$d/s.sh"
      before=$(sha256sum < "$d/s.sh")
      args=$(jq -nc --arg p "$d/s.sh" --arg e $'s/    local anomalies=\\(\\)\n    local actions_needed=\\(\\)/    local anomalies=()\n    local advisory=()\n    local actions_needed=()/' '{path:$p, expression:$e}')
      res=$(native_tools_dispatch "call_fe1" "file_edit" "$args" "$d" 2>/dev/null)
      assert_eq "$(sha256sum < "$d/s.sh")" "$before"
      assert_contains "$res" "ERROR"
      bash -n "$d/s.sh"; assert_ok $?
      rm -rf "$d"
  }

  it "still applies a simple single-line sed edit" && {
      d=$(test_tmpdir)
      printf '#!/bin/bash\nX=1\n' > "$d/t.sh"
      args=$(jq -nc --arg p "$d/t.sh" '{path:$p, expression:"s/X=1/X=2/"}')
      native_tools_dispatch "call_fe2" "file_edit" "$args" "$d" >/dev/null 2>&1
      assert_contains "$(cat "$d/t.sh")" "X=2"
      rm -rf "$d"
  }

test_end
