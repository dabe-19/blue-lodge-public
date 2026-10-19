//! Sovereign Loan Fund & Lending routes (treasury, fund ledger, yields, opportunities,
//! pool health, Polymarket scan, calibrated price ladders, underwriting, loan book, servicing).
//!
//! All routes live under `/api/finance/`, so every non-GET request passes
//! `security::token_guard` + `security::origin_guard`. User input is validated against
//! allow-lists and passed as `--flag=value` argv to the Python tools (never through a shell).
//! Transactions (loan disbursement, collateral return, liquidation) require
//! `execute: true` AND `confirm: "BROADCAST"`; otherwise servicing is a dry run.

use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use std::sync::Arc;

use super::desk::{bad, finite_pos, is_asset, is_cardano_addr, run_tool, wants_broadcast};
use crate::state::AppState;

const FUND: &[&str] = &["lib", "tools", "sovereign_fund.py"];
const LENDING: &[&str] = &["lib", "tools", "sovereign_lending.py"];
const POOLS: &[&str] = &["lib", "tools", "dex_liquidity_squeeze_detector.py"];
const POLY: &[&str] = &["lib", "tools", "polymarket_probability_arbitrageur.py"];
const FORECAST: &[&str] = &["lib", "tools", "limit_order_forecaster.py"];

const FUND_ASSETS: &[&str] = &["ADA", "USDC", "POL", "ETH", "BTC"];
const LEDGER_TYPES: &[&str] = &[
    "allocate", "deallocate", "profit_sweep", "repay_principal", "interest", "fee_income",
    "liquidation_proceeds", "writeoff", "expense",
];

fn is_loan_id(s: &str) -> bool {
    s.len() == 11 && s.starts_with("LN-") && s[3..].chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_lowercase())
}

fn clean_note(s: &str, max: usize) -> Option<String> {
    if s.len() > max || s.contains('\0') || s.starts_with('-') {
        return None;
    }
    Some(s.chars().filter(|c| !c.is_control()).collect())
}

pub async fn treasury(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["treasury".into(), "--json".into()], vec![], 150).await
}

pub async fn fund_state(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["state".into(), "--json".into()], vec![], 60).await
}

pub async fn yields(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["yields".into(), "--json".into()], vec![], 90).await
}

pub async fn opportunities(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["opportunities".into(), "--json".into()], vec![], 240).await
}

pub async fn ledger(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["ledger".into(), "--json".into()], vec![], 30).await
}

pub async fn policy(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, FUND, vec!["policy".into(), "--json".into()], vec![], 30).await
}

#[derive(Deserialize)]
pub struct LedgerReq {
    #[serde(rename = "type")]
    pub kind: String,
    pub asset: String,
    pub amount: f64,
    pub note: Option<String>,
    pub r#ref: Option<String>,
}

pub async fn ledger_add(State(state): State<Arc<AppState>>, Json(p): Json<LedgerReq>) -> impl IntoResponse {
    if !LEDGER_TYPES.contains(&p.kind.as_str()) {
        return bad("invalid ledger type (loan_out is recorded by the servicer only)");
    }
    if !FUND_ASSETS.contains(&p.asset.as_str()) || !finite_pos(p.amount) || p.amount > 1e9 {
        return bad("invalid asset or amount");
    }
    let note = match clean_note(p.note.as_deref().unwrap_or(""), 300) {
        Some(n) => n,
        None => return bad("invalid note"),
    };
    let rf = match clean_note(p.r#ref.as_deref().unwrap_or(""), 120) {
        Some(n) => n,
        None => return bad("invalid ref"),
    };
    run_tool(
        &state,
        FUND,
        vec![
            "ledger-add".into(),
            format!("--type={}", p.kind),
            format!("--asset={}", p.asset),
            format!("--amount={}", p.amount),
            format!("--note={note}"),
            format!("--ref={rf}"),
            "--actor=operator".into(),
            "--json".into(),
        ],
        vec![],
        60,
    )
    .await
}

pub async fn pools(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, POOLS, vec!["--json".into()], vec![], 180).await
}

pub async fn polymarket(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, POLY, vec!["--json".into()], vec![], 120).await
}

#[derive(Deserialize)]
pub struct LadderReq {
    pub asset: String,
    pub direction: String,
    pub amount: f64,
    pub span_pct: Option<f64>,
    pub rungs: Option<u32>,
}

pub async fn ladder(State(state): State<Arc<AppState>>, Json(p): Json<LadderReq>) -> impl IntoResponse {
    if !is_asset(&p.asset) || !(p.direction == "buy" || p.direction == "sell") || !finite_pos(p.amount) {
        return bad("invalid asset, direction or amount");
    }
    let span = p.span_pct.unwrap_or(4.0);
    let rungs = p.rungs.unwrap_or(11);
    if !(0.2..=25.0).contains(&span) || !(3..=31).contains(&rungs) {
        return bad("span_pct must be 0.2..25 and rungs 3..31");
    }
    run_tool(
        &state,
        FORECAST,
        vec![
            format!("--asset={}", p.asset),
            format!("--direction={}", p.direction),
            format!("--amount={}", p.amount),
            "--ladder".into(),
            format!("--span-pct={span}"),
            format!("--rungs={rungs}"),
        ],
        vec![],
        120,
    )
    .await
}

