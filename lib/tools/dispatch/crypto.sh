#!/bin/bash
# ── George: Modular Crypto, Wallet, DEX & Sovereign Fund Tool Dispatcher ──
# Extracted from lib/tools/native_tools.sh to modularize native_tools_dispatch.
# Expects caller (native_tools_dispatch) to provide _arg, _call_sim, LODGE_DIR,
# args_json, and populates `output` and `exit_code` in caller scope.

[ -n "${_LIB_DISPATCH_CRYPTO_LOADED:-}" ] && return 0
_LIB_DISPATCH_CRYPTO_LOADED=1

_native_dispatch_crypto() {
    local name="$1"
    local args_json="$2"
    local workdir="${3:-$PWD}"
    local arguments="$args_json"

    case "$name" in
        wallet_status|wallet_balances)
            local json_out
            json_out=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/wallet_status.py" 2>&1)
            exit_code=$?
            output=$(printf "=== Cryptocurrency Wallets ===\n%s" "$json_out")
            ;;
        wallet_receive)
            local _py="$LODGE_DIR/.venv/bin/python"
            [ ! -x "$_py" ] && _py="python3"
            local _chain _amt _tok _memo _wid _chk
            _chain=$(_arg .chain "cardano")
            _amt=$(_arg .amount "")
            _tok=$(_arg .token "")
            _memo=$(_arg .memo "")
            _wid=$(_arg .wallet_id "")
            _chk=$(_arg .check_incoming "false")
            local -a _rcmd=("$_py" "$LODGE_DIR/lib/tools/wallet/keystore.py" "receive" "--chain" "$_chain")
            [ -n "$_wid" ] && _rcmd+=("--id" "$_wid")
            [ -n "$_amt" ] && _rcmd+=("--amount" "$_amt")
            [ -n "$_tok" ] && _rcmd+=("--token" "$_tok")
            [ -n "$_memo" ] && _rcmd+=("--memo" "$_memo")
            [ "$_chk" = "true" ] && _rcmd+=("--check-incoming")
            output=$(PYTHONPATH="$LODGE_DIR" "${_rcmd[@]}" 2>&1 | jq 'del(.qr_svg)' 2>/dev/null)
            exit_code=$?
            ;;
        wallet_send_preview)
            local _py="$LODGE_DIR/.venv/bin/python"
            [ ! -x "$_py" ] && _py="python3"
            local _to _amt _tok _chain _msg
            _to=$(_arg .to "$(_arg .to_address)")
            _amt=$(_arg .amount "")
            _tok=$(_arg .token "ADA")
            _chain=$(_arg .chain "cardano")
            _msg=$(_arg .message "$(_arg .memo)")
            if [ -z "$_to" ] || [ -z "$_amt" ]; then
                output='{"status":"error","message":"wallet_send_preview requires to and amount"}'
                exit_code=1
            else
                local _intent_json
                _intent_json=$(jq -nc --arg to "$_to" --argjson amt "$_amt" --arg tok "$_tok" --arg chain "$_chain" --arg msg "$_msg" \
                    '{kind:"wallet_send", to:$to, amount:$amt, token:$tok, chain:$chain, message:(if $msg == "" then null else $msg end)}')
                output=$(cd "$LODGE_DIR" && "$_py" "$LODGE_DIR/lib/tools/trading/agent_tools.py" --origin=george plan "--intent=$_intent_json" 2>&1)
                exit_code=$?
            fi
            ;;
        cardano_dex_swap)
            local _amt="$(_arg .amount)" _tok="$(_arg .token)" _exec="$(_arg .execute false)"
            local _dir="$(_arg .direction)" _from="$(_arg .from_token)" _to="$(_arg .to_token)"
            local _flg="--dry-run"
            [ "$_exec" = "true" ] && _flg="--execute"
            local _extra=""
            [ -n "$_dir" ] && _extra="$_extra --direction $_dir"
            [ -n "$_from" ] && _extra="$_extra --from-token $_from"
            [ -n "$_to" ] && _extra="$_extra --to-token $_to"
            output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/cardano_dex_swapper.py" --amount "$_amt" --token "$_tok" "$_flg" $_extra 2>&1)
            exit_code=$?
            ;;
        cardano_p2p_underwrite)
            local _extra="$(_arg .simulate_flags)"
            if [ -n "$_extra" ]; then
                output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/sovereign_lending.py" --simulate $_extra 2>&1)
            else
                output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/sovereign_lending.py" --scan 2>&1)
            fi
            exit_code=$?
            ;;
        cardano_flash_sniper)
            output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/cardano_flash_sniper.py" --scan 2>&1)
            exit_code=$?
            ;;
        polygon_swap_usdc)
            local _amt="$(_arg .amount "15.0")" _slip="$(_arg .max_slippage_bps "100")" _exec="$(_arg .execute false)"
            local _flg="--dry-run"
            [ "$_exec" = "true" ] && _flg="--execute"
            output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/polygon_swapper.py" --amount "$_amt" --max-slippage-bps "$_slip" "$_flg" 2>&1)
            exit_code=$?
            ;;
        polygon_approve_polymarket)
            local _exec="$(_arg .execute false)"
            local _flg="--dry-run"
            [ "$_exec" = "true" ] && _flg="--execute"
            output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/polygon_approver.py" "$_flg" 2>&1)
            exit_code=$?
            ;;
        cardano_stop_manage)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools"
            [ ! -x "$_py" ] && _py="python3"
            local _act _asset _trigger _cap _inv _ttype _tp _sl _tid _exec _force _bad=""
            _act=$(_arg .action "calc")
            _asset=$(_arg .asset | tr '[:lower:]' '[:upper:]')
            _trigger=$(_arg .trigger_price "$(_arg .trigger)")
            _cap=$(_arg .capital_ada "$(_arg .amount)")
            _inv=$(_arg .invalidation_price "$(_arg .invalidation)")
            _ttype=$(_arg .trigger_type "STOP_BUY" | tr '[:lower:]' '[:upper:]')
            _tp=$(_arg .tp_pct); _sl=$(_arg .sl_pct)
            _tid=$(_arg .trigger_id)
            _exec=$(_arg .execute false)
            _force=$(_arg .force_overallocate "$(_arg .force)")

            local _num='^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            [[ -n "$_asset" && ! "$_asset" =~ ^[A-Z0-9]{2,12}$ ]] && _bad="asset"
            [[ -n "$_trigger" && ! "$_trigger" =~ $_num ]] && _bad="trigger_price"
            [[ -n "$_cap" && ! "$_cap" =~ $_num ]] && _bad="capital_ada"
            [[ -n "$_inv" && ! "$_inv" =~ $_num ]] && _bad="invalidation_price"
            [[ -n "$_tp" && ! "$_tp" =~ $_num ]] && _bad="tp_pct"
            [[ -n "$_sl" && ! "$_sl" =~ $_num ]] && _bad="sl_pct"

            local -a _cmd=("$_py" "$_t/cardano_stop_engine.py")
            case "$_act" in
                calc)
                    [ -z "$_asset" ] && _bad="asset"
                    _cmd+=("calc" "$_asset" "--json")
                    ;;
                arm)
                    [ -z "$_asset" ] && _bad="asset"
                    [ -z "$_trigger" ] && _bad="trigger_price"
                    [ -z "$_cap" ] && _bad="capital_ada"
                    _cmd+=("arm" "$_asset" "--trigger=$_trigger" "--amount=$_cap" "--json")
                    [ -n "$_inv" ] && _cmd+=("--invalidation=$_inv")
                    [ -n "$_ttype" ] && _cmd+=("--type=$_ttype")
                    [ -n "$_tp" ] && _cmd+=("--tp-pct=$_tp")
                    [ -n "$_sl" ] && _cmd+=("--sl-pct=$_sl")
                    [ "$_exec" = "true" ] && _cmd+=("--execute")
                    [ "$_force" = "true" ] && _cmd+=("--force-overallocate")
                    ;;
                list)
                    _cmd+=("list" "--json")
                    [ -n "$_asset" ] && _cmd+=("--asset=$_asset")
                    ;;
                cancel)
                    [ -z "$_tid" ] && _bad="trigger_id"
                    _cmd+=("cancel" "$_tid" "--json")
                    ;;
                prune)
                    _cmd+=("prune" "--all" "--json")
                    ;;
                journal)
                    _cmd+=("journal" "--json")
                    ;;
                *)
                    _bad="action (valid: calc, arm, list, cancel, prune, journal)"
                    ;;
            esac

            if [ -n "$_bad" ]; then
                output="ERROR: missing or invalid $_bad argument"; exit_code=1
            else
                output=$("${_cmd[@]}" 2>/dev/null)
                exit_code=$?
                if [ $exit_code -ne 0 ] || [ -z "$output" ]; then
                    output=$("${_cmd[@]}" 2>&1)
                fi
                [ -z "$output" ] && output="ERROR: cardano_stop_manage produced no output (exit $exit_code)"
            fi
            ;;
        cardano_desk_summary|crypto_desk_summary)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools"
            [ ! -x "$_py" ] && _py="python3"
            local _asset _json_fmt
            _asset=$(_arg .asset "SNEK" | tr '[:lower:]' '[:upper:]')
            _json_fmt=$(_arg .json_format false)
            [[ -n "$_asset" && ! "$_asset" =~ ^[A-Z0-9]{2,12}$ ]] && _asset="SNEK"

            local -a _cmd=("$_py" "$_t/cardano_desk_summary.py" "$_asset")
            [ "$_json_fmt" = "true" ] && _cmd+=("--json")

            output=$("${_cmd[@]}" 2>&1)
            exit_code=$?
            ;;
        cardano_order_tool|crypto_order)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools"
            [ ! -x "$_py" ] && _py="python3"
            local _subcmd _asset _cap _rungs _prof _exec _json_fmt _ref_id _tp _sl _trig _inv _ladder_id _rung_id
            _subcmd=$(_arg .subcommand "status")
            _asset=$(_arg .asset "" | tr '[:lower:]' '[:upper:]')
            _cap=$(_arg .capital 160.0)
            _rungs=$(_arg .rungs 2)
            _prof=$(_arg .profile "geometric")
            _exec=$(_arg .execute false)
            _json_fmt=$(_arg .json_format true)
            _ref_id=$(_arg .ref_id "")
            _tp=$(_arg .tp 4.0)
            _sl=$(_arg .sl 2.5)
            _trig=$(_arg .trigger_price "")
            _inv=$(_arg .invalidation_price "")
            _ladder_id=$(_arg .ladder_id "")
            _rung_id=$(_arg .filled_rung_id "")

            local -a _cmd=("$_py" "$_t/cardano_order_tool.py" "$_subcmd")
            case "$_subcmd" in
                ladder)
                    [ -n "$_asset" ] && _cmd+=("$_asset")
                    _cmd+=("--capital=$_cap" "--rungs=$_rungs" "--profile=$_prof")
                    [ "$_exec" = "true" ] && _cmd+=("--execute")
                    ;;
                stop)
                    [ -n "$_asset" ] && _cmd+=("$_asset")
                    [ -n "$_trig" ] && _cmd+=("--trigger-price=$_trig")
                    [ -n "$_inv" ] && _cmd+=("--invalidation-price=$_inv")
                    _cmd+=("--capital=$_cap" "--tp=$_tp" "--sl=$_sl")
                    [ "$_exec" = "true" ] && _cmd+=("--execute")
                    ;;
                cancel)
                    [ -n "$_ref_id" ] && _cmd+=("$_ref_id")
                    ;;
                prune)
                    [ -n "$_ladder_id" ] && _cmd+=("--ladder-id=$_ladder_id")
                    [ -n "$_rung_id" ] && _cmd+=("--filled-rung-id=$_rung_id")
                    ;;
                status|*)
                    [ -n "$_asset" ] && _cmd+=("--asset=$_asset")
                    ;;
            esac
            [ "$_json_fmt" = "true" ] && _cmd+=("--json")

            output=$("${_cmd[@]}" 2>&1)
            exit_code=$?
            ;;
        cardano_triangle_deploy|crypto_triangle_deploy)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools"
            [ ! -x "$_py" ] && _py="python3"
            local _asset _cap _tp _sl _exec _json_fmt
            _asset=$(_arg .asset "SNEK" | tr '[:lower:]' '[:upper:]')
            _cap=$(_arg .total_capital_ada 120.0)
            _tp=$(_arg .tp_pct 4.0)
            _sl=$(_arg .sl_pct 2.5)
            _exec=$(_arg .execute false)
            _json_fmt=$(_arg .json_format false)
            [[ -n "$_asset" && ! "$_asset" =~ ^[A-Z0-9]{2,12}$ ]] && _asset="SNEK"

            local -a _cmd=("$_py" "$_t/cardano_order_tool.py" "triangle" "$_asset" "--capital=$_cap" "--tp=$_tp" "--sl=$_sl")
            [ "$_exec" = "true" ] && _cmd+=("--execute")
            [ "$_json_fmt" = "true" ] && _cmd+=("--json")

            output=$("${_cmd[@]}" 2>&1)
            exit_code=$?
            ;;
        crypto_review|crypto_scan|crypto_plan|crypto_execute|crypto_standing_order|crypto_journal|crypto_backtest)
            local _py="$LODGE_DIR/.venv/bin/python" _at="$LODGE_DIR/lib/tools/trading/agent_tools.py" _bad=""
            local _origin="george"
            [ "${GEORGE_HEADLESS_ESCALATION:-0}" = "1" ] && _origin="headless"
            local -a _cmd=("$_py" "$_at" "--origin=$_origin")
            case "$name" in
                crypto_review) _cmd+=(review) ;;
                crypto_scan)
                    local _assets; _assets=$(_arg .assets)
                    [[ -n "$_assets" && ! "$_assets" =~ ^[A-Za-z0-9,\ ]{1,120}$ ]] && _bad="assets"
                    _cmd+=(scan "--assets=${_assets// /}") ;;
                crypto_plan)
                    local _intent; _intent=$(jq -r 'if (.intent|type) == "object" then (.intent|tojson) else (.intent // "review") end' <<<"$args_json" 2>/dev/null)
                    [ "${#_intent}" -gt 2000 ] && _bad="intent (too long)"
                    _cmd+=(plan "--intent=$_intent") ;;
                crypto_execute)
                    local _pid _tok; _pid=$(_arg .plan_id); _tok=$(_arg .confirm_token)
                    [[ "$_pid" =~ ^P-[0-9A-F]{6}$ ]] || _bad="plan_id (expected P-XXXXXX from crypto_plan)"
                    [[ -n "$_tok" && ! "$_tok" =~ ^[A-Za-z0-9_-]{20,64}$ ]] && _bad="confirm_token"
                    _cmd+=(execute "--plan-id=$_pid")
                    [ -n "$_tok" ] && _cmd+=("--confirm-token=$_tok") ;;
                crypto_standing_order)
                    local _soa; _soa=$(_arg .action list)
                    case "$_soa" in
                        list) _cmd+=(standing-order list) ;;
                        revoke)
                            local _soid; _soid=$(_arg .id)
                            [[ "$_soid" =~ ^SO-[0-9A-F]{6}$ ]] || _bad="id"
                            _cmd+=(standing-order revoke "--id=$_soid") ;;
                        create)
                            local _spec
                            _spec=$(jq -c '{strategy: (.strategy // "manual"), asset: ((.asset // "") | ascii_upcase),
                                            max_ada: (.max_ada | tonumber? // null), price_min: ((.price_min // .price_low) | tonumber? // null),
                                            price_max: ((.price_max // .price_high) | tonumber? // null), expires_hours: (.expires_hours | tonumber? // 72),
                                            no_fill_hours: (.no_fill_hours | tonumber? // 6),
                                            reason: (.reason // ""),
                                            supersede_so_id: (.supersede_so_id // null),
                                            replace: (.replace // false)} | with_entries(select(.value != null))' <<<"$args_json" 2>/dev/null)
                            if ! jq -e '(.strategy | test("^[A-Za-z0-9_]{2,40}$")) and (.asset | test("^[A-Z0-9]{2,12}$")) and (.max_ada != null)' <<<"$_spec" >/dev/null 2>&1; then
                                _bad="standing order spec (strategy, asset, max_ada required)"
                            fi
                            _cmd+=(standing-order create "--spec=$_spec") ;;
                        *) _bad="action" ;;
                    esac ;;
                crypto_journal)
                    local _wd _st; _wd=$(_arg .window_days 30); _st=$(_arg .strategy)
                    [[ "$_wd" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _bad="window_days"
                    [[ -n "$_st" && ! "$_st" =~ ^[A-Za-z0-9_]{2,40}$ ]] && _bad="strategy"
                    _cmd+=(journal "--window-days=$_wd")
                    [ -n "$_st" ] && _cmd+=("--strategy=$_st") ;;
                crypto_backtest)
                    local _bts _bta _btd _btov
                    _bts=$(_arg .strategy S2); _bta=$(_arg .assets); _btd=$(_arg .days 30)
                    [[ "$_bts" =~ ^[A-Za-z0-9_]{2,40}$ ]] || _bad="strategy"
                    [[ -n "$_bta" && ! "$_bta" =~ ^[A-Za-z0-9,\ ]{1,120}$ ]] && _bad="assets"
                    [[ "$_btd" =~ ^[0-9]{1,3}$ ]] || _bad="days"
                    _btov=$(jq -c '{
                        entry_mode: (.entry_mode // null),
                        exit_mode: (.exit_mode // null),
                        entry_offset_sigma: (.entry_offset_sigma | tonumber? // null),
                        exit_start_markup: (.exit_start_markup | tonumber? // null),
                        exit_floor_markup: (.exit_floor_markup | tonumber? // null),
                        min_net_profit_ada: (.min_net_profit_ada | tonumber? // null),
                        hold_hours: (.hold_hours | tonumber? // null),
                        stop_sigma_1h: (.stop_sigma_1h | tonumber? // null),
                        stop_pct: (.stop_pct | tonumber? // null),
                        k_sigma: (.k_sigma | tonumber? // null),
                        size_ada: (.size_ada | tonumber? // null)
                    } | with_entries(select(.value != null))' <<<"$args_json" 2>/dev/null || echo "{}")
                    _cmd+=(backtest "--strategy=$_bts" "--assets=${_bta// /}" "--days=$_btd" "--overrides=$_btov") ;;
            esac
            if [ -n "$_bad" ]; then
                output="ERROR: invalid $_bad argument"; exit_code=1
            else
                output=$(cd "$LODGE_DIR" && "${_cmd[@]}" 2>/dev/null)
                exit_code=$?
                [ -z "$output" ] && output="ERROR: $name produced no output (exit $exit_code)"
            fi
            ;;
        operator_notify|operator_ask)
            local _py="$LODGE_DIR/.venv/bin/python" _esc="$LODGE_DIR/lib/comms/escalation.py" _bad=""
            local _txt _sev _pid _eid
            _txt=$(_arg .text); _sev=$(_arg .severity normal); _pid=$(_arg .plan_id); _eid=$(_arg .escalation_id)
            [ -z "$_txt" ] && _bad="text"
            [ "${#_txt}" -gt 1800 ] && _bad="text (over 1800 characters)"
            [[ "$_sev" =~ ^(info|normal|urgent)$ ]] || _bad="severity"
            [[ -n "$_pid" && ! "$_pid" =~ ^P-[0-9A-F]{6}$ ]] && _bad="plan_id"
            [[ -n "$_eid" && ! "$_eid" =~ ^E-[0-9A-F]{6}$ ]] && _bad="escalation_id"
            local -a _cmd=("$_py" "$_esc")
            if [ "$name" = "operator_notify" ]; then
                _cmd+=(notify "--text=$_txt" "--severity=$_sev")
            else
                _cmd+=(ask "--text=$_txt")
                [ -n "$_pid" ] && _cmd+=("--plan-id=$_pid")
            fi
            [ -n "$_eid" ] && _cmd+=("--escalation-id=$_eid")
            if [ -n "$_bad" ]; then
                output="ERROR: invalid $_bad argument"; exit_code=1
            else
                output=$(cd "$LODGE_DIR" && "${_cmd[@]}" 2>/dev/null)
                exit_code=$?
                [ -z "$output" ] && output="ERROR: $name produced no output (exit $exit_code)"
            fi
            ;;
        crypto_analyze|crypto_forecast|crypto_chart|crypto_orders|crypto_place_limit|crypto_reclaim_order)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools"
            local _asset _price _amount _dir _utxo _dl _exec _tf _act _bad=""
            _asset=$(_arg .asset | tr '[:lower:]' '[:upper:]')
            _price=$(_arg .price "$(_arg .target_price)"); _amount=$(_arg .amount)
            _dir=$(_arg .direction); _utxo=$(_arg .utxo); _dl=$(_arg .deadline_hours)
            _exec=$(_arg .execute false); _tf=$(_arg .timeframe 1h); _act=$(_arg .action discover)
            local _num='^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$'
            [[ -n "$_asset" && ! "$_asset" =~ ^[A-Z0-9]{2,12}$ ]] && _bad="asset"
            [[ -n "$_price" && ! "$_price" =~ $_num ]] && _bad="price"
            [[ -n "$_amount" && ! "$_amount" =~ $_num ]] && _bad="amount"
            [[ -n "$_dl" && ! "$_dl" =~ $_num ]] && _bad="deadline_hours"
            [[ -n "$_dir" && ! "$_dir" =~ ^(buy|sell)$ ]] && _bad="direction"
            [[ -n "$_utxo" && ! "$_utxo" =~ ^[0-9a-f]{64}#[0-9]{1,4}$ ]] && _bad="utxo"
            if [ -n "$_bad" ]; then
                output="ERROR: invalid $_bad argument"; exit_code=1
            else
                local -a _cmd=()
                case "$name" in
                    crypto_analyze)
                        [ -z "$_asset" ] && _bad="asset"
                        _cmd=("$_py" "$_t/cardano_volatility_engine.py" "--asset=$_asset" --json) ;;
                    crypto_forecast)
                        [ -z "$_asset" ] && _bad="asset"
                        _cmd=("$_py" "$_t/limit_order_forecaster.py" "--asset=$_asset" --json --no-dossier)
                        [ -n "$_price" ] && _cmd+=("--target-price=$_price")
                        [ -n "$_amount" ] && _cmd+=("--amount=$_amount")
                        [ -n "$_dir" ] && _cmd+=("--direction=$_dir")
                        [ -n "$_dl" ] && _cmd+=("--deadline=$_dl")
                        [ -n "$_utxo" ] && _cmd+=("--utxo=$_utxo")
                        [ "$(_arg .hypothetical false)" = "true" ] && [ -n "$_price" ] && _cmd+=(--hypothetical) ;;
                    crypto_chart)
                        [ -z "$_asset" ] && _bad="asset"
                        local _tfa="hour" _agg="1"
                        case "$_tf" in 15m) _tfa=minute; _agg=15 ;; 1h) ;; 4h) _agg=4 ;; 1d) _tfa=day ;; *) _bad="timeframe" ;; esac
                        _cmd=("$_py" "$_t/chart_data.py" "--asset=$_asset" "--timeframe=$_tfa" "--aggregate=$_agg" --json) ;;
                    crypto_orders)
                        case "$_act" in
                            discover)
                                local _ord_status _ord_compact
                                _ord_status=$(printf '%s' "$arguments" | jq -r '.status // "open"' 2>/dev/null)
                                _ord_compact=$(printf '%s' "$arguments" | jq -r 'if .compact == false then "false" else "true" end' 2>/dev/null)
                                _cmd=("$_py" "$_t/cardano_orders.py" discover "--status=$_ord_status")
                                [ "$_ord_compact" != "true" ] && _cmd+=(--full)
                                ;;
                            inspect) [ -z "$_utxo" ] && _bad="utxo"; _cmd=("$_py" "$_t/cardano_orders.py" inspect "$_utxo") ;;
                            *) _bad="action" ;;
                        esac ;;
                    crypto_place_limit)
                        [ -z "$_asset" ] && _bad="asset"; [ -z "$_dir" ] && _bad="direction"
                        [ -z "$_amount" ] && _bad="amount"; [ -z "$_price" ] && _bad="price"
                        _cmd=("$_py" "$_t/minswap_v2.py" "--asset=$_asset" "--direction=$_dir" "--amount=$_amount" "--price=$_price" --actor=george)
                        [ "$_exec" = "true" ] && _cmd+=(--execute) ;;
                    crypto_reclaim_order)
                        [ -z "$_utxo" ] && _bad="utxo"
                        _cmd=("$_py" "$_t/cardano_orders.py" reclaim "$_utxo" --actor=george)
                        [ "$_exec" = "true" ] && _cmd+=(--execute) ;;
                esac
                if [ -n "$_bad" ]; then
                    output="ERROR: missing or invalid $_bad argument"; exit_code=1
                else
                    output=$("${_cmd[@]}" 2>/dev/null)
                    exit_code=$?
                    if [ "$name" = "crypto_chart" ] && [ $exit_code -eq 0 ]; then
                        output=$(printf '%s' "$output" | jq -c '{status, asset, timeframe, spot, quote, pool, lines, cone, diagnostics, coverage, provenance, explorer, orders, candles: (.candles|length), markers: [.markers[]? | {time, text, url}][-15:]}' 2>/dev/null || printf '%s' "$output" | head -c 6000)
                    fi
                    [ -z "$output" ] && output="ERROR: $name produced no output (exit $exit_code)"
                fi
            fi
            ;;
        fund_treasury|fund_opportunities|fund_state|fund_ledger_add|lending_underwrite|lending_request|lending_service|lending_book|crypto_price_ladder|pool_health|polymarket_scan)
            local _py="$LODGE_DIR/.venv/bin/python" _t="$LODGE_DIR/lib/tools" _bad=""
            local _num='^[0-9]+(\.[0-9]+)?$'
            local _asset _amt _type _note _coll _units _prin _pa _term _apr _borr _lid _exec _dir _span _rungs
            _asset=$(_arg .asset | tr '[:lower:]' '[:upper:]'); _amt=$(_arg .amount); _type=$(_arg .type)
            _note=$(_arg .note | tr -d '\000-\037' | head -c 300)
            _coll=$(_arg .collateral | tr '[:lower:]' '[:upper:]'); _units=$(_arg .units); _prin=$(_arg .principal)
            _pa=$(_arg .principal_asset ADA | tr '[:lower:]' '[:upper:]'); _term=$(_arg .term_days 14); _apr=$(_arg .apr)
            _borr=$(_arg .borrower); _lid=$(_arg .loan_id); _exec=$(_arg .execute false)
            _dir=$(_arg .direction sell); _span=$(_arg .span_pct 4); _rungs=$(_arg .rungs 9)
            [[ -n "$_asset" && ! "$_asset" =~ ^[A-Z0-9]{2,12}$ ]] && _bad="asset"
            [[ -n "$_coll" && ! "$_coll" =~ ^[A-Z0-9]{2,12}$ ]] && _bad="collateral"
            for _v in "$_amt" "$_units" "$_prin" "$_apr" "$_span"; do [[ -n "$_v" && ! "$_v" =~ $_num ]] && _bad="number"; done
            [[ ! "$_term" =~ ^[0-9]{1,3}$ ]] && _bad="term_days"
            [[ ! "$_rungs" =~ ^[0-9]{1,2}$ ]] && _bad="rungs"
            [[ ! "$_pa" =~ ^(ADA|USDC)$ ]] && _bad="principal_asset"
            [[ ! "$_dir" =~ ^(buy|sell)$ ]] && _bad="direction"
            [[ -n "$_borr" && ! "$_borr" =~ ^addr1[0-9a-z]{50,110}$ ]] && _bad="borrower"
            [[ -n "$_lid" && ! "$_lid" =~ ^LN-[0-9A-F]{8}$ ]] && _bad="loan_id"
            [[ "$_note" == -* ]] && _bad="note"
            local -a _cmd=()
            if [ -z "$_bad" ]; then
                case "$name" in
                    fund_treasury) _cmd=("$_py" "$_t/sovereign_fund.py" treasury --json) ;;
                    fund_opportunities) _cmd=("$_py" "$_t/sovereign_fund.py" opportunities --json) ;;
                    fund_state) _cmd=("$_py" "$_t/sovereign_fund.py" state --json) ;;
                    fund_ledger_add)
                        [[ ! "$_type" =~ ^(profit_sweep|expense)$ ]] && _bad="type (george may record profit_sweep or expense only)"
                        [[ ! "$_asset" =~ ^(ADA|USDC|POL|ETH|BTC)$ ]] && _bad="asset"
                        [ -z "$_amt" ] && _bad="amount"
                        _cmd=("$_py" "$_t/sovereign_fund.py" ledger-add "--type=$_type" "--asset=$_asset" "--amount=$_amt" "--note=$_note" --actor=george --json) ;;
                    lending_underwrite|lending_request)
                        [ -z "$_coll" ] && _bad="collateral"; [ -z "$_units" ] && _bad="units"
                        [ -z "$_prin" ] && _bad="principal"; [ -z "$_apr" ] && _bad="apr"
                        local _sub=underwrite
                        if [ "$name" = "lending_request" ]; then _sub=request; [ -z "$_borr" ] && _bad="borrower"; fi
                        _cmd=("$_py" "$_t/sovereign_lending.py" "$_sub" "--collateral=$_coll" "--units=$_units" "--principal=$_prin"
                              "--term-days=$_term" "--apr=$_apr" "--principal-asset=$_pa" --actor=george)
                        [ -n "$_borr" ] && _cmd+=("--borrower=$_borr")
                        [ -n "$_note" ] && _cmd+=("--note=$_note") ;;
                    lending_service)
                        _cmd=("$_py" "$_t/sovereign_lending.py" service --actor=george)
                        [ -n "$_lid" ] && _cmd+=("--loan-id=$_lid")
                        [ "$_exec" = "true" ] && _cmd+=(--execute) ;;
                    lending_book) _cmd=("$_py" "$_t/sovereign_lending.py" book) ;;
                    crypto_price_ladder)
                        [ -z "$_asset" ] && _bad="asset"; [ -z "$_amt" ] && _bad="amount"
                        _cmd=("$_py" "$_t/limit_order_forecaster.py" "--asset=$_asset" "--direction=$_dir" "--amount=$_amt"
                              --ladder "--span-pct=$_span" "--rungs=$_rungs") ;;
                    pool_health)
                        _cmd=("$_py" "$_t/dex_liquidity_squeeze_detector.py" --json)
                        [ -n "$_asset" ] && _cmd+=(--pair "${_asset}/ADA") ;;
                    polymarket_scan) _cmd=("$_py" "$_t/polymarket_probability_arbitrageur.py" --json) ;;
                esac
            fi
            if [ -n "$_bad" ]; then
                output="ERROR: missing or invalid $_bad argument"; exit_code=1
            else
                output=$("${_cmd[@]}" 2>/dev/null)
                exit_code=$?
                case "$name" in
                    polymarket_scan) output=$(printf '%s' "$output" | jq -c '{status, scanned, viable, budget_usdc, top: ([.opportunities[]? | {question, net_edge_pct, viable, blockers}] | sort_by(-.net_edge_pct) | .[:8])}' 2>/dev/null || printf '%s' "$output" | head -c 6000) ;;
                    fund_treasury|pool_health) output=$(printf '%s' "$output" | head -c 12000) ;;
                esac
                [ -z "$output" ] && output="ERROR: $name produced no output (exit $exit_code)"
            fi
            ;;
        polymarket_arbitrage)
            output=$("$LODGE_DIR/.venv/bin/python" "$LODGE_DIR/lib/tools/polymarket_probability_arbitrageur.py" --scan 2>&1)
            exit_code=$?
            ;;
        wallet_set_network) _call_sim wallet_set_network "Wallet network set to $(_arg .network mainnet)" "$(_arg .network mainnet)" ;;
        crypto_send)
            local _chain="$(_arg .chain)" _to="$(_arg .to)" _amt="$(_arg .amount)"
            case "$_chain" in
                btc|bitcoin) output=$(btc_send "$_to" "$_amt" 2>&1); exit_code=$? ;;
                sol|solana) output=$(sol_send "$_to" "$_amt" 2>&1); exit_code=$? ;;
                ada|cardano) output=$(ada_send "$_to" "$_amt" 2>&1); exit_code=$? ;;
                *) output="ERROR: Unknown chain '$_chain' (supported: btc, sol, ada)"; exit_code=1 ;;
            esac
            ;;
        solana_airdrop) _call_sim sol_airdrop "Requested devnet airdrop: $(_arg .amount 1) SOL" "$(_arg .amount 1)" ;;
        *)
            return 1
            ;;
    esac
    return 0
}
