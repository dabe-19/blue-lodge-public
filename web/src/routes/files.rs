use axum::{
    extract::{Multipart, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json},
};
use serde::Deserialize;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::fs;

use crate::helpers::*;
use crate::state::{AppState, DockedWorkspace};

#[derive(Deserialize)]
pub struct FilesListQuery {
    pub root: Option<String>,
}

#[derive(Deserialize)]
pub struct ReadFileQuery {
    pub path: String,
}

#[derive(Deserialize)]
pub struct SaveFilePayload {
    pub path: String,
    pub content: String,
}

#[derive(Deserialize)]
pub struct DockWorkspacePayload {
    pub path: String,
    pub mode: Option<String>,
}

#[derive(Deserialize)]
pub struct ResolveScriptQuery {
    pub path: String,
}

pub fn validate_bounded_path_strict(
    candidate: &Path,
    state: &AppState,
    docked_path: &Path,
    allow_creation: bool,
) -> Result<PathBuf, (StatusCode, Json<serde_json::Value>)> {
    if candidate.to_string_lossy().contains('\0') {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({ "status": "error", "message": "Invalid path: null byte detected" })),
        ));
    }

    let canonical_lodge = state.lodge_dir.canonicalize().unwrap_or_else(|_| state.lodge_dir.clone());
    let canonical_george = state.george_dir.canonicalize().unwrap_or_else(|_| state.george_dir.clone());
    let canonical_docked = docked_path.canonicalize().unwrap_or_else(|_| docked_path.to_path_buf());

    let norm = normalize_path(candidate);
    let allowed_lexical = norm.starts_with(&canonical_lodge)
        || norm.starts_with(&state.lodge_dir)
        || norm.starts_with(&canonical_george)
        || norm.starts_with(&state.george_dir)
        || norm.starts_with(&canonical_docked)
        || norm.starts_with(docked_path);

    if !allowed_lexical {
        return Err((
            StatusCode::FORBIDDEN,
            Json(json!({ "status": "error", "message": "Access outside workspace denied" })),
        ));
    }

    if norm.exists() {
        match norm.canonicalize() {
            Ok(canonical) => {
                let allowed_canonical = canonical.starts_with(&canonical_lodge)
                    || canonical.starts_with(&canonical_george)
                    || canonical.starts_with(&canonical_docked);
                if allowed_canonical {
                    Ok(canonical)
                } else {
                    Err((
                        StatusCode::FORBIDDEN,
                        Json(json!({ "status": "error", "message": "Access outside workspace denied (symlink escape)" })),
                    ))
                }
            }
            Err(e) => Err((
                StatusCode::NOT_FOUND,
                Json(json!({ "status": "error", "message": e.to_string() })),
            )),
        }
    } else if allow_creation {
        let mut ancestor = norm.as_path();
        while !ancestor.exists() {
            if let Some(parent) = ancestor.parent() {
                ancestor = parent;
            } else {
                break;
            }
        }
        if ancestor.exists() {
            match ancestor.canonicalize() {
                Ok(canonical_ancestor) => {
                    let allowed_ancestor = canonical_ancestor.starts_with(&canonical_lodge)
                        || canonical_ancestor.starts_with(&canonical_george)
                        || canonical_ancestor.starts_with(&canonical_docked);
                    if allowed_ancestor {
                        Ok(norm)
                    } else {
                        Err((
                            StatusCode::FORBIDDEN,
                            Json(json!({ "status": "error", "message": "Access outside workspace denied" })),
                        ))
                    }
                }
                Err(e) => Err((
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "status": "error", "message": e.to_string() })),
                )),
            }
        } else {
            Err((
                StatusCode::FORBIDDEN,
                Json(json!({ "status": "error", "message": "Root directory does not exist" })),
            ))
        }
    } else {
        Err((
            StatusCode::NOT_FOUND,
            Json(json!({ "status": "error", "message": "File not found" })),
        ))
    }
}

