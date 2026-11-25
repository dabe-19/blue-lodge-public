use axum::{
    extract::{Path, Query, State},
    response::{IntoResponse, Json},
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::chrono_epoch_secs;
use crate::state::AppState;

fn python_bin(lodge_dir: &std::path::Path) -> PathBuf {
    let venv = lodge_dir.join(".venv/bin/python3");
    if venv.exists() { venv } else { PathBuf::from("python3") }
}

async fn run_py_json(lodge_dir: &std::path::Path, script_rel: &str, args: &[&str]) -> Value {
    let py = python_bin(lodge_dir);
    let script = lodge_dir.join(script_rel);
    let out = tokio::process::Command::new(&py)
        .arg(&script)
        .args(args)
        .env("LODGE_DIR", lodge_dir)
        .env("GEORGE_DIR", lodge_dir.join(".george"))
        .current_dir(lodge_dir)
        .output()
        .await;
    match out {
        Ok(res) => {
            let stdout = String::from_utf8_lossy(&res.stdout).trim().to_string();
            let last_line = stdout.lines().last().unwrap_or("").trim();
            if let Ok(v) = serde_json::from_str::<Value>(&stdout) {
                return v;
            }
            if let Ok(v) = serde_json::from_str::<Value>(last_line) {
                return v;
            }
            let stderr = String::from_utf8_lossy(&res.stderr).trim().to_string();
            json!({
                "status": if res.status.success() { "ok" } else { "error" },
                "message": if !stderr.is_empty() { stderr } else { stdout },
            })
        }
        Err(e) => json!({ "status": "error", "message": format!("Failed to spawn {}: {}", script_rel, e) }),
    }
}

fn plain_id(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

fn resolve_spec_path(lodge: &std::path::Path, cfg: &str) -> Option<PathBuf> {
    let root = lodge.join("configs").canonicalize().ok()?;
    let cand = std::path::Path::new(cfg);
    let p = if cand.is_absolute() { cand.to_path_buf() } else { lodge.join(cand) };
    let rp = p.canonicalize().ok()?;
    let ext_ok = rp.extension().map_or(false, |e| e == "json");
    (rp.starts_with(&root) && rp.is_file() && ext_ok).then_some(rp)
}

#[derive(Deserialize)]
pub struct TrainingRunPayload {
    pub config: Option<String>,
    pub spec: Option<Value>,
    pub dry_run: Option<bool>,
    pub execute: Option<bool>,
    pub force: Option<bool>,
}

#[derive(Deserialize)]
pub struct TrainingActionPayload {
    pub action: String, // "collect" | "merge" | "resume" | "cancel" | "approve" | "deny" | "forge_pantry" | "forge_build"
    pub run_name: Option<String>,
    pub reason: Option<String>,
    pub focus: Option<String>,
    pub count: Option<u32>,
    pub include_journal: Option<bool>,
}

#[derive(Deserialize)]
pub struct TrainingPolicyPayload {
    pub policy: Value,
}

#[derive(Deserialize)]
pub struct HotswapPayload {
    pub endpoint: Option<String>,
    pub scales: Value,
}

#[derive(Deserialize)]
pub struct BackupPayload {
    pub target: Option<String>, // "drive" | "hf" | "both"
    pub hf_repo: Option<String>,
}

#[derive(Deserialize)]
pub struct BenchmarkPayload {
    pub mode: Option<String>, // "run" | "head_to_head" | "compare"
    pub endpoint: Option<String>,
    pub label: Option<String>,
    pub model_family: Option<String>,
    pub file_a: Option<String>,
    pub file_b: Option<String>,
}

#[derive(Deserialize)]
pub struct TrainingWizardPayload {
    pub name: String,
    pub role: Option<String>,
    pub model_slug: Option<String>,
    pub base_model_path: Option<String>,
    pub base_source: Option<String>,
    pub compute_target: Option<String>,
    pub gpu: Option<String>,
    pub rank: Option<u32>,
    pub alpha: Option<u32>,
    pub lr: Option<f64>,
    pub batch_size: Option<u32>,
    pub epochs: Option<u32>,
    pub prior_adapter_weight: Option<f64>,
    pub pause_inference: Option<bool>,
    pub drive_checkpoint_sync: Option<bool>,
    pub focus: Option<String>,
    pub sample_count: Option<u32>,
    pub include_journal: Option<bool>,
}

#[derive(Deserialize)]
pub struct RunLogsQuery {
    pub track: Option<String>,
    pub live: Option<String>,
    pub lines: Option<u32>,
}

/// GET /api/training/runs/:run_name/logs — Stream live Colab or local training logs + GPU telemetry
pub async fn get_training_run_logs(
    State(state): State<Arc<AppState>>,
    Path(run_name): Path<String>,
    Query(q): Query<RunLogsQuery>,
) -> impl IntoResponse {
    if !plain_id(&run_name, 48) {
        return Json(json!({ "status": "error", "message": "Invalid run_name" }));
    }
    let lines_str = q.lines.unwrap_or(80).clamp(10, 300).to_string();
    let mut args = vec!["logs", run_name.as_str(), "--lines", lines_str.as_str()];
    let track_clean = q.track.filter(|t| plain_id(t, 48));
    if let Some(ref t) = track_clean {
        args.push("--track");
        args.push(t.as_str());
    }
    let want_live = match q.live.as_deref() {
        Some("0") | Some("false") | Some("no") => false,
        _ => true,
    };
    if want_live {
        args.push("--live");
    }
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &args).await)
}

