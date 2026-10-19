use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::{chrono_epoch_secs, chrono_utc_now};
use crate::state::AppState;

#[derive(Debug, Serialize, Deserialize)]
pub struct DossierSummary {
    pub slug: String,
    pub title: String,
    pub domain: String,
    pub category: String,
    pub theme: String,
    pub status: String, // "verified" | "quarantined"
    pub date: String,
    pub updated_at: u64,
    pub word_count: usize,
    pub reading_time_min: usize,
    pub has_thread: bool,
    pub has_plate: bool,
    pub has_scratchpad: bool,
    pub revision_count: usize,
    pub failure_reason: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Serialize, Deserialize)]
pub struct DossierDetail {
    pub slug: String,
    pub title: String,
    pub domain: String,
    pub category: String,
    pub theme: String,
    pub status: String,
    pub dossier: String,
    pub scratchpad: Option<String>,
    pub thread: Option<String>,
    pub quarantine_report: Option<String>,
    pub revisions: Vec<String>,
    pub artifacts: Vec<String>,
    pub papers: Vec<String>,
}

#[derive(Deserialize)]
pub struct ResearchModeSetPayload {
    pub domain: String,
}

#[derive(Deserialize)]
pub struct TopicAddPayload {
    pub domain: Option<String>,
    pub topic: String,
}

#[derive(Deserialize)]
pub struct TopicRandomQuery {
    pub domain: Option<String>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
pub struct ResearchStartPayload {
    pub topic: String,
    pub domain: Option<String>,
    pub style: Option<String>,
    pub max_turns: Option<u32>,
    pub publish_social: Option<bool>,
    pub publish_x: Option<bool>,
    pub publish_mastodon: Option<bool>,
    pub publish_bluesky: Option<bool>,
}

#[allow(dead_code)]
#[derive(Deserialize)]
pub struct ResearchRefinePayload {
    pub steering_prompt: String,
    pub max_retries: Option<u32>,
}

#[derive(Deserialize)]
pub struct TopicDraftPayload {
    pub domain: String,
    pub style: Option<String>,
    pub seed: Option<String>,
}

#[derive(Deserialize)]
pub struct BrainstormChatPayload {
    pub message: String,
    pub domain: Option<String>,
    pub history: Option<Vec<serde_json::Value>>,
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/dossiers
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_dossiers(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let quarantine_dir = research_dir.join("quarantine");

    let mut list: Vec<DossierSummary> = Vec::new();

    // 1. Scan verified dossiers in .george/research/*
    if let Ok(mut entries) = fs::read_dir(&research_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if name == "quarantine" || name.starts_with('.') {
                continue;
            }

            if let Some(summary) = summarize_dossier(&path, &name, "verified").await {
                list.push(summary);
            }
        }
    }

    // 2. Scan quarantined dossiers in .george/research/quarantine/*
    if let Ok(mut entries) = fs::read_dir(&quarantine_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }

            if let Some(summary) = summarize_dossier(&path, &name, "quarantined").await {
                list.push(summary);
            }
        }
    }

    // Sort newest first
    list.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));

    Json(json!({ "dossiers": list }))
}

async fn summarize_dossier(path: &PathBuf, slug: &str, status: &str) -> Option<DossierSummary> {
    let dossier_file = path.join("dossier.md");
    if !dossier_file.exists() {
        return None;
    }

    let content = fs::read_to_string(&dossier_file).await.unwrap_or_default();
    let word_count = content.split_whitespace().count();
    let reading_time_min = (word_count / 200).max(1);

    // Extract title from first H1 line
    let mut title = slug.replace('-', " ");
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("# ") {
            title = trimmed
                .trim_start_matches("# ")
                .trim_start_matches("Sovereign Research Dossier:")
                .trim_start_matches("Sovereign Engineering Dossier:")
                .trim_start_matches("Sovereign Financial Dossier:")
                .trim_start_matches("Sovereign Gaming & Emulation Dossier:")
                .trim_start_matches("Sovereign Analytical Dossier:")
                .trim()
                .to_string();
            break;
        }
    }

    // Extract frontmatter metadata if present
    let mut frontmatter_category: Option<String> = None;
    let mut frontmatter_domain: Option<String> = None;
    let mut frontmatter_theme: Option<String> = None;

    if content.starts_with("---") {
        let lines: Vec<&str> = content.lines().collect();
        if let Some(end_idx) = lines.iter().skip(1).position(|l| l.trim() == "---") {
            for line in &lines[1..=end_idx] {
                let trimmed = line.trim();
                if let Some(val) = trimmed.strip_prefix("category:") {
                    frontmatter_category = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                } else if let Some(val) = trimmed.strip_prefix("domain:") {
                    frontmatter_domain = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                } else if let Some(val) = trimmed.strip_prefix("theme:") {
                    frontmatter_theme = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                }
            }
        }
    }

    // Extract domain from frontmatter, scratchpad.md, or classify
    let scratchpad_file = path.join("scratchpad.md");
    let mut domain = frontmatter_domain.unwrap_or_default();
    if domain.is_empty() && scratchpad_file.exists() {
        if let Ok(sp) = fs::read_to_string(&scratchpad_file).await {
            for line in sp.lines() {
                if line.trim().starts_with("**Domain:**") {
                    domain = line.trim().trim_start_matches("**Domain:**").trim().to_string();
                    break;
                }
            }
        }
    }
    if domain.is_empty() || domain == "academic" {
        domain = classify_domain_fallback(slug);
    }
    let norm_domain = normalize_domain(&domain);
    let (default_cat, default_thm) = domain_to_category_and_theme(&norm_domain);

    let category = frontmatter_category
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| default_cat.to_string());
    let theme = frontmatter_theme
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| default_thm.to_string());

    // Check files & revisions
    let has_thread = path.join("thread.md").exists();
    let has_plate = path.join("summary_card.png").exists();
    let has_scratchpad = scratchpad_file.exists();

    let rev_dir = path.join("revisions");
    let mut revision_count = 0;
    if rev_dir.exists() {
        if let Ok(mut revs) = fs::read_dir(&rev_dir).await {
            while let Ok(Some(_)) = revs.next_entry().await {
                revision_count += 1;
            }
        }
    }

    let mtime = fs::metadata(&dossier_file)
        .await
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let date_str = format_epoch_date(mtime);

    let mut failure_reason = None;
    let qr_file = path.join("quarantine_report.md");
    if qr_file.exists() {
        if let Ok(qr) = fs::read_to_string(&qr_file).await {
            let mut summary = String::new();
            for line in qr.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("- [BLOCKING:") || trimmed.starts_with("Gate 2") {
                    summary.push_str(trimmed);
                    summary.push(' ');
                    if summary.len() > 180 {
                        break;
                    }
                }
            }
            if !summary.is_empty() {
                failure_reason = Some(summary);
            } else {
                failure_reason = Some("Verification gate failed: Primitive audit or citation mismatch".into());
            }
        }
    }

    Some(DossierSummary {
        slug: slug.to_string(),
        title,
        domain: norm_domain,
        category,
        theme,
        status: status.to_string(),
        date: date_str,
        updated_at: mtime,
        word_count,
        reading_time_min,
        has_thread,
        has_plate,
        has_scratchpad,
        revision_count,
        failure_reason,
    })
}