pub async fn read_file_content(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ReadFileQuery>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let raw_target = if q.path.starts_with('/') {
        PathBuf::from(&q.path)
    } else {
        docked.path.join(&q.path)
    };

    let target = match validate_bounded_path_strict(&raw_target, &state, &docked.path, false) {
        Ok(t) => t,
        Err(err_resp) => return err_resp.into_response(),
    };

    match fs::read_to_string(&target).await {
        Ok(content) => Json(json!({ "status": "ok", "path": target.to_string_lossy(), "content": content })).into_response(),
        Err(e) => (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

pub async fn save_file_content(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<SaveFilePayload>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let raw_target = if payload.path.starts_with('/') {
        PathBuf::from(&payload.path)
    } else {
        docked.path.join(&payload.path)
    };

    let target = match validate_bounded_path_strict(&raw_target, &state, &docked.path, true) {
        Ok(t) => t,
        Err(err_resp) => return err_resp.into_response(),
    };

    let is_shell_script = target.extension().map_or(false, |ext| ext == "sh")
        || payload.content.starts_with("#!/bin/")
        || payload.content.starts_with("#!/usr/bin/env bash");

    if is_shell_script {
        let temp_file = state.george_dir.join(format!(".syntax_test_{}.sh", chrono_epoch_secs()));
        if let Ok(_) = fs::write(&temp_file, &payload.content).await {
            let check = tokio::process::Command::new("bash")
                .args(["-n", &temp_file.to_string_lossy()])
                .output()
                .await;
            let _ = fs::remove_file(&temp_file).await;

            if let Ok(out) = check {
                if !out.status.success() {
                    let err_msg = String::from_utf8_lossy(&out.stderr).to_string();
                    return Json(json!({
                        "status": "syntax_error",
                        "message": format!("Bash syntax validation failed:\n{}", err_msg.trim())
                    })).into_response();
                }
            }
        }
    }

    if let Some(parent) = target.parent() {
        let _ = fs::create_dir_all(parent).await;
    }

    match fs::write(&target, &payload.content).await {
        Ok(_) => {
            #[cfg(unix)]
            {
                if is_shell_script {
                    use std::os::unix::fs::PermissionsExt;
                    let perms = std::fs::Permissions::from_mode(0o755);
                    let _ = std::fs::set_permissions(&target, perms);
                }
            }
            Json(json!({ "status": "ok", "path": target.to_string_lossy() })).into_response()
        },
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    }
}

#[derive(Clone, Debug, serde::Serialize)]
pub struct AstMetadata {
    pub language: String,
    pub description: String,
    pub exports: Vec<String>,
    pub dependencies: Vec<String>,
}

pub fn determine_file_category(rel_path: &str) -> (&'static str, &'static str) {
    if rel_path.starts_with("lib/core") {
        ("Core Reasoning (lib/core)", "urn:blue-lodge:subsystem:core")
    } else if rel_path.starts_with("lib/tools") {
        ("Tools & Bridges (lib/tools)", "urn:blue-lodge:subsystem:tools")
    } else if rel_path.starts_with("lib/ipc") {
        ("FIFO IPC & Flow Control (lib/ipc)", "urn:blue-lodge:subsystem:ipc")
    } else if rel_path.starts_with("lib/sys") {
        ("System & Security (lib/sys)", "urn:blue-lodge:subsystem:sys")
    } else if rel_path.starts_with("lib/comms") {
        ("Communications (lib/comms)", "urn:blue-lodge:subsystem:comms")
    } else if rel_path.starts_with("lib/memory") {
        ("Memory & Recall (lib/memory)", "urn:blue-lodge:subsystem:memory")
    } else if rel_path.starts_with("lib/agents") {
        ("Agents & Remediation (lib/agents)", "urn:blue-lodge:subsystem:agents")
    } else if rel_path.starts_with("lib/ui") {
        ("Terminal UI (lib/ui)", "urn:blue-lodge:subsystem:ui")
    } else if rel_path.starts_with("lib/knowledge") {
        ("Knowledge & OKF (lib/knowledge)", "urn:blue-lodge:subsystem:knowledge")
    } else if rel_path.starts_with("lib/") {
        ("Core Engine (lib/)", "urn:blue-lodge:subsystem:core")
    } else if rel_path.starts_with("commands") {
        ("Slash Commands (commands/)", "urn:blue-lodge:subsystem:commands")
    } else if rel_path.starts_with("web/src") {
        ("Web Backend (web/src)", "urn:blue-lodge:subsystem:web")
    } else if rel_path.starts_with("web/static") {
        ("Web Frontend (web/static)", "urn:blue-lodge:subsystem:web")
    } else if rel_path.starts_with("web") {
        ("Web UI Sidecar (web/)", "urn:blue-lodge:subsystem:web")
    } else if rel_path.starts_with("scripts") {
        ("Operational Scripts (scripts/)", "urn:blue-lodge:subsystem:scripts")
    } else if rel_path.starts_with("tests") {
        ("Test Suites (tests/)", "urn:blue-lodge:subsystem:tests")
    } else if rel_path.starts_with("dossiers") {
        ("Strategic Dossiers (dossiers/)", "urn:blue-lodge:subsystem:dossiers")
    } else if rel_path.starts_with("okf") {
        ("Google OKF Graph (okf/)", "urn:blue-lodge:subsystem:knowledge")
    } else if rel_path.starts_with("deploy") {
        ("Deployment & Systemd (deploy/)", "urn:blue-lodge:subsystem:sys")
    } else if rel_path.starts_with("config") {
        ("Configuration (config/)", "urn:blue-lodge:subsystem:sys")
    } else if rel_path.starts_with(".agents/workflows") {
        ("Agent Workflows (.agents/workflows)", "urn:blue-lodge:subsystem:agents")
    } else if rel_path.starts_with(".agents/skills") {
        ("Agent Skills (.agents/skills)", "urn:blue-lodge:subsystem:agents")
    } else if rel_path.starts_with(".agents/rules") {
        ("Agent Rules (.agents/rules)", "urn:blue-lodge:subsystem:agents")
    } else if rel_path.starts_with(".agents") {
        ("Agent System (.agents/)", "urn:blue-lodge:subsystem:agents")
    } else if rel_path.starts_with(".george/cron_jobs") {
        ("Autonomic Sweeps (.george/cron_jobs)", "urn:blue-lodge:subsystem:sys")
    } else if rel_path.starts_with(".george") {
        ("George System State (.george/)", "urn:blue-lodge:subsystem:sys")
    } else if rel_path.starts_with("docs") {
        ("Documentation (docs/)", "urn:blue-lodge:core")
    } else if rel_path.starts_with("benchmarks") {
        ("Benchmarks (benchmarks/)", "urn:blue-lodge:subsystem:scripts")
    } else if rel_path.starts_with("bin") {
        ("Binaries & Wrappers (bin/)", "urn:blue-lodge:core")
    } else if rel_path.starts_with("models") {
        ("Model Weights & Specs (models/)", "urn:blue-lodge:subsystem:scripts")
    } else if !rel_path.contains('/') {
        ("Root Architecture", "urn:blue-lodge:core")
    } else {
        ("Other Workspace Files", "urn:blue-lodge:core")
    }
}

pub async fn extract_ast_file_metadata(full_path: &Path, rel_path: &str, ext: &str) -> AstMetadata {
    let mut language = match ext {
        "sh" | "bash" => "Bash".to_string(),
        "rs" => "Rust".to_string(),
        "py" => "Python".to_string(),
        "js" => "JavaScript".to_string(),
        "json" | "jsonld" => "JSON".to_string(),
        "md" => "Markdown".to_string(),
        "sql" => "SQL".to_string(),
        "toml" | "yaml" | "yml" | "env" | "conf" => "Config".to_string(),
        _ => "Plain Text".to_string(),
    };

    let mut desc = String::new();
    let mut exports = Vec::new();
    let mut dependencies = Vec::new();

    if let Ok(content) = fs::read_to_string(full_path).await {
        let lines: Vec<&str> = content.lines().take(60).collect();

        if language == "Plain Text" {
            if let Some(first) = lines.first() {
                if first.starts_with("#!/bin/bash") || first.starts_with("#!/bin/sh") {
                    language = "Bash".to_string();
                } else if first.starts_with("#!/usr/bin/env python") {
                    language = "Python".to_string();
                }
            }
        }

        if language == "Bash" {
            for line in lines.iter().take(35) {
                let trimmed = line.trim();
                if trimmed.starts_with("# DESC:") || trimmed.starts_with("# desc:") {
                    desc = trimmed[7..].trim().to_string();
                    break;
                } else if trimmed.starts_with("# ── ") && desc.is_empty() {
                    let cleaned = trimmed.trim_start_matches("# ── ").trim_end_matches('─').trim();
                    if !cleaned.is_empty() {
                        desc = cleaned.to_string();
                    }
                } else if trimmed.starts_with('#') && !trimmed.starts_with("#!") && desc.is_empty() {
                    let cleaned = trimmed.trim_start_matches('#').trim();
                    if !cleaned.starts_with("═══") && !cleaned.starts_with("───") && cleaned.len() > 14 {
                        desc = cleaned.to_string();
                    }
                }
            }
            if desc.is_empty() {
                let base = full_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                if rel_path.starts_with("commands/") {
                    desc = format!("Slash command handler for /{}", base.replace(".sh", ""));
                } else if rel_path.starts_with("scripts/") {
                    desc = format!("Operational utility script for {}", base);
                } else {
                    desc = format!("Subsystem module for {}", base);
                }
            }

            for line in content.lines() {
                let trimmed = line.trim();
                if let Some(pos) = trimmed.find("() {") {
                    let prefix = trimmed[..pos].trim();
                    let fn_name = prefix.strip_prefix("function ").unwrap_or(prefix).trim();
                    if !fn_name.is_empty() && !fn_name.contains(' ') && !fn_name.starts_with('_') && fn_name != "main" && fn_name != "usage" && fn_name != "help" {
                        if !exports.contains(&fn_name.to_string()) {
                            exports.push(fn_name.to_string());
                        }
                    }
                }
                if trimmed.starts_with("source ") || trimmed.starts_with(". ") {
                    let rest = if trimmed.starts_with("source ") { &trimmed[7..] } else { &trimmed[2..] };
                    let clean = rest.trim_matches(|c| c == '"' || c == '\'' || c == ' ');
                    if let Some(file) = Path::new(clean).file_name() {
                        let f_str = file.to_string_lossy().to_string();
                        if f_str.ends_with(".sh") && !dependencies.contains(&f_str) {
                            dependencies.push(f_str);
                        }
                    }
                }
            }
        } else if language == "Rust" {
            for line in lines.iter().take(25) {
                let trimmed = line.trim();
                if trimmed.starts_with("///") || trimmed.starts_with("//!") {
                    desc = trimmed.trim_start_matches("/! ").trim().to_string();
                    break;
                }
            }
            if desc.is_empty() {
                let base = full_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                desc = format!("Rust server module for {}", base);
            }
            for line in content.lines() {
                let trimmed = line.trim();
                let is_pub_fn = trimmed.starts_with("pub fn ") || trimmed.starts_with("pub async fn ");
                if is_pub_fn {
                    let rest = if trimmed.starts_with("pub async fn ") { &trimmed[13..] } else { &trimmed[7..] };
                    if let Some(p_paren) = rest.find('(') {
                        let fn_name = rest[..p_paren].trim();
                        if !fn_name.is_empty() && !exports.contains(&fn_name.to_string()) {
                            exports.push(fn_name.to_string());
                        }
                    }
                }
            }
        } else if language == "Python" {
            let mut in_doc = false;
            for line in lines.iter().take(30) {
                let trimmed = line.trim();
                if trimmed.contains("\"\"\"") || trimmed.contains("'''") {
                    if !in_doc {
                        in_doc = true;
                        let cleaned = trimmed.replace("\"\"\"", "").replace("'''", "").trim().to_string();
                        if !cleaned.is_empty() {
                            desc = cleaned;
                            break;
                        }
                    } else {
                        break;
                    }
                } else if in_doc {
                    if !trimmed.is_empty() && desc.is_empty() {
                        desc = trimmed.to_string();
                        break;
                    }
                }
            }
            if desc.is_empty() {
                let base = full_path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                desc = format!("Python script for {}", base);
            }
            for line in content.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("def ") {
                    if let Some(p) = trimmed.find('(') {
                        let fn_name = trimmed[4..p].trim();
                        if !fn_name.is_empty() && !fn_name.starts_with('_') && fn_name != "main" && !exports.contains(&fn_name.to_string()) {
                            exports.push(fn_name.to_string());
                        }
                    }
                }
            }
        } else if language == "Markdown" {
            for line in lines.iter().take(10) {
                let trimmed = line.trim();
                if trimmed.starts_with("# ") {
                    desc = trimmed.trim_start_matches("# ").trim().to_string();
                    break;
                }
            }
        }
    }

    AstMetadata {
        language,
        description: desc,
        exports,
        dependencies,
    }
}

pub fn build_directory_tree(files: &[serde_json::Value], root_name: &str) -> serde_json::Value {
    use std::collections::BTreeMap;
    let mut tree_map: BTreeMap<String, (Vec<String>, Vec<serde_json::Value>)> = BTreeMap::new();
    tree_map.insert("".to_string(), (Vec::new(), Vec::new()));

    for f in files {
        let path = f["path"].as_str().unwrap_or("");
        let parts: Vec<&str> = path.split('/').collect();
        if parts.is_empty() {
            continue;
        }

        let mut cur_dir = String::new();
        for i in 0..parts.len() - 1 {
            let next_dir = if cur_dir.is_empty() {
                parts[i].to_string()
            } else {
                format!("{}/{}", cur_dir, parts[i])
            };
            let parent_entry = tree_map.entry(cur_dir.clone()).or_insert_with(|| (Vec::new(), Vec::new()));
            if !parent_entry.0.contains(&next_dir) {
                parent_entry.0.push(next_dir.clone());
            }
            tree_map.entry(next_dir.clone()).or_insert_with(|| (Vec::new(), Vec::new()));
            cur_dir = next_dir;
        }

        if let Some(entry) = tree_map.get_mut(&cur_dir) {
            entry.1.push(f.clone());
        }
    }

    fn assemble_node(
        dir_path: &str,
        name: &str,
        tree_map: &BTreeMap<String, (Vec<String>, Vec<serde_json::Value>)>,
    ) -> serde_json::Value {
        let mut children = Vec::new();
        if let Some((subdirs, dir_files)) = tree_map.get(dir_path) {
            for subdir in subdirs {
                let sub_name = subdir.split('/').last().unwrap_or(subdir);
                children.push(assemble_node(subdir, sub_name, tree_map));
            }
            for file in dir_files {
                children.push(json!({
                    "name": file["name"],
                    "path": file["path"],
                    "type": "file",
                    "size_bytes": file["size_bytes"],
                    "group": file["group"],
                    "category": file["category"],
                    "subsystem": file["subsystem"],
                    "lang": file["lang"],
                    "ext": file["ext"],
                    "desc": file["desc"],
                    "exports_count": file["exports_count"],
                    "exports": file["exports"],
                }));
            }
        }
        json!({
            "name": name,
            "path": dir_path,
            "type": "directory",
            "children": children
        })
    }

    assemble_node("", root_name, &tree_map)
}

pub async fn scan_workspace_ast_files(
    current_dir: &Path,
    base_root: &Path,
    depth: usize,
    out_files: &mut Vec<serde_json::Value>,
) {
    if depth > 6 {
        return;
    }
    if let Ok(mut entries) = fs::read_dir(current_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();

            if name == ".git"
                || name == "target"
                || name == "node_modules"
                || name == ".venv"
                || name == "vendor"
                || name == "__pycache__"
                || name == ".tempmediaStorage"
                || name == ".gemini"
                || name == "tmp"
                || name == "build_prism"
                || name == "build"
                || name == ".sandboxes"
                || name == ".act-runner-data"
                || name == ".gitea-data"
            {
                continue;
            }

            let rel = p.strip_prefix(base_root).unwrap_or(&p);
            let rel_str = rel.to_string_lossy().to_string();

            if p.is_dir() {
                if name == ".george" {
                    let cron_jobs_dir = p.join("cron_jobs");
                    if cron_jobs_dir.is_dir() {
                        Box::pin(scan_workspace_ast_files(&cron_jobs_dir, base_root, depth + 1, out_files)).await;
                    }
                    continue;
                }
                Box::pin(scan_workspace_ast_files(&p, base_root, depth + 1, out_files)).await;
            } else if p.is_file() {
                let ext = p.extension().map_or("".into(), |e| e.to_string_lossy().to_string());
                if ext == "db" || ext == "sqlite" || ext == "bin" || ext == "pyc" || ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "lock" || ext == "pid" {
                    continue;
                }

                let size = entry.metadata().await.map(|m| m.len()).unwrap_or(0);
                let (category, subsystem) = determine_file_category(&rel_str);
                let meta = extract_ast_file_metadata(&p, &rel_str, &ext).await;
                let dir_str = rel.parent().map(|d| d.to_string_lossy().to_string()).unwrap_or_default();

                out_files.push(json!({
                    "name": name,
                    "path": rel_str,
                    "dir": dir_str,
                    "size_bytes": size,
                    "group": category,
                    "category": category,
                    "subsystem": subsystem,
                    "ext": ext,
                    "lang": meta.language,
                    "desc": meta.description,
                    "exports": meta.exports,
                    "exports_count": meta.exports.len(),
                    "depends_on": meta.dependencies,
                }));
            }
        }
    }
}

pub async fn list_blue_lodge_files(state: &AppState) -> axum::response::Response {
    let mut files = Vec::new();
    let root = &state.lodge_dir;

    scan_workspace_ast_files(root, root, 0, &mut files).await;
    files.sort_by(|a, b| a["path"].as_str().unwrap_or("").cmp(b["path"].as_str().unwrap_or("")));

    let tree = build_directory_tree(&files, "blue-lodge");

    Json(json!({
        "status": "ok",
        "root": state.lodge_dir.to_string_lossy(),
        "total_files": files.len(),
        "files": files,
        "tree": tree
    })).into_response()
}

pub async fn list_workspace_files(
    State(state): State<Arc<AppState>>,
    Query(q): Query<FilesListQuery>,
) -> impl IntoResponse {
    let docked = state.docked_workspace.read().await.clone();
    let query_root = q.root.map(PathBuf::from);
    let raw_target_root = query_root.unwrap_or(docked.path.clone());

    let target_root = match validate_bounded_path_strict(&raw_target_root, &state, &docked.path, false) {
        Ok(t) if t.is_dir() => t,
        _ => return (StatusCode::FORBIDDEN, Json(json!({ "status": "error", "message": "Access outside workspace denied" }))).into_response(),
    };

    let canonical_lodge = state.lodge_dir.canonicalize().unwrap_or_else(|_| state.lodge_dir.clone());
    if target_root == canonical_lodge || target_root == state.lodge_dir {
        return list_blue_lodge_files(&state).await;
    }

    let mut files = Vec::new();
    scan_workspace_ast_files(&target_root, &target_root, 0, &mut files).await;
    files.sort_by(|a, b| a["path"].as_str().unwrap_or("").cmp(b["path"].as_str().unwrap_or("")));

    let repo_name = target_root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "workspace".to_string());
    let tree = build_directory_tree(&files, &repo_name);

    Json(json!({
        "status": "ok",
        "root": target_root.to_string_lossy(),
        "total_files": files.len(),
        "files": files,
        "tree": tree
    })).into_response()
}