#[derive(Deserialize)]
pub struct ColabSessionsQuery {
    pub probe: Option<String>,
}

#[derive(Deserialize)]
pub struct CullVmPayload {
    pub target: Option<String>,
    pub all_stale: Option<bool>,
}

/// GET /api/training/colab/sessions — Live Colab GPU assignments & stale/orphan classification
pub async fn get_colab_sessions(
    State(state): State<Arc<AppState>>,
    Query(q): Query<ColabSessionsQuery>,
) -> impl IntoResponse {
    let want_probe = matches!(q.probe.as_deref(), Some("1") | Some("true") | Some("yes"));
    let mut args = vec!["colab-sessions"];
    if want_probe {
        args.push("--probe");
    }
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &args).await)
}

/// POST /api/training/colab/cull — Terminate a specific Colab GPU VM or cull all stale/orphaned VMs
pub async fn post_colab_cull(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CullVmPayload>,
) -> impl IntoResponse {
    if payload.all_stale.unwrap_or(false) {
        return Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["cull-vm", "--all-stale"]).await);
    }
    let Some(t) = payload.target.filter(|s| plain_id(s, 80)) else {
        return Json(json!({ "status": "error", "message": "Valid target endpoint/session or all_stale:true required" }));
    };
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["cull-vm", "--target", &t]).await)
}

#[derive(Serialize, Deserialize)]
pub struct GateDecisionPayload {
    pub reason: Option<String>,
}

