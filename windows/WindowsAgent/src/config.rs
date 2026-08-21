use std::{fs, path::PathBuf, sync::Arc};

use directories::ProjectDirs;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};

use crate::error::{AgentError, AgentResult};

pub const DEFAULT_PORT: u16 = 45900;
pub const DEFAULT_DEEPSEEK_CREDENTIAL: &str = "WindowsAgent/DeepSeek";

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    pub port: u16,
    pub bind_address: String,
    pub workspaces: Vec<WorkspaceConfig>,
    pub models: Vec<ModelProfile>,
    pub current_model: Option<String>,
    pub max_tasks: usize,
    pub max_model_tool_steps: usize,
    pub task_retention_days: u64,
    pub max_output_bytes: usize,
}

impl Default for AppConfig {
    fn default() -> Self {
        let profile = ModelProfile::deepseek_default();
        Self {
            port: DEFAULT_PORT,
            bind_address: "0.0.0.0".to_owned(),
            workspaces: Vec::new(),
            current_model: Some(profile.id.clone()),
            models: vec![profile],
            max_tasks: 4,
            max_model_tool_steps: 12,
            task_retention_days: 14,
            max_output_bytes: 2 * 1024 * 1024,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct ModelProfile {
    pub id: String,
    pub name: String,
    pub base_url: String,
    pub model: String,
    pub credential: String,
    pub supports_images: bool,
    pub timeout_seconds: u64,
    pub input_cost_per_million: Option<f64>,
    pub output_cost_per_million: Option<f64>,
}

impl ModelProfile {
    pub fn deepseek_default() -> Self {
        Self {
            id: "deepseek-v4-flash".to_owned(),
            name: "DeepSeek V4 Flash".to_owned(),
            base_url: "https://api.deepseek.com/v1".to_owned(),
            model: "deepseek-v4-flash".to_owned(),
            credential: DEFAULT_DEEPSEEK_CREDENTIAL.to_owned(),
            supports_images: false,
            timeout_seconds: 120,
            input_cost_per_million: None,
            output_cost_per_million: None,
        }
    }

    pub fn validate(&self) -> AgentResult<()> {
        validate_id(&self.id)?;
        if self.name.trim().is_empty() || self.name.len() > 100 {
            return Err(AgentError::InvalidArgument("模型名称无效".to_owned()));
        }
        let url = reqwest::Url::parse(self.base_url.trim())
            .map_err(|error| AgentError::InvalidArgument(format!("API 地址无效: {error}")))?;
        if !matches!(url.scheme(), "http" | "https") {
            return Err(AgentError::InvalidArgument(
                "API 地址只允许 http 或 https".to_owned(),
            ));
        }
        if self.model.trim().is_empty() || self.model.len() > 200 {
            return Err(AgentError::InvalidArgument("模型标识无效".to_owned()));
        }
        if self.credential.len() > 200 {
            return Err(AgentError::InvalidArgument("凭据名称无效".to_owned()));
        }
        if !(5..=900).contains(&self.timeout_seconds) {
            return Err(AgentError::InvalidArgument(
                "模型超时必须在 5 到 900 秒之间".to_owned(),
            ));
        }
        Ok(())
    }

    pub fn chat_completions_url(&self) -> String {
        let base = self.base_url.trim_end_matches('/');
        if base.ends_with("/chat/completions") {
            base.to_owned()
        } else {
            format!("{base}/chat/completions")
        }
    }
}

impl Default for ModelProfile {
    fn default() -> Self {
        Self::deepseek_default()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct WorkspaceConfig {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
}

impl Default for WorkspaceConfig {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            path: PathBuf::new(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct DataPaths {
    pub root: PathBuf,
    pub config_dir: PathBuf,
    pub tasks_dir: PathBuf,
    pub logs_dir: PathBuf,
    pub temp_dir: PathBuf,
    pub config_file: PathBuf,
}

#[derive(Clone)]
pub struct ConfigStore {
    paths: DataPaths,
    inner: Arc<RwLock<AppConfig>>,
}

impl ConfigStore {
    pub fn new(paths: DataPaths, config: AppConfig) -> Self {
        Self {
            paths,
            inner: Arc::new(RwLock::new(config)),
        }
    }

    pub fn snapshot(&self) -> AppConfig {
        self.inner.read().clone()
    }

    pub fn update<F>(&self, change: F) -> AgentResult<AppConfig>
    where
        F: FnOnce(&mut AppConfig) -> AgentResult<()>,
    {
        let mut next = self.snapshot();
        change(&mut next)?;
        validate_config(&next)?;
        save(&self.paths, &next)?;
        *self.inner.write() = next.clone();
        Ok(next)
    }
}

pub fn data_paths() -> DataPaths {
    let root = ProjectDirs::from("local", "Meno", "Windows Agent")
        .map(|dirs| dirs.data_local_dir().to_path_buf())
        .unwrap_or_else(|| PathBuf::from("data"));
    DataPaths {
        config_dir: root.join("config"),
        tasks_dir: root.join("tasks"),
        logs_dir: root.join("logs"),
        temp_dir: root.join("tmp"),
        config_file: root.join("config").join("config.json"),
        root,
    }
}

pub fn ensure_data_directories(paths: &DataPaths) -> AgentResult<()> {
    for path in [
        &paths.root,
        &paths.config_dir,
        &paths.tasks_dir,
        &paths.logs_dir,
        &paths.temp_dir,
    ] {
        fs::create_dir_all(path)?;
    }
    Ok(())
}

pub fn load_or_create(paths: &DataPaths) -> AgentResult<AppConfig> {
    ensure_data_directories(paths)?;
    let mut config = if paths.config_file.exists() {
        let bytes = fs::read(&paths.config_file)?;
        serde_json::from_slice(&bytes)
            .map_err(|error| AgentError::InvalidArgument(format!("配置文件无效: {error}")))?
    } else {
        AppConfig::default()
    };
    migrate(&mut config);
    validate_config(&config)?;
    save(paths, &config)?;
    Ok(config)
}

fn migrate(config: &mut AppConfig) {
    for workspace in &mut config.workspaces {
        if workspace.name.trim().is_empty() {
            workspace.name = workspace.id.clone();
        }
    }
    if config.models.is_empty() {
        config.models.push(ModelProfile::deepseek_default());
    }
    if config
        .current_model
        .as_deref()
        .is_none_or(|id| !config.models.iter().any(|profile| profile.id == id))
    {
        config.current_model = config.models.first().map(|profile| profile.id.clone());
    }
    config.max_tasks = config.max_tasks.clamp(1, 16);
    config.max_model_tool_steps = config.max_model_tool_steps.clamp(1, 32);
}

pub fn validate_config(config: &AppConfig) -> AgentResult<()> {
    if config.port == 0 {
        return Err(AgentError::InvalidArgument("MCP 端口无效".to_owned()));
    }
    let mut ids = std::collections::HashSet::new();
    for profile in &config.models {
        profile.validate()?;
        if !ids.insert(&profile.id) {
            return Err(AgentError::Conflict("模型编号重复".to_owned()));
        }
    }
    if let Some(current) = &config.current_model
        && !config.models.iter().any(|profile| &profile.id == current)
    {
        return Err(AgentError::InvalidArgument("当前模型不存在".to_owned()));
    }
    ids.clear();
    for workspace in &config.workspaces {
        validate_id(&workspace.id)?;
        if workspace.name.trim().is_empty() || workspace.path.as_os_str().is_empty() {
            return Err(AgentError::InvalidArgument("登记项目配置无效".to_owned()));
        }
        if !ids.insert(&workspace.id) {
            return Err(AgentError::Conflict("登记项目编号重复".to_owned()));
        }
    }
    Ok(())
}

pub fn save(paths: &DataPaths, config: &AppConfig) -> AgentResult<()> {
    let bytes = serde_json::to_vec_pretty(config)
        .map_err(|error| AgentError::Internal(error.to_string()))?;
    let temporary = paths.config_file.with_extension("json.tmp");
    fs::write(&temporary, bytes)?;
    fs::rename(temporary, &paths.config_file)?;
    Ok(())
}

pub fn validate_id(id: &str) -> AgentResult<()> {
    if id.is_empty()
        || id.len() > 64
        || !id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(AgentError::InvalidArgument(
            "编号只能包含字母、数字、连字符和下划线".to_owned(),
        ));
    }
    Ok(())
}

pub fn display_path(path: &std::path::Path) -> String {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = text.strip_prefix(r"\\?\") {
        rest.to_owned()
    } else {
        text.into_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generic_model_profiles_validate_and_must_be_unique() {
        let mut config = AppConfig::default();
        assert!(validate_config(&config).is_ok());
        config.models.push(config.models[0].clone());
        assert!(matches!(
            validate_config(&config),
            Err(AgentError::Conflict(_))
        ));
    }

    #[test]
    fn profile_accepts_keyless_local_compatible_api() {
        let mut profile = ModelProfile::deepseek_default();
        profile.id = "local-compatible".to_owned();
        profile.base_url = "http://127.0.0.1:8080/v1".to_owned();
        profile.credential.clear();
        assert!(profile.validate().is_ok());
        assert_eq!(
            profile.chat_completions_url(),
            "http://127.0.0.1:8080/v1/chat/completions"
        );
    }
}
