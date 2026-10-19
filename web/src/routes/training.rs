use axum::{
    extract::State,
    response::{IntoResponse, Json},
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use tokio::fs;

use crate::helpers::chrono_epoch_secs;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct TrainingRunPayload {
    pub config: Option<String>,
    pub dry_run: Option<bool>,
}

#[derive(Deserialize)]
pub struct TrainingWizardPayload {
    pub name: String,
    pub version: Option<String>,
    pub base_model_path: Option<String>,
    pub compute_target: Option<String>,
    pub rank: Option<u32>,
    pub alpha: Option<u32>,
    pub lr: Option<f64>,
    pub batch_size: Option<u32>,
    pub epochs: Option<u32>,
    pub curricula: Option<Vec<CurriculumSelection>>,
}

#[derive(Serialize, Deserialize)]
pub struct CurriculumSelection {
    pub id: String,
    pub name: String,
    pub path: String,
    pub sampling_weight: f64,
    pub target_adapter_name: String,
}

pub async fn get_training_status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let py_bin = if state.lodge_dir.join(".venv/bin/python3").exists() {
        state.lodge_dir.join(".venv/bin/python3")
    } else {
        std::path::PathBuf::from("python3")
    };

    let check_script = state.lodge_dir.join("scripts/training/check_credits.py");
    let adc_output = if check_script.exists() {
        tokio::process::Command::new(&py_bin)
            .arg(&check_script)
            .current_dir(&state.lodge_dir)
            .output()
            .await
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|_| "Unavailable".into())
    } else {
        "ADC Script Not Found".into()
    };

    // Scan configs directory for YAML training configs
    let mut configs = Vec::new();
    let configs_dir = state.lodge_dir.join("configs");
    if let Ok(mut entries) = fs::read_dir(&configs_dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let p = entry.path();
            if p.extension().map_or(false, |ext| ext == "yaml" || ext == "yml") {
                configs.push(json!({
                    "name": entry.file_name().to_string_lossy(),
                    "path": p.to_string_lossy(),
                    "size_bytes": entry.metadata().await.map(|m| m.len()).unwrap_or(0),
                }));
            }
        }
    }

    Json(json!({
        "status": "ok",
        "adc_status": adc_output,
        "configs": configs,
    }))
}

/// Resolve a training config to a `.yaml`/`.yml` file inside `<lodge>/configs` (no traversal, no symlink escape).
fn resolve_config(lodge: &std::path::Path, cfg: &str) -> Option<std::path::PathBuf> {
    let root = lodge.join("configs").canonicalize().ok()?;
    let cand = std::path::Path::new(cfg);
    let p = if cand.is_absolute() { cand.to_path_buf() } else { root.join(cand) };
    let rp = p.canonicalize().ok()?;
    let ext_ok = rp.extension().map_or(false, |e| e == "yaml" || e == "yml");
    (rp.starts_with(&root) && rp.is_file() && ext_ok).then_some(rp)
}

pub async fn run_training(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingRunPayload>,
) -> impl IntoResponse {
    let cfg_in = payload.config.unwrap_or_else(|| "training_run.template.yaml".into());
    let Some(cfg) = resolve_config(&state.lodge_dir, &cfg_in) else {
        return Json(json!({"status": "error", "message": "config must be a .yaml file inside configs/"}));
    };
    let dry_run = payload.dry_run.unwrap_or(false);
    let script = state.lodge_dir.join("commands/train.sh");
    let lodge = state.lodge_dir.clone();
    let cfg2 = cfg.clone();
    tokio::spawn(async move {
        // argv only: the config path is never interpolated into a shell string.
        let _ = tokio::process::Command::new("bash")
            .arg(&script).arg(if dry_run { "dry-run" } else { "run" }).arg(&cfg2)
            .current_dir(&lodge)
            .output()
            .await;
    });

    Json(json!({
        "status": "launched",
        "config": cfg.to_string_lossy(),
        "dry_run": dry_run,
        "message": if dry_run { "Dry-run validation started" } else { "Training pipeline launched" }
    }))
}

fn plain(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && s.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}
/// JSON string literals are valid YAML double-quoted scalars, so this escapes quotes/newlines safely.
fn yq(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// Writes a model-agnostic training-run spec. Nothing is assumed about the base model: the operator
/// supplies it (a GGUF from their library or an HF repo id), and curricula default to none.
pub async fn generate_training_wizard(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<TrainingWizardPayload>,
) -> impl IntoResponse {
    let run_name = payload.name.trim();
    let version = payload.version.as_deref().unwrap_or("1");
    if !plain(run_name, 64) || !plain(version, 16) {
        return Json(json!({"status": "error", "message": "name and version: letters, digits, . _ - only"}));
    }
    let base_model = payload.base_model_path.as_deref().unwrap_or("").trim().to_string();
    if base_model.is_empty() || base_model.len() > 512 || base_model.chars().any(|c| c.is_control()) {
        return Json(json!({"status": "error", "message": "base_model_path is required (a GGUF path or an HF repo id)"}));
    }
    let target = payload.compute_target.as_deref().unwrap_or("local");
    if !plain(target, 32) {
        return Json(json!({"status": "error", "message": "invalid compute_target"}));
    }
    let rank = payload.rank.unwrap_or(16).clamp(1, 512);
    let alpha = payload.alpha.unwrap_or(32).clamp(1, 1024);
    let lr = payload.lr.unwrap_or(0.0001).clamp(1e-7, 1e-2);
    let batch_size = payload.batch_size.unwrap_or(1).clamp(1, 256);
    let epochs = payload.epochs.unwrap_or(1).clamp(1, 50);

    let timestamp = chrono_epoch_secs();
    let config_dir = state.lodge_dir.join("configs");
    let _ = fs::create_dir_all(&config_dir).await;
    let yaml_filename = format!("training_run_{}_v{}_{}.yaml", run_name, version, timestamp);
    let yaml_path = config_dir.join(&yaml_filename);

    let mut yaml = format!(
r#"# Auto-generated by Blue Lodge Training Wizard
name: {}
version: {}
description: "Generated training run specification"

base_model:
  path: {}

compute:
  target: {}

hyperparameters:
  rank: {}
  lora_alpha: {}
  learning_rate: {}
  batch_size: {}
  gradient_accumulation_steps: 4
  max_seq_length: 4096
  epochs: {}

curricula:
"#,
        yq(run_name), yq(version), yq(&base_model), yq(target), rank, alpha, lr, batch_size, epochs
    );

    for c in payload.curricula.unwrap_or_default() {
        yaml.push_str(&format!(
r#"  - id: {}
    name: {}
    path: {}
    sampling_weight: {}
    target_adapter_name: {}
"#,
            yq(&c.id), yq(&c.name), yq(&c.path), c.sampling_weight.clamp(0.0, 1.0), yq(&c.target_adapter_name)
        ));
    }

    if let Err(e) = fs::write(&yaml_path, &yaml).await {
        return Json(json!({ "status": "error", "message": format!("Failed to write config: {}", e) }));
    }

    Json(json!({
        "status": "ok",
        "config_path": yaml_path.to_string_lossy(),
        "filename": yaml_filename,
        "yaml": yaml
    }))
}