/// GET /api/training/status — Comprehensive Forge state: Colab CU + prerequisites, policy, runs, playbooks, backups
pub async fn get_training_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let lodge = &state.lodge_dir;
    let (credits, policy, gate_queue, adapters, backup_st) = tokio::join!(
        run_py_json(lodge, "scripts/training/check_credits.py", &["--json"]),
        run_py_json(lodge, "scripts/training/runs.py", &["policy"]),
        run_py_json(lodge, "scripts/training/runs.py", &["gate-queue"]),
        run_py_json(lodge, "scripts/training/runs.py", &["adapters"]),
        run_py_json(lodge, "scripts/training/backup_artifacts.py", &["status"]),
    );

    // Scan configs/playbooks/*.json
    let mut playbooks = Vec::new();
    let pb_dir = lodge.join("configs/playbooks");
    if let Ok(mut entries) = fs::read_dir(&pb_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "json") {
                if let Ok(txt) = fs::read_to_string(&p).await {
                    if let Ok(spec) = serde_json::from_str::<Value>(&txt) {
                        playbooks.push(json!({
                            "name": entry.file_name().to_string_lossy(),
                            "path": format!("configs/playbooks/{}", entry.file_name().to_string_lossy()),
                            "spec": spec,
                        }));
                    }
                }
            }
        }
    }

    // List recent benchmark scorecards in benchmarks/results/
    let mut scorecards = Vec::new();
    let bench_dir = lodge.join("benchmarks/results");
    if let Ok(mut entries) = fs::read_dir(&bench_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            let fname = entry.file_name().to_string_lossy().to_string();
            if fname.ends_with(".json") && (fname.contains("multiturn") || fname.contains("bluelodge")) {
                if let Ok(txt) = fs::read_to_string(&p).await {
                    if let Ok(v) = serde_json::from_str::<Value>(&txt) {
                        if v.get("overall_score").is_some() {
                            scorecards.push(json!({
                                "file": fname,
                                "path": format!("benchmarks/results/{}", fname),
                                "model_label": v.get("model_label").and_then(|x| x.as_str()).unwrap_or(&fname),
                                "overall_score": v.get("overall_score"),
                                "early_quit_rate_pct": v.get("early_quit_rate_pct"),
                                "timestamp": v.get("timestamp"),
                            }));
                        }
                    }
                }
            }
        }
    }
    scorecards.sort_by(|a, b| {
        b.get("timestamp").and_then(|x| x.as_str()).unwrap_or("")
            .cmp(a.get("timestamp").and_then(|x| x.as_str()).unwrap_or(""))
    });
    scorecards.truncate(20);

    let adc_summary = if credits.get("status").and_then(|v| v.as_str()) == Some("ok") {
        format!(
            "{} CU (rate: {}, active VMs: {})",
            credits.get("balance").map(|v| v.to_string()).unwrap_or_else(|| "?".into()),
            credits.get("rate").and_then(|v| v.as_str()).unwrap_or("0/hr"),
            credits.get("active_assignments").and_then(|v| v.as_u64()).unwrap_or(0),
        )
    } else {
        credits.get("message").and_then(|v| v.as_str()).unwrap_or("Colab / ADC not configured").to_string()
    };

    Json(json!({
        "status": "ok",
        "adc_status": adc_summary,
        "credits": credits,
        "prerequisites": credits.get("prerequisites").cloned().unwrap_or(json!({})),
        "policy": policy,
        "gate_queue": gate_queue,
        "adapters": adapters,
        "backup_status": backup_st,
        "playbooks": playbooks,
        "scorecards": scorecards,
    }))
}

pub async fn get_training_runs(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["list"]).await)
}

pub async fn get_training_adapters(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["adapters"]).await)
}

/// POST /api/training/run — Preflight (`dry_run: true`) or launch (`dry_run: false`) a JSON training run via runs.py
pub async fn run_training(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingRunPayload>,
) -> impl IntoResponse {
    let lodge = &state.lodge_dir;
    let spec_path = if let Some(spec_val) = payload.spec {
        let tmp_dir = lodge.join(".george/training/specs");
        let _ = fs::create_dir_all(&tmp_dir).await;
        let p = tmp_dir.join(format!("ui_spec_{}.json", chrono_epoch_secs()));
        if let Err(e) = fs::write(&p, serde_json::to_string_pretty(&spec_val).unwrap_or_default()).await {
            return Json(json!({ "status": "error", "message": format!("Failed to write spec: {}", e) }));
        }
        p
    } else {
        let cfg_in = payload.config.unwrap_or_else(|| "configs/playbooks/colab_gemma4_31b_svd32.json".into());
        let Some(p) = resolve_spec_path(lodge, &cfg_in) else {
            return Json(json!({ "status": "error", "message": "config must be a .json file inside configs/" }));
        };
        p
    };

    let spec_str = spec_path.to_string_lossy().to_string();
    let dry_run = payload.dry_run.unwrap_or(false);
    let execute = payload.execute.unwrap_or(false);
    let force = payload.force.unwrap_or(false);

    if dry_run {
        let res = run_py_json(lodge, "scripts/training/runs.py", &["plan", &spec_str]).await;
        return Json(res);
    }

    let mut args = vec!["start", spec_str.as_str()];
    if execute {
        args.push("--execute");
    }
    if force {
        args.push("--force");
    }
    let res = run_py_json(lodge, "scripts/training/runs.py", &args).await;
    Json(res)
}