#[derive(Deserialize)]
pub struct UnderwriteReq {
    pub collateral: String,
    pub units: f64,
    pub principal: f64,
    pub term_days: u32,
    pub apr: f64,
    pub principal_asset: Option<String>,
    pub borrower: Option<String>,
    pub note: Option<String>,
}

fn underwrite_args(cmd: &str, p: &UnderwriteReq) -> Result<Vec<String>, &'static str> {
    if !is_asset(&p.collateral) {
        return Err("invalid collateral asset");
    }
    if !finite_pos(p.units) || !finite_pos(p.principal) || !(p.apr.is_finite() && p.apr >= 0.0 && p.apr <= 1000.0) {
        return Err("units/principal must be > 0 and apr 0..1000");
    }
    if !(1..=365).contains(&p.term_days) {
        return Err("term_days must be 1..365");
    }
    let pa = p.principal_asset.clone().unwrap_or_else(|| "ADA".into());
    if pa != "ADA" && pa != "USDC" {
        return Err("principal_asset must be ADA or USDC");
    }
    let mut a = vec![
        cmd.to_string(),
        format!("--collateral={}", p.collateral),
        format!("--units={}", p.units),
        format!("--principal={}", p.principal),
        format!("--term-days={}", p.term_days),
        format!("--apr={}", p.apr),
        format!("--principal-asset={pa}"),
        "--actor=operator".into(),
    ];
    if let Some(b) = p.borrower.as_deref().filter(|b| !b.is_empty()) {
        if !is_cardano_addr(b) {
            return Err("borrower must be a Cardano address");
        }
        a.push(format!("--borrower={b}"));
    }
    if let Some(n) = p.note.as_deref().filter(|n| !n.is_empty()) {
        match clean_note(n, 300) {
            Some(n) => a.push(format!("--note={n}")),
            None => return Err("invalid note"),
        }
    }
    Ok(a)
}

pub async fn underwrite(State(state): State<Arc<AppState>>, Json(p): Json<UnderwriteReq>) -> impl IntoResponse {
    match underwrite_args("underwrite", &p) {
        Ok(a) => run_tool(&state, LENDING, a, vec![], 150).await,
        Err(e) => bad(e),
    }
}

pub async fn request(State(state): State<Arc<AppState>>, Json(p): Json<UnderwriteReq>) -> impl IntoResponse {
    if p.borrower.as_deref().map(|b| b.is_empty()).unwrap_or(true) {
        return bad("borrower address is required to open a loan request");
    }
    match underwrite_args("request", &p) {
        Ok(a) => run_tool(&state, LENDING, a, vec![], 150).await,
        Err(e) => bad(e),
    }
}

pub async fn book(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    run_tool(&state, LENDING, vec!["book".into()], vec![], 30).await
}

#[derive(Deserialize)]
pub struct ServiceReq {
    pub loan_id: Option<String>,
    pub execute: Option<bool>,
    pub confirm: Option<String>,
}

pub async fn service(State(state): State<Arc<AppState>>, Json(p): Json<ServiceReq>) -> impl IntoResponse {
    let live = match wants_broadcast(p.execute, &p.confirm) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let mut a = vec!["service".to_string(), "--actor=operator".into()];
    if let Some(id) = p.loan_id.as_deref().filter(|s| !s.is_empty()) {
        if !is_loan_id(id) {
            return bad("invalid loan id");
        }
        a.push(format!("--loan-id={id}"));
    }
    if live {
        a.push("--execute".into());
    }
    run_tool(&state, LENDING, a, vec![], 400).await
}

#[derive(Deserialize)]
pub struct CancelReq {
    pub loan_id: String,
}

pub async fn cancel(State(state): State<Arc<AppState>>, Json(p): Json<CancelReq>) -> impl IntoResponse {
    if !is_loan_id(&p.loan_id) {
        return bad("invalid loan id");
    }
    run_tool(
        &state,
        LENDING,
        vec!["cancel".into(), format!("--loan-id={}", p.loan_id), "--actor=operator".into()],
        vec![],
        30,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loan_id_validation() {
        assert!(is_loan_id("LN-0A1B2C3D"));
        assert!(!is_loan_id("LN-0a1b2c3d"));
        assert!(!is_loan_id("LN-0A1B2C3"));
        assert!(!is_loan_id("--execute"));
    }

    #[test]
    fn note_rejects_option_injection() {
        assert!(clean_note("--execute", 300).is_none());
        assert_eq!(clean_note("rent\nmoney", 300).as_deref(), Some("rentmoney"));
    }

    #[test]
    fn underwrite_args_validate() {
        let mut p = UnderwriteReq {
            collateral: "SNEK".into(),
            units: 100.0,
            principal: 10.0,
            term_days: 14,
            apr: 12.0,
            principal_asset: None,
            borrower: None,
            note: None,
        };
        assert!(underwrite_args("underwrite", &p).is_ok());
        p.collateral = "SNEK;rm".into();
        assert!(underwrite_args("underwrite", &p).is_err());
        p.collateral = "SNEK".into();
        p.borrower = Some("0xdeadbeef".into());
        assert!(underwrite_args("underwrite", &p).is_err());
    }
}