pub async fn get_active_workspace(
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let ws = state.docked_workspace.read().await.clone();
    let recent_file = state.george_dir.join("workspaces_recent.json");
    let mut recent: Vec<serde_json::Value> = Vec::new();
    if let Ok(data) = fs::read_to_string(&recent_file).await {
        if let Ok(parsed) = serde_json::from_str::<Vec<serde_json::Value>>(&data) {
            recent = parsed;
        }
    }
    if recent.is_empty() {
        recent.push(json!({
            "path": state.lodge_dir.to_string_lossy(),
            "name": "blue-lodge",
            "mode": "local",
            "branch": "develop"
        }));
    }
    Json(json!({
        "status": "ok",
        "workspace": ws,
        "recent": recent
    }))
}

pub async fn dock_workspace(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<DockWorkspacePayload>,
) -> impl IntoResponse {
    let raw_path = payload.path.trim();
    if raw_path.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": "Path cannot be empty" }))).into_response();
    }
    let target_path = PathBuf::from(raw_path);
    if !target_path.exists() || !target_path.is_dir() {
        return (StatusCode::BAD_REQUEST, Json(json!({ "status": "error", "message": format!("Directory not found: {}", raw_path) }))).into_response();
    }

    let mode = payload.mode.unwrap_or_else(|| "local".to_string());
    let repo_name = target_path.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "workspace".to_string());

    let git_check = tokio::process::Command::new("git")
        .args(["-C", target_path.to_str().unwrap_or("."), "branch", "--show-current"])
        .output()
        .await;

    let branch = match git_check {
        Ok(out) if out.status.success() => {
            let b = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if b.is_empty() { "main".into() } else { b }
        }
        _ => "main".into(),
    };

    let new_ws = DockedWorkspace {
        path: target_path.clone(),
        mode,
        branch,
        repo_name: repo_name.clone(),
        gitea_synced: true,
    };

    *state.docked_workspace.write().await = new_ws.clone();

    // Persist to workspace.conf
    let ws_conf = state.george_dir.join("workspace.conf");
    let _ = fs::write(&ws_conf, serde_json::to_string_pretty(&new_ws).unwrap_or_default()).await;

    // Update workspaces_recent.json
    let recent_file = state.george_dir.join("workspaces_recent.json");
    let mut recent: Vec<serde_json::Value> = Vec::new();
    if let Ok(data) = fs::read_to_string(&recent_file).await {
        if let Ok(parsed) = serde_json::from_str::<Vec<serde_json::Value>>(&data) {
            recent = parsed;
        }
    }
    recent.retain(|e| e["path"].as_str() != Some(target_path.to_str().unwrap_or("")));
    recent.insert(0, json!({
        "path": target_path.to_string_lossy(),
        "name": repo_name,
        "mode": new_ws.mode,
        "branch": new_ws.branch
    }));
    recent.truncate(10);
    let _ = fs::write(&recent_file, serde_json::to_string_pretty(&recent).unwrap_or_default()).await;

    Json(json!({
        "status": "ok",
        "workspace": new_ws
    })).into_response()
}