/// POST /api/training/action — Collect, merge, resume, cancel, approve, deny, forge_pantry, forge_build
pub async fn post_training_action(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingActionPayload>,
) -> impl IntoResponse {
    let lodge = &state.lodge_dir;
    match payload.action.as_str() {
        "forge_pantry" => {
            Json(run_py_json(lodge, "scripts/training/forge.py", &["pantry", "--json"]).await)
        }
        "forge_build" => {
            let focus = payload.focus.unwrap_or_else(|| "persistence,multi-hop,error-recovery,tool-syntax".into());
            let count = payload.count.unwrap_or(400).clamp(10, 50000).to_string();
            let mut args = vec!["build", "--focus", focus.as_str(), "--count", count.as_str()];
            if payload.include_journal.unwrap_or(false) {
                args.push("--include-journal");
            }
            Json(run_py_json(lodge, "scripts/training/forge.py", &args).await)
        }
        "collect" | "merge" | "resume" | "cancel" | "approve" | "deny" => {
            let Some(rn) = payload.run_name.filter(|s| plain_id(s, 48)) else {
                return Json(json!({ "status": "error", "message": "valid run_name is required" }));
            };
            if payload.action == "deny" {
                let reason = payload.reason.unwrap_or_else(|| "Denied in Forge UI".into());
                Json(run_py_json(lodge, "scripts/training/runs.py", &["deny", &rn, "--reason", &reason]).await)
            } else if payload.action == "approve" {
                Json(run_py_json(lodge, "scripts/training/runs.py", &["approve", &rn, "--approver", "forge_ui"]).await)
            } else {
                Json(run_py_json(lodge, "scripts/training/runs.py", &[payload.action.as_str(), &rn]).await)
            }
        }
        _ => Json(json!({ "status": "error", "message": "Unknown training action" })),
    }
}

pub async fn approve_gate_candidate(
    State(state): State<Arc<AppState>>,
    Path(run_name): Path<String>,
) -> impl IntoResponse {
    if !plain_id(&run_name, 48) {
        return Json(json!({ "status": "error", "message": "Invalid run_name" }));
    }
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["approve", &run_name, "--approver", "forge_ui"]).await)
}

pub async fn deny_gate_candidate(
    State(state): State<Arc<AppState>>,
    Path(run_name): Path<String>,
    Json(payload): Json<GateDecisionPayload>,
) -> impl IntoResponse {
    if !plain_id(&run_name, 48) {
        return Json(json!({ "status": "error", "message": "Invalid run_name" }));
    }
    let reason = payload.reason.unwrap_or_else(|| "Denied in Forge UI".into());
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["deny", &run_name, "--reason", &reason]).await)
}

pub async fn post_training_policy(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingPolicyPayload>,
) -> impl IntoResponse {
    let serialized = serde_json::to_string(&payload.policy).unwrap_or_else(|_| "{}".into());
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["policy", "--set", &serialized]).await)
}

pub async fn post_adapter_hotswap(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<HotswapPayload>,
) -> impl IntoResponse {
    let ep = payload.endpoint.unwrap_or_else(|| "http://127.0.0.1:8080".into());
    let scales = serde_json::to_string(&payload.scales).unwrap_or_else(|_| "[]".into());
    Json(run_py_json(&state.lodge_dir, "scripts/training/runs.py", &["hotswap", "--endpoint", &ep, "--scales", &scales]).await)
}

