use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::chrono_utc_now;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct SaveJournalPayload {
    pub george_md: Option<String>,
}

#[derive(Deserialize)]
pub struct SqliteQueryPayload {
    pub query: Option<String>,
    pub search: Option<String>,
    pub db: Option<String>,
}

#[derive(Deserialize)]
pub struct ResearchConfigQuery {
    pub domain: Option<String>,
}

#[derive(Deserialize)]
pub struct ResearchConfigPayload {
    pub candidate_topics: Option<Vec<String>>,
    pub directives: Option<String>,
    pub temperature: Option<f64>,
    pub max_tokens: Option<u32>,
    pub publish_social: Option<bool>,
    pub default_style: Option<String>,
    pub domain: Option<String>,
    pub active_domain: Option<String>,
    pub set_active: Option<bool>,
}

pub async fn get_memories(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let reg_path = state.george_dir.join("memories").join("registry.json");
    if let Ok(content) = fs::read_to_string(&reg_path).await {
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
            return Json(val);
        }
    }
    Json(json!({}))
}

pub async fn get_transcripts(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut list = Vec::new();
    let trans_dir = state.george_dir.join("transcripts");
    if let Ok(mut entries) = fs::read_dir(&trans_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let fname = entry.file_name().to_string_lossy().to_string();
            if fname.ends_with(".md") || fname.ends_with(".md.gz") {
                let meta = entry.metadata().await.ok();
                let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
                list.push(json!({
                    "name": entry.file_name().to_string_lossy(),
                    "size_bytes": size,
                    "path": p.to_string_lossy(),
                }));
            }
        }
    }
    list.sort_by(|a, b| b["name"].as_str().unwrap_or("").cmp(a["name"].as_str().unwrap_or("")));
    Json(list)
}

pub async fn get_transcript_content(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace("..", "").replace('/', "");
    let path = state.george_dir.join("transcripts").join(&clean_name);
    if clean_name.ends_with(".gz") {
        // Retention janitor compresses transcripts older than 7 days.
        return match tokio::process::Command::new("gzip").arg("-dc").arg(&path).output().await {
            Ok(out) if out.status.success() => {
                (StatusCode::OK, String::from_utf8_lossy(&out.stdout).to_string()).into_response()
            }
            _ => (StatusCode::NOT_FOUND, "Transcript not found").into_response(),
        };
    }
    match fs::read_to_string(&path).await {
        Ok(content) => (StatusCode::OK, content).into_response(),
        Err(_) => (StatusCode::NOT_FOUND, "Transcript not found").into_response(),
    }
}

pub async fn delete_transcript(
    State(state): State<Arc<AppState>>,
    Path(name): Path<String>,
) -> impl IntoResponse {
    let clean_name = name.replace("..", "").replace('/', "");
    let mut deleted = false;
    let path = state.george_dir.join("transcripts").join(&clean_name);
    if path.exists() && fs::remove_file(&path).await.is_ok() {
        deleted = true;
    }
    let ws_path = state.george_dir.join("workspaces").join(&clean_name);
    if ws_path.exists() && fs::remove_file(&ws_path).await.is_ok() {
        deleted = true;
    }
    if deleted {
        Json(json!({ "status": "deleted", "name": clean_name }))
    } else {
        Json(json!({ "status": "not_found", "name": clean_name }))
    }
}

pub async fn get_journal(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let george_path = state.lodge_dir.join("GEORGE.md");
    let george_content = fs::read_to_string(&george_path).await.unwrap_or_default();

    let recall_db = state.george_dir.join("recall.db");
    let mut journal_entries = Vec::new();
    if recall_db.exists() {
        let out = tokio::process::Command::new("sqlite3")
            .args(["-json", &recall_db.to_string_lossy(), "SELECT id, section, substr(content, 1, 200) as snippet, indexed_at FROM chunks WHERE source = 'journal' ORDER BY id DESC LIMIT 15;"])
            .output()
            .await;
        if let Ok(res) = out {
            if let Ok(rows) = serde_json::from_slice::<serde_json::Value>(&res.stdout) {
                journal_entries = rows.as_array().cloned().unwrap_or_default();
            }
        }
    }

    Json(json!({
        "george_md": george_content,
        "journal_entries": journal_entries,
    }))
}

