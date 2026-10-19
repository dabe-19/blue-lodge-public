//! Sovereign DEX Desk routes: hot-wallet management, on-chain order lifecycle,
//! native Minswap V2 limit placement, and chart payloads.
//!
//! Security model
//! * Every `/api/wallet/*` route and every non-GET `/api/finance/*` route is behind
//!   `security::token_guard` (X-Lodge-Token) and `security::origin_guard`.
//! * Secrets (passphrase, imported key material) reach the Python child ONLY via
//!   environment variables (`LODGE_WALLET_PASSPHRASE`, `LODGE_WALLET_SECRET`), which the
//!   child pops immediately. They are never placed in argv, logs, or responses.
//! * All user-controlled argv values are validated against strict allow-lists and passed
//!   in `--flag=value` form so a value can never be parsed as an option.
//! * Broadcasting a mainnet transaction requires `execute: true` AND
//!   `confirm: "BROADCAST"`; otherwise the request is a dry run (build + evaluate only).

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;

use crate::state::AppState;

const CONFIRM_WORD: &str = "BROADCAST";

fn python_bin(state: &AppState) -> String {
    let venv_py = state.lodge_dir.join(".venv").join("bin").join("python");
    if venv_py.exists() {
        venv_py.to_string_lossy().to_string()
    } else {
        "python3".to_string()
    }
}

pub(crate) fn bad(msg: &str) -> (StatusCode, Json<Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({"status": "error", "message": msg})))
}

/// Runs a repo Python tool and returns its JSON stdout. `secrets` are passed via env only.
pub(crate) async fn run_tool(
    state: &AppState,
    script: &[&str],
    args: Vec<String>,
    secrets: Vec<(&'static str, String)>,
    timeout_s: u64,
) -> (StatusCode, Json<Value>) {
    let mut path = state.lodge_dir.clone();
    for p in script {
        path = path.join(p);
    }
    let mut cmd = Command::new(python_bin(state));
    cmd.arg(&path)
        .args(&args)
        .current_dir(&state.lodge_dir)
        .env("PYTHONPATH", &state.lodge_dir)
        .env_remove("LODGE_WALLET_PASSPHRASE")
        .env_remove("LODGE_WALLET_SECRET")
        .kill_on_drop(true);
    for (k, v) in secrets {
        if !v.is_empty() {
            cmd.env(k, v);
        }
    }
    let fut = cmd.output();
    match tokio::time::timeout(Duration::from_secs(timeout_s), fut).await {
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(json!({"status": "error", "message": format!("tool timed out after {timeout_s}s")})),
        ),
        Ok(Err(e)) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"status": "error", "message": format!("spawn failed: {e}")})),
        ),
        Ok(Ok(out)) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            // Tools print a single JSON document; tolerate leading log lines.
            let start = stdout.find('{').unwrap_or(0);
            match serde_json::from_str::<Value>(stdout[start..].trim()) {
                Ok(v) => {
                    let code = match v.get("status").and_then(|s| s.as_str()) {
                        Some("error") => StatusCode::UNPROCESSABLE_ENTITY,
                        Some("denied") => StatusCode::FORBIDDEN,
                        _ => StatusCode::OK,
                    };
                    (code, Json(v))
                }
                // Do not echo stderr/stdout: it may contain tracebacks with local paths.
                Err(_) => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"status": "error", "message": "tool returned non-JSON output"})),
                ),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Validators (allow-lists; no regex dependency)
// ---------------------------------------------------------------------------

pub(crate) fn is_asset(s: &str) -> bool {
    (1..=16).contains(&s.len()) && s.chars().all(|c| c.is_ascii_alphanumeric())
}

fn is_wallet_id(s: &str) -> bool {
    (1..=64).contains(&s.len())
        && !s.starts_with('-')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn is_utxo(s: &str) -> bool {
    match s.split_once('#') {
        Some((h, i)) => {
            h.len() == 64
                && h.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
                && (1..=4).contains(&i.len())
                && i.chars().all(|c| c.is_ascii_digit())
        }
        None => false,
    }
}

fn is_label(s: &str) -> bool {
    (1..=48).contains(&s.len())
        && !s.starts_with('-')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || " -_.".contains(c))
}

