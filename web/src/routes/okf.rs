use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::state::AppState;

#[derive(Deserialize)]
pub struct OkfSearchQuery {
    pub q: Option<String>,
    pub subsystem: Option<String>,
    pub limit: Option<usize>,
}

pub async fn get_okf_graph(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let graph_path = state.lodge_dir.join("okf").join("blue_lodge_graph.jsonld");

    if !graph_path.exists() {
        let gen_script = state.lodge_dir.join("okf").join("generate_okf_graph.py");
        if gen_script.exists() {
            let _ = tokio::process::Command::new("python3")
                .arg(&gen_script)
                .output()
                .await;
        }
    }

    match fs::read_to_string(&graph_path).await {
        Ok(content) => {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                let nodes_count = val["@graph"].as_array().map(|a| a.len()).unwrap_or(0);
                Json(json!({
                    "status": "ok",
                    "nodes_count": nodes_count,
                    "graph": val
                })).into_response()
            } else {
                (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": "Failed to parse OKF JSON-LD graph" }))).into_response()
            }
        }
        Err(e) => (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn search_okf_modules(
    State(state): State<Arc<AppState>>,
    Query(q): Query<OkfSearchQuery>,
) -> impl IntoResponse {
    let query_str = q.q.unwrap_or_default();
    let limit = q.limit.unwrap_or(30).to_string();
    let indexer_script = state.lodge_dir.join("lib").join("tools").join("okf_sqlite_indexer.py");

    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(&indexer_script).arg("--json");

    if query_str.trim().is_empty() {
        if let Some(ref sub) = q.subsystem {
            if !sub.trim().is_empty() && sub != "ALL" {
                cmd.arg("--subsystem").arg(sub);
                cmd.arg("--limit").arg(limit);
            } else {
                cmd.arg("--stats");
            }
        } else {
            cmd.arg("--stats");
        }
    } else {
        cmd.arg("--search").arg(&query_str);
        if let Some(ref sub) = q.subsystem {
            if !sub.trim().is_empty() && sub != "ALL" {
                cmd.arg("--subsystem").arg(sub);
            }
        }
        cmd.arg("--limit").arg(limit);
    }

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                Json(json!({
                    "status": "ok",
                    "results": parsed
                })).into_response()
            } else {
                Json(json!({
                    "status": "error",
                    "message": "Invalid JSON response from OKF indexer",
                    "raw": stdout
                })).into_response()
            }
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({
            "status": "error",
            "message": e.to_string()
        }))).into_response(),
    }
}

pub async fn reindex_okf(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let indexer_script = state.lodge_dir.join("lib").join("tools").join("okf_sqlite_indexer.py");

    let mut cmd = tokio::process::Command::new("python3");
    cmd.arg(&indexer_script).arg("--index").arg("--json");

    match cmd.output().await {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&stdout) {
                Json(json!({
                    "status": "ok",
                    "result": parsed
                })).into_response()
            } else {
                Json(json!({
                    "status": "ok",
                    "raw": stdout
                })).into_response()
            }
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({
            "status": "error",
            "message": e.to_string()
        }))).into_response(),
    }
}