pub fn domain_to_category_and_theme(domain: &str) -> (&'static str, &'static str) {
    match domain.trim().to_lowercase().as_str() {
        "engineering" => ("Systems & Security", "Engineering & Systems Integrity"),
        "finance" => ("Finance & Macro", "Cardano DeFi & Global Macro"),
        "gaming" => ("Gaming & Emulation", "Interactive Mechanics & Emulation R&D"),
        "general_sports_auto" | "sports_auto" | "sports" | "automotive" => {
            ("Sports & Automotive", "Athletic Science & Automotive Engineering")
        }
        "auto_optimal" | "resonance" => ("Auto-Optimal", "Resonance-Guided Domain Selection"),
        _ => ("AI / ML Science", "Autonomous Intelligence & Deep Learning"),
    }
}

pub fn normalize_domain(domain: &str) -> String {
    match domain.trim().to_lowercase().as_str() {
        "engineering" | "systems" | "security" => "engineering".to_string(),
        "finance" | "macro" | "cardano" => "finance".to_string(),
        "gaming" | "emulation" => "gaming".to_string(),
        "sports" | "auto" | "sports_auto" | "general_sports_auto" | "automotive" => {
            "general_sports_auto".to_string()
        }
        "auto_optimal" | "resonance" => "auto_optimal".to_string(),
        _ => "academic".to_string(),
    }
}

fn classify_domain_fallback(s: &str) -> String {
    let lower = s.to_lowercase();
    let tokens: Vec<&str> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();

    if tokens.iter().any(|&t| {
        t == "sport" || t == "sports" || t == "racing" || t == "porsche" || t == "nfl" || t == "f1" || t == "automotive" || t == "motorsport" || t == "dyno" || t == "aerodynamics"
    }) {
        "general_sports_auto".to_string()
    } else if tokens.iter().any(|&t| {
        t == "finance" || t == "cardano" || t == "crypto" || t == "market" || t == "stock" || t == "defi" || t == "sec" || t == "tokenomics" || t == "sofr"
    }) {
        "finance".to_string()
    } else if tokens.iter().any(|&t| {
        t == "game" || t == "gaming" || t == "emulation" || t == "emulator" || t == "decompile" || t == "decompilation" || t == "ps5" || t == "ps2" || t == "n64" || t == "vulkan"
    }) {
        "gaming".to_string()
    } else if tokens.iter().any(|&t| {
        t == "kernel" || t == "linux" || t == "driver" || t == "protocol" || t == "rfc" || t == "cve" || t == "ebpf" || t == "pgp" || t == "ed25519" || t == "raft"
    }) {
        "engineering".to_string()
    } else {
        "academic".to_string()
    }
}

