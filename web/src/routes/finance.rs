use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;
use tokio::process::Command;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct TradePayload {
    pub asset: String,
    pub action: String,
    pub amount: f64,
    pub rationale: Option<String>,
}

#[derive(Deserialize)]
pub struct BetPayload {
    pub market_id: String,
    pub bet: String,
    pub amount: f64,
    pub rationale: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct ReportPayload {
    pub user: Option<String>,
}

#[derive(Deserialize)]
pub struct ResearchBetPayload {
    pub market_id: String,
    pub question: Option<String>,
    pub yes_price: Option<f64>,
    pub bankroll: Option<f64>,
}

fn get_python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    }
}

pub async fn get_finance_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("trading_bot.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse trading bot JSON output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn execute_trade(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TradePayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("trading_bot.py");

    let asset = payload.asset.trim().to_uppercase();
    let action = payload.action.trim().to_uppercase();
    let amount = payload.amount.to_string();
    let rationale = payload.rationale.unwrap_or_else(|| "Operator manual execution via Craftsman Workbench".to_string());

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--trade")
        .arg(&action)
        .arg("--asset")
        .arg(&asset)
        .arg("--amount")
        .arg(&amount)
        .arg("--rationale")
        .arg(&rationale)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw_output": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn execute_bet(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<BetPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("trading_bot.py");

    let bet = payload.bet.trim().to_uppercase();
    let market_id = payload.market_id.trim();
    let amount = payload.amount.to_string();
    let rationale = payload.rationale.unwrap_or_else(|| "Operator manual execution via Craftsman Workbench".to_string());

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--bet-poly")
        .arg(&bet)
        .arg("--market-id")
        .arg(market_id)
        .arg("--amount")
        .arg(&amount)
        .arg("--rationale")
        .arg(&rationale)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw_output": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn reset_portfolio(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("trading_bot.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--reset-portfolio")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(_) => (
            StatusCode::OK,
            Json(json!({"status": "ok", "message": "Paper portfolio reset to $10,000 cash"})),
        ),
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn send_discord_report(
    State(state): State<Arc<AppState>>,
    payload: Option<Json<ReportPayload>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("trading_bot.py");
    let user = payload
        .and_then(|p| p.user.clone())
        .filter(|u| !u.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--send-dm")
        .arg("--user")
        .arg(&user)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            (
                StatusCode::OK,
                Json(json!({"status": "ok", "message": stdout.trim().to_string()})),
            )
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_finance_dossier(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let dossier_path = state.lodge_dir.join("dossiers").join("finance_intel.md");
    if !dossier_path.exists() {
        return Json(json!({
            "status": "ok",
            "content": "# Financial Intelligence & Market Signals\n\nNo reports recorded yet.",
            "path": dossier_path.to_string_lossy().to_string()
        }));
    }

    match fs::read_to_string(&dossier_path).await {
        Ok(content) => Json(json!({
            "status": "ok",
            "content": content,
            "path": dossier_path.to_string_lossy().to_string()
        })),
        Err(e) => Json(json!({"status": "error", "message": e.to_string()})),
    }
}

pub async fn research_bet(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResearchBetPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("finance_researcher.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script)
        .arg("--market-id")
        .arg(&payload.market_id)
        .current_dir(&state.lodge_dir);

    if let Some(q) = &payload.question {
        cmd.arg("--question").arg(q);
    }
    if let Some(yp) = payload.yes_price {
        cmd.arg("--yes-price").arg(yp.to_string());
    }
    if let Some(b) = payload.bankroll {
        cmd.arg("--bankroll").arg(b.to_string());
    }

    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse researcher JSON output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_wallets_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("wallet_status.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse wallet_status JSON output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn execute_sweep(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_trader.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--sweep")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw_output": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_sovereign_loop_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let status_path = state.lodge_dir.join(".george").join("wallets").join("sovereign_trading_status.json");
    if status_path.exists() {
        if let Ok(content) = tokio::fs::read_to_string(&status_path).await {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&content) {
                return (StatusCode::OK, Json(parsed));
            }
        }
    }
    (StatusCode::OK, Json(json!({
        "status": "pending",
        "summary": {
            "approved_loans_count": 0,
            "viable_flash_snipes_count": 0,
            "viable_polymarket_arb_count": 0
        },
        "message": "3-pillar sovereign trading loop initializing"
    })))
}

#[derive(Deserialize, Default)]
pub struct ArbitrageRunPayload {
    pub mode: Option<String>,
    pub pair: Option<String>,
    pub force_sim: Option<bool>,
}

pub async fn get_arbitrage_spreads(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_arbitrage_searcher.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse arbitrage spreads output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn run_arbitrage_graph(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ArbitrageRunPayload>,
) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_arbitrage_graph.sh");
    let mut cmd = Command::new("bash");
    cmd.arg(&script).arg("--json");

    if let Some(m) = &payload.mode {
        if m == "liquidate" {
            cmd.arg("--liquidate");
        } else if m == "execute" || m == "live" {
            cmd.arg("--execute");
        } else {
            cmd.arg("--dry-run");
        }
    } else {
        cmd.arg("--dry-run");
    }

    if let Some(p) = &payload.pair {
        let p_trimmed = p.trim();
        if !p_trimmed.is_empty() {
            cmd.arg("--pair").arg(p_trimmed);
        }
    }

    if payload.force_sim.unwrap_or(false) {
        cmd.arg("--force-sim");
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({
                        "status": "ok",
                        "raw_output": stdout.to_string(),
                        "stderr": String::from_utf8_lossy(&out.stderr).to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_arbitrage_history(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let log_path = state.lodge_dir.join("dossiers").join("finance").join("trades.jsonl");
    if log_path.exists() {
        if let Ok(content) = tokio::fs::read_to_string(&log_path).await {
            let mut entries: Vec<serde_json::Value> = Vec::new();
            for line in content.lines().rev() {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(line) {
                    entries.push(parsed);
                    if entries.len() >= 50 {
                        break;
                    }
                }
            }
            return (StatusCode::OK, Json(json!({"status": "ok", "history": entries})));
        }
    }
    (StatusCode::OK, Json(json!({"status": "ok", "history": []})))
}

#[derive(Deserialize, Default)]
pub struct MakerCorridorsQuery {
    pub capital: Option<f64>,
    pub horizon: Option<String>,
}

pub async fn get_maker_corridors(
    State(state): State<Arc<AppState>>,
    Query(query): Query<MakerCorridorsQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_market_maker.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("--json");

    if let Some(c) = query.capital {
        cmd.arg("--capital").arg(c.to_string());
    }

    if let Some(h) = &query.horizon {
        let h_trim = h.trim();
        if !h_trim.is_empty() {
            cmd.arg("--horizon").arg(h_trim);
        }
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse market maker output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_maker_volatility(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_volatility_engine.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse volatility engine output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_maker_orders(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_market_maker.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--orders")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse orders output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize, Default)]
pub struct MakerRunPayload {
    pub mode: Option<String>,
    pub pair: Option<String>,
    pub asset: Option<String>,
    pub capital: Option<f64>,
    pub horizon: Option<String>,
    pub direction: Option<String>,
    pub tokens: Option<f64>,
    #[allow(dead_code)]
    pub cost_basis: Option<f64>,
}

pub async fn run_maker_graph(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<MakerRunPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let is_sell = payload.direction.as_deref() == Some("sell");

    let mut cmd = if is_sell {
        let script = state.lodge_dir.join("lib").join("tools").join("cardano_market_maker.py");
        let mut c = Command::new(&py_bin);
        c.arg(&script)
            .arg("--place")
            .arg("--direction")
            .arg("sell")
            .arg("--json");

        let target_asset = payload.asset.as_deref().or(payload.pair.as_deref()).unwrap_or("IAG");
        c.arg("--asset").arg(target_asset);

        if let Some(t) = payload.tokens {
            c.arg("--tokens").arg(t.to_string());
        }
        c
    } else {
        let script = state.lodge_dir.join("lib").join("tools").join("cardano_market_maker_graph.sh");
        let mut c = Command::new("bash");
        c.arg(&script).arg("--json");

        if let Some(p) = &payload.pair {
            let p_trimmed = p.trim();
            if !p_trimmed.is_empty() {
                c.arg("--pair").arg(p_trimmed);
            }
        }
        if let Some(cap) = payload.capital {
            c.arg("--capital").arg(cap.to_string());
        }
        if let Some(h) = &payload.horizon {
            let h_trimmed = h.trim();
            if !h_trimmed.is_empty() {
                c.arg("--horizon").arg(h_trimmed);
            }
        }
        c
    };

    if let Some(m) = &payload.mode {
        if m == "execute" || m == "live" {
            cmd.arg("--execute");
        } else {
            cmd.arg("--dry-run");
        }
    } else {
        cmd.arg("--dry-run");
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({
                        "status": "ok",
                        "raw_output": stdout.to_string(),
                        "stderr": String::from_utf8_lossy(&out.stderr).to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct MakerSimulatePayload {
    pub asset: String,
    pub capital: Option<f64>,
    pub discount: Option<f64>,
    pub direction: Option<String>,
}

pub async fn simulate_maker_order(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<MakerSimulatePayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_market_maker.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script)
        .arg("--simulate")
        .arg("--asset")
        .arg(&payload.asset)
        .arg("--json");

    if let Some(c) = payload.capital {
        cmd.arg("--capital").arg(c.to_string());
    }
    if let Some(d) = payload.discount {
        cmd.arg("--discount").arg(d.to_string());
    }
    if let Some(dir) = &payload.direction {
        cmd.arg("--direction").arg(dir);
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse simulate output",
                        "raw": stdout.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_maker_active_cycles(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_maker_db.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--list")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "cycles": []})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_simulator_maker_cycles(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_maker_db.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--sim-list")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "cycles": []})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn reconcile_maker_orders(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_maker_db.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--reconcile")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse reconcile output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct SimulateFillPayload {
    pub asset: String,
}

pub async fn simulate_maker_fill(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SimulateFillPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_order_watcher.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--simulate-fill")
        .arg(&payload.asset)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse simulate-fill output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct LinkInventoryPayload {
    pub active_order_id: String,
    pub held_order_id: Option<String>,
}

pub async fn link_maker_inventory(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<LinkInventoryPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_maker_db.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script)
        .arg("--link-inventory")
        .arg("--active-id")
        .arg(&payload.active_order_id)
        .arg("--json");

    if let Some(ref held) = payload.held_order_id {
        if !held.is_empty() {
            cmd.arg("--held-id").arg(held);
        }
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse link-inventory output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct UnlinkInventoryPayload {
    pub active_order_id: String,
}

pub async fn unlink_maker_inventory(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<UnlinkInventoryPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_maker_db.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script)
        .arg("--unlink-inventory")
        .arg("--active-id")
        .arg(&payload.active_order_id)
        .arg("--json");

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse unlink-inventory output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct CancelMakerOrderPayload {
    pub order_id: Option<String>,
    pub tx_in: Option<String>,
    pub execute: Option<bool>,
}

pub async fn cancel_maker_order(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CancelMakerOrderPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_order_canceller.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script);

    if let Some(ref ord) = payload.order_id {
        if !ord.is_empty() {
            cmd.arg("--order-id").arg(ord);
        }
    }

    if let Some(ref tx) = payload.tx_in {
        if !tx.is_empty() {
            cmd.arg("--tx-in").arg(tx);
        }
    }

    if payload.execute.unwrap_or(false) {
        cmd.arg("--execute");
    }

    cmd.arg("--json");
    cmd.current_dir(&state.lodge_dir);

    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse cancel output",
                        "raw": stdout.to_string(),
                        "stderr": stderr.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ── Sovereign Stop Orders & Reactive Triggers (stop_triggers) ─────────────

#[derive(Deserialize)]
pub struct StopTriggersQuery {
    pub asset: Option<String>,
}

pub async fn get_stop_triggers(
    State(state): State<Arc<AppState>>,
    Query(query): Query<StopTriggersQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_stop_engine.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("list").arg("--json");

    if let Some(ref asset) = query.asset {
        if !asset.is_empty() {
            cmd.arg("--asset").arg(asset);
        }
    }

    cmd.current_dir(&state.lodge_dir);
    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "triggers": []})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct CancelStopTriggerPayload {
    pub trigger_id: String,
    pub prune_all: Option<bool>,
}

pub async fn cancel_stop_trigger(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CancelStopTriggerPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_stop_engine.py");

    let mut cmd = Command::new(&py_bin);
    if payload.prune_all.unwrap_or(false) || payload.trigger_id.to_lowercase() == "all" {
        cmd.arg(&script).arg("prune").arg("--all").arg("--json");
    } else {
        cmd.arg(&script).arg("cancel").arg(&payload.trigger_id).arg("--json");
    }

    cmd.current_dir(&state.lodge_dir);
    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"status": "ok", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ── Multi-Chain Portfolio, Ethereum USDC Rescue & Lending Handlers ─────────

#[derive(Deserialize)]
pub struct EthTransferPayload {
    pub amount: f64,
    pub to: String,
    pub execute: Option<bool>,
}

#[derive(Deserialize)]
pub struct MicroLoanSimulatePayload {
    pub asset: String,
    pub units: f64,
    pub req_usd: f64,
    pub apr: f64,
    pub days: i32,
    pub borrower: Option<String>,
}

#[derive(Deserialize)]
pub struct SqueezePairPayload {
    pub pair: String,
}

#[derive(Deserialize)]
pub struct CryptoResearchPayload {
    pub asset: String,
}

pub async fn get_multichain_portfolio(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sovereign_multichain_wallet.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse multichain portfolio", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn execute_eth_transfer(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<EthTransferPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("sovereign_multichain_wallet.py");

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script)
        .arg("--eth-transfer-usdc")
        .arg(payload.amount.to_string())
        .arg("--to")
        .arg(&payload.to);

    if payload.execute.unwrap_or(false) {
        cmd.arg("--execute");
    } else {
        cmd.arg("--dry-run");
    }

    cmd.current_dir(&state.lodge_dir);
    let output = cmd.output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({
                        "status": "error",
                        "message": "Failed to parse eth transfer output",
                        "raw": stdout.to_string(),
                        "stderr": stderr.to_string()
                    })),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_underwriting_scan(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("crosschain_lending_underwriter.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse underwriter scan", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn simulate_microloan(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<MicroLoanSimulatePayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("crosschain_lending_underwriter.py");

    let borrower = payload.borrower.unwrap_or_else(|| "addr1_borrower_community_microloan".to_string());

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--simulate")
        .arg("--asset")
        .arg(&payload.asset)
        .arg("--units")
        .arg(payload.units.to_string())
        .arg("--req-usd")
        .arg(payload.req_usd.to_string())
        .arg("--apr")
        .arg(payload.apr.to_string())
        .arg("--days")
        .arg(payload.days.to_string())
        .arg("--borrower")
        .arg(&borrower)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse microloan simulation", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_squeeze_scan(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("dex_liquidity_squeeze_detector.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse liquidity squeeze output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn audit_squeeze_pair(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SqueezePairPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("dex_liquidity_squeeze_detector.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--pair")
        .arg(&payload.pair)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse pair audit", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn research_crypto_asset(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CryptoResearchPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("finance_researcher.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--crypto")
        .arg(&payload.asset)
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse crypto research output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_trade_reactors(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("trade_event_trigger.sh");

    let output = Command::new(&script)
        .arg("status")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            (StatusCode::OK, Json(json!({"status": "ok", "output": stdout})))
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn run_stale_scan(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib").join("tools").join("trade_event_trigger.sh");

    let output = Command::new(&script)
        .arg("stale-scan")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            (StatusCode::OK, Json(json!({"status": "ok", "output": stdout})))
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

#[derive(Deserialize)]
pub struct ForecastHittingTimeRequest {
    pub asset: Option<String>,
    pub target_price: Option<f64>,
    pub amount: Option<f64>,
    pub direction: Option<String>,
    pub utxo: Option<String>,
    pub deadline_hours: Option<f64>,
    pub hypothetical: Option<bool>,
}

pub async fn forecast_hitting_time(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ForecastHittingTimeRequest>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("limit_order_forecaster.py");
    let bad = |m: &str| (StatusCode::BAD_REQUEST, Json(json!({"status": "error", "message": m})));

    let mut cmd = Command::new(&py_bin);
    cmd.arg(&script).arg("--json");

    if let Some(ref asset) = payload.asset {
        if asset.is_empty() || asset.len() > 16 || !asset.chars().all(|c| c.is_ascii_alphanumeric()) {
            return bad("invalid asset");
        }
        cmd.arg(format!("--asset={asset}"));
    }
    if let Some(price) = payload.target_price.filter(|p| *p > 0.0) {
        if !price.is_finite() {
            return bad("invalid target price");
        }
        cmd.arg(format!("--target-price={price}"));
    }
    if let Some(amount) = payload.amount.filter(|a| *a > 0.0) {
        if !amount.is_finite() {
            return bad("invalid amount");
        }
        cmd.arg(format!("--amount={amount}"));
    }
    if let Some(ref direction) = payload.direction {
        if direction != "buy" && direction != "sell" {
            return bad("direction must be buy or sell");
        }
        cmd.arg(format!("--direction={direction}"));
    }
    if let Some(ref utxo) = payload.utxo.as_ref().filter(|u| !u.is_empty()) {
        let ok = utxo.split_once('#').map_or(false, |(h, i)| {
            h.len() == 64 && h.chars().all(|c| c.is_ascii_hexdigit()) && !i.is_empty() && i.len() <= 4
                && i.chars().all(|c| c.is_ascii_digit())
        });
        if !ok {
            return bad("utxo must be <64 hex>#<index>");
        }
        cmd.arg(format!("--utxo={utxo}"));
    }
    if let Some(d) = payload.deadline_hours.filter(|d| *d > 0.0 && d.is_finite()) {
        cmd.arg(format!("--deadline={d}"));
    }
    if payload.hypothetical == Some(true) {
        cmd.arg("--hypothetical");
    }

    let output = cmd.current_dir(&state.lodge_dir).output().await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse forecaster output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Sovereign Crypto Tax & IRS Form 8949 Cost Basis Auditor
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
pub struct TaxQuery {
    pub year: Option<i32>,
}

#[derive(Deserialize, Default)]
pub struct TaxAuditPayload {
    pub year: Option<i32>,
}

pub async fn get_tax_status(
    State(state): State<Arc<AppState>>,
    Query(query): Query<TaxQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("crypto_tax_auditor.py");
    let year = query.year.unwrap_or(2026);

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--status")
        .arg("--year")
        .arg(year.to_string())
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse tax status output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn run_tax_audit(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TaxAuditPayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("crypto_tax_auditor.py");
    let year = payload.year.unwrap_or(2026);

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--audit")
        .arg("--year")
        .arg(year.to_string())
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse tax audit output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_tax_export(
    State(state): State<Arc<AppState>>,
    Query(query): Query<TaxQuery>,
) -> impl IntoResponse {
    let year = query.year.unwrap_or(2026);
    let csv_path = state.lodge_dir.join("dossiers").join("finance").join("tax").join(format!("irs_form_8949_{year}.csv"));

    if !csv_path.exists() {
        // Run audit on the fly if not exists
        let py_bin = get_python_bin(&state);
        let script = state.lodge_dir.join("lib").join("tools").join("crypto_tax_auditor.py");
        let _ = Command::new(&py_bin)
            .arg(&script)
            .arg("--audit")
            .arg("--year")
            .arg(year.to_string())
            .current_dir(&state.lodge_dir)
            .output()
            .await;
    }

    match fs::read_to_string(&csv_path).await {
        Ok(content) => (
            StatusCode::OK,
            [
                (axum::http::header::CONTENT_TYPE, "text/csv; charset=utf-8"),
                (axum::http::header::CONTENT_DISPOSITION, &format!("attachment; filename=\"irs_form_8949_{year}.csv\"")),
            ],
            content,
        ).into_response(),
        Err(e) => (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": format!("IRS Form 8949 CSV not found: {e}")})),
        ).into_response(),
    }
}

pub async fn backup_tax_keys(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("crypto_tax_auditor.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--backup-keys")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse backup keys output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

// ---------------------------------------------------------------------------
// Provenance Traversal & Staking Rewards Audit Handlers
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
pub struct ProvenanceQuery {
    pub address: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct StakingQuery {
    pub stake_address: Option<String>,
    pub year: Option<i32>,
}

#[derive(Deserialize, Default)]
pub struct TaxBundlePayload {
    pub year: Option<i32>,
}

pub async fn get_provenance_trace(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ProvenanceQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_provenance_engine.py");
    let target = query
        .address
        .filter(|a| !a.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--trace")
        .arg(&target)
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse provenance trace output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_staking_audit(
    State(state): State<Arc<AppState>>,
    Query(query): Query<StakingQuery>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_provenance_engine.py");
    let stake_key = query
        .stake_address
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    let year = query.year.unwrap_or(2026);

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--staking")
        .arg(&stake_key)
        .arg("--year")
        .arg(year.to_string())
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse staking rewards output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn get_schedule1_export(
    State(state): State<Arc<AppState>>,
    Query(query): Query<StakingQuery>,
) -> impl IntoResponse {
    let year = query.year.unwrap_or(2026);
    let csv_path = state.lodge_dir.join("dossiers").join("finance").join("tax").join(format!("irs_schedule_1_staking_{year}.csv"));

    if !csv_path.exists() {
        let py_bin = get_python_bin(&state);
        let script = state.lodge_dir.join("lib").join("tools").join("cardano_provenance_engine.py");
        let stake_key = query
            .stake_address
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| "default".to_string());
        let _ = Command::new(&py_bin)
            .arg(&script)
            .arg("--staking")
            .arg(&stake_key)
            .arg("--year")
            .arg(year.to_string())
            .arg("--export-schedule1")
            .current_dir(&state.lodge_dir)
            .output()
            .await;
    }

    match fs::read_to_string(&csv_path).await {
        Ok(content) => (
            StatusCode::OK,
            [
                (axum::http::header::CONTENT_TYPE, "text/csv; charset=utf-8"),
                (axum::http::header::CONTENT_DISPOSITION, &format!("attachment; filename=\"irs_schedule_1_staking_{year}.csv\"")),
            ],
            content,
        ).into_response(),
        Err(e) => (
            StatusCode::NOT_FOUND,
            Json(json!({"status": "error", "message": format!("IRS Schedule 1 CSV not found: {e}")})),
        ).into_response(),
    }
}

pub async fn get_wallet_library(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_provenance_engine.py");

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--library")
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse wallet library output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}

pub async fn run_tax_bundle(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TaxBundlePayload>,
) -> impl IntoResponse {
    let py_bin = get_python_bin(&state);
    let script = state.lodge_dir.join("lib").join("tools").join("cardano_provenance_engine.py");
    let year = payload.year.unwrap_or(2026);

    let output = Command::new(&py_bin)
        .arg(&script)
        .arg("--bundle")
        .arg("--year")
        .arg(year.to_string())
        .arg("--json")
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                (StatusCode::OK, Json(parsed))
            } else {
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "Failed to parse tax bundle output", "raw": stdout.to_string()})),
                )
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": e.to_string()})),
        ),
    }
}