pub async fn resolve_script_deps(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ResolveScriptQuery>,
) -> impl IntoResponse {
    let script_path = PathBuf::from(&q.path);
    let target = if script_path.is_absolute() {
        script_path
    } else {
        state.lodge_dir.join(&script_path)
    };

    if !target.exists() {
        return (StatusCode::NOT_FOUND, Json(json!({ "status": "error", "message": "Script not found" }))).into_response();
    }

    let content = match fs::read_to_string(&target).await {
        Ok(c) => c,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "status": "error", "message": e.to_string() }))).into_response(),
    };

    let mut sourced_deps = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("source ") || trimmed.starts_with(". ") {
            let part = trimmed.trim_start_matches("source ").trim_start_matches(". ").trim();
            let cleaned = part.split_whitespace().next().unwrap_or("").trim_matches('"').trim_matches('\'');
            if !cleaned.is_empty() {
                sourced_deps.push(cleaned.to_string());
            }
        }
    }

    Json(json!({
        "status": "ok",
        "script": target.to_string_lossy(),
        "dependencies": sourced_deps
    })).into_response()
}

pub async fn upload_file(
    State(state): State<Arc<AppState>>,
    mut multipart: Multipart,
) -> impl IntoResponse {
    let upload_dir = state.lodge_dir.join("artifacts");
    let _ = fs::create_dir_all(&upload_dir).await;

    let mut uploaded_files = Vec::new();

    while let Ok(Some(field)) = multipart.next_field().await {
        let file_name = field
            .file_name()
            .map(String::from)
            .unwrap_or_else(|| format!("upload_{}", chrono_epoch_secs()));

        let safe_name = file_name.replace("..", "").replace('/', "_");
        let dest = upload_dir.join(&safe_name);

        if let Ok(data) = field.bytes().await {
            if fs::write(&dest, &data).await.is_ok() {
                let cmd_stage = if safe_name.ends_with(".png")
                    || safe_name.ends_with(".jpg")
                    || safe_name.ends_with(".jpeg")
                    || safe_name.ends_with(".svg")
                {
                    format!("/vision artifacts/{}", safe_name)
                } else {
                    format!("cat artifacts/{}", safe_name)
                };

                uploaded_files.push(json!({
                    "name": safe_name,
                    "path": format!("artifacts/{}", safe_name),
                    "staged_command": cmd_stage,
                }));
            }
        }
    }

    Json(json!({ "uploaded": uploaded_files }))
}