fn is_chain(s: &str) -> bool {
    s == "cardano" || s == "evm"
}

pub(crate) fn is_cardano_addr(s: &str) -> bool {
    (s.starts_with("addr1") || s.starts_with("addr_test1"))
        && (50..=130).contains(&s.len())
        && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
}

fn is_evm_addr(s: &str) -> bool {
    s.len() == 42 && s.starts_with("0x") && s[2..].chars().all(|c| c.is_ascii_hexdigit())
}

fn is_hex(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.chars().all(|c| c.is_ascii_hexdigit())
}

pub(crate) fn finite_pos(x: f64) -> bool {
    x.is_finite() && x > 0.0
}

pub(crate) fn wants_broadcast(execute: Option<bool>, confirm: &Option<String>) -> Result<bool, (StatusCode, Json<Value>)> {
    if execute.unwrap_or(false) {
        if confirm.as_deref() == Some(CONFIRM_WORD) {
            Ok(true)
        } else {
            Err(bad("broadcast requires confirm: \"BROADCAST\""))
        }
    } else {
        Ok(false)
    }
}

const KEYSTORE: &[&str] = &["lib", "tools", "wallet", "keystore.py"];
const ORDERS: &[&str] = &["lib", "tools", "cardano_orders.py"];
const MINSWAP: &[&str] = &["lib", "tools", "minswap_v2.py"];
const CHART: &[&str] = &["lib", "tools", "chart_data.py"];
const MARKET_DIMENSIONS: &[&str] = &["lib", "tools", "cardano_market_dimensions.py"];
const COINTEGRATION: &[&str] = &["lib", "tools", "cardano_cointegration.py"];
const DESK_SUMMARY: &[&str] = &["lib", "tools", "cardano_desk_summary.py"];
const DESK_FEED: &[&str] = &["lib", "tools", "trading", "desk_feed.py"];
const AGENT_TOOLS: &[&str] = &["lib", "tools", "trading", "agent_tools.py"];

// ---------------------------------------------------------------------------
// Wallet
// ---------------------------------------------------------------------------

pub async fn wallet_list(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, KEYSTORE, vec!["list".into()], vec![], 30).await
}

#[derive(Deserialize)]
pub struct CreateReq {
    pub chain: String,
    pub label: String,
    pub words: Option<u32>,
    pub passphrase: String,
}

pub async fn wallet_create(State(state): State<Arc<AppState>>, Json(p): Json<CreateReq>) -> impl IntoResponse {
    if !is_chain(&p.chain) || !is_label(&p.label) {
        return bad("invalid chain or label");
    }
    let words = p.words.unwrap_or(24);
    if ![12u32, 15, 24].contains(&words) {
        return bad("words must be 12, 15 or 24");
    }
    run_tool(
        &state,
        KEYSTORE,
        vec!["create".into(), format!("--chain={}", p.chain), format!("--label={}", p.label), format!("--words={words}")],
        vec![("LODGE_WALLET_PASSPHRASE", p.passphrase)],
        60,
    )
    .await
}

#[derive(Deserialize)]
pub struct ImportReq {
    pub chain: String,
    pub label: String,
    pub kind: String,
    pub secret: String,
    pub passphrase: String,
}

pub async fn wallet_import(State(state): State<Arc<AppState>>, Json(p): Json<ImportReq>) -> impl IntoResponse {
    if !is_chain(&p.chain) || !is_label(&p.label) {
        return bad("invalid chain or label");
    }
    if !["mnemonic", "privkey", "cardano_skey_cbor"].contains(&p.kind.as_str()) {
        return bad("kind must be mnemonic | privkey | cardano_skey_cbor");
    }
    if p.secret.is_empty() || p.secret.len() > 1024 {
        return bad("secret missing or too long");
    }
    run_tool(
        &state,
        KEYSTORE,
        vec!["import".into(), format!("--chain={}", p.chain), format!("--label={}", p.label), format!("--kind={}", p.kind)],
        vec![("LODGE_WALLET_PASSPHRASE", p.passphrase), ("LODGE_WALLET_SECRET", p.secret)],
        60,
    )
    .await
}

