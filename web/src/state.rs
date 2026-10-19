use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone, Serialize, Deserialize)]
pub struct DockedWorkspace {
    pub path: PathBuf,
    pub mode: String,
    pub branch: String,
    pub repo_name: String,
    pub gitea_synced: bool,
}

#[derive(Clone)]
pub struct AppState {
    pub lodge_dir: PathBuf,
    pub george_dir: PathBuf,
    pub docked_workspace: Arc<tokio::sync::RwLock<DockedWorkspace>>,
    /// Per-install secret required on fund-moving and key-handling routes.
    pub api_token: String,
    /// Paired remote browsers (phone over headscale, etc.).
    pub devices: Arc<crate::devices::DeviceStore>,
}
