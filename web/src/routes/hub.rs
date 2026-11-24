//! Model Hub API (Phase 5). Thin, validated wrapper over lib/tools/model_hub_cli.py.
//! Every subprocess is spawned with an argv vector (never a shell string); values that
//! could be read as options (leading '-') are rejected. Mutating routes are token-gated
//! in security.rs (`/api/hub/` non-GET, and `/api/hub/accounts`).
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{process::Stdio, sync::Arc, time::Duration};
use tokio::{io::AsyncWriteExt, process::Command};

use crate::state::AppState;

fn bad(msg: &str) -> Response {
    (StatusCode::BAD_REQUEST, Json(json!({"status": "error", "message": msg}))).into_response()
}

fn ok_chars(s: &str, max: usize, extra: &str) -> bool {
    !s.is_empty()
        && s.len() <= max
        && !s.starts_with('-')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}
fn valid_provider(p: &str) -> bool {
    matches!(p, "huggingface" | "hf" | "modelscope" | "ms" | "all")
}
fn valid_repo(r: &str) -> bool {
    ok_chars(r, 96, "._-/") && r.matches('/').count() == 1 && !r.contains("..")
}
fn valid_name(n: &str) -> bool {
    ok_chars(n, 64, "._-") && n.chars().next().map_or(false, |c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && n.chars().all(|c| !c.is_ascii_uppercase())
}
fn valid_quant(q: &str) -> bool {
    ok_chars(q, 32, "._-")
}
fn valid_kv(k: &str) -> bool {
    matches!(k, "f16" | "bf16" | "q8_0" | "q5_1" | "q5_0" | "q4_1" | "q4_0" | "iq4_nl")
}

fn python(state: &AppState) -> String {
    let venv = state.lodge_dir.join(".venv/bin/python");
    if venv.exists() { venv.display().to_string() } else { "python3".into() }
}

/// Run the hub CLI with argv; returns parsed JSON (or an error object).
async fn cli(state: &AppState, args: &[&str], stdin: Option<String>, secs: u64) -> Value {
    let script = state.lodge_dir.join("lib/tools/model_hub_cli.py");
    let mut cmd = Command::new(python(state));
    cmd.arg(script).args(args).current_dir(&state.lodge_dir)
        .env("LODGE_DIR", &state.lodge_dir)
        .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => return json!({"error": format!("spawn failed: {e}")}),
    };
    if let (Some(data), Some(mut si)) = (stdin, child.stdin.take()) {
        let _ = si.write_all(data.as_bytes()).await;
        drop(si);
    }
    match tokio::time::timeout(Duration::from_secs(secs), child.wait_with_output()).await {
        Ok(Ok(out)) => serde_json::from_slice::<Value>(&out.stdout)
            .unwrap_or_else(|_| json!({"error": String::from_utf8_lossy(&out.stderr).chars().take(400).collect::<String>()})),
        Ok(Err(e)) => json!({"error": e.to_string()}),
        Err(_) => json!({"error": "hub request timed out"}),
    }
}

fn reply(v: Value) -> Response {
    let code = if v.get("error").is_some() { StatusCode::UNPROCESSABLE_ENTITY } else { StatusCode::OK };
    (code, Json(v)).into_response()
}

pub async fn hw(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["hw"], None, 30).await)
}

#[derive(Deserialize)]
pub struct SearchQ { q: String, provider: Option<String>, limit: Option<u32> }
pub async fn search(State(s): State<Arc<AppState>>, Query(p): Query<SearchQ>) -> Response {
    let prov = p.provider.unwrap_or_else(|| "huggingface".into());
    let q = p.q.trim();
    if q.is_empty() || q.len() > 120 || q.starts_with('-') || q.chars().any(|c| c.is_control()) {
        return bad("invalid query");
    }
    if !valid_provider(&prov) { return bad("invalid provider"); }
    let lim = p.limit.unwrap_or(20).clamp(1, 50).to_string();
    reply(cli(&s, &["search", q, "--provider", &prov, "--limit", &lim], None, 60).await)
}