#[derive(Deserialize)]
pub struct IdQuery {
    pub id: String,
}

pub async fn wallet_balance(State(state): State<Arc<AppState>>, Query(q): Query<IdQuery>) -> impl IntoResponse {
    if !is_wallet_id(&q.id) {
        return bad("invalid wallet id");
    }
    run_tool(&state, KEYSTORE, vec!["balance".into(), format!("--id={}", q.id)], vec![], 45).await
}

#[derive(Deserialize)]
pub struct SignReq {
    pub id: String,
    pub message: String,
    pub passphrase: Option<String>,
}

pub async fn wallet_sign(State(state): State<Arc<AppState>>, Json(p): Json<SignReq>) -> impl IntoResponse {
    if !is_wallet_id(&p.id) {
        return bad("invalid wallet id");
    }
    if p.message.is_empty() || p.message.len() > 4096 || p.message.contains('\0') {
        return bad("message must be 1..4096 chars");
    }
    run_tool(
        &state,
        KEYSTORE,
        vec!["sign".into(), format!("--id={}", p.id), format!("--message={}", p.message)],
        vec![("LODGE_WALLET_PASSPHRASE", p.passphrase.unwrap_or_default())],
        30,
    )
    .await
}

#[derive(Deserialize)]
pub struct VerifyReq {
    pub chain: String,
    pub signature: Value,
    pub message: Option<String>,
    pub address: Option<String>,
}

pub async fn wallet_verify(State(state): State<Arc<AppState>>, Json(p): Json<VerifyReq>) -> impl IntoResponse {
    if !is_chain(&p.chain) {
        return bad("invalid chain");
    }
    let sig = match &p.signature {
        Value::String(s) => s.clone(),
        Value::Object(_) => p.signature.to_string(),
        _ => return bad("signature must be a string or COSE object"),
    };
    if sig.is_empty() || sig.len() > 8192 || sig.contains('\0') {
        return bad("signature too long");
    }
    let mut args = vec!["verify".into(), format!("--chain={}", p.chain), format!("--signature={sig}")];
    if let Some(m) = p.message.filter(|m| !m.is_empty()) {
        if m.len() > 4096 || m.contains('\0') {
            return bad("message too long");
        }
        args.push(format!("--message={m}"));
    }
    if let Some(a) = p.address.filter(|a| !a.is_empty()) {
        if !(is_cardano_addr(&a) || is_evm_addr(&a)) {
            return bad("invalid address");
        }
        args.push(format!("--address={a}"));
    }
    run_tool(&state, KEYSTORE, args, vec![], 30).await
}

#[derive(Deserialize)]
pub struct IdReq {
    pub id: String,
    pub passphrase: Option<String>,
}

pub async fn wallet_set_active(State(state): State<Arc<AppState>>, Json(p): Json<IdReq>) -> impl IntoResponse {
    if !is_wallet_id(&p.id) {
        return bad("invalid wallet id");
    }
    run_tool(&state, KEYSTORE, vec!["set-active".into(), format!("--id={}", p.id)], vec![], 30).await
}

pub async fn wallet_delete(State(state): State<Arc<AppState>>, Json(p): Json<IdReq>) -> impl IntoResponse {
    if !is_wallet_id(&p.id) {
        return bad("invalid wallet id");
    }
    run_tool(
        &state,
        KEYSTORE,
        vec!["delete".into(), format!("--id={}", p.id)],
        vec![("LODGE_WALLET_PASSPHRASE", p.passphrase.unwrap_or_default())],
        30,
    )
    .await
}