pub async fn save_journal(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveJournalPayload>,
) -> impl IntoResponse {
    if let Some(content) = payload.george_md {
        let path = state.lodge_dir.join("GEORGE.md");
        let _ = fs::write(&path, content).await;
    }
    Json(json!({ "status": "saved" }))
}

pub async fn query_sqlite(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SqliteQueryPayload>,
) -> impl IntoResponse {
    let db_name = payload.db.unwrap_or_else(|| "recall".into());
    let db_path = match db_name.as_str() {
        "discord_channels" => state.george_dir.join("discord_channels.db"),
        "discord_profiles" => state.george_dir.join("discord_profiles.db"),
        "reputation" => state.george_dir.join("reputation.db"),
        "mastodon" => state.george_dir.join("mastodon_instances.db"),
        "public_apis" | "apis" => {
            let p = state.lodge_dir.join("data/catalog/public_apis.sqlite");
            if p.exists() {
                p
            } else {
                state.george_dir.join("public_apis.db")
            }
        }
        _ => state.george_dir.join("recall.db"),
    };

    if !db_path.exists() {
        return Json(json!({ "status": "error", "error": format!("Database {} not found", db_path.display()) }));
    }

    let sql_to_run = if let Some(search_term) = payload.search {
        let term_clean = search_term.replace('\'', "''");
        if db_name == "public_apis" || db_name == "apis" {
            format!(
                "SELECT a.id, a.name, a.category, a.auth, a.url, a.description, a.is_keyless, bm25(apis_fts) AS bm25_score FROM apis a JOIN apis_fts f ON a.id = f.rowid WHERE apis_fts MATCH '{}*' ORDER BY a.is_keyless DESC, bm25_score ASC LIMIT 25;",
                term_clean
            )
        } else if db_name == "okf" {
            format!(
                "SELECT m.id, m.name, m.path, m.subsystem_name, m.language, m.description, m.exports, bm25(okf_modules_fts) AS bm25_score FROM okf_modules m JOIN okf_modules_fts ON m.id = okf_modules_fts.rowid WHERE okf_modules_fts MATCH '{}*' ORDER BY bm25_score ASC LIMIT 25;",
                term_clean
            )
        } else {
            format!(
                "SELECT rowid, source, section, substr(content, 1, 300) AS snippet, bm25(chunks_fts) AS bm25_score FROM chunks_fts WHERE chunks_fts MATCH '{}' ORDER BY bm25_score LIMIT 25;",
                term_clean
            )
        }
    } else if let Some(raw_q) = payload.query {
        let trimmed = raw_q.trim();
        let upper = trimmed.to_uppercase();
        if !upper.starts_with("SELECT") && !upper.starts_with("PRAGMA") && !upper.starts_with(".SCHEMA") && !upper.starts_with("EXPLAIN") {
            return Json(json!({ "status": "error", "error": "Only read-only queries (SELECT, PRAGMA, .schema) are permitted." }));
        }
        trimmed.to_string()
    } else {
        return Json(json!({ "status": "error", "error": "Empty query or search term" }));
    };

    let out = tokio::process::Command::new("sqlite3")
        .args(["-json", &db_path.to_string_lossy(), &sql_to_run])
        .output()
        .await;

    match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout).to_string();
            let stderr = String::from_utf8_lossy(&res.stderr).to_string();
            if !res.status.success() || stdout.trim().is_empty() {
                if !stderr.is_empty() {
                    return Json(json!({ "status": "error", "error": stderr.trim() }));
                }
                return Json(json!({ "status": "ok", "rows": [], "count": 0 }));
            }
            if let Ok(rows) = serde_json::from_str::<serde_json::Value>(&stdout) {
                let count = rows.as_array().map(|a| a.len()).unwrap_or(0);
                Json(json!({ "status": "ok", "rows": rows, "count": count }))
            } else {
                Json(json!({ "status": "ok", "raw": stdout, "count": 0 }))
            }
        }
        Err(e) => Json(json!({ "status": "error", "error": e.to_string() })),
    }
}