#[derive(Deserialize)]
pub struct RepoQ { provider: String, repo: String, ctx: Option<u32>, kv: Option<String> }
pub async fn inspect(State(s): State<Arc<AppState>>, Query(p): Query<RepoQ>) -> Response {
    if !valid_provider(&p.provider) || !valid_repo(&p.repo) { return bad("invalid provider or repo"); }
    reply(cli(&s, &["inspect", &p.provider, &p.repo], None, 60).await)
}
pub async fn quants(State(s): State<Arc<AppState>>, Query(p): Query<RepoQ>) -> Response {
    if !valid_provider(&p.provider) || !valid_repo(&p.repo) { return bad("invalid provider or repo"); }
    let ctx = p.ctx.unwrap_or(32768).clamp(512, 1_048_576).to_string();
    let kv = p.kv.unwrap_or_else(|| "f16".into());
    if !valid_kv(&kv) { return bad("invalid kv type"); }
    reply(cli(&s, &["quants", &p.provider, &p.repo, "--ctx", &ctx, "--kv", &kv], None, 120).await)
}

#[derive(Deserialize)]
pub struct DraftBody {
    provider: String, repo: String, quant: String,
    ctx: Option<u32>, kv: Option<String>, name: Option<String>,
    #[serde(default)] with_mmproj: bool, #[serde(default)] with_draft: bool,
}
pub async fn draft(State(s): State<Arc<AppState>>, Json(b): Json<DraftBody>) -> Response {
    if !valid_provider(&b.provider) || !valid_repo(&b.repo) || !valid_quant(&b.quant) {
        return bad("invalid provider, repo or quant");
    }
    let ctx = b.ctx.unwrap_or(32768).clamp(512, 1_048_576).to_string();
    let kv = b.kv.unwrap_or_else(|| "f16".into());
    if !valid_kv(&kv) { return bad("invalid kv type"); }
    let mut args: Vec<String> = vec!["draft-from".into(), b.provider, b.repo, b.quant, "--ctx".into(), ctx, "--kv".into(), kv, "--operator".into()];
    if let Some(n) = b.name.filter(|n| !n.is_empty()) {
        if !valid_name(&n) { return bad("invalid profile name"); }
        args.push("--name".into()); args.push(n);
    }
    if b.with_mmproj { args.push("--with-mmproj".into()); }
    if b.with_draft { args.push("--with-draft".into()); }
    let refs: Vec<&str> = args.iter().map(String::as_str).collect();
    reply(cli(&s, &refs, None, 120).await)
}

pub async fn profiles(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["profiles"], None, 30).await)
}

pub async fn profile_show(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    reply(cli(&s, &["show", &name], None, 30).await)
}

pub async fn profile_approve(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    reply(cli(&s, &["approve", &name], None, 30).await)
}

pub async fn profile_install(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    // Pre-check approval synchronously so the UI gets an immediate, honest error.
    let shown = cli(&s, &["show", &name], None, 30).await;
    if shown.get("error").is_some() { return reply(shown); }
    if shown.get("approved_valid") != Some(&Value::Bool(true)) {
        return reply(json!({"error": "profile is not approved (or was edited after approval)"}));
    }
    let st = s.clone();
    let n = name.clone();
    tokio::spawn(async move {
        let _ = cli(&st, &["install", &n], None, 60 * 60 * 24).await;
    });
    Json(json!({"status": "started", "name": name})).into_response()
}

pub async fn profile_progress(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    reply(cli(&s, &["progress", &name], None, 15).await)
}

pub async fn profile_cancel(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    reply(cli(&s, &["cancel", &name], None, 15).await)
}