pub async fn post_training_backup(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<BackupPayload>,
) -> impl IntoResponse {
    let tgt = payload.target.unwrap_or_else(|| "both".into());
    let mut args = vec!["backup", "--all", "--target", tgt.as_str()];
    let repo_owned = payload.hf_repo.unwrap_or_default();
    if !repo_owned.is_empty() {
        args.push("--hf-repo");
        args.push(repo_owned.as_str());
    }
    Json(run_py_json(&state.lodge_dir, "scripts/training/backup_artifacts.py", &args).await)
}

pub async fn post_training_benchmark(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<BenchmarkPayload>,
) -> impl IntoResponse {
    let lodge = &state.lodge_dir;
    let mode = payload.mode.unwrap_or_else(|| "head_to_head".into());
    if mode == "head_to_head" || mode == "compare" {
        let Some(fa) = payload.file_a else {
            return Json(json!({ "status": "error", "message": "file_a and file_b required" }));
        };
        let Some(fb) = payload.file_b else {
            return Json(json!({ "status": "error", "message": "file_a and file_b required" }));
        };
        let root = match lodge.join("benchmarks/results").canonicalize() {
            Ok(r) => r,
            Err(_) => return Json(json!({ "status": "error", "message": "benchmarks/results missing" })),
        };
        let pa = root.join(std::path::Path::new(&fa).file_name().unwrap_or_default());
        let pb = root.join(std::path::Path::new(&fb).file_name().unwrap_or_default());
        if !pa.is_file() || !pb.is_file() {
            return Json(json!({ "status": "error", "message": "scorecard file not found" }));
        }
        let flag = if mode == "compare" { "--compare" } else { "--head-to-head" };
        let res = run_py_json(
            lodge,
            "scripts/eval/multiturn_bench.py",
            &[flag, &pa.to_string_lossy(), &pb.to_string_lossy(), "--json"],
        ).await;
        return Json(res);
    }

    let ep = payload.endpoint.unwrap_or_else(|| {
        if std::env::var("KUBERNETES_SERVICE_HOST").is_ok() {
            "http://george-inference:8080".into()
        } else {
            "http://127.0.0.1:8080".into()
        }
    });
    let lbl = payload.label.unwrap_or_else(|| "live-candidate".into());
    let fam = payload.model_family.unwrap_or_else(|| "auto".into());
    let lodge_bg = lodge.clone();
    let ep_bg = ep.clone();
    let lbl_bg = lbl.clone();
    tokio::spawn(async move {
        let _ = run_py_json(
            &lodge_bg,
            "scripts/eval/multiturn_bench.py",
            &["--endpoint", &ep_bg, "--label", &lbl_bg, "--model-family", &fam],
        ).await;
    });
    Json(json!({ "status": "launched", "message": format!("7-Pillar benchmark started against {} ({})", ep, lbl) }))
}