#[derive(Deserialize)]
pub struct ReceiveQuery {
    pub id: Option<String>,
    pub chain: Option<String>,
    pub amount: Option<f64>,
    pub token: Option<String>,
    pub memo: Option<String>,
    pub check_incoming: Option<bool>,
}

pub async fn wallet_receive(State(state): State<Arc<AppState>>, Query(q): Query<ReceiveQuery>) -> impl IntoResponse {
    let mut args = vec!["receive".into()];
    if let Some(id) = q.id.filter(|s| !s.is_empty()) {
        if !is_wallet_id(&id) {
            return bad("invalid wallet id");
        }
        args.push(format!("--id={id}"));
    }
    if let Some(ch) = q.chain.filter(|s| !s.is_empty()) {
        if !["cardano", "ada", "evm", "polygon", "pol", "ethereum", "eth", "btc", "sol"].contains(&ch.as_str()) {
            return bad("invalid chain");
        }
        args.push(format!("--chain={ch}"));
    }
    if let Some(amt) = q.amount {
        if finite_pos(amt) && amt <= 1_000_000_000.0 {
            args.push(format!("--amount={amt}"));
        }
    }
    if let Some(tok) = q.token.filter(|s| !s.is_empty()) {
        if !is_asset(&tok.replace('.', "")) {
            return bad("invalid token symbol");
        }
        args.push(format!("--token={tok}"));
    }
    if let Some(memo) = q.memo.filter(|s| !s.is_empty()) {
        if memo.len() > 160 || memo.contains('\0') {
            return bad("memo too long");
        }
        args.push(format!("--memo={memo}"));
    }
    if q.check_incoming.unwrap_or(false) {
        args.push("--check-incoming".into());
    }
    run_tool(&state, KEYSTORE, args, vec![], 30).await
}

#[derive(Deserialize)]
pub struct SendReq {
    pub id: String,
    pub to: String,
    pub ada: f64,
    pub chain: Option<String>,
    pub token: Option<String>,
    pub token_amount: Option<f64>,
    pub message: Option<String>,
    pub asset_unit: Option<String>,
    pub asset_qty: Option<u64>,
    pub passphrase: Option<String>,
    pub execute: Option<bool>,
    pub confirm: Option<String>,
}

pub async fn wallet_send(State(state): State<Arc<AppState>>, Json(p): Json<SendReq>) -> impl IntoResponse {
    if !is_wallet_id(&p.id) || !(is_cardano_addr(&p.to) || is_evm_addr(&p.to)) {
        return bad("invalid wallet id or destination address");
    }
    if !finite_pos(p.ada) || p.ada > 1_000_000.0 {
        return bad("amount must be a positive number");
    }
    let execute = match wants_broadcast(p.execute, &p.confirm) {
        Ok(b) => b,
        Err(e) => return e,
    };
    let mut args = vec![
        "send".into(),
        format!("--id={}", p.id),
        format!("--to={}", p.to),
        format!("--ada={}", p.ada),
        "--actor=operator".into(),
    ];
    if let Some(ch) = p.chain.filter(|s| !s.is_empty()) {
        if !["cardano", "ada", "evm", "polygon", "pol", "ethereum", "eth"].contains(&ch.as_str()) {
            return bad("invalid chain");
        }
        args.push(format!("--chain={ch}"));
    }
    if let Some(tok) = p.token.filter(|s| !s.is_empty()) {
        if !is_asset(&tok.replace('.', "")) {
            return bad("invalid token symbol");
        }
        args.push(format!("--token={tok}"));
        if let Some(ta) = p.token_amount {
            if finite_pos(ta) {
                args.push(format!("--token-amount={ta}"));
            }
        }
    }
    if let Some(msg) = p.message.filter(|s| !s.is_empty()) {
        if msg.len() > 256 || msg.contains('\0') {
            return bad("message must be <= 256 chars");
        }
        args.push(format!("--message={msg}"));
    }
    if let Some(u) = p.asset_unit.filter(|u| !u.is_empty()) {
        if !is_hex(&u, 120) || u.len() < 56 {
            return bad("asset_unit must be policy_id+hex asset name");
        }
        args.push(format!("--asset-unit={u}"));
        args.push(format!("--asset-qty={}", p.asset_qty.unwrap_or(0)));
    }
    if execute {
        args.push("--execute".into());
    }
    run_tool(&state, KEYSTORE, args, vec![("LODGE_WALLET_PASSPHRASE", p.passphrase.unwrap_or_default())], 120).await
}