#[derive(Deserialize, Default)]
pub struct RemoveQ { #[serde(default)] delete_files: bool }
pub async fn profile_remove(State(s): State<Arc<AppState>>, Path(name): Path<String>, Query(q): Query<RemoveQ>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    let mut args = vec!["remove", name.as_str()];
    if q.delete_files { args.push("--delete-files"); }
    reply(cli(&s, &args, None, 60).await)
}

#[derive(Deserialize, Default)]
pub struct ActivateBody { #[serde(default)] dry_run: bool }
async fn activate_cmd(s: &AppState, args: &[&str], secs: u64) -> Value {
    let script = s.lodge_dir.join("scripts/inference/activate_profile.sh");
    let fut = Command::new("bash").arg(script).args(args).current_dir(&s.lodge_dir)
        .env("LODGE_DIR", &s.lodge_dir).stdin(Stdio::null()).kill_on_drop(true).output();
    match tokio::time::timeout(Duration::from_secs(secs), fut).await {
        Ok(Ok(o)) => json!({
            "status": if o.status.success() { "ok" } else { "error" },
            "output": String::from_utf8_lossy(&o.stdout),
            "stderr": String::from_utf8_lossy(&o.stderr),
        }),
        Ok(Err(e)) => json!({"error": e.to_string()}),
        Err(_) => json!({"error": "activation timed out (the server may still be loading; check /api/models/status)"}),
    }
}
pub async fn profile_activate(State(s): State<Arc<AppState>>, Path(name): Path<String>, body: Option<Json<ActivateBody>>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    let dry = body.map(|b| b.dry_run).unwrap_or(false);
    let mut args = vec![name.as_str()];
    if dry { args.push("--dry-run"); }
    Json(activate_cmd(&s, &args, 420).await).into_response()
}
pub async fn rollback(State(s): State<Arc<AppState>>) -> Response {
    Json(activate_cmd(&s, &["--rollback"], 120).await).into_response()
}

pub async fn accounts(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["accounts"], None, 30).await)
}

#[derive(Deserialize)]
pub struct LoginBody { provider: String, token: String }
pub async fn login(State(s): State<Arc<AppState>>, Json(b): Json<LoginBody>) -> Response {
    if !matches!(b.provider.as_str(), "huggingface" | "modelscope") { return bad("invalid provider"); }
    let tok = b.token.trim().to_string();
    if tok.is_empty() || tok.len() > 512 || tok.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return bad("invalid token format");
    }
    // Token travels via stdin only — never argv (visible in /proc) and never logged.
    reply(cli(&s, &["login", &b.provider], Some(format!("{tok}\n")), 30).await)
}

#[derive(Deserialize)]
pub struct LogoutBody { provider: String }
pub async fn logout(State(s): State<Arc<AppState>>, Json(b): Json<LogoutBody>) -> Response {
    if !matches!(b.provider.as_str(), "huggingface" | "modelscope") { return bad("invalid provider"); }
    reply(cli(&s, &["logout", &b.provider], None, 15).await)
}

// ── Local library (the operator's own GGUFs) ──────────────────────────────────────────────

/// Relative path inside MODELS_DIR: plain chars, no traversal, no option-looking values, `.gguf` only.
/// The CLI re-checks the resolved path against the models directory (symlink escapes included).
fn valid_rel(p: &str) -> bool {
    ok_chars(p, 512, "._-/+@")
        && !p.starts_with('/')
        && !p.split('/').any(|seg| seg.is_empty() || seg == "." || seg == ".." || seg.starts_with('-'))
        && p.to_ascii_lowercase().ends_with(".gguf")
}
fn valid_ds_id(d: &str) -> bool {
    (d.starts_with("training:") || d.starts_with("exports:"))
        && ok_chars(d, 300, "._-/:")
        && !d.contains("..")
}

pub async fn library(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["library"], None, 120).await)
}

#[derive(Deserialize)]
pub struct FitLocalQ { file: String, ctx: Option<u32>, kv: Option<String>, mmproj: Option<String>, draft: Option<String> }
fn local_args(verb: &str, file: &str, ctx: Option<u32>, kv: Option<String>, mmproj: Option<String>, draft: Option<String>)
    -> Result<Vec<String>, &'static str> {
    if !valid_rel(file) { return Err("invalid file path"); }
    let mut a: Vec<String> = vec![verb.into(), file.into()];
    if let Some(c) = ctx { a.push("--ctx".into()); a.push(c.clamp(512, 1_048_576).to_string()); }
    let kv = kv.unwrap_or_else(|| "f16".into());
    if !valid_kv(&kv) { return Err("invalid kv type"); }
    a.push("--kv".into()); a.push(kv);
    for (flag, v) in [("--mmproj", mmproj), ("--draft", draft)] {
        if let Some(v) = v.filter(|v| !v.is_empty()) {
            if !valid_rel(&v) { return Err("invalid mmproj/draft path"); }
            a.push(flag.into()); a.push(v);
        }
    }
    Ok(a)
}
pub async fn fit_local(State(s): State<Arc<AppState>>, Query(q): Query<FitLocalQ>) -> Response {
    match local_args("fit-local", &q.file, q.ctx, q.kv, q.mmproj, q.draft) {
        Ok(a) => { let r: Vec<&str> = a.iter().map(String::as_str).collect(); reply(cli(&s, &r, None, 60).await) }
        Err(e) => bad(e),
    }
}

