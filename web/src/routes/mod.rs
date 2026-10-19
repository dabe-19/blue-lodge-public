pub mod cardano_node;
pub mod chat;
pub mod config;
pub mod copilot;
pub mod cron;
pub mod desk;
pub mod files;
pub mod finance;
pub mod fund;
pub mod hub;
pub mod mcp;
pub mod memories;
pub mod models;
pub mod nodes;
pub mod okf;
pub mod rack;
pub mod react;
pub mod research;
pub mod runs;
pub mod sdr;
pub mod status;
pub mod stream;
pub mod tasks;
pub mod terminal;
pub mod training;
pub mod tunnel;

use axum::{
    middleware::{from_fn, from_fn_with_state},
    routing::{delete, get, post},
    Router,
};
use std::sync::Arc;
use tower_http::cors::CorsLayer;
use tower_http::services::ServeDir;

use crate::state::AppState;

pub fn create_router(state: Arc<AppState>, cors: CorsLayer) -> Router {
    let static_dir = state.lodge_dir.join("web").join("static");

    Router::new()
        // Session token: master token for localhost, per-device token for paired
        // remote browsers. Pairing / device management (see security.rs, devices.rs).
        .route("/api/session/token", get(crate::security::get_session_token))
        .route("/api/session/pair", post(crate::security::post_pair))
        .route("/api/session/pair-code", post(crate::security::post_pair_code))
        .route("/api/session/devices", get(crate::security::get_devices))
        .route("/api/session/devices/revoke", post(crate::security::post_revoke))
        .route("/api/session/forget", post(crate::security::post_forget))

        // Status & Telemetry
        .route("/api/status", get(status::get_status))
        .route("/api/rack", get(rack::get_rack))

        // Tasks & Bay
        .route("/api/tasks", get(tasks::get_tasks))
        .route("/api/task/:id/input", post(tasks::post_task_input))
        .route("/api/task/:id/pause", post(tasks::pause_task))
        .route("/api/task/:id/resume", post(tasks::resume_task))
        .route("/api/task/:id/inject", post(tasks::inject_task))
        .route("/api/task/:id/compact", post(tasks::compact_task))
        .route("/api/task/:id/abort", post(tasks::abort_task))
        .route("/api/tasks/cull", post(tasks::cull_tasks))
        .route("/api/task/:id/trajectory", get(tasks::get_task_trajectory))

        // Chat & Commands
        .route("/api/session", get(chat::get_session).delete(chat::clear_session))
        .route("/api/chat", post(chat::post_chat))
        .route("/api/chat/dispatch", post(chat::post_dispatch))
        .route("/api/command", post(chat::post_chat))

        // Co-Pilot
        .route("/api/copilot/chat", post(copilot::post_copilot_chat))
        .route("/api/copilot/agents", get(copilot::get_copilot_agents))
        .route("/api/copilot/agent/save", post(copilot::post_copilot_agent_save))
        .route("/api/copilot/workflows", get(copilot::get_copilot_workflows))
        .route("/api/copilot/workflow/save", post(copilot::post_copilot_workflow_save))
        .route("/api/copilot/tools", get(copilot::get_copilot_tools))
        .route("/api/copilot/tool/build", post(copilot::post_copilot_tool_build))
        .route("/api/copilot/tool/test", post(copilot::post_copilot_tool_test))
        .route("/api/copilot/rules", get(copilot::get_copilot_rules))
        .route("/api/copilot/comment", post(copilot::post_copilot_comment))

        // Compute Nodes & Hardware
        .route("/api/node/probe", post(nodes::probe_node))
        .route("/api/node/save", post(nodes::save_node_endpoint))
        .route("/api/node/discover", get(nodes::discover_remote_node).post(nodes::discover_remote_node))
        .route("/api/node/switch-model", post(nodes::switch_remote_model))
        .route("/api/node/enroll", post(nodes::enroll_remote_node))
        .route("/api/swarm/status", get(nodes::get_swarm_status))

        // Game mode + operator model-pull staging (model management lives under /api/hub)
        .route("/api/system/gamemode", get(models::get_gamemode).post(models::toggle_gamemode))
        .route("/api/model/stage-pull", post(models::stage_model_pull))

        // Model Hub (Phase 5): verified, approval-gated model lifecycle + Model Copilot
        .route("/api/hub/hw", get(hub::hw))
        .route("/api/hub/search", get(hub::search))
        .route("/api/hub/inspect", get(hub::inspect))
        .route("/api/hub/quants", get(hub::quants))
        .route("/api/hub/draft", post(hub::draft))
        .route("/api/hub/profiles", get(hub::profiles))
        .route("/api/hub/profile/:name", get(hub::profile_show).delete(hub::profile_remove))
        .route("/api/hub/profile/:name/approve", post(hub::profile_approve))
        .route("/api/hub/profile/:name/install", post(hub::profile_install))
        .route("/api/hub/profile/:name/progress", get(hub::profile_progress))
        .route("/api/hub/profile/:name/cancel", post(hub::profile_cancel))
        .route("/api/hub/profile/:name/activate", post(hub::profile_activate))
        .route("/api/hub/rollback", post(hub::rollback))
        .route("/api/hub/accounts", get(hub::accounts))
        .route("/api/hub/login", post(hub::login))
        .route("/api/hub/logout", post(hub::logout))
        // Model Workbench: the operator's own GGUFs (no curated catalog)
        .route("/api/hub/library", get(hub::library))
        .route("/api/hub/library/file", delete(hub::delete_file))
        .route("/api/hub/fit-local", get(hub::fit_local))
        .route("/api/hub/import-local", post(hub::import_local))
        .route("/api/hub/profile/:name/tune", post(hub::profile_tune))
        .route("/api/hub/profile/:name/attach", post(hub::profile_attach))
        .route("/api/hub/profile/:name/detach", post(hub::profile_detach))
        .route("/api/hub/jobs", get(hub::jobs))
        .route("/api/hub/jobs/:name/clear", post(hub::job_clear))
        .route("/api/hub/server", get(hub::server_status))
        .route("/api/hub/presets", get(hub::presets))
        .route("/api/hub/presets/:id/run", post(hub::preset_run))
        .route("/api/hub/datasets", get(hub::datasets))
        .route("/api/hub/datasets/files", get(hub::dataset_files))
        .route("/api/hub/datasets/pull", post(hub::dataset_pull))
        .route("/api/hub/datasets/export-runs", post(hub::export_runs))
        .route("/api/hub/train/kit", post(hub::train_kit))
        .route("/api/hub/train/kits", get(hub::kits))
        .route("/api/hub/forge/recipes", get(hub::forge_recipes))
        .route("/api/hub/forge/pantry", get(hub::forge_pantry))
        .route("/api/hub/forge/build", post(hub::forge_build))
        .route("/api/hub/ask", post(hub::ask))
        .route("/api/hub/ask/:id", get(hub::ask_status))

        // Sovereign Training & ADC Quota
        .route("/api/training/status", get(training::get_training_status))
        .route("/api/training/run", post(training::run_training))
        .route("/api/training/wizard", post(training::generate_training_wizard))

        // Workspace & File Management
        .route("/api/file/read", get(files::read_file_content))
        .route("/api/file/save", post(files::save_file_content))
        .route("/api/files/list", get(files::list_workspace_files))
        .route("/api/file/resolve-deps", get(files::resolve_script_deps))
        .route("/api/workspace/active", get(files::get_active_workspace))
        .route("/api/workspace/dock", post(files::dock_workspace))
        .route("/api/upload", post(files::upload_file))

        // Configuration Levers & Keys
        .route("/api/config", get(config::get_config).post(config::update_config))
        .route("/api/config/all", get(config::get_config_all))
        .route("/api/config/full", get(config::get_config_full))
        .route("/api/config/key", post(config::update_config_key))
        .route("/api/config/test", post(config::test_connection))

        // Autonomic Sweeps & Cron
        .route("/api/cron", get(cron::get_cron_jobs).post(cron::save_cron_job))
        .route("/api/cron/run/:name", post(cron::run_cron_job))
        .route("/api/cron/job/:name", delete(cron::delete_cron_job))
        .route("/api/cron/job/:name/toggle-platform", post(cron::toggle_cron_platform))
        .route("/api/cron/job/:name/toggle-enabled", post(cron::toggle_cron_enabled))
        .route("/api/social/gate", get(cron::get_social_gate))
        .route("/api/social/gate/toggle", post(cron::toggle_social_gate))
        .route("/api/cron/generate", post(cron::generate_cron_job))
        .route("/api/cron/daemon/start", post(cron::start_cron_daemon))
        .route("/api/cron/daemon/stop", post(cron::stop_cron_daemon))
        .route("/api/cron/daemon/restart", post(cron::restart_cron_daemon))

        // Sovereign Research Studio & Dossier Library
        .route("/api/research/dossiers", get(research::get_dossiers))
        .route("/api/research/dossier/:slug", get(research::get_dossier))
        .route("/api/research/dossier/:slug/plate", get(research::get_dossier_plate))
        .route("/api/research/dossier/:slug/revision/:rev", get(research::get_revision))
        .route("/api/research/start", post(research::post_research_start))
        .route("/api/research/refine/:slug", post(research::post_research_refine))
        .route("/api/research/salvage/:slug", post(research::post_research_salvage))
        .route("/api/research/resynthesize-thread/:slug", post(research::post_resynthesize_thread))
        .route("/api/research/topics/draft", post(research::post_topics_draft))
        .route("/api/research/topics/random", get(research::get_topics_random))
        .route("/api/research/topics/add", post(research::post_topics_add))
        .route("/api/research/mode/set", post(research::post_research_mode_set))
        .route("/api/research/brainstorm/chat", post(research::post_brainstorm_chat))
        .route("/api/research/publish/:slug", post(research::post_research_publish))
        .route("/api/research/analytics", get(research::get_social_analytics))
        .route("/api/research/analytics/sync", post(research::post_social_analytics_sync))

        // Reactive Event Bus & Sovereign OSINT
        .route("/api/react/reactors", get(react::get_reactors).post(react::add_reactor))
        .route("/api/react/reactor/:id", delete(react::delete_reactor))
        .route("/api/react/reactor/:id/toggle", post(react::toggle_reactor))
        .route("/api/react/emit", post(react::emit_event))
        .route("/api/osint/config", get(react::get_osint_config).post(react::save_osint_config))
        .route("/api/osint/sweep", post(react::run_osint_sweep))
        .route("/api/react/api-presets", get(react::get_api_presets))
        .route("/api/react/api-search", get(react::search_api_catalog))
        .route("/api/react/api-build", post(react::build_api_trigger))
        .route("/api/react/daemon/start", post(react::start_event_bus_daemon))
        .route("/api/react/daemon/stop", post(react::stop_event_bus_daemon))
        .route("/api/react/daemon/restart", post(react::restart_event_bus_daemon))
        .route("/api/react/daemon/status", get(react::get_event_bus_status))

        // Financial OSINT, Paper Trading & Polymarket Simulator
        .route("/api/finance/status", get(finance::get_finance_status))
        .route("/api/finance/wallets", get(finance::get_wallets_status))
        .route("/api/finance/loop", get(finance::get_sovereign_loop_status))
        .route("/api/finance/sweep", post(finance::execute_sweep))
        .route("/api/finance/trade", post(finance::execute_trade))
        .route("/api/finance/bet", post(finance::execute_bet))
        .route("/api/finance/research-bet", post(finance::research_bet))
        .route("/api/finance/reset", post(finance::reset_portfolio))
        .route("/api/finance/send-dm", post(finance::send_discord_report))
        .route("/api/finance/dossier", get(finance::get_finance_dossier))
        .route("/api/finance/arbitrage/spreads", get(finance::get_arbitrage_spreads))
        .route("/api/finance/arbitrage/maker", get(finance::get_maker_corridors))
        .route("/api/finance/arbitrage/run", post(finance::run_arbitrage_graph))
        .route("/api/finance/arbitrage/history", get(finance::get_arbitrage_history))
        .route("/api/finance/maker/corridors", get(finance::get_maker_corridors))
        .route("/api/finance/maker/volatility", get(finance::get_maker_volatility))
        .route("/api/finance/maker/orders", get(finance::get_maker_orders))
        .route("/api/finance/maker/active-cycles", get(finance::get_maker_active_cycles))
        .route("/api/finance/simulator/maker-cycles", get(finance::get_simulator_maker_cycles))
        .route("/api/finance/maker/reconcile", post(finance::reconcile_maker_orders))
        .route("/api/finance/maker/simulate-fill", post(finance::simulate_maker_fill))
        .route("/api/finance/maker/link-inventory", post(finance::link_maker_inventory))
        .route("/api/finance/maker/unlink-inventory", post(finance::unlink_maker_inventory))
        .route("/api/finance/maker/cancel", post(finance::cancel_maker_order))
        .route("/api/finance/maker/stops", get(finance::get_stop_triggers))
        .route("/api/finance/maker/stops/cancel", post(finance::cancel_stop_trigger))
        .route("/api/finance/maker/run", post(finance::run_maker_graph))
        .route("/api/finance/maker/simulate", post(finance::simulate_maker_order))

        // Sovereign Multi-Chain Desk, Lending Underwriter, Squeeze Detector & Crypto Research
        .route("/api/finance/multichain", get(finance::get_multichain_portfolio))
        .route("/api/finance/eth/transfer", post(finance::execute_eth_transfer))
        .route("/api/finance/underwrite/scan", get(finance::get_underwriting_scan))
        .route("/api/finance/underwrite/simulate", post(finance::simulate_microloan))
        .route("/api/finance/squeeze/scan", get(finance::get_squeeze_scan))
        .route("/api/finance/squeeze/pair", post(finance::audit_squeeze_pair))
        .route("/api/finance/research/crypto", post(finance::research_crypto_asset))
        .route("/api/finance/reactors/status", get(finance::get_trade_reactors))
        .route("/api/finance/reactors/stale-scan", post(finance::run_stale_scan))
        .route("/api/finance/forecast/hitting-time", post(finance::forecast_hitting_time))

        // Sovereign Crypto Tax & IRS Form 8949 Cost Basis Auditor
        .route("/api/finance/tax/status", get(finance::get_tax_status))
        .route("/api/finance/tax/audit", post(finance::run_tax_audit))
        .route("/api/finance/tax/export", get(finance::get_tax_export))
        .route("/api/finance/tax/backup-keys", post(finance::backup_tax_keys))
        .route("/api/finance/tax/provenance", get(finance::get_provenance_trace))
        .route("/api/finance/tax/staking", get(finance::get_staking_audit))
        .route("/api/finance/tax/schedule1", get(finance::get_schedule1_export))
        .route("/api/finance/tax/library", get(finance::get_wallet_library))
        .route("/api/finance/tax/bundle", post(finance::run_tax_bundle))

        // Sovereign Cardano Node, Block Crawler & Sieve Bridge
        .route("/api/cardano/node/status", get(cardano_node::get_node_status))
        .route("/api/cardano/node/logs", get(cardano_node::get_node_logs))
        .route("/api/cardano/node/restart", post(cardano_node::restart_node))
        .route("/api/cardano/blocks/latest", get(cardano_node::get_latest_blocks))
        .route("/api/cardano/tx/:hash", get(cardano_node::get_transaction_inspect))
        .route("/api/cardano/mode", get(cardano_node::get_execution_mode).post(cardano_node::set_execution_mode))
        .route("/api/cardano/sieve/emit", post(cardano_node::emit_sieve_signal))
        .route("/api/cardano/orders/stale", get(cardano_node::get_stale_orders))

        // Sovereign DEX Desk: hot wallets, chain-truth orders, native limit orders, charts
        .route("/api/wallet/list", get(desk::wallet_list))
        .route("/api/wallet/create", post(desk::wallet_create))
        .route("/api/wallet/import", post(desk::wallet_import))
        .route("/api/wallet/balance", get(desk::wallet_balance))
        .route("/api/wallet/sign", post(desk::wallet_sign))
        .route("/api/wallet/verify", post(desk::wallet_verify))
        .route("/api/wallet/set-active", post(desk::wallet_set_active))
        .route("/api/wallet/delete", post(desk::wallet_delete))
        .route("/api/wallet/receive", get(desk::wallet_receive))
        .route("/api/wallet/send", post(desk::wallet_send))
        .route("/api/wallet/policy", get(desk::wallet_policy_get).post(desk::wallet_policy_set))
        .route("/api/finance/orders/discover", get(desk::orders_discover))
        .route("/api/finance/orders/inspect", get(desk::orders_inspect))
        .route("/api/finance/orders/reclaim", post(desk::orders_reclaim))
        .route("/api/finance/limit/place", post(desk::limit_place))
        .route("/api/finance/chart", get(desk::chart))
        .route("/api/finance/market-dimensions", get(desk::market_dimensions))
        .route("/api/finance/cointegration", get(desk::cointegration))
        .route("/api/finance/desk/summary", get(desk::position_summary))
        .route("/api/finance/desk/feed", get(desk::desk_feed))
        .route("/api/finance/desk/plan/confirm", post(desk::plan_confirm))
        .route("/api/finance/desk/standing-order/revoke", post(desk::standing_order_revoke))

        // Sovereign Loan Fund & Lending (live data; POSTs token-guarded under /api/finance/)
        .route("/api/finance/fund/treasury", get(fund::treasury))
        .route("/api/finance/fund/state", get(fund::fund_state))
        .route("/api/finance/fund/yields", get(fund::yields))
        .route("/api/finance/fund/opportunities", get(fund::opportunities))
        .route("/api/finance/fund/policy", get(fund::policy))
        .route("/api/finance/fund/ledger", get(fund::ledger).post(fund::ledger_add))
        .route("/api/finance/fund/pools", get(fund::pools))
        .route("/api/finance/fund/polymarket", get(fund::polymarket))
        .route("/api/finance/fund/ladder", post(fund::ladder))
        .route("/api/finance/lending/underwrite", post(fund::underwrite))
        .route("/api/finance/lending/request", post(fund::request))
        .route("/api/finance/lending/book", get(fund::book))
        .route("/api/finance/lending/service", post(fund::service))
        .route("/api/finance/lending/cancel", post(fund::cancel))

        // Sovereign SDR Radio Lab & TrunkRecorder
        .route("/api/sdr/status", get(sdr::get_sdr_status))
        .route("/api/sdr/config", post(sdr::save_sdr_config))
        .route("/api/sdr/sync", post(sdr::sync_sdr_gateway))
        .route("/api/sdr/ingest", post(sdr::ingest_sdr_spool))
        .route("/api/sdr/transcribe", post(sdr::transcribe_sdr_spool))
        .route("/api/sdr/node", get(sdr::get_sdr_node_status))
        .route("/api/sdr/simulate", post(sdr::simulate_sdr_call))
        .route("/api/sdr/dossier", get(sdr::get_sdr_dossier))
        .route("/api/sdr/audio/:call_id", get(sdr::get_sdr_audio))

        // Remote GPU Tunneling
        .route("/api/tunnel/status", get(tunnel::get_tunnel_status))
        .route("/api/tunnel/connect", post(tunnel::connect_tunnel))
        .route("/api/tunnel/disconnect", post(tunnel::disconnect_tunnel))

        // Memories, Recall, Transcripts & Journal
        .route("/api/memories", get(memories::get_memories))
        .route("/api/runs", get(runs::list_runs))
        .route("/api/runs/:id", get(runs::get_run))
        .route("/api/transcripts", get(memories::get_transcripts))
        .route("/api/transcripts/:name", get(memories::get_transcript_content).delete(memories::delete_transcript))
        .route("/api/journal", get(memories::get_journal).post(memories::save_journal))
        .route("/api/sqlite/query", post(memories::query_sqlite))
        .route("/api/commands", get(memories::get_commands))
        .route("/api/research/config", get(memories::get_research_config).post(memories::save_research_config))

        // Google Open Knowledge Graph (OKF) & Codebase BM25 Navigator
        .route("/api/okf/graph", get(okf::get_okf_graph))
        .route("/api/okf/search", get(okf::search_okf_modules))
        .route("/api/okf/reindex", post(okf::reindex_okf))

        // Model Context Protocol (MCP)
        .route("/api/mcp/servers", get(mcp::get_mcp_servers))
        .route("/api/mcp/server/start", post(mcp::start_mcp_server))
        .route("/api/mcp/server/stop", post(mcp::stop_mcp_server))
        .route("/api/mcp/server/add", post(mcp::add_mcp_server))
        .route("/api/mcp/server/remove", post(mcp::remove_mcp_server))
        .route("/api/mcp/server/test", post(mcp::test_mcp_server_tool))
        .route("/api/mcp/catalog", get(mcp::get_mcp_catalog))
        .route("/api/mcp/catalog/install", post(mcp::install_mcp_catalog_server))
        .route("/api/mcp/server/create_custom", post(mcp::create_custom_mcp_server))

        // Streaming Fabric (SSE)
        .route("/api/stream/events", get(stream::stream_events))
        .route("/api/stream/task/:id", get(stream::stream_task_trajectory))

        // Interactive WebSocket Terminal
        .route("/api/terminal/ws", get(terminal::terminal_ws_handler))

        // Static Web Assets & SPA Fallback
        .nest_service("/static", ServeDir::new(&static_dir))
        .fallback_service(ServeDir::new(&static_dir))
        .layer(from_fn_with_state(state.clone(), crate::security::token_guard))
        .layer(from_fn(crate::security::origin_guard))
        .layer(cors)
        .layer(from_fn(crate::security::security_headers))
        .with_state(state)
}