fn format_epoch_date(secs: u64) -> String {
    if secs == 0 {
        return "Unknown".to_string();
    }
    // Simple ISO-ish representation
    let days = secs / 86400;
    // Approximation for display
    let year = 1970 + days / 365;
    let day_of_year = days % 365;
    let month = (day_of_year / 30) + 1;
    let day = (day_of_year % 30) + 1;
    format!("{:04}-{:02}-{:02}", year, month.min(12), day.min(31))
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/dossier/:slug
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_dossier(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let verified_path = research_dir.join(&slug);
    let quarantine_path = research_dir.join("quarantine").join(&slug);

    let (dir_path, status) = if verified_path.exists() {
        (verified_path, "verified")
    } else if quarantine_path.exists() {
        (quarantine_path, "quarantined")
    } else {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Dossier not found" }))).into_response();
    };

    let dossier_content = fs::read_to_string(dir_path.join("dossier.md")).await.unwrap_or_default();
    let scratchpad_content = fs::read_to_string(dir_path.join("scratchpad.md")).await.ok();
    let thread_content = fs::read_to_string(dir_path.join("thread.md")).await.ok();
    let qr_content = fs::read_to_string(dir_path.join("quarantine_report.md")).await.ok();
    let has_plate = dir_path.join("summary_card.png").exists();

    // Extract title
    let mut title = slug.replace('-', " ");
    for line in dossier_content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("# ") {
            title = trimmed
                .trim_start_matches("# ")
                .trim_start_matches("Sovereign Research Dossier:")
                .trim_start_matches("Sovereign Engineering Dossier:")
                .trim_start_matches("Sovereign Financial Dossier:")
                .trim_start_matches("Sovereign Gaming & Emulation Dossier:")
                .trim_start_matches("Sovereign Analytical Dossier:")
                .trim()
                .to_string();
            break;
        }
    }

    let mut frontmatter_category: Option<String> = None;
    let mut frontmatter_domain: Option<String> = None;
    let mut frontmatter_theme: Option<String> = None;

    if dossier_content.starts_with("---") {
        let lines: Vec<&str> = dossier_content.lines().collect();
        if let Some(end_idx) = lines.iter().skip(1).position(|l| l.trim() == "---") {
            for line in &lines[1..=end_idx] {
                let trimmed = line.trim();
                if let Some(val) = trimmed.strip_prefix("category:") {
                    frontmatter_category = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                } else if let Some(val) = trimmed.strip_prefix("domain:") {
                    frontmatter_domain = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                } else if let Some(val) = trimmed.strip_prefix("theme:") {
                    frontmatter_theme = Some(val.trim().trim_matches('"').trim_matches('\'').to_string());
                }
            }
        }
    }

    let mut domain = frontmatter_domain.unwrap_or_default();
    if domain.is_empty() {
        if let Some(ref sp) = scratchpad_content {
            for line in sp.lines() {
                if line.trim().starts_with("**Domain:**") {
                    domain = line.trim().trim_start_matches("**Domain:**").trim().to_string();
                    break;
                }
            }
        }
    }
    if domain.is_empty() {
        domain = classify_domain_fallback(&slug);
    }
    let norm_domain = normalize_domain(&domain);
    let (default_cat, default_thm) = domain_to_category_and_theme(&norm_domain);
    let category = frontmatter_category
        .filter(|c| !c.is_empty())
        .unwrap_or_else(|| default_cat.to_string());
    let theme = frontmatter_theme
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| default_thm.to_string());

    // List revisions
    let mut revisions = Vec::new();
    let rev_dir = dir_path.join("revisions");
    if rev_dir.exists() {
        if let Ok(mut revs) = fs::read_dir(&rev_dir).await {
            while let Ok(Some(entry)) = revs.next_entry().await {
                revisions.push(entry.file_name().to_string_lossy().to_string());
            }
        }
        revisions.sort();
    }

    // List papers / artifacts
    let mut papers = Vec::new();
    let papers_dir = dir_path.join("papers");
    if papers_dir.exists() {
        if let Ok(mut p_entries) = fs::read_dir(&papers_dir).await {
            while let Ok(Some(entry)) = p_entries.next_entry().await {
                papers.push(entry.file_name().to_string_lossy().to_string());
            }
        }
        papers.sort();
    }

    let mut artifacts = Vec::new();
    let artifacts_dir = dir_path.join("artifacts");
    if artifacts_dir.exists() {
        if let Ok(mut a_entries) = fs::read_dir(&artifacts_dir).await {
            while let Ok(Some(entry)) = a_entries.next_entry().await {
                artifacts.push(entry.file_name().to_string_lossy().to_string());
            }
        }
        artifacts.sort();
    }

    Json(json!({
        "slug": slug,
        "title": title,
        "domain": norm_domain,
        "category": category,
        "theme": theme,
        "status": status,
        "dossier": dossier_content,
        "scratchpad": scratchpad_content,
        "thread": thread_content,
        "has_plate": has_plate,
        "quarantine_report": qr_content,
        "revisions": revisions,
        "artifacts": artifacts,
        "papers": papers,
    })).into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/dossier/:slug/revision/:rev
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_revision(
    State(state): State<Arc<AppState>>,
    Path((slug, rev)): Path<(String, String)>,
) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let verified_rev = research_dir.join(&slug).join("revisions").join(&rev);
    let quarantine_rev = research_dir.join("quarantine").join(&slug).join("revisions").join(&rev);

    let rev_path = if verified_rev.exists() {
        verified_rev
    } else if quarantine_rev.exists() {
        quarantine_rev
    } else {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Revision not found" }))).into_response();
    };

    match fs::read_to_string(rev_path).await {
        Ok(text) => Json(json!({ "slug": slug, "revision": rev, "content": text })).into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/start
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_research_start(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResearchStartPayload>,
) -> impl IntoResponse {
    let topic = payload.topic.trim();
    if topic.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Topic cannot be empty" }))).into_response();
    }

    let mut args: Vec<String> = vec!["/research".to_string(), "start".to_string(), topic.to_string()];

    if payload.publish_social.unwrap_or(false) {
        args.push("--publish".to_string());
    } else {
        if payload.publish_x.unwrap_or(false) {
            args.push("--publish-x".to_string());
        }
        if payload.publish_mastodon.unwrap_or(false) {
            args.push("--publish-mastodon".to_string());
        }
        if payload.publish_bluesky.unwrap_or(false) {
            args.push("--publish-bluesky".to_string());
        }
    }

    let _lodge_bin = state.lodge_dir.join("lodge");
    let lodge_str = state.lodge_dir.to_string_lossy().to_string();

    let safe_topic = topic.replace('\'', "'\\''");
    let run_cmd = format!(
        "cd '{}' && source lib/ipc/fifo_ipc.sh 2>/dev/null && ipc_async 'chan_research' './lodge /research start \"{}\"' 70",
        lodge_str, safe_topic
    );

    let spawn_res = tokio::process::Command::new("bash")
        .args(["-c", &run_cmd])
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match spawn_res {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            Json(json!({
                "status": "queued",
                "channel": "chan_research",
                "priority": 70,
                "topic": topic,
                "output": stdout.trim()
            })).into_response()
        }
        Err(e) => {
            // Fallback direct spawn
            let direct_cmd = format!("cd '{}' && ./lodge /research start '{}' > /dev/null 2>&1 &", lodge_str, safe_topic);
            let _ = tokio::process::Command::new("bash").args(["-c", &direct_cmd]).spawn();
            Json(json!({
                "status": "queued_fallback",
                "topic": topic,
                "note": e.to_string()
            })).into_response()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/refine/:slug
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_research_refine(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
    Json(payload): Json<ResearchRefinePayload>,
) -> impl IntoResponse {
    let steering = payload.steering_prompt.trim();
    if steering.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Steering prompt cannot be empty" }))).into_response();
    }

    let research_dir = state.george_dir.join("research");
    let v_path = research_dir.join(&slug);
    let q_path = research_dir.join("quarantine").join(&slug);

    let target_dir = if v_path.exists() {
        v_path
    } else if q_path.exists() {
        q_path
    } else {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Dossier not found" }))).into_response();
    };

    let dossier_file = target_dir.join("dossier.md");
    if !dossier_file.exists() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Missing dossier.md" }))).into_response();
    }

    // 1. Snapshot current version to revisions/
    let rev_dir = target_dir.join("revisions");
    let _ = fs::create_dir_all(&rev_dir).await;
    let ts = chrono_epoch_secs();
    let rev_file = rev_dir.join(format!("dossier.v{}.md", ts));
    let _ = fs::copy(&dossier_file, &rev_file).await;

    // 2. Append steering directives to scratchpad.md
    let scratchpad_file = target_dir.join("scratchpad.md");
    let directive_block = format!(
        "\n\n## Operator Steering Directives (Turn Refinement - {})\n{}\n",
        chrono_utc_now(),
        steering
    );
    let mut cur_sp = fs::read_to_string(&scratchpad_file).await.unwrap_or_default();
    cur_sp.push_str(&directive_block);
    let _ = fs::write(&scratchpad_file, cur_sp).await;

    // 3. Queue verification/salvage via FIFO IPC
    let lodge_str = state.lodge_dir.to_string_lossy().to_string();
    let safe_slug = slug.replace('\'', "'\\''");
    let run_cmd = format!(
        "cd '{}' && source lib/ipc/fifo_ipc.sh 2>/dev/null && ipc_async 'chan_research' './lodge /research salvage \"{}\"' 70",
        lodge_str, safe_slug
    );

    let _spawn_res = tokio::process::Command::new("bash")
        .args(["-c", &run_cmd])
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    Json(json!({
        "status": "refinement_queued",
        "slug": slug,
        "revision_snapshot": format!("dossier.v{}.md", ts),
        "steering": steering,
    })).into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/salvage/:slug
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_research_salvage(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let lodge_str = state.lodge_dir.to_string_lossy().to_string();
    let safe_slug = slug.replace('\'', "'\\''");
    let run_cmd = format!(
        "cd '{}' && source lib/ipc/fifo_ipc.sh 2>/dev/null && ipc_async 'chan_research' './lodge /research salvage \"{}\"' 70",
        lodge_str, safe_slug
    );

    let _ = tokio::process::Command::new("bash")
        .args(["-c", &run_cmd])
        .current_dir(&state.lodge_dir)
        .spawn();

    Json(json!({
        "status": "salvage_queued",
        "slug": slug
    }))
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/topics/draft (Option 1: Directed Candidate Generation)
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_topics_draft(
    State(_state): State<Arc<AppState>>,
    Json(payload): Json<TopicDraftPayload>,
) -> impl IntoResponse {
    let domain = payload.domain.trim();
    let style = payload.style.as_deref().unwrap_or("empirical");
    let seed = payload.seed.as_deref().unwrap_or("");

    let domain_instruction = match domain {
        "academic" => "AI/ML foundations, deep learning theory, arXiv preprints, physics, mathematics, cryptography, speculative decoding, KV-cache architectures.",
        "engineering" => "Linux kernel subsystems, eBPF, distributed consensus protocols, compiler backends, high-throughput network fabrics, RFCs, memory-safety architectures.",
        "finance" => "SEC 10-K disclosures, macro liquidity flows, tokenomics invariants, Cardano eUTxO protocols, DeFi yield curves, quantitative valuation models, geopolitics.",
        "gaming" => "Console emulation internals, cycle-accurate timing, JIT recompiler pipelines, GPU register emulation, memory map architectures, reverse engineering.",
        "general_sports_auto" => "Automotive telemetry, aeromechanical engineering, dyno performance, F1 telemetry strategies, athlete biometrics, draft capital allocation models.",
        _ => "Deep technical exploration and empirical verification."
    };

    let prompt = format!(
        "Generate 6 provocative, cutting-edge research inquiries for George's Sovereign Research Studio.\n\
        Domain: {} ({})\n\
        Style: {}\n\
        Seed Focus: {}\n\n\
        Requirements:\n\
        1. Every inquiry must demand rigorous empirical grounding, mathematical equations, or verifiable primary data (not generic thinkpieces).\n\
        2. Format output strictly as a JSON array of objects with keys: title, angle, hypothesis, domain, complexity (Low/Medium/High), key_sources.\n\
        3. Do not include markdown code fences or narrative preambles, ONLY the JSON array.",
        domain, domain_instruction, style, seed
    );

    let req_body = json!({
        "model": "base",
        "messages": [
            {
                "role": "system",
                "content": "You are George's Senior Research Architect. Output ONLY a valid JSON array of 6 candidate research inquiry objects."
            },
            {
                "role": "user",
                "content": prompt
            }
        ],
        "temperature": 0.7,
        "max_tokens": 1200
    });

    let llm_call = tokio::time::timeout(
        std::time::Duration::from_secs(35),
        tokio::process::Command::new("curl")
            .args([
                "-s",
                "--max-time", "30",
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", &req_body.to_string(),
                "http://127.0.0.1:8080/v1/chat/completions"
            ])
            .output()
    ).await;

    if let Ok(Ok(out)) = llm_call {
        if out.status.success() {
            if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                if let Some(content) = val["choices"][0]["message"]["content"].as_str() {
                    let clean = content
                        .trim()
                        .trim_start_matches("```json")
                        .trim_start_matches("```")
                        .trim_end_matches("```")
                        .trim();
                    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(clean) {
                        return Json(json!({ "status": "ok", "domain": domain, "candidates": parsed })).into_response();
                    }
                }
            }
        }
    }

    // High-density curated fallback candidates per domain
    let fallbacks = match domain {
        "engineering" => json!([
            {
                "title": "eBPF Ring Buffer Backpressure under 100GbE Line Rates",
                "angle": "Kernel memory allocation bottlenecks in high-frequency packet filters",
                "hypothesis": "Per-CPU perf event buffers exhibit less tail latency than shared ring buffers when CPU core pinning exceeds NUMA boundaries.",
                "domain": "engineering",
                "complexity": "High",
                "key_sources": "Linux kernel source, RFC 8962, Cilium BPF benchmarks"
            },
            {
                "title": "io_uring vs epoll in Zero-Copy Storage Fabrics",
                "angle": "Kernel-bypass trade-offs on NVMe-oF block engines",
                "hypothesis": "Registered buffer fixed-files mode achieves 2.8x IOPS over epoll while eliminating TLB shootdowns.",
                "domain": "engineering",
                "complexity": "Medium",
                "key_sources": "Jens Axboe io_uring specifications, SPDK architecture"
            },
            {
                "title": "Deterministic Raft Consensus under Byzantine Network Partitions",
                "angle": "Clock skew impact on lease reads in distributed log replication",
                "hypothesis": "Hybrid logical clocks prevent stale leader reads without paying the full RTT penalty of quorum reads.",
                "domain": "engineering",
                "complexity": "High",
                "key_sources": "Ongaro Raft dissertation, CockroachDB transaction model"
            }
        ]),
        "finance" => json!([
            {
                "title": "Cardano Hydra Head Settlement Latency and Invariant Proofs",
                "angle": "Isomorphic state channel security under Byzantine closure games",
                "hypothesis": "Head decommit transactions under Plutus V3 require less than 1.2M execution units, permitting sub-second dispute finality.",
                "domain": "finance",
                "complexity": "High",
                "key_sources": "IOG Hydra Specification, Plutus Ledger state transitions"
            },
            {
                "title": "Polymarket Negative-Risk Arbitrage & Combinatorial Market Makers",
                "angle": "Cross-outcome probability sum exploitation in multi-candidate pools",
                "hypothesis": "Sum of inverse share prices exceeding 1.0 creates a riskless collateral split/merge profit margin bounded only by gas and slippage.",
                "domain": "finance",
                "complexity": "Medium",
                "key_sources": "Gnosis CTF contracts, Polymarket CLOB orderbook telemetry"
            },
            {
                "title": "Federal Reserve Treasury Repo Facility & Commercial Paper Spreads",
                "angle": "Empirical SOFR-FFR corridor divergence during quarter-end balance sheet contractions",
                "hypothesis": "Foreign bank regulatory capital rules create predictable 15-25 bps spikes in standing repo utilization.",
                "domain": "finance",
                "complexity": "Medium",
                "key_sources": "NY Fed open market operations, Basel III leverage ratio disclosures"
            }
        ]),
        "gaming" => json!([
            {
                "title": "Emotion Engine Vector Unit 0/1 Microcode JIT Recompilation",
                "angle": "Cycle-accurate synchronization trade-offs in modern PS2 emulators",
                "hypothesis": "Recoupling VU1 execution to branch delay slots via basic block compilation eliminates microcode stalls without host GPU synchronization.",
                "domain": "gaming",
                "complexity": "High",
                "key_sources": "PCSX2 source repository, Sony EE Core Instruction Set Manual"
            },
            {
                "title": "Dynamic Binary Translation of ARM64 NEON to x86-64 AVX2",
                "angle": "Permutation instruction mapping in Switch emulation",
                "hypothesis": "Vector shuffle registers can be mapped into AVX-512 VPERMB without spilling to stack, speeding emulation by 32%.",
                "domain": "gaming",
                "complexity": "High",
                "key_sources": "Ryujinx / Yuzu recompiler postmortems, ARM Architecture Reference Manual"
            }
        ]),
        "general_sports_auto" => json!([
            {
                "title": "Active Aerodynamic DRS Ground Effect Separation in Formula 1",
                "angle": "Venturi tunnel stall characteristics under low-ride-height porpoising",
                "hypothesis": "Floor edge vortex breakdown occurs at boundary layer displacement thicknesses exceeding 4.2mm, inducing sudden downforce loss.",
                "domain": "general_sports_auto",
                "complexity": "High",
                "key_sources": "FIA Technical Regulations, SAE Motorsport aerodynamics papers"
            },
            {
                "title": "Porsche 911 GT3 RS Dual-Clutch Shift Latency & Torque Vectoring Telemetry",
                "angle": "Pre-engagement gear cluster hydraulic pressure profiles during apex deceleration",
                "hypothesis": "Clutch overlap timing under 15ms preserves chassis pitch stability, reducing Nürburgring Nordschleife sector variance by 0.3s.",
                "domain": "general_sports_auto",
                "complexity": "Medium",
                "key_sources": "Porsche OEM technical documentation, Bosch Motorsport telemetry logs"
            }
        ]),
        _ => json!([
            {
                "title": "Multi-Token Speculative Drafting with Medusa Heads on Constrained VRAM",
                "angle": "Prefix-tree attention verification and KV-cache compression under 16GB VRAM bounds",
                "hypothesis": "Dynamic tree expansion bounded to N<100 nodes achieves 2.4x speedup on single-consumer GPUs without target distribution drift.",
                "domain": "academic",
                "complexity": "High",
                "key_sources": "arXiv:2401.10774, Leviathan et al. Speculative Decoding"
            },
            {
                "title": "Modern Hopfield Networks & Exponential Associative Memory in Transformers",
                "angle": "Continuous energy functions and dense associative memory retrieval dynamics",
                "hypothesis": "Transformer self-attention with softmax temperature matches the continuous state update rule of modern Hopfield networks.",
                "domain": "academic",
                "complexity": "High",
                "key_sources": "Ramsauer et al. (ICLR 2021), Krotov & Hopfield (2016)"
            },
            {
                "title": "FlashAttention-3 Asynchronous Warp Specialization on Hopper & Blackwell",
                "angle": "Overlapping GEMM and softmax via Tensor Memory Accelerator (TMA)",
                "hypothesis": "FP8 low-precision GEMM pipelining achieves 75% of peak theoretical FLOPS by eliminating register file bank conflicts.",
                "domain": "academic",
                "complexity": "High",
                "key_sources": "Dao et al. FlashAttention-3 preprint, NVIDIA CUTLASS documentation"
            }
        ])
    };

    Json(json!({
        "status": "ok",
        "domain": domain,
        "candidates": fallbacks,
        "note": "Curated empirical candidates"
    })).into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/topics/random
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_topics_random(
    State(state): State<Arc<AppState>>,
    Query(query): Query<TopicRandomQuery>,
) -> impl IntoResponse {
    let domain_req = query.domain.as_deref().unwrap_or("all");
    let mut candidate_pool: Vec<(String, String)> = Vec::new(); // (topic, domain)

    let files: Vec<(&str, &str)> = if domain_req.is_empty() || domain_req == "all" || domain_req == "random" {
        vec![
            ("academic", "research_topics_academic.txt"),
            ("engineering", "research_topics_engineering.txt"),
            ("finance", "research_topics_finance.txt"),
            ("gaming", "research_topics_gaming.txt"),
            ("general_sports_auto", "research_topics_general_sports_auto.txt"),
        ]
    } else {
        let norm = normalize_domain(domain_req);
        match norm.as_str() {
            "engineering" => vec![("engineering", "research_topics_engineering.txt")],
            "finance" => vec![("finance", "research_topics_finance.txt")],
            "gaming" => vec![("gaming", "research_topics_gaming.txt")],
            "general_sports_auto" => vec![("general_sports_auto", "research_topics_general_sports_auto.txt")],
            _ => vec![("academic", "research_topics_academic.txt")],
        }
    };

    for (dom, filename) in files {
        let path = state.george_dir.join(filename);
        if let Ok(content) = fs::read_to_string(&path).await {
            for line in content.lines() {
                let t = line.trim();
                if !t.is_empty() && !t.starts_with('#') {
                    candidate_pool.push((t.to_string(), dom.to_string()));
                }
            }
        }
    }

    if candidate_pool.is_empty() {
        return (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "No candidate topics found in pool" })),
        )
            .into_response();
    }

    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as usize;
    let idx = (nanos ^ (candidate_pool.len() * 31)) % candidate_pool.len();
    let (chosen_topic, chosen_domain) = &candidate_pool[idx];
    let (category, theme) = domain_to_category_and_theme(chosen_domain);

    Json(json!({
        "ok": true,
        "topic": chosen_topic,
        "domain": chosen_domain,
        "category": category,
        "theme": theme,
        "total_pool_size": candidate_pool.len()
    }))
    .into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/topics/add
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_topics_add(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TopicAddPayload>,
) -> impl IntoResponse {
    let topic = payload.topic.trim();
    if topic.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Topic cannot be empty" })),
        )
            .into_response();
    }

    let raw_domain = payload.domain.as_deref().unwrap_or("academic");
    let norm_domain = normalize_domain(raw_domain);
    let filename = match norm_domain.as_str() {
        "engineering" => "research_topics_engineering.txt",
        "finance" => "research_topics_finance.txt",
        "gaming" => "research_topics_gaming.txt",
        "general_sports_auto" => "research_topics_general_sports_auto.txt",
        _ => "research_topics_academic.txt",
    };

    let target_path = state.george_dir.join(filename);
    let mut current_lines: Vec<String> = Vec::new();
    if let Ok(content) = fs::read_to_string(&target_path).await {
        current_lines = content.lines().map(|s| s.to_string()).collect();
    }

    if !current_lines.iter().any(|l| l.trim().eq_ignore_ascii_case(topic)) {
        current_lines.push(topic.to_string());
        let new_content = current_lines.join("\n") + "\n";
        let _ = fs::write(&target_path, new_content).await;
    }

    let conf_path = state.george_dir.join("research.conf");
    let mut is_active = false;
    if let Ok(conf_text) = fs::read_to_string(&conf_path).await {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&conf_text) {
            if let Some(ad) = parsed["active_domain"].as_str() {
                if normalize_domain(ad) == norm_domain {
                    is_active = true;
                }
            }
        } else {
            for line in conf_text.lines() {
                let trimmed = line.trim();
                if let Some(val) = trimmed.strip_prefix("active_domain=") {
                    let v = val.trim().trim_matches('"').trim_matches('\'');
                    if normalize_domain(v) == norm_domain {
                        is_active = true;
                    }
                }
            }
        }
    }

    if is_active {
        let master_path = state.george_dir.join("research_topics.txt");
        let _ = fs::copy(&target_path, &master_path).await;
    }

    let (category, theme) = domain_to_category_and_theme(&norm_domain);

    Json(json!({
        "ok": true,
        "topic": topic,
        "domain": norm_domain,
        "category": category,
        "theme": theme,
        "count": current_lines.iter().filter(|l| !l.trim().is_empty() && !l.trim().starts_with('#')).count()
    }))
    .into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/mode/set
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_research_mode_set(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<ResearchModeSetPayload>,
) -> impl IntoResponse {
    let norm_domain = normalize_domain(&payload.domain);
    let mut effective_domain = norm_domain.clone();
    if norm_domain == "auto_optimal" {
        let telem_file = state.george_dir.join("social").join("engagement_telemetry.json");
        if let Ok(raw) = fs::read_to_string(&telem_file).await {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw) {
                if let Some(rec) = parsed["recommended_domain"].as_str() {
                    effective_domain = normalize_domain(rec);
                }
            }
        }
        if effective_domain == "auto_optimal" {
            effective_domain = "academic".to_string();
        }
    }

    let filename = match effective_domain.as_str() {
        "engineering" => "research_topics_engineering.txt",
        "finance" => "research_topics_finance.txt",
        "gaming" => "research_topics_gaming.txt",
        "general_sports_auto" => "research_topics_general_sports_auto.txt",
        _ => "research_topics_academic.txt",
    };

    let domain_topics_file = state.george_dir.join(filename);
    let master_topics_file = state.george_dir.join("research_topics.txt");

    if domain_topics_file.exists() {
        let _ = fs::copy(&domain_topics_file, &master_topics_file).await;
    }

    let conf_path = state.george_dir.join("research.conf");
    let mut conf_val: serde_json::Value = if let Ok(content) = fs::read_to_string(&conf_path).await {
        serde_json::from_str(&content).unwrap_or_else(|_| json!({}))
    } else {
        json!({})
    };
    if !conf_val.is_object() {
        conf_val = json!({});
    }
    conf_val["active_domain"] = json!(norm_domain);
    let _ = fs::write(&conf_path, serde_json::to_string_pretty(&conf_val).unwrap_or_default()).await;

    let (category, theme) = domain_to_category_and_theme(&norm_domain);

    let count = if let Ok(c) = fs::read_to_string(&domain_topics_file).await {
        c.lines().filter(|l| !l.trim().is_empty() && !l.trim().starts_with('#')).count()
    } else {
        0
    };

    Json(json!({
        "ok": true,
        "domain": norm_domain,
        "effective_domain": effective_domain,
        "category": category,
        "theme": theme,
        "file": filename,
        "count": count
    }))
    .into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/brainstorm/chat (Option 3: Conversational Brainstorm Sidebar)
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_brainstorm_chat(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<BrainstormChatPayload>,
) -> impl IntoResponse {
    let message = payload.message.trim();
    if message.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "Message cannot be empty" }))).into_response();
    }

    let domain = payload.domain.as_deref().unwrap_or("academic");
    let lodge_str = state.lodge_dir.to_string_lossy().to_string();

    // Check if message demands active research tool execution
    let mut tool_results = Vec::new();
    let msg_lower = message.to_lowercase();

    // 1. Tool check: arXiv search
    if msg_lower.contains("arxiv") || msg_lower.contains("paper") || msg_lower.contains("preprint") {
        let q = extract_query_term(message, &["arxiv", "search for", "find papers on", "find", "about"]);
        let py_cmd = format!(
            "python3 '{}/lib/tools/searxng_backend.py' arxiv --query '{}' --max-results 4 --format markdown 2>&1",
            lodge_str, q.replace('\'', "'\\''")
        );
        if let Ok(out) = tokio::process::Command::new("bash").args(["-c", &py_cmd]).output().await {
            let res_text = String::from_utf8_lossy(&out.stdout).to_string();
            if !res_text.trim().is_empty() && !res_text.contains("ERROR") {
                tool_results.push(format!("### arXiv Literature Search for '{}':\n{}", q, res_text.trim()));
            }
        }
    }

    // 2. Tool check: Web Search
    if msg_lower.contains("search") || msg_lower.contains("google") || msg_lower.contains("look up") || msg_lower.contains("latest news") {
        let q = extract_query_term(message, &["search", "look up", "google", "find"]);
        let cmd = format!(
            "source '{}/lib/comms/web.sh' 2>/dev/null; web_search '{}' 4",
            lodge_str, q.replace('\'', "'\\''")
        );
        if let Ok(out) = tokio::process::Command::new("bash").args(["-c", &cmd]).output().await {
            let res_text = String::from_utf8_lossy(&out.stdout).to_string();
            if !res_text.trim().is_empty() {
                tool_results.push(format!("### Web Telemetry & Document Findings for '{}':\n{}", q, res_text.trim()));
            }
        }
    }

    // 3. Tool check: Web Fetch
    if msg_lower.contains("http://") || msg_lower.contains("https://") {
        if let Some(url) = extract_url(message) {
            let cmd = format!(
                "source '{}/lib/comms/web.sh' 2>/dev/null; web_fetch '{}'",
                lodge_str, url.replace('\'', "'\\''")
            );
            if let Ok(out) = tokio::process::Command::new("bash").args(["-c", &cmd]).output().await {
                let res_text = String::from_utf8_lossy(&out.stdout).to_string();
                let truncated = if res_text.len() > 3000 { format!("{}...\n[Truncated]", &res_text[..3000]) } else { res_text };
                tool_results.push(format!("### Web Document Ingest from <{}>:\n{}", url, truncated.trim()));
            }
        }
    }

    // Compose System Prompt for George Brainstorm Copilot
    let mut system_prompt = format!(
        "You are George, Blue Lodge's Senior Technical Investigator and Brainstorm Copilot.\n\
        Domain Focus: {}\n\
        Design Philosophy: Tony Fadell-inspired craftsmanship. Focused, tactile, empirical, zero-fluff.\n\
        Your Mission: Help the operator explore, stress-test, and formulate rigorous research inquiries for the Sovereign Research Studio.\n\
        Guidelines:\n\
        1. When the operator asks about topics, suggest 2-3 specific, high-leverage inquiry angles with concrete empirical questions.\n\
        2. Format proposed inquiry titles clearly so the operator can launch them into the research pipeline.\n\
        3. Never invent facts or citations. Ground claims in peer-reviewed literature, specifications, or audited balance sheets.\n",
        domain
    );

    if !tool_results.is_empty() {
        system_prompt.push_str("\n--- RECENT TOOL TELEMETRY AND EVIDENCE ---\n");
        for tr in &tool_results {
            system_prompt.push_str(tr);
            system_prompt.push_str("\n\n");
        }
    }

    let mut chat_messages: Vec<serde_json::Value> = vec![
        json!({ "role": "system", "content": system_prompt })
    ];

    if let Some(hist) = payload.history {
        for h in hist.into_iter().take(6) {
            chat_messages.push(h);
        }
    }

    chat_messages.push(json!({ "role": "user", "content": message }));

    let req_body = json!({
        "model": "base",
        "messages": chat_messages,
        "temperature": 0.6,
        "max_tokens": 1000
    });

    let llm_call = tokio::time::timeout(
        std::time::Duration::from_secs(35),
        tokio::process::Command::new("curl")
            .args([
                "-s",
                "--max-time", "30",
                "-X", "POST",
                "-H", "Content-Type: application/json",
                "-d", &req_body.to_string(),
                "http://127.0.0.1:8080/v1/chat/completions"
            ])
            .output()
    ).await;

    let mut reply = String::new();
    if let Ok(Ok(out)) = llm_call {
        if out.status.success() {
            if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&out.stdout) {
                if let Some(content) = val["choices"][0]["message"]["content"].as_str() {
                    reply = content.trim().to_string();
                }
            }
        }
    }

    if reply.is_empty() {
        reply = format!(
            "I've analyzed your inquiry regarding '{}' within the **{}** domain.\n\n\
            Here are two concrete, high-leverage inquiry angles we could forge into full monographs:\n\n\
            1. **Empirical Grounding & Invariant Audit:** Focus on verified constraints, benchmark distributions, and mathematical bounds.\n\
            2. **Comparative Trade-off Analysis:** Contrast primary architectures against prevailing baselines under constrained hardware.\n\n\
            Would you like to search arXiv for recent preprints on this, or forge this directly into an active inquiry?",
            message, domain
        );
    }

    Json(json!({
        "role": "assistant",
        "content": reply,
        "tools_executed": tool_results,
        "timestamp": chrono_utc_now()
    })).into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/publish/:slug
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_research_publish(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let thread_file = research_dir.join(&slug).join("thread.md");

    if !thread_file.exists() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "No thread.md found to publish" }))).into_response();
    }

    let lodge_str = state.lodge_dir.to_string_lossy().to_string();
    let safe_slug = slug.replace('\'', "'\\''");

    // Re-queue thread for social broadcast
    let queue_cmd = format!(
        "cd '{}' && ./lodge /research queue '{}'",
        lodge_str, safe_slug
    );

    let res = tokio::process::Command::new("bash")
        .args(["-c", &queue_cmd])
        .output()
        .await;

    match res {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            Json(json!({
                "status": "published_or_queued",
                "slug": slug,
                "message": stdout.trim()
            })).into_response()
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "error": e.to_string() }))).into_response(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/dossier/:slug/plate
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_dossier_plate(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let verified_path = research_dir.join(&slug);
    let quarantine_path = research_dir.join("quarantine").join(&slug);

    let dir_path = if verified_path.exists() {
        verified_path
    } else if quarantine_path.exists() {
        quarantine_path
    } else {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Dossier not found" }))).into_response();
    };

    let plate_path = dir_path.join("summary_card.png");
    if !plate_path.exists() {
        let venv_py = state.lodge_dir.join(".venv/bin/python");
        let py_bin = if venv_py.exists() {
            venv_py.to_string_lossy().to_string()
        } else {
            "python3".to_string()
        };
        let script = state.lodge_dir.join("lib/tools/research_plate.py");
        let _ = tokio::process::Command::new(&py_bin)
            .args([
                script.to_string_lossy().as_ref(),
                "--research-dir",
                dir_path.to_string_lossy().as_ref(),
            ])
            .output()
            .await;
    }

    match fs::read(&plate_path).await {
        Ok(bytes) => (
            StatusCode::OK,
            [(axum::http::header::CONTENT_TYPE, "image/png")],
            bytes,
        )
            .into_response(),
        Err(_) => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": "Monograph plate not available" })),
        )
            .into_response(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/resynthesize-thread/:slug
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_resynthesize_thread(
    State(state): State<Arc<AppState>>,
    Path(slug): Path<String>,
) -> impl IntoResponse {
    let research_dir = state.george_dir.join("research");
    let dir_path = research_dir.join(&slug);
    if !dir_path.exists() {
        return (StatusCode::NOT_FOUND, Json(json!({ "error": "Dossier not found" }))).into_response();
    }

    let lodge_str = state.lodge_dir.to_string_lossy().to_string();
    let safe_slug = slug.replace('\'', "'\\''");
    let cmd = format!(
        "cd '{}' && ./lodge /research resynthesize '{}'",
        lodge_str, safe_slug
    );

    let res = tokio::process::Command::new("bash")
        .args(["-c", &cmd])
        .current_dir(&state.lodge_dir)
        .output()
        .await;

    match res {
        Ok(out) => {
            let thread = fs::read_to_string(dir_path.join("thread.md")).await.ok();
            let has_plate = dir_path.join("summary_card.png").exists();
            let stdout = String::from_utf8_lossy(&out.stdout).to_string();
            Json(json!({
                "ok": out.status.success(),
                "slug": slug,
                "thread": thread,
                "has_plate": has_plate,
                "output": stdout.trim()
            }))
            .into_response()
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GET /api/research/analytics
// ─────────────────────────────────────────────────────────────────────────────
pub async fn get_social_analytics(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let telem_file = state.george_dir.join("social").join("engagement_telemetry.json");
    if let Ok(raw) = fs::read_to_string(&telem_file).await {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw) {
            return Json(parsed).into_response();
        }
    }

    let script = state.lodge_dir.join("lib/tools/social_analytics.py");
    let out = tokio::process::Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "summary",
            "--lodge-dir",
            state.lodge_dir.to_string_lossy().as_ref(),
            "--offline",
        ])
        .output()
        .await;

    if let Ok(res) = out {
        if let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&res.stdout) {
            return Json(parsed).into_response();
        }
    }

    Json(json!({
        "total_broadcasts": 0,
        "total_likes": 0,
        "total_reposts": 0,
        "total_replies": 0,
        "x_api_budget_used": 0,
        "domains": [],
        "time_windows": [],
        "broadcasts": []
    }))
    .into_response()
}

// ─────────────────────────────────────────────────────────────────────────────
// POST /api/research/analytics/sync
// ─────────────────────────────────────────────────────────────────────────────
pub async fn post_social_analytics_sync(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let script = state.lodge_dir.join("lib/tools/social_analytics.py");
    let out = tokio::process::Command::new("python3")
        .args([
            script.to_string_lossy().as_ref(),
            "sync",
            "--lodge-dir",
            state.lodge_dir.to_string_lossy().as_ref(),
        ])
        .output()
        .await;

    match out {
        Ok(res) => {
            if let Ok(parsed) = serde_json::from_slice::<serde_json::Value>(&res.stdout) {
                Json(parsed).into_response()
            } else {
                let err_txt = String::from_utf8_lossy(&res.stderr).to_string();
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": err_txt })),
                )
                    .into_response()
            }
        }
        Err(e) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": e.to_string() })),
        )
            .into_response(),
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────
fn extract_query_term(msg: &str, prefixes: &[&str]) -> String {
    let lower = msg.to_lowercase();
    for p in prefixes {
        if let Some(idx) = lower.find(p) {
            let sub = &msg[idx + p.len()..];
            let clean = sub.trim().trim_start_matches(':').trim();
            if !clean.is_empty() {
                return clean.to_string();
            }
        }
    }
    msg.to_string()
}

fn extract_url(msg: &str) -> Option<String> {
    for word in msg.split_whitespace() {
        if word.starts_with("http://") || word.starts_with("https://") {
            let trimmed = word.trim_matches(|c| c == '<' || c == '>' || c == ')' || c == '(' || c == '"' || c == '\'');
            return Some(trimmed.to_string());
        }
    }
    None
}