#[derive(Deserialize)]
pub struct ImportBody {
    file: String, name: String, ctx: Option<u32>, kv: Option<String>,
    mmproj: Option<String>, draft: Option<String>, #[serde(default)] approve: bool,
}
/// Hashes every file (minutes for large models) in the background; poll /api/hub/profile/:name/progress.
pub async fn import_local(State(s): State<Arc<AppState>>, Json(b): Json<ImportBody>) -> Response {
    if !valid_name(&b.name) { return bad("invalid profile name"); }
    let mut a = match local_args("import-local", &b.file, b.ctx, b.kv, b.mmproj, b.draft) {
        Ok(a) => a,
        Err(e) => return bad(e),
    };
    // Fail fast on fit / kind errors before spawning the long hash job.
    let pre: Vec<String> = { let mut p = a.clone(); p[0] = "fit-local".into(); p };
    let pre_refs: Vec<&str> = pre.iter().map(String::as_str).collect();
    let fit = cli(&s, &pre_refs, None, 60).await;
    if fit.get("error").is_some() { return reply(fit); }
    if fit.get("verdict").and_then(Value::as_str) == Some("does_not_fit") {
        return reply(json!({"error": "does not fit this machine at this context; lower the context or pick a smaller quant"}));
    }
    a.push("--name".into()); a.push(b.name.clone());
    if b.approve { a.push("--approve".into()); }
    let st = s.clone();
    tokio::spawn(async move {
        let r: Vec<&str> = a.iter().map(String::as_str).collect();
        let _ = cli(&st, &r, None, 60 * 60 * 6).await;
    });
    Json(json!({"status": "started", "name": b.name})).into_response()
}

#[derive(Deserialize)]
pub struct DeleteFileQ { file: String, #[serde(default)] force: bool }
pub async fn delete_file(State(s): State<Arc<AppState>>, Query(q): Query<DeleteFileQ>) -> Response {
    if !valid_rel(&q.file) { return bad("invalid file path"); }
    let mut a = vec!["delete-file", q.file.as_str()];
    if q.force { a.push("--force"); }
    reply(cli(&s, &a, None, 60).await)
}

pub async fn profile_tune(State(s): State<Arc<AppState>>, Path(name): Path<String>, Json(b): Json<Value>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    if !b.is_object() { return bad("expected {\"server\": {...}, \"sampling\": {...}}"); }
    // Edits travel via stdin as JSON; the CLI enforces the key allow-list and typed ranges.
    reply(cli(&s, &["tune", &name], Some(b.to_string()), 30).await)
}

#[derive(Deserialize)]
pub struct AttachBody { role: String, file: String, scale: Option<f64> }
pub async fn profile_attach(State(s): State<Arc<AppState>>, Path(name): Path<String>, Json(b): Json<AttachBody>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    if !matches!(b.role.as_str(), "lora" | "control_vector") { return bad("role must be lora or control_vector"); }
    if !valid_rel(&b.file) { return bad("invalid file path"); }
    let scale = b.scale.unwrap_or(1.0);
    if !(-4.0..=4.0).contains(&scale) { return bad("scale must be within [-4, 4]"); }
    let sc = format!("{scale}");
    reply(cli(&s, &["attach", &name, &b.role, &b.file, "--from-library", "--scale", &sc], None, 300).await)
}

#[derive(Deserialize)]
pub struct DetachBody { file: String }
pub async fn profile_detach(State(s): State<Arc<AppState>>, Path(name): Path<String>, Json(b): Json<DetachBody>) -> Response {
    if !valid_name(&name) { return bad("invalid profile name"); }
    if !ok_chars(&b.file, 200, "._-+@") || !b.file.ends_with(".gguf") { return bad("invalid adapter file"); }
    reply(cli(&s, &["detach", &name, &b.file], None, 30).await)
}

pub async fn jobs(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["jobs"], None, 15).await)
}
pub async fn job_clear(State(s): State<Arc<AppState>>, Path(name): Path<String>) -> Response {
    if !valid_name(&name) { return bad("invalid job name"); }
    reply(cli(&s, &["clear-job", &name], None, 15).await)
}