pub async fn get_commands(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let mut list = Vec::new();
    let cmd_dir = state.lodge_dir.join("commands");
    if let Ok(mut entries) = fs::read_dir(&cmd_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "sh") {
                let stem = p.file_stem().unwrap_or_default().to_string_lossy().to_string();
                let mut desc = String::new();
                let mut usage = format!("/{}", stem);

                if let Ok(content) = fs::read_to_string(&p).await {
                    for line in content.lines().take(25) {
                        let trimmed = line.trim();
                        if let Some(d) = trimmed.strip_prefix("# DESC:") {
                            desc = d.trim().to_string();
                        } else if let Some(u) = trimmed.strip_prefix("# Usage:") {
                            usage = u.trim().to_string();
                        }
                    }
                }

                if desc.is_empty() {
                    desc = format!("Execute /{} command", stem);
                }

                list.push(json!({
                    "name": stem,
                    "command": format!("/{}", stem),
                    "usage": usage,
                    "desc": desc,
                }));
            }
        }
    }

    list.sort_by(|a, b| a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or("")));
    Json(list)
}

pub async fn get_research_config(
    State(state): State<Arc<AppState>>,
    Query(query): Query<ResearchConfigQuery>,
) -> impl IntoResponse {
    let conf_path = state.george_dir.join("research.conf");

    let mut active_domain = "academic".to_string();
    let mut directives = "Ground every section strictly in concrete equations, hardware bounds, benchmark metrics, and arXiv citations. Strictly forbid superficial filler.".into();
    let mut temperature = 0.3;
    let mut max_tokens = 4500;
    let mut publish_social = true;
    let mut default_style = "storyteller".to_string();

    if let Ok(content) = fs::read_to_string(&conf_path).await {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&content) {
            if let Some(ad) = parsed["active_domain"].as_str() {
                if !ad.trim().is_empty() {
                    active_domain = ad.trim().to_string();
                }
            }
            if let Some(d) = parsed["directives"].as_str() {
                directives = d.to_string();
            }
            if let Some(temp) = parsed["temperature"].as_f64() {
                temperature = temp;
            }
            if let Some(mt) = parsed["max_tokens"].as_u64() {
                max_tokens = mt as u32;
            }
            if let Some(ps) = parsed["publish_social"].as_bool() {
                publish_social = ps;
            }
            if let Some(ds) = parsed["default_style"].as_str() {
                default_style = ds.to_string();
            }
        }
    }

    let target_domain = match query.domain.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        Some("all") => active_domain.clone(),
        Some(d) => d.to_string(),
        None => active_domain.clone(),
    };

    let file_name = match target_domain.as_str() {
        "engineering" => "research_topics_engineering.txt",
        "finance" => "research_topics_finance.txt",
        "gaming" => "research_topics_gaming.txt",
        "general_sports_auto" | "sports_auto" | "sports" => "research_topics_general_sports_auto.txt",
        "academic" => "research_topics_academic.txt",
        _ => "research_topics.txt",
    };

    let target_topics_path = state.george_dir.join(file_name);
    let mut topics = Vec::new();

    if let Ok(content) = fs::read_to_string(&target_topics_path).await {
        topics = content
            .lines()
            .map(|l| l.trim().to_string())
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .collect();
    }

    if topics.is_empty() {
        let fallback_path = state.george_dir.join("research_topics.txt");
        if let Ok(content) = fs::read_to_string(&fallback_path).await {
            topics = content
                .lines()
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty() && !l.starts_with('#'))
                .collect();
        }
    }

    // Compute live counts for all 5 meta-topic pools
    let domain_keys = ["academic", "engineering", "finance", "gaming", "general_sports_auto"];
    let mut all_domain_counts = serde_json::Map::new();
    for dk in &domain_keys {
        let df_name = match *dk {
            "engineering" => "research_topics_engineering.txt",
            "finance" => "research_topics_finance.txt",
            "gaming" => "research_topics_gaming.txt",
            "general_sports_auto" => "research_topics_general_sports_auto.txt",
            _ => "research_topics_academic.txt",
        };
        let df_path = state.george_dir.join(df_name);
        let cnt = if let Ok(c) = fs::read_to_string(&df_path).await {
            c.lines().filter(|l| {
                let t = l.trim();
                !t.is_empty() && !t.starts_with('#')
            }).count()
        } else {
            0
        };
        all_domain_counts.insert(dk.to_string(), json!(cnt));
    }

    Json(json!({
        "candidate_topics": topics,
        "active_domain": active_domain,
        "target_domain": target_domain,
        "topic_file": format!(".george/{}", file_name),
        "all_domain_counts": all_domain_counts,
        "directives": directives,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "default_style": default_style,
        "publish_social": publish_social,
        "phases": [
            { "phase": 1, "name": "ReAct Sandbox Investigation", "desc": "Multi-turn ReAct search, arXiv PDF download, pdftotext extraction, vision diagram analysis" },
            { "phase": 2, "name": "Evidence Audit & Gap Analysis", "desc": "Citation density threshold gate (>2 verified sources) and PDF ingestion check" },
            { "phase": 3, "name": "Monograph Synthesis", "desc": "Authoring authoritative dossier.md grounded in equations, bounds, and benchmarks" },
            { "phase": 4, "name": "Editorial Critique & Revision", "desc": "Refinement pass eliminating speculative boilerplate and verifying technical consistency" },
            { "phase": 5, "name": "PGP Archival & Social Syndication", "desc": "Ed25519/PGP signature, research_index.jsonl registration, and Mastodon/Bluesky/X queueing" }
        ]
    }))
}