#[derive(Deserialize)]
pub struct PolicyReq {
    pub policy: Value,
}

pub async fn wallet_policy_get(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, KEYSTORE, vec!["policy".into()], vec![], 20).await
}

pub async fn wallet_policy_set(State(state): State<Arc<AppState>>, Json(p): Json<PolicyReq>) -> impl IntoResponse {
    if !p.policy.is_object() {
        return bad("policy must be a JSON object");
    }
    let doc = p.policy.to_string();
    if doc.len() > 8192 {
        return bad("policy document too large");
    }
    run_tool(&state, KEYSTORE, vec!["policy".into(), format!("--set={doc}")], vec![], 20).await
}

// ---------------------------------------------------------------------------
// Orders (chain truth)
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct DiscoverQuery {
    pub open_only: Option<bool>,
    pub lookback: Option<u32>,
}

pub async fn orders_discover(State(state): State<Arc<AppState>>, Query(q): Query<DiscoverQuery>) -> impl IntoResponse {
    let lb = q.lookback.unwrap_or(30).clamp(5, 100);
    let mut args = vec!["discover".into(), format!("--lookback={lb}")];
    if q.open_only.unwrap_or(false) {
        args.push("--open-only".into());
    }
    run_tool(&state, ORDERS, args, vec![], 180).await
}

#[derive(Deserialize)]
pub struct UtxoQuery {
    pub utxo: String,
}

pub async fn orders_inspect(State(state): State<Arc<AppState>>, Query(q): Query<UtxoQuery>) -> impl IntoResponse {
    if !is_utxo(&q.utxo) {
        return bad("utxo must be <64 hex>#<index>");
    }
    run_tool(&state, ORDERS, vec!["inspect".into(), q.utxo], vec![], 45).await
}

#[derive(Deserialize)]
pub struct ReclaimReq {
    pub utxo: String,
    pub wallet_id: Option<String>,
    pub passphrase: Option<String>,
    pub execute: Option<bool>,
    pub confirm: Option<String>,
}

pub async fn orders_reclaim(State(state): State<Arc<AppState>>, Json(p): Json<ReclaimReq>) -> impl IntoResponse {
    if !is_utxo(&p.utxo) {
        return bad("utxo must be <64 hex>#<index>");
    }
    let execute = match wants_broadcast(p.execute, &p.confirm) {
        Ok(b) => b,
        Err(e) => return e,
    };
    let mut args = vec!["reclaim".into(), p.utxo.clone(), "--no-wait".into(), "--actor=operator".into()];
    if let Some(w) = p.wallet_id.filter(|w| !w.is_empty()) {
        if !is_wallet_id(&w) {
            return bad("invalid wallet id");
        }
        args.push(format!("--wallet-id={w}"));
    }
    if execute {
        args.push("--execute".into());
    }
    run_tool(&state, ORDERS, args, vec![("LODGE_WALLET_PASSPHRASE", p.passphrase.unwrap_or_default())], 150).await
}

// ---------------------------------------------------------------------------
// Native Minswap V2 limit orders
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct LimitReq {
    pub asset: String,
    pub direction: String,
    pub amount: f64,
    pub price: f64,
    pub wallet_id: Option<String>,
    pub passphrase: Option<String>,
    pub execute: Option<bool>,
    pub confirm: Option<String>,
}