pub async fn server_status(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["server-status"], None, 20).await)
}
pub async fn presets(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["presets"], None, 15).await)
}
#[derive(Deserialize, Default)]
pub struct PresetBody { #[serde(default)] status: bool }
pub async fn preset_run(State(s): State<Arc<AppState>>, Path(id): Path<String>, body: Option<Json<PresetBody>>) -> Response {
    if !ok_chars(&id, 32, "_-") || id.chars().any(|c| c.is_ascii_uppercase()) { return bad("invalid preset id"); }
    let mut a = vec!["preset-run", id.as_str()];
    if body.map(|b| b.status).unwrap_or(false) { a.push("--status"); }
    reply(cli(&s, &a, None, 960).await)
}

// ── Fine-tuning helpers (datasets + kits; training itself runs in the operator's env) ─────

pub async fn datasets(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["datasets"], None, 30).await)
}
#[derive(Deserialize)]
pub struct DsRepoQ { repo: String }
pub async fn dataset_files(State(s): State<Arc<AppState>>, Query(q): Query<DsRepoQ>) -> Response {
    if !valid_repo(&q.repo) { return bad("invalid dataset repo"); }
    reply(cli(&s, &["dataset-files", &q.repo], None, 60).await)
}
#[derive(Deserialize)]
pub struct DsPullBody { repo: String, path: String }
pub async fn dataset_pull(State(s): State<Arc<AppState>>, Json(b): Json<DsPullBody>) -> Response {
    if !valid_repo(&b.repo) { return bad("invalid dataset repo"); }
    if !ok_chars(&b.path, 300, "._-/+@") || b.path.contains("..") || b.path.starts_with('/') { return bad("invalid dataset path"); }
    let st = s.clone();
    tokio::spawn(async move {
        let _ = cli(&st, &["dataset-pull", &b.repo, &b.path], None, 60 * 60 * 6).await;
    });
    Json(json!({"status": "started"})).into_response()
}
#[derive(Deserialize, Default)]
pub struct ExportBody { since: Option<String> }
pub async fn export_runs(State(s): State<Arc<AppState>>, body: Option<Json<ExportBody>>) -> Response {
    let since = body.and_then(|b| b.since.clone()).filter(|x| !x.is_empty());
    match since {
        Some(d) => {
            if d.len() != 10 || !d.chars().all(|c| c.is_ascii_digit() || c == '-') { return bad("since must be YYYY-MM-DD"); }
            reply(cli(&s, &["export-runs", "--since", &d], None, 620).await)
        }
        None => reply(cli(&s, &["export-runs"], None, 620).await),
    }
}
pub async fn train_kit(State(s): State<Arc<AppState>>, Json(b): Json<Value>) -> Response {
    let Some(o) = b.as_object() else { return bad("expected a JSON object") };
    for k in ["train", "val"] {
        if let Some(v) = o.get(k).and_then(Value::as_str) {
            if !v.is_empty() && !valid_ds_id(v) { return bad("invalid dataset id"); }
        }
    }
    reply(cli(&s, &["train-kit"], Some(b.to_string()), 30).await)
}
/// Dataset Forge: recipe catalogue (static, fast).
pub async fn forge_recipes(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["forge-recipes"], None, 30).await)
}
/// Dataset Forge: how many unique samples each recipe can cut from the operator's transcripts.
pub async fn forge_pantry(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["forge-pantry"], None, 620).await)
}
/// Dataset Forge: build in the background; progress shows up in /api/hub/jobs as "forge".
pub async fn forge_build(State(s): State<Arc<AppState>>, Json(b): Json<Value>) -> Response {
    let Some(o) = b.as_object() else { return bad("expected a JSON object") };
    let focus = o.get("focus").and_then(Value::as_str).unwrap_or("mix");
    if focus.is_empty() || focus.len() > 200 || !focus.chars().all(|c| c.is_ascii_lowercase() || c == '-' || c == ',') {
        return bad("focus: 'mix' or comma-separated recipe names");
    }
    match o.get("count").and_then(Value::as_u64) {
        Some(n) if (1..=200_000).contains(&n) => {}
        _ => return bad("count must be 1-200000"),
    }
    let body = b.to_string();
    if body.len() > 4096 { return bad("request too large"); }
    let st = s.clone();
    tokio::spawn(async move {
        let _ = cli(&st, &["forge-build"], Some(body), 60 * 60 * 3 + 60).await;
    });
    Json(json!({"status": "started", "job": "forge"})).into_response()
}
pub async fn kits(State(s): State<Arc<AppState>>) -> Response {
    reply(cli(&s, &["kits"], None, 15).await)
}