/// POST /api/training/wizard — Forge dataset + generate modern JSON playbook for runs.py
pub async fn generate_training_wizard(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingWizardPayload>,
) -> impl IntoResponse {
    let lodge = &state.lodge_dir;
    let run_name = payload.name.trim().to_lowercase();
    if !plain_id(&run_name, 48) {
        return Json(json!({ "status": "error", "message": "name: lowercase letters, digits, . _ - only (2-48 chars)" }));
    }
    let role = payload.role.unwrap_or_else(|| "core-agent".into());
    let base_model = payload.base_model_path.unwrap_or_else(|| "google/gemma-4-31b-it".into()).trim().to_string();
    let base_source = payload.base_source.unwrap_or_else(|| "hf_direct".into());
    let backend = match payload.compute_target.as_deref().unwrap_or("colab") {
        "local" | "local_dual_gpu" => "local",
        _ => "colab",
    };
    let focus = payload.focus.unwrap_or_else(|| "persistence,multi-hop,error-recovery,tool-syntax,failure-modes".into());
    let sample_count = payload.sample_count.unwrap_or(400).clamp(20, 20000).to_string();

    let mut f_args = vec!["build", "--focus", focus.as_str(), "--count", sample_count.as_str()];
    if payload.include_journal.unwrap_or(true) {
        f_args.push("--include-journal");
    }
    let forge_res = run_py_json(lodge, "scripts/training/forge.py", &f_args).await;
    let ids = forge_res.get("ids").cloned().unwrap_or(json!({}));
    let mut tracks = Vec::new();
    if let Some(sft_tr) = ids.get("sft_train").and_then(|v| v.as_str()) {
        tracks.push(json!({
            "name": "sft-core", "method": "sft", "train": sft_tr,
            "val": ids.get("sft_val").and_then(|v| v.as_str()), "gpu": 0
        }));
    }
    if let Some(dpo_tr) = ids.get("dpo_train").and_then(|v| v.as_str()) {
        tracks.push(json!({
            "name": "dpo-persistence", "method": "dpo", "train": dpo_tr,
            "val": ids.get("dpo_val").and_then(|v| v.as_str()), "gpu": 0
        }));
    }
    if tracks.is_empty() {
        return Json(json!({ "status": "error", "message": "Dataset Forge produced 0 samples for selected focus", "forge": forge_res }));
    }

    let model_slug = payload.model_slug.unwrap_or_else(|| {
        base_model.split('/').last().unwrap_or("model").to_lowercase()
    });
    let gpu = payload.gpu.unwrap_or_else(|| "A100".into());
    let spec = json!({
        "name": run_name,
        "role": role,
        "model_slug": model_slug,
        "backend": backend,
        "base_model": base_model,
        "base_source": base_source,
        "base_hf_path": "",
        "tracks": tracks,
        "hyper": {
            "epochs": payload.epochs.unwrap_or(2).clamp(1, 20),
            "learning_rate": payload.lr.unwrap_or(0.0001).clamp(1e-7, 1e-2),
            "lora_r": payload.rank.unwrap_or(32).clamp(4, 256),
            "lora_alpha": payload.alpha.unwrap_or(64).clamp(8, 512),
            "lora_dropout": 0.05,
            "max_seq_len": 4096,
            "batch_size": payload.batch_size.unwrap_or(1).clamp(1, 32),
            "grad_accum": 8,
            "dpo_beta": 0.1,
            "save_steps": 40,
            "load_in_4bit": true,
            "use_unsloth": true
        },
        "merge": {
            "method": "svd",
            "target_rank": 32,
            "prior_adapter_weight": payload.prior_adapter_weight.unwrap_or(0.70).clamp(0.0, 0.95),
            "weights": Value::Null
        },
        "colab": {
            "auth": "adc",
            "gpu": gpu,
            "gpu_fallback": ["H100", "G4", "A100", "L4", "T4"],
            "min_gpu_vram_gb": 24,
            "high_mem": true,
            "max_concurrent_sessions": 3,
            "min_cu_balance": 150,
            "max_runtime_min": 180,
            "drive_checkpoints": true,
            "drive_checkpoint_sync": payload.drive_checkpoint_sync.unwrap_or(true),
            "drive_checkpoint_keep": 2,
            "export_gguf_on_colab": true
        },
        "local": {
            "pause_inference": payload.pause_inference.unwrap_or(true)
        }
    });

    let pb_dir = lodge.join("configs/playbooks");
    let _ = fs::create_dir_all(&pb_dir).await;
    let filename = format!("{}_{}.json", run_name, chrono_epoch_secs());
    let path = pb_dir.join(&filename);
    let body = serde_json::to_string_pretty(&spec).unwrap_or_default();
    if let Err(e) = fs::write(&path, &body).await {
        return Json(json!({ "status": "error", "message": format!("Failed to write playbook: {}", e) }));
    }

    let preflight = run_py_json(lodge, "scripts/training/runs.py", &["plan", &path.to_string_lossy()]).await;
    Json(json!({
        "status": "ok",
        "filename": filename,
        "config_path": format!("configs/playbooks/{}", filename),
        "spec": spec,
        "forge": forge_res,
        "preflight": preflight,
    }))
}