pub async fn limit_place(State(state): State<Arc<AppState>>, Json(p): Json<LimitReq>) -> impl IntoResponse {
    if !is_asset(&p.asset) || !(p.direction == "buy" || p.direction == "sell") {
        return bad("invalid asset or direction");
    }
    if !finite_pos(p.amount) || !finite_pos(p.price) {
        return bad("amount and price must be positive");
    }
    let execute = match wants_broadcast(p.execute, &p.confirm) {
        Ok(b) => b,
        Err(e) => return e,
    };
    let mut args = vec![
        format!("--asset={}", p.asset),
        format!("--direction={}", p.direction),
        format!("--amount={}", p.amount),
        format!("--price={}", p.price),
        "--actor=operator".into(),
    ];
    if let Some(w) = p.wallet_id.filter(|w| !w.is_empty()) {
        if !is_wallet_id(&w) {
            return bad("invalid wallet id");
        }
        args.push(format!("--wallet-id={w}"));
    }
    if execute {
        args.push("--execute".into());
    }
    run_tool(&state, MINSWAP, args, vec![("LODGE_WALLET_PASSPHRASE", p.passphrase.unwrap_or_default())], 120).await
}

// ---------------------------------------------------------------------------
// Chart payload
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct ChartQuery {
    pub asset: String,
    pub timeframe: Option<String>,
    pub aggregate: Option<u32>,
    pub bars: Option<u32>,
}

pub async fn chart(State(state): State<Arc<AppState>>, Query(q): Query<ChartQuery>) -> impl IntoResponse {
    if !is_asset(&q.asset) {
        return bad("invalid asset");
    }
    let tf = q.timeframe.unwrap_or_else(|| "hour".into());
    if !["minute", "hour", "day"].contains(&tf.as_str()) {
        return bad("timeframe must be minute|hour|day");
    }
    let agg = q.aggregate.unwrap_or(1);
    let allowed = match tf.as_str() {
        "minute" => [1u32, 5, 15].contains(&agg),
        "hour" => [1u32, 4, 12].contains(&agg),
        _ => agg == 1,
    };
    if !allowed {
        return bad("unsupported aggregate for timeframe");
    }
    let bars = q.bars.unwrap_or(500).clamp(50, 1000);
    run_tool(
        &state,
        CHART,
        vec![format!("--asset={}", q.asset), format!("--timeframe={tf}"), format!("--aggregate={agg}"), format!("--bars={bars}"), "--json".into()],
        vec![],
        60,
    )
    .await
}

// ---------------------------------------------------------------------------
// Market Dimensions & Cointegration
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct MarketDimensionsQuery {
    pub asset: String,
    pub size: Option<f64>,
    pub direction: Option<String>,
}

pub async fn market_dimensions(
    State(state): State<Arc<AppState>>,
    Query(q): Query<MarketDimensionsQuery>,
) -> impl IntoResponse {
    if !is_asset(&q.asset) {
        return bad("invalid asset");
    }
    let size = q.size.unwrap_or(50.0);
    let dir = q.direction.unwrap_or_else(|| "buy".into());
    run_tool(
        &state,
        MARKET_DIMENSIONS,
        vec![
            format!("--asset={}", q.asset),
            format!("--size={size}"),
            format!("--dir={dir}"),
            "--json".into(),
        ],
        vec![],
        30,
    )
    .await
}

#[derive(Deserialize)]
pub struct CointegrationQuery {
    pub asset_a: Option<String>,
    pub asset_b: Option<String>,
}

pub async fn cointegration(
    State(state): State<Arc<AppState>>,
    Query(q): Query<CointegrationQuery>,
) -> impl IntoResponse {
    let mut args = vec!["--json".to_string()];
    if let (Some(a), Some(b)) = (q.asset_a, q.asset_b) {
        if !is_asset(&a) || !is_asset(&b) {
            return bad("invalid asset symbols");
        }
        args.push("--pair".into());
        args.push(a);
        args.push(b);
    } else {
        args.push("--scan".into());
    }

    run_tool(&state, COINTEGRATION, args, vec![], 45).await
}

#[derive(Deserialize)]
pub struct PositionSummaryQuery {
    pub asset: Option<String>,
}

