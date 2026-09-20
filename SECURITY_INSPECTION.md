# Security Audit: lib/remote.sh Shell Injection Analysis

Analyzed 1363 lines from `lib/remote.sh`.

### Scanner Findings (85 matches):

| Pattern Name | Line | Code Snippet |
|---|---|---|
| `unquoted_var_in_cmd` | 16 | `LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"` |
| `unquoted_var_in_cmd` | 22 | `REMOTE_SSH_KEY="${REMOTE_SSH_KEY:-$GEORGE_DIR/ssh/id_ed25519}"` |
| `unquoted_var_in_cmd` | 79 | `REMOTE_SSH_KEY="$GEORGE_DIR/ssh/id_ed25519"` |
| `unquoted_var_in_cmd` | 123 | `_pid=$(ps aux 2>/dev/null \| grep "ssh.*-N.*${_target}" \| grep -v grep \| awk '{print $2}' \| tail -1)` |
| `unquoted_var_in_cmd` | 127 | `_pid=$(ps -ef 2>/dev/null \| grep "ssh.*-N.*${_target}" \| grep -v grep \| awk '{print $2}' \| tail -1)` |
| `unquoted_var_in_cmd` | 133 | `_pid=$(ps aux 2>/dev/null \| grep "autossh.*${_target}" \| grep -v grep \| awk '{print $2}' \| tail -1)` |
| `unquoted_var_in_cmd` | 174 | `ssh-add -l 2>/dev/null \| grep -q "$(ssh-keygen -lf "$REMOTE_SSH_KEY" 2>/dev/null \| awk '{print $2}')" 2>/dev/null && return 0` |
| `unquoted_var_in_cmd` | 200 | `echo "Port $_ollama_port in use (local Ollama?). Remapping tunnel to $_new_port." >&2` |
| `unquoted_var_in_cmd` | 218 | `echo "Port $_llama_port in use. Remapping tunnel to $_new_port." >&2` |
| `unquoted_var_in_cmd` | 249 | `curl -so /dev/null --max-time 1 "http://127.0.0.1:$_port/" 2>/dev/null && return 0` |
| `unquoted_var_in_cmd` | 267 | `_pids="$_pids $(ps aux 2>/dev/null \| grep -E '[a]utossh' \| awk '{print $2}')"` |
| `unquoted_var_in_cmd` | 270 | `for _p in $_pids; do` |
| `unquoted_var_in_cmd` | 276 | `_pids="$_pids $(ps aux 2>/dev/null \| grep -E '[s]sh.*-N' \| awk '{print $2}')"` |
| `unquoted_var_in_cmd` | 278 | `for _p in $_pids; do` |
| `unquoted_var_in_cmd` | 288 | `_stragglers="$_stragglers $(ps aux 2>/dev/null \| grep -E '[a]utossh' \| awk '{print $2}')"` |
| `unquoted_var_in_cmd` | 290 | `_stragglers="$_stragglers $(ps aux 2>/dev/null \| grep -E '[s]sh.*-N' \| awk '{print $2}')"` |
| `unquoted_var_in_cmd` | 292 | `for _p in $_stragglers; do` |
| `unquoted_var_in_cmd` | 434 | `_bin=$(_remote_exec 'pid=$(pgrep -o -f "llama-server" 2>/dev/null); [ -n "$pid" ] && readlink -f /proc/$pid/exe 2>/dev/null' 2>/dev/null)` |
| `unquoted_var_in_cmd` | 442 | `_bin=$(_remote_exec 'ps -eo args 2>/dev/null \| awk "/[l]lama-server/{print \$1; exit}"' 2>/dev/null)` |
| `unquoted_var_in_cmd` | 451 | `_bin=$(_remote_exec 'for p in $HOME/llama.cpp-prism/build/bin/llama-server /opt/llama.cpp-prism/build/bin/llama-server $HOME/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server /opt/llama.cpp/build/bin/llama-server /usr/bin/llama-server; do [ -x "$p" ] && echo "$p" && break; done' 2>/dev/null)` |
| `unquoted_var_in_cmd` | 491 | `if [[ \"\$_ref\" == /* ]] && [ -f \"\$_ref\" ]; then` |
| `unquoted_var_in_cmd` | 492 | `echo \"\$_ref\"` |
| `unquoted_var_in_cmd` | 495 | `if [[ \"\$_ref\" == ~/* ]]; then` |
| `unquoted_var_in_cmd` | 496 | `_expanded=\"\$HOME/\${_ref#~/}\"` |
| `unquoted_var_in_cmd` | 497 | `if [ -f \"\$_expanded\" ]; then` |
| `unquoted_var_in_cmd` | 498 | `echo \"\$_expanded\"` |
| `unquoted_var_in_cmd` | 503 | `for _dir in \$HOME/models /opt/models /workspace/.george/models; do` |
| `unquoted_var_in_cmd` | 504 | `[ -d \"\$_dir\" ] \|\| continue` |
| `unquoted_var_in_cmd` | 506 | `if [ -f \"\$_dir/\$_ref\" ]; then` |
| `unquoted_var_in_cmd` | 507 | `echo \"\$_dir/\$_ref\"` |
| `unquoted_var_in_cmd` | 511 | `if [ -f \"\$_dir/\${_ref}.gguf\" ]; then` |
| `unquoted_var_in_cmd` | 512 | `echo \"\$_dir/\${_ref}.gguf\"` |
| `unquoted_var_in_cmd` | 516 | `_f=\$(find \"\$_dir\" -maxdepth 3 -type f -iname \"*\${_ref}*.gguf\" 2>/dev/null \| head -1)` |
| `unquoted_var_in_cmd` | 517 | `if [ -n \"\$_f\" ]; then` |
| `unquoted_var_in_cmd` | 518 | `echo \"\$_f\"` |
| `unquoted_var_in_cmd` | 531 | `_show_resp=$(curl -sf --max-time 10 "$OLLAMA_URL/api/show" \` |
| `unquoted_var_in_cmd` | 532 | `-d "{\"name\":\"$_model_ref\"}" 2>/dev/null)` |
| `unquoted_var_in_cmd` | 555 | `for _manifest in \$(find \"\$_data/models/manifests\" -name '*' -type f 2>/dev/null \| head -20); do` |
| `unquoted_var_in_cmd` | 556 | `_layer=\$(jq -r '.layers[] \| select(.mediaType \| test(\"model\")) \| .digest' \"\$_manifest\" 2>/dev/null \| head -1)` |
| `unquoted_var_in_cmd` | 557 | `if [ -n \"\$_layer\" ]; then` |
| `unquoted_var_in_cmd` | 558 | `_blob=\"\$_data/models/blobs/\$(echo \"\$_layer\" \| tr ':' '-')\"` |
| `unquoted_var_in_cmd` | 559 | `if [ -f \"\$_blob\" ]; then` |
| `unquoted_var_in_cmd` | 560 | `echo \"\$_blob\"` |
| `unquoted_var_in_cmd` | 566 | `_match=\$(find \"\$_data/models/blobs\" -type f -name 'sha256-*' -size +500M 2>/dev/null \| head -1)` |
| `unquoted_var_in_cmd` | 567 | `[ -n \"\$_match\" ] && echo \"\$_match\"` |
| `unquoted_var_in_cmd` | 706 | `if [ -n \"\$_pid\" ]; then` |
| `unquoted_var_in_cmd` | 707 | `kill \"\$_pid\" 2>/dev/null` |
| `unquoted_var_in_cmd` | 709 | `kill -9 \"\$_pid\" 2>/dev/null` |
| `unquoted_var_in_cmd` | 710 | `wait \"\$_pid\" 2>/dev/null` |
| `unquoted_var_in_cmd` | 737 | `_health=$(curl -sf --max-time 3 "$LLAMA_CPP_URL/health" 2>/dev/null)` |
| `unquoted_var_in_cmd` | 741 | `_model_check=$(curl -sf --max-time 3 "$LLAMA_CPP_URL/v1/models" 2>/dev/null)` |
| `unquoted_var_in_cmd` | 758 | `echo "WARNING: Remote llama-server started (PID $_restart_result) but not healthy after ${_max_wait}s" >&2` |
| `unquoted_var_in_cmd` | 766 | `local target="${1:-$REMOTE_SSH_TARGET}"` |
| `unquoted_var_in_cmd` | 824 | `echo "ERROR: SSH tunnel failed (exit $rc). Check:" >&2` |
| `unquoted_var_in_cmd` | 826 | `echo "  - Tunnel target: $_tunnel_target:$REMOTE_SSH_PORT" >&2` |
| `unquoted_var_in_cmd` | 864 | `echo "Connected via $_tunnel_target (via $_method)"` |
| `unquoted_var_in_cmd` | 872 | `if curl -sf --max-time 3 "$OLLAMA_URL/api/tags" &>/dev/null; then` |
| `unquoted_var_in_cmd` | 874 | `elif curl -sf --max-time 3 "$LLAMA_CPP_URL/health" &>/dev/null; then` |
| `unquoted_var_in_cmd` | 900 | `echo "NOTE: Cloud provider active (GEORGE_PROVIDER=$GEORGE_PROVIDER)." >&2` |
| `unquoted_var_in_cmd` | 1006 | `local target="${1:-$REMOTE_SSH_TARGET}"` |
| `unquoted_var_in_cmd` | 1046 | `echo "SSH key already authorized on $target."` |
| `unquoted_var_in_cmd` | 1057 | `echo "Copying key to $target..."` |
| `unquoted_var_in_cmd` | 1126 | `echo "Started ssh-agent (PID: $SSH_AGENT_PID)"` |
| `unquoted_var_in_cmd` | 1288 | `printf "  Port %-6s %s\n" "$_p:" "$_listening"` |
| `unquoted_var_in_cmd` | 1334 | `echo "  Check that the forward host ($_fwd) is correct and services are running on the remote."` |
| `subshell_of_remote_output` | 345 | `_tunnel_target=$(_remote_tunnel_target)` |
| `subshell_of_remote_output` | 353 | `_pid=$(_remote_find_tunnel_pid "$_tunnel_target")` |
| `subshell_of_remote_output` | 434 | `_bin=$(_remote_exec 'pid=$(pgrep -o -f "llama-server" 2>/dev/null); [ -n "$pid" ] && readlink -f /proc/$pid/exe 2>/dev/null' 2>/dev/null)` |
| `subshell_of_remote_output` | 442 | `_bin=$(_remote_exec 'ps -eo args 2>/dev/null \| awk "/[l]lama-server/{print \$1; exit}"' 2>/dev/null)` |
| `subshell_of_remote_output` | 451 | `_bin=$(_remote_exec 'for p in $HOME/llama.cpp-prism/build/bin/llama-server /opt/llama.cpp-prism/build/bin/llama-server $HOME/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server /opt/llama.cpp/build/bin/llama-server /usr/bin/llama-server; do [ -x "$p" ] && echo "$p" && break; done' 2>/dev/null)` |
| `subshell_of_remote_output` | 459 | `_bin=$(_remote_exec 'command -v llama-server 2>/dev/null' 2>/dev/null)` |
| `subshell_of_remote_output` | 467 | `_bin=$(_remote_exec 'find /home /usr/local /opt -name llama-server -executable -type f 2>/dev/null \| head -1' 2>/dev/null)` |
| `subshell_of_remote_output` | 602 | `_remote_gguf=$(_remote_resolve_gguf "$_model_base")` |
| `subshell_of_remote_output` | 609 | `_remote_gguf=$(_remote_exec "ollama show --modelfile '$_model_base' 2>/dev/null \| grep -oP '(?<=FROM\s)/\S+' \| head -1" 2>/dev/null)` |
| `subshell_of_remote_output` | 616 | `_remote_gguf=$(_remote_resolve_gguf "$_model_name")` |
| `subshell_of_remote_output` | 661 | `_has_systemd=$(_remote_exec "systemctl cat llama-server &>/dev/null && echo yes \|\| echo no" 2>/dev/null)` |
| `subshell_of_remote_output` | 669 | `_sudo_raw=$(_remote_exec "sudo -n /bin/systemctl daemon-reload 2>/dev/null && echo SUDO_OK \|\| echo SUDO_FAIL")` |
| `subshell_of_remote_output` | 682 | `_threads=$(_remote_exec "nproc 2>/dev/null \|\| echo 4" 2>/dev/null)` |
| `subshell_of_remote_output` | 804 | `_tunnel_target=$(_remote_tunnel_target)` |
| `subshell_of_remote_output` | 838 | `_pid=$(_remote_find_tunnel_pid "$_tunnel_target")` |
| `subshell_of_remote_output` | 1176 | `_tunnel_target=$(_remote_tunnel_target)` |
| `echo_of_remote_output` | 373 | `[ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] _remote_exec: ssh ${_ssh_args[*]} $REMOTE_SSH_TARGET '${_cmd:0:80}...'" >&2` |
| `echo_of_remote_output` | 603 | `[ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] remote: GGUF='${_remote_gguf:-<empty>}'" >&2` |
| `echo_of_remote_output` | 610 | `[ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] remote: CLI GGUF='${_remote_gguf:-<empty>}'" >&2` |
| `echo_of_remote_output` | 617 | `[ "${LODGE_DEBUG:-0}" -eq 1 ] && echo "  [debug] remote: model_name GGUF='${_remote_gguf:-<empty>}'" >&2` |