pub async fn save_research_config(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResearchConfigPayload>,
) -> impl IntoResponse {
    let conf_path = state.george_dir.join("research.conf");

    let mut current_conf = if let Ok(content) = fs::read_to_string(&conf_path).await {
        serde_json::from_str::<serde_json::Value>(&content).unwrap_or(json!({}))
    } else {
        json!({})
    };

    let target_domain = payload.domain
        .or_else(|| payload.active_domain.clone())
        .unwrap_or_else(|| current_conf["active_domain"].as_str().unwrap_or("academic").to_string());

    if let Some(ref ad) = payload.active_domain {
        current_conf["active_domain"] = json!(ad);
    } else if payload.set_active.unwrap_or(false) {
        current_conf["active_domain"] = json!(target_domain);
    }

    if let Some(ref d) = payload.directives {
        current_conf["directives"] = json!(d);
    }
    if let Some(temp) = payload.temperature {
        current_conf["temperature"] = json!(temp);
    }
    if let Some(mt) = payload.max_tokens {
        current_conf["max_tokens"] = json!(mt);
    }
    if let Some(ref ds) = payload.default_style {
        current_conf["default_style"] = json!(ds);
    }
    if let Some(ps) = payload.publish_social {
        current_conf["publish_social"] = json!(ps);
    }
    current_conf["updated_at"] = json!(chrono_utc_now());

    let file_name = match target_domain.as_str() {
        "engineering" => "research_topics_engineering.txt",
        "finance" => "research_topics_finance.txt",
        "gaming" => "research_topics_gaming.txt",
        "general_sports_auto" | "sports_auto" | "sports" => "research_topics_general_sports_auto.txt",
        "academic" => "research_topics_academic.txt",
        _ => "research_topics.txt",
    };
    let target_topics_path = state.george_dir.join(file_name);
    let master_topics_path = state.george_dir.join("research_topics.txt");

    let mut count = 0;
    if let Some(ref topics) = payload.candidate_topics {
        let topics_str = topics.join("\n") + "\n";
        let _ = fs::write(&target_topics_path, &topics_str).await;

        let active_domain_str = current_conf["active_domain"].as_str().unwrap_or("academic");
        if target_domain == active_domain_str || (target_domain == "academic" && active_domain_str == "academic") {
            let _ = fs::write(&master_topics_path, &topics_str).await;
        }
        current_conf["candidate_topics"] = json!(topics);
        count = topics.len();
    }

    if let Ok(serialized) = serde_json::to_string_pretty(&current_conf) {
        let _ = fs::write(&conf_path, serialized).await;
    }

    Json(json!({
        "status": "saved",
        "domain": target_domain,
        "active_domain": current_conf["active_domain"],
        "topic_file": format!(".george/{}", file_name),
        "count": count
    }))
}