pub async fn position_summary(
    State(state): State<Arc<AppState>>,
    Query(q): Query<PositionSummaryQuery>,
) -> impl IntoResponse {
    let asset = q.asset.unwrap_or_else(|| "SNEK".to_string()).to_uppercase();
    if !is_asset(&asset) {
        return bad("invalid asset symbol");
    }
    run_tool(&state, DESK_SUMMARY, vec![asset, "--json".into()], vec![], 30).await
}

// ---------------------------------------------------------------------------
// Trading Desk aggregate feed & plan execution (P5)
// ---------------------------------------------------------------------------

pub(crate) fn is_plan_id(s: &str) -> bool {
    s.len() == 8 && s.starts_with("P-") && s[2..].chars().all(|c| c.is_ascii_hexdigit())
}

pub(crate) fn is_envelope_id(s: &str) -> bool {
    s.len() == 9 && s.starts_with("SO-") && s[3..].chars().all(|c| c.is_ascii_hexdigit())
}

pub async fn desk_feed(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, DESK_FEED, vec![], vec![], 30).await
}

#[derive(Deserialize)]
pub struct PlanConfirmReq {
    pub plan_id: String,
}

pub async fn plan_confirm(
    State(state): State<Arc<AppState>>,
    Json(p): Json<PlanConfirmReq>,
) -> impl IntoResponse {
    if !is_plan_id(&p.plan_id) {
        return bad("invalid plan id format, must be P-XXXXXX");
    }
    let secret_path = state.lodge_dir.join(".george").join("secrets").join("trading_confirm.key");
    let secret = match tokio::fs::read_to_string(&secret_path).await {
        Ok(s) if !s.trim().is_empty() => s.trim().to_string(),
        _ => {
            let _ = run_tool(&state, AGENT_TOOLS, vec!["init-web-secret".into()], vec![], 10).await;
            tokio::fs::read_to_string(&secret_path)
                .await
                .unwrap_or_default()
                .trim()
                .to_string()
        }
    };
    run_tool(
        &state,
        AGENT_TOOLS,
        vec!["confirm".into(), format!("--plan={}", p.plan_id), "--via=web".into()],
        vec![("TRADING_WEB_CONFIRM_SECRET", secret)],
        60,
    )
    .await
}

#[derive(Deserialize)]
pub struct StandingOrderRevokeReq {
    pub envelope_id: String,
}

pub async fn standing_order_revoke(
    State(state): State<Arc<AppState>>,
    Json(p): Json<StandingOrderRevokeReq>,
) -> impl IntoResponse {
    if !is_envelope_id(&p.envelope_id) {
        return bad("invalid envelope id format, must be SO-XXXXXX");
    }
    run_tool(
        &state,
        AGENT_TOOLS,
        vec!["standing-order".into(), "revoke".into(), format!("--id={}", p.envelope_id)],
        vec![],
        30,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validators_reject_option_injection_and_garbage() {
        assert!(is_utxo("493a7e1a2af4799010eafed9f36b3de742bd0a74e1ec63ebf8726069f88da9df#0"));
        assert!(!is_utxo("--execute"));
        assert!(!is_utxo("493A7E1A2AF4799010EAFED9F36B3DE742BD0A74E1EC63EBF8726069F88DA9DF#0"));
        assert!(!is_wallet_id("-x"));
        assert!(is_wallet_id("agent-hot"));
        assert!(!is_label("--execute"));
        assert!(!is_asset("IAG;rm"));
        assert!(is_cardano_addr("addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"));
        assert!(!is_cardano_addr("addr1 --execute"));
        assert!(wants_broadcast(Some(true), &None).is_err());
        assert_eq!(wants_broadcast(Some(true), &Some("BROADCAST".into())).unwrap(), true);
        assert_eq!(wants_broadcast(None, &None).unwrap(), false);
        assert!(is_plan_id("P-92426D"));
        assert!(!is_plan_id("P-9242"));
        assert!(!is_plan_id("P-92426D;rm"));
        assert!(is_envelope_id("SO-123456"));
        assert!(!is_envelope_id("SO-123"));
    }
}
