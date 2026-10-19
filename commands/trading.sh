#!/bin/bash
# DESC: Sovereign Multi-Chain Crypto Trading, Lending, and Analysis Platform
# Usage:
#   /trading [status]                    — Show Unified Sovereign Multi-Chain Desk (ADA, POL, ETH, USDC)
#   /trading eth [status|transfer|gas]   — Manage Ethereum Mainnet wallet and ERC-20 USDC rescue
#   /trading underwrite [scan|simulate]  — Cross-Chain Yield & P2P Microloan Underwriter (Cardano & EVM)
#   /trading squeeze [scan|pair]         — AMM Liquidity Imbalance & Stale Batcher Pool Squeeze Detector
#   /trading quant [asset|matrix]        — Parkinson Volatility Corridors & Ornstein-Uhlenbeck Mean Reversion
#   /trading dimensions [asset]          — Higher-Dimensional Market Dimensions (Queue, Slip, Flow)
#   /trading pretrade [asset] [amt] [dir]— Multi-Dimensional Pre-Trade Clearance Gate
#   /trading cointegration [pair]        — Cointegration & Stationary Spread Discovery (Engle-Granger)
#   /trading reactor [--no-notify]       — Cointegration Resting Limit Order Reactor (Gated by AUTO/MANUAL)
#   /trading order [status|ladder|stop|cancel|prune] — Unified Cardano Order Manager (UCOM)
#   /trading maker [scan|orders|place|graph] — Sovereign Cardano Resting Limit Order Engine (Path D)
#   /trading stops [status|calc|arm|cancel|graph] — Reactive Breakout Stop-Order & OCO Bracket Engine
#   /trading cancel [order_id|tx_id]     — Emergency Plutus Order Reclaimer from AMM scripts
#   /trading reactors [status|scan]      — FIFO IPC Flow Control & Automated Event-Bus Reactors
#   /trading tax [status|audit|export]   — US IRS Form 8949 HIFO Tax Auditor & Cryptographic Vault
#   /trading loop [run|status]           — 3-Pillar Autonomous Sovereign Capital Loop
#   /trading mode [AUTO|MANUAL]          — Sovereign Execution Guard (AUTO enables mainnet, MANUAL locks dry-run)
#   /trading stale [scan|reclaim]        — Stale Order & Microloan Reclaimer (>48h / >3.5% drift)
#   /trading graph [arbitrage|maker|stops] — 5-Phase Deterministic Execution Graphs (Triple Engine Architecture)
#   /trading sim <subcmd>                — Secondary Menu: Simulated Paper Trading Sandbox (trade, bet, reset)

LODGE_DIR="${LODGE_DIR:-$HOME/blue-lodge}"
source "$LODGE_DIR/lib/ui/ui.sh" 2>/dev/null || true
PY_BIN="$LODGE_DIR/.venv/bin/python"
[ ! -x "$PY_BIN" ] && PY_BIN="python3"