#[derive(Deserialize)]
pub struct AskBody { question: String }
/// Model Copilot: launches a George ReAct run restricted to the model_hub tool profile.
pub async fn ask(State(s): State<Arc<AppState>>, Json(b): Json<AskBody>) -> Response {
    let q = b.question.trim().to_string();
    if q.is_empty() || q.len() > 4000 { return bad("question must be 1-4000 characters"); }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let sid = format!("copilot_{}_{:08x}", now.as_secs(), now.subsec_nanos() ^ std::process::id());
    let lodge = s.lodge_dir.clone();
    let sid2 = sid.clone();
    tokio::spawn(async move {
        // Question is passed as a positional parameter ($1), never interpolated into the script.
        let _ = Command::new("bash")
            .args(["-c", "source \"$LODGE_DIR/lib/tools/model_hub.sh\" && model_hub_ask \"$1\"", "model_hub_ask", &q])
            .current_dir(&lodge).env("LODGE_DIR", &lodge).env("REACT_SESSION_ID", &sid2)
            .env("DISCORD_STATUS_ENABLED", "0").stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .kill_on_drop(false).status().await;
    });
    Json(json!({"status": "started", "run_id": sid})).into_response()
}

pub async fn ask_status(State(s): State<Arc<AppState>>, Path(sid): Path<String>) -> Response {
    if !sid.starts_with("copilot_") || !ok_chars(&sid, 64, "_") { return bad("invalid run id"); }
    let george = std::env::var("GEORGE_DIR").map(std::path::PathBuf::from).unwrap_or_else(|_| s.lodge_dir.join(".george"));
    let dir = george.join("runs").join(&sid);
    let run: Value = tokio::fs::read(dir.join("run.json")).await.ok()
        .and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(json!({"status": "STARTING"}));
    let final_reply = tokio::fs::read_to_string(dir.join("final_reply.md")).await.unwrap_or_default();
    Json(json!({
        "run_id": sid,
        "status": run.get("status").cloned().unwrap_or(json!("STARTING")),
        "outcome": run.get("outcome").cloned().unwrap_or(Value::Null),
        "reply": final_reply,
    })).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validators() {
        assert!(valid_repo("unsloth/Qwen3-8B-GGUF"));
        assert!(!valid_repo("../etc/passwd"));
        assert!(!valid_repo("a/b/c"));
        assert!(!valid_repo("-x/y"));
        assert!(!valid_repo("a/b;rm"));
        assert!(valid_name("qwen3-8b-q4_k_m"));
        assert!(!valid_name("Qwen"));
        assert!(!valid_name("-rf"));
        assert!(valid_quant("UD-Q4_K_XL"));
        assert!(!valid_quant("--delete-files"));
        assert!(valid_kv("q8_0") && !valid_kv("q2"));
        assert!(valid_provider("modelscope") && !valid_provider("file"));
        assert!(valid_rel("mine/My-Model-Q4_K_M.gguf"));
        assert!(valid_rel("a/b/c-00001-of-00003.gguf"));
        assert!(!valid_rel("../x.gguf"));
        assert!(!valid_rel("a/../../x.gguf"));
        assert!(!valid_rel("/etc/x.gguf"));
        assert!(!valid_rel("a//x.gguf"));
        assert!(!valid_rel("a/-rf.gguf"));
        assert!(!valid_rel("x.bin"));
        assert!(!valid_rel("a b.gguf"));
        assert!(valid_ds_id("exports:lora_x/train.jsonl") && valid_ds_id("training:active/a.jsonl"));
        assert!(!valid_ds_id("exports:../../etc/passwd") && !valid_ds_id("/etc/passwd"));
    }
}