cmd_trading() {
    local args="$1"
    local subcmd="${args%% *}"
    local rest="${args#"$subcmd"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$subcmd" in
        review)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Review (Policy, Gates, Inventory & Orders)"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" review | jq .
            ;;
        scan)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Market Scan (Fair Value, Regime & Signals)"
            if [ -n "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" scan --assets "$rest" | jq .
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" scan | jq .
            fi
            ;;
        plan)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Plan Builder"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" plan --intent "${rest:-review}" | jq .
            ;;
        execute)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Plan Executor"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" execute --plan-id "$rest" | jq .
            ;;
        plans)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Plans"
            if [ -n "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" plans --plan-id "$rest" | jq .
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" plans | jq .
            fi
            ;;
        standing-order)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Standing Orders"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" standing-order ${rest:-list} | jq .
            ;;
        journal)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trading Journal & Markouts"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/agent_tools.py" journal | jq .
            ;;
        gates)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Strategy Gates & Freeze Status"
            "$PY_BIN" "$LODGE_DIR/lib/tools/trading/gates.py" ${rest:-status} | jq .
            ;;
        desk|dex|position|positions)
            local desk_asset="${rest%% *}"
            [ -z "$desk_asset" ] && desk_asset="SNEK"
            declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano DEX Desk: $desk_asset"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_desk_summary.py" "$desk_asset"
            ;;
        order|orders|ucom)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano Unified Order Manager (UCOM)"
            if [ -z "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" status
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" $rest
            fi
            ;;
        triangle|coverage|deploy-triangle)
            local tri_asset="${rest%% *}"
            local tri_args="${rest#"$tri_asset"}"
            tri_args="${tri_args#"${tri_args%%[![:space:]]*}"}"
            [ -z "$tri_asset" ] && tri_asset="SNEK"
            declare -f ui_section &>/dev/null && ui_section "Sovereign Coverage Triangle Deployer: $tri_asset"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_tool.py" triangle "$tri_asset" $tri_args
            ;;
        ""|status|portfolio)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Multi-Chain Treasury Desk"
            "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py"
            ;;
        eth|ethereum)
            declare -f ui_section &>/dev/null && ui_section "Ethereum Mainnet Sovereign Asset Manager"
            local eth_action="${rest%% *}"
            local eth_args="${rest#"$eth_action"}"
            eth_args="${eth_args#"${eth_args%%[![:space:]]*}"}"
            case "$eth_action" in
                transfer|send)
                    local amt to_addr
                    amt=$(echo "$eth_args" | awk '{print $1}')
                    to_addr=$(echo "$eth_args" | awk '{print $2}')
                    local exec_flag="--dry-run"
                    [[ "$eth_args" =~ --execute ]] && exec_flag="--execute"
                    if [ -z "$amt" ] || [ -z "$to_addr" ]; then
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading eth transfer <amount_usdc> <recipient_0x_address> [--execute]"
                        return 1
                    fi
                    "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py" --eth-transfer-usdc "$amt" --to "$to_addr" $exec_flag
                    ;;
                json)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py" --chain ethereum --json
                    ;;
                *)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py" --chain ethereum
                    ;;
            esac
            ;;
        underwrite|lending|loans|microloan)
            declare -f ui_section &>/dev/null && ui_section "Cross-Chain Yield & Microloan Underwriter"
            if [ "$rest" = "scan" ] || [ -z "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/crosschain_lending_underwriter.py" --scan
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/crosschain_lending_underwriter.py" $rest
            fi
            ;;
        squeeze|depth|staleness)
            declare -f ui_section &>/dev/null && ui_section "AMM Liquidity Imbalance & Stale Pool Squeeze Detector"
            if [ -z "$rest" ] || [ "$rest" = "scan" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py" --scan
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/dex_liquidity_squeeze_detector.py" $rest
            fi
            ;;
        quant|volatility|ou)
            declare -f ui_section &>/dev/null && ui_section "Quantitative Volatility & Ornstein-Uhlenbeck Engine"
            if [ -n "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_volatility_engine.py" --asset "$rest"
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_volatility_engine.py"
            fi
            ;;
        forecast|hitting-time|fht)
            declare -f ui_section &>/dev/null && ui_section "Probabilistic Limit Order Fill Forecaster (Path D)"
            if [ -z "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/limit_order_forecaster.py" --asset IAG
            else
                local f_asset f_price f_amount
                f_asset=$(echo "$rest" | awk '{print $1}')
                f_price=$(echo "$rest" | awk '{print $2}')
                f_amount=$(echo "$rest" | awk '{print $3}')
                local args=()
                [ -n "$f_asset" ] && args+=(--asset "$f_asset")
                [ -n "$f_price" ] && args+=(--target-price "$f_price")
                [ -n "$f_amount" ] && args+=(--amount "$f_amount")
                "$PY_BIN" "$LODGE_DIR/lib/tools/limit_order_forecaster.py" "${args[@]}"
            fi
            ;;
        maker|limit|market-maker)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano Resting Limit Order Engine (Path D)"
            if [ -z "$rest" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" --orders
            elif [ "$rest" = "graph" ] || [[ "$rest" =~ ^graph ]]; then
                source "$LODGE_DIR/lib/tools/cardano_market_maker_graph.sh" 2>/dev/null || true
                cardano_maker_run ${rest#graph}
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_maker.py" $rest
            fi
            ;;
        stops|stop|bracket)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Reactive Stop-Order & OCO Bracket Engine"
            local stop_cmd="${rest%% *}"
            local stop_args="${rest#"$stop_cmd"}"
            stop_args="${stop_args#"${stop_args%%[![:space:]]*}"}"
            case "$stop_cmd" in
                ""|status|list)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" list $stop_args
                    ;;
                calc|calculate|bounds)
                    local s_asset=$(echo "$stop_args" | awk '{print $1}')
                    if [ -z "$s_asset" ]; then
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading stops calc <asset> [--json]"
                        return 1
                    fi
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" calc $stop_args
                    ;;
                arm|create)
                    if [ -z "$stop_args" ]; then
                        declare -f ui_dim &>/dev/null && ui_dim "Usage: /trading stops arm <asset> --trigger <px> --amount <ada> [--invalidation <px>] [--type STOP_BUY|STOP_LOSS]"
                        return 1
                    fi
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" arm $stop_args
                    ;;
                cancel|disarm)
                    local t_id=$(echo "$stop_args" | awk '{print $1}')
                    if [ -z "$t_id" ]; then
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading stops cancel <trigger_id|all>"
                        return 1
                    fi
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" cancel "$t_id"
                    ;;
                prune|clean)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" prune $stop_args
                    ;;
                journal|history|log)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" journal $stop_args
                    ;;
                ticker|poll)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_pair_ticker.py" --poll $stop_args
                    ;;
                graph|reactor|run)
                    bash "$LODGE_DIR/lib/tools/cardano_stop_reactor.sh" $stop_args
                    ;;
                *)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stop_engine.py" $rest
                    ;;
            esac
            ;;
        cancel|reclaim|refund)
            declare -f ui_section &>/dev/null && ui_section "Emergency Plutus Script Order Reclaimer"
            local cancel_id="$rest"
            local exec_flag="--dry-run"
            [[ "$rest" =~ --execute ]] && exec_flag="--execute"
            cancel_id="${cancel_id//--execute/}"
            cancel_id="${cancel_id#"${cancel_id%%[![:space:]]*}"}"
            cancel_id="${cancel_id%"${cancel_id##*[![:space:]]}"}"

            if [ -z "$cancel_id" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_canceller.py" --dry-run
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_order_canceller.py" --order-id "$cancel_id" $exec_flag
            fi
            ;;
        mode)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano Operating Mode Guard"
            local conf_file="$LODGE_DIR/.george/cardano_mode.conf"
            local current="AUTO"
            [ -f "$conf_file" ] && current=$(tr -d '[:space:]' < "$conf_file" | tr '[:lower:]' '[:upper:]')

            local target_mode=$(echo "$rest" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
            if [ -z "$target_mode" ]; then
                declare -f ui_info &>/dev/null && ui_info "Current Operating Mode: [${current}]"
                declare -f ui_dim &>/dev/null && ui_dim "Options: /trading mode AUTO   (Arms live autonomous execution)"
                declare -f ui_dim &>/dev/null && ui_dim "         /trading mode MANUAL (Enforces dry-run simulation only)"
            elif [ "$target_mode" = "AUTO" ]; then
                mkdir -p "$(dirname "$conf_file")"
                echo "AUTO" > "$conf_file"
                declare -f ui_warn &>/dev/null && ui_warn "Operating Mode ARMED: [AUTO]"
                declare -f ui_dim &>/dev/null && ui_dim "Arbitrage Graph and Sieve signals can now execute live mainnet transactions."
            elif [ "$target_mode" = "MANUAL" ]; then
                mkdir -p "$(dirname "$conf_file")"
                echo "MANUAL" > "$conf_file"
                declare -f ui_ok &>/dev/null && ui_ok "Operating Mode LOCKED: [MANUAL]"
                declare -f ui_dim &>/dev/null && ui_dim "All graph runs and order executions are restricted to risk-free dry runs."
            else
                declare -f ui_err &>/dev/null && ui_err "Invalid mode: $target_mode. Choose AUTO or MANUAL."
            fi
            ;;
        stale)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano Stale Order Reclaimer"
            local stale_action="${rest%% *}"
            local stale_arg="${rest#"$stale_action"}"
            stale_arg="${stale_arg#"${stale_arg%%[![:space:]]*}"}"
            case "$stale_action" in
                reclaim)
                    local exec_flag="--dry-run"
                    [[ "$stale_arg" =~ --execute ]] && exec_flag="--execute"
                    local oid=$(echo "$stale_arg" | awk '{print $1}')
                    if [ -z "$oid" ]; then
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading stale reclaim <order_id> [--execute]"
                        return 1
                    fi
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stale_reclaimer.py" --reclaim "$oid" $exec_flag
                    ;;
                reclaim-all)
                    local exec_flag="--dry-run"
                    [[ "$stale_arg" =~ --execute ]] && exec_flag="--execute"
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stale_reclaimer.py" --reclaim-all $exec_flag
                    ;;
                json)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stale_reclaimer.py" --json
                    ;;
                scan|"")
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_stale_reclaimer.py" --scan
                    ;;
                *)
                    declare -f ui_dim &>/dev/null && ui_dim "Usage: /trading stale [scan|reclaim <order_id>|reclaim-all] [--execute]"
                    ;;
            esac
            ;;
        graph)
            local graph_target="${rest%% *}"
            local graph_args="${rest#"$graph_target"}"
            graph_args="${graph_args#"${graph_args%%[![:space:]]*}"}"
            case "$graph_target" in
                maker|limit)
                    source "$LODGE_DIR/lib/tools/cardano_market_maker_graph.sh" 2>/dev/null || true
                    cardano_maker_run $graph_args
                    ;;
                stops|stop|bracket)
                    bash "$LODGE_DIR/lib/tools/cardano_stop_reactor.sh" $graph_args
                    ;;
                arbitrage|swap)
                    source "$LODGE_DIR/lib/tools/cardano_arbitrage_graph.sh" 2>/dev/null || true
                    cardano_graph_run $graph_args
                    ;;
                "")
                    declare -f ui_section &>/dev/null && ui_section "Sovereign Cardano Execution Graphs (Triple Engine Architecture)"
                    echo "  Strategic Mandate: Sovereign ADA Accumulation for Microfinancing Pool (1 ADA = 1 ADA)"
                    echo "  USD Gate: Bypassed by default (--gate-ada-24h -999.0)"
                    echo ""
                    echo "  ┌── Engine A: Taker Arbitrage Graph ───────────┐   /trading graph arbitrage [--capital ADA] [--pair ASSET] [--dry-run|--execute]"
                    echo "  │ Cross-DEX Flash Spread & Volatility Arb      │   Direct 2-leg atomic round trip (Minswap, WingRiders, Sundae)"
                    echo "  └──────────────────────────────────────────────┘"
                    echo "  ┌── Engine B: Cointegration Limit Maker Graph ─┐   /trading graph maker [--pair ASSET] [--capital ADA] [--dry-run]"
                    echo "  │ 5-Phase Passive Resting Limit Order Plutus   │   Zero aggregator toll; buys below spot on stationary pairs"
                    echo "  └──────────────────────────────────────────────┘"
                    echo "  ┌── Engine C: Breakout Stop-Buy & Bracket ─────┐   /trading graph stops [--once|--dry-run]"
                    echo "  │ Reactive Stop Engine & Chained OCO Bracket   │   Breakout buy -> +4% TP / -2.5% SL -> 100% Liquid ADA to Fund"
                    echo "  └──────────────────────────────────────────────┘"
                    echo ""
                    ;;
                *)
                    source "$LODGE_DIR/lib/tools/cardano_arbitrage_graph.sh" 2>/dev/null || true
                    cardano_graph_run $rest
                    ;;
            esac
            ;;
        arbitrage)
            source "$LODGE_DIR/lib/tools/cardano_arbitrage_graph.sh" 2>/dev/null || true
            cardano_graph_run $rest
            ;;
        reactors|triggers|bus)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Trade Event-Bus Reactors & Flow Control"
            "$LODGE_DIR/lib/tools/trade_event_trigger.sh" ${rest:-status}
            ;;
        cardano|ada)
            declare -f ui_section &>/dev/null && ui_section "Cardano Sovereign Hot Wallet Status"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_trader.py" --balance
            ;;
        polygon|poly)
            declare -f ui_section &>/dev/null && ui_section "Polygon PoS Sovereign Wallet Status"
            "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py" --chain polygon
            ;;
        wallets|keys)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Multi-Chain Wallet & Keys Register"
            "$PY_BIN" "$LODGE_DIR/lib/tools/sovereign_multichain_wallet.py"
            ;;
        sweep)
            declare -f ui_section &>/dev/null && ui_section "Sweeping Excess Capital to Trezor Master Vault"
            local dry_flag=""
            [[ "$rest" =~ --dry-run ]] && dry_flag="--dry-run"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_trader.py" --sweep $dry_flag
            ;;
        swap)
            declare -f ui_section &>/dev/null && ui_section "Executing Cardano DEX Swap Engine"
            local amount token extra_args
            amount=$(echo "$rest" | awk '{print $1}')
            token=$(echo "$rest" | awk '{print $2}')
            extra_args=$(echo "$rest" | cut -d' ' -f3-)
            if [ -z "$amount" ] || [ -z "$token" ]; then
                declare -f ui_err &>/dev/null && ui_err "Usage: /trading swap <amount_ada> <token_symbol> [--execute | --dry-run]"
                return 1
            fi
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_dex_swapper.py" --amount "$amount" --token "$token" $extra_args
            ;;
        sniper|flash)
            declare -f ui_section &>/dev/null && ui_section "Cardano DEX Flash Spread & Volatility Sniper"
            local flags="--scan"
            [ -n "$rest" ] && flags="$flags $rest"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_flash_sniper.py" $flags
            ;;
        polymarket|poly-arb)
            declare -f ui_section &>/dev/null && ui_section "Polymarket Probability & Negative-Risk Arbitrage Desk"
            local extra_flags=""
            [[ "$rest" =~ --json ]] && extra_flags="--json"
            "$PY_BIN" "$LODGE_DIR/lib/tools/polymarket_probability_arbitrageur.py" ${extra_flags:-"--scan"}
            ;;
        loop|autonomic)
            declare -f ui_section &>/dev/null && ui_section "3-Pillar Sovereign Capital Autonomous Loop"
            if [ "$rest" = "run" ] || [ "$rest" = "scan" ]; then
                "$LODGE_DIR/.george/cron_jobs/sovereign_trading_loop.sh"
            fi
            local sf="$LODGE_DIR/.george/wallets/sovereign_trading_status.json"
            if [ -f "$sf" ]; then
                jq -r '"Last Scan: " + .timestamp + "\nApproved Loans: " + (.summary.approved_loans_count|tostring) + "\nViable Flash Snipes: " + (.summary.viable_flash_snipes_count|tostring) + "\nViable Polymarket Arb: " + (.summary.viable_polymarket_arb_count|tostring)' "$sf"
            else
                echo "No loop state recorded yet. Run /trading loop run"
            fi
            ;;
        research|analyze)
            local mid=$(echo "$rest" | awk '{print $1}')
            local q=$(echo "$rest" | cut -d' ' -f2-)
            [ -z "$mid" ] && {
                declare -f ui_err &>/dev/null && ui_err "Usage: /trading research <market_id> [question]"
                return 1
            }
            declare -f ui_info &>/dev/null && ui_info "Initiating Adam Smith ReAct Research Loop for: $mid"
            python3 "$LODGE_DIR/lib/tools/finance_researcher.py" -m "$mid" -q "${q:-Market $mid}"
            ;;
        brainstorm|strategy)
            local topic="${rest:-Cardano DEX arbitrage and Plutus microloan escrow}"
            declare -f ui_section &>/dev/null && ui_section "Strategic Strategy Brainstorming Loop"
            declare -f ui_info &>/dev/null && ui_info "Topic: $topic"
            source "$LODGE_DIR/lib/tools/research_graph.sh" 2>/dev/null || true
            research_graph_run "Quantitative Finance: $topic"
            ;;

        # ── ISOLATED SIMULATED TRADING SANDBOX (Secondary Menu / Tab) ───────
        sim|paper|mock)
            local sim_cmd="${rest%% *}"
            local sim_args="${rest#"$sim_cmd"}"
            sim_args="${sim_args#"${sim_args%%[![:space:]]*}"}"

            declare -f ui_section &>/dev/null && ui_section "Simulated Trading Sandbox (Isolated Paper Environment)"
            case "$sim_cmd" in
                ""|status|report)
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --report
                    ;;
                send-dm|stream)
                    local user="${sim_args:-${OPERATOR_DISCORD_HANDLE:-${OPERATOR_HANDLE:-operator}}}"
                    declare -f ui_info &>/dev/null && ui_info "Dispatching simulated 10-minute report to Discord user: $user"
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --send-dm --user "$user"
                    ;;
                markets|poly)
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --markets
                    ;;
                trade)
                    local action asset amount rationale
                    action=$(echo "$sim_args" | awk '{print $1}')
                    asset=$(echo "$sim_args" | awk '{print $2}')
                    amount=$(echo "$sim_args" | awk '{print $3}')
                    rationale=$(echo "$sim_args" | cut -d' ' -f4-)
                    [ -z "$action" ] || [ -z "$asset" ] || [ -z "$amount" ] && {
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading sim trade <BUY|SELL> <BTC|ADA> <amount_usd> [rationale]"
                        return 1
                    }
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --trade "$action" --asset "$asset" --amount "$amount" --rationale "${rationale:-Operator manual simulation}"
                    ;;
                bet)
                    local outcome market_id amount rationale
                    outcome=$(echo "$sim_args" | awk '{print $1}')
                    market_id=$(echo "$sim_args" | awk '{print $2}')
                    amount=$(echo "$sim_args" | awk '{print $3}')
                    rationale=$(echo "$sim_args" | cut -d' ' -f4-)
                    [ -z "$outcome" ] || [ -z "$market_id" ] || [ -z "$amount" ] && {
                        declare -f ui_err &>/dev/null && ui_err "Usage: /trading sim bet <YES|NO> <market_id> <amount_usd> [rationale]"
                        return 1
                    }
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --bet-poly "$outcome" --market-id "$market_id" --amount "$amount" --rationale "${rationale:-Operator manual simulation}"
                    ;;
                reset)
                    python3 "$LODGE_DIR/lib/tools/trading_bot.py" --reset-portfolio
                    ;;
                *)
                    declare -f ui_dim &>/dev/null && ui_dim "Simulated Sandbox Commands: /trading sim [status|trade|bet|markets|report|reset]"
                    ;;
            esac
            ;;

        tax|taxes|irs|costbasis)
            declare -f ui_section &>/dev/null && ui_section "Sovereign Crypto Tax & Cost Basis Auditor (Form 8949 / Schedule 1)"
            local tax_action="${rest%% *}"
            local tax_args="${rest#"$tax_action"}"
            tax_args="${tax_args#"${tax_args%%[![:space:]]*}"}"
            case "$tax_action" in
                audit|run)
                    local yr="${tax_args:-2026}"
                    "$PY_BIN" "$LODGE_DIR/lib/tools/crypto_tax_auditor.py" --audit --year "$yr"
                    ;;
                bundle)
                    local yr="${tax_args:-2026}"
                    declare -f ui_info &>/dev/null && ui_info "Compiling complete 4-part IRS compliance bundle for tax year $yr..."
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_provenance_engine.py" --bundle --year "$yr"
                    ;;
                provenance|trace)
                    local target_addr="${tax_args:-${CARDANO_WALLET_ADDR:-}}"
                    declare -f ui_info &>/dev/null && ui_info "Crawling on-chain provenance for ${target_addr:-default wallet}..."
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_provenance_engine.py" --trace "$target_addr"
                    ;;
                staking|rewards)
                    local s_key
                    s_key=$(echo "$tax_args" | awk '{print $1}')
                    local s_yr
                    s_yr=$(echo "$tax_args" | awk '{print $2}')
                    s_key="${s_key:-${CARDANO_STAKE_ADDR:-}}"
                    s_yr="${s_yr:-2026}"
                    declare -f ui_info &>/dev/null && ui_info "Auditing staking rewards (IRS Rev. Rul. 2023-14) for ${s_key:-default stake key} (Year $s_yr)..."
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_provenance_engine.py" --staking "$s_key" --year "$s_yr"
                    ;;
                schedule1|sch1)
                    local s_key
                    s_key=$(echo "$tax_args" | awk '{print $1}')
                    local s_yr
                    s_yr=$(echo "$tax_args" | awk '{print $2}')
                    s_key="${s_key:-${CARDANO_STAKE_ADDR:-}}"
                    s_yr="${s_yr:-2026}"
                    declare -f ui_info &>/dev/null && ui_info "Exporting IRS Schedule 1 Staking CSV for ${s_key:-default stake key} (Year $s_yr)..."
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_provenance_engine.py" --staking "$s_key" --year "$s_yr" --export-schedule1
                    ;;
                library|wallets)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_provenance_engine.py" --library
                    ;;
                export|csv)
                    local yr="${tax_args:-2026}"
                    declare -f ui_info &>/dev/null && ui_info "Exporting IRS Form 8949 CSV for tax year $yr..."
                    "$PY_BIN" "$LODGE_DIR/lib/tools/crypto_tax_auditor.py" --audit --year "$yr"
                    declare -f ui_ok &>/dev/null && ui_ok "Export ready: $LODGE_DIR/dossiers/finance/tax/irs_form_8949_${yr}.csv"
                    ;;
                verify)
                    local yr="${tax_args:-2026}"
                    "$PY_BIN" "$LODGE_DIR/lib/tools/crypto_tax_auditor.py" --verify --year "$yr"
                    ;;
                backup-keys|backup|keys)
                    "$PY_BIN" "$LODGE_DIR/lib/tools/crypto_tax_auditor.py" --backup-keys
                    ;;
                status|"")
                    local yr="${tax_args:-2026}"
                    "$PY_BIN" "$LODGE_DIR/lib/tools/crypto_tax_auditor.py" --status --year "$yr"
                    ;;
                *)
                    declare -f ui_dim &>/dev/null && ui_dim "Tax Commands: /trading tax [status|audit <year>|bundle <year>|provenance <addr>|staking <key> <year>|schedule1 <key> <year>|library|verify|backup-keys]"
                    ;;
            esac
            ;;

        dimensions|dim|market)
            declare -f ui_section &>/dev/null && ui_section "Cardano Higher-Dimensional Market Dimensions"
            local d_asset="${rest:-IAG}"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_dimensions.py" --asset "$d_asset"
            ;;

        pretrade|clearance)
            declare -f ui_section &>/dev/null && ui_section "Pre-Trade Multi-Dimensional Clearance Evaluator"
            local p_asset p_size p_dir
            p_asset=$(echo "$rest" | awk '{print $1}')
            p_size=$(echo "$rest" | awk '{print $2}')
            p_dir=$(echo "$rest" | awk '{print $3}')
            p_asset="${p_asset:-IAG}"
            p_size="${p_size:-50}"
            p_dir="${p_dir:-buy}"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_market_dimensions.py" --pre-trade --asset "$p_asset" --size "$p_size" --dir "$p_dir"
            ;;

        cointegration|coint|pairs)
            declare -f ui_section &>/dev/null && ui_section "Cardano Cointegration & Engineered Spread Scanner"
            local p1 p2
            p1=$(echo "$rest" | awk '{print $1}')
            p2=$(echo "$rest" | awk '{print $2}')
            if [ -n "$p1" ] && [ -n "$p2" ]; then
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_cointegration.py" --pair "$p1" "$p2"
            else
                "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_cointegration.py" --scan
            fi
            ;;

        coint-reactor|reactor)
            declare -f ui_section &>/dev/null && ui_section "Cardano Cointegration & Limit Order Reactor"
            local reactor_flags="--scan"
            [[ "$rest" =~ --no-notify ]] && reactor_flags="$reactor_flags --no-notify"
            [[ "$rest" =~ --execute ]] && reactor_flags="$reactor_flags --execute"
            [[ "$rest" =~ --json ]] && reactor_flags="$reactor_flags --json"
            [[ "$rest" =~ --capital[[:space:]]+([0-9.]+) ]] && reactor_flags="$reactor_flags --capital ${BASH_REMATCH[1]}"
            [[ "$rest" =~ --trade-size[[:space:]]+([0-9.]+) ]] && reactor_flags="$reactor_flags --capital ${BASH_REMATCH[1]}"
            "$PY_BIN" "$LODGE_DIR/lib/tools/cardano_cointegration_reactor.py" $reactor_flags
            ;;

        *)
            declare -f ui_err &>/dev/null && ui_err "Unknown /trading action: $subcmd"
            declare -f ui_dim &>/dev/null && ui_dim "Sovereign Actions: /trading [status|dimensions|pretrade|cointegration|reactor|eth|underwrite|squeeze|quant|maker|cancel|reactors|tax|ada|poly|wallets|swap|sniper|loop|research|sim]"
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_trading "$*"
fi
