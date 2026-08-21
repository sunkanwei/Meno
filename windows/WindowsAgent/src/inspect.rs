use std::path::Path;

use rmcp::schemars;
use serde::{Deserialize, Serialize};
use sysinfo::System;
use winreg::{
    RegKey,
    enums::{
        HKEY_CLASSES_ROOT, HKEY_CURRENT_CONFIG, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, HKEY_USERS,
    },
};

use crate::{
    background_process,
    config::AppConfig,
    error::{AgentError, AgentResult},
    security,
};

const MAX_OUTPUT: usize = 512 * 1024;

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct WorkspaceStatus {
    pub id: String,
    pub name: String,
    pub path: String,
    pub exists: bool,
    pub git_repository: bool,
    pub checked_utc: String,
}

pub fn list_workspaces(config: &AppConfig) -> Vec<WorkspaceStatus> {
    let checked_utc = chrono::Utc::now().to_rfc3339();
    config
        .workspaces
        .iter()
        .map(|workspace| WorkspaceStatus {
            id: workspace.id.clone(),
            name: workspace.name.clone(),
            path: crate::config::display_path(&workspace.path),
            exists: workspace.path.is_dir(),
            git_repository: workspace.path.join(".git").exists(),
            checked_utc: checked_utc.clone(),
        })
        .collect()
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct GitInspectRequest {
    pub workspace: String,
    pub operation: String,
    pub path: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct GitInspectResponse {
    pub operation: String,
    pub output: String,
    pub truncated: bool,
}

pub fn git_inspect(
    config: &AppConfig,
    request: &GitInspectRequest,
) -> AgentResult<GitInspectResponse> {
    let workspace = security::workspace(config, &request.workspace)?;
    let root = std::fs::canonicalize(&workspace.path)?;
    if !root.join(".git").exists() {
        return Err(AgentError::InvalidArgument(
            "工作区不是 Git 仓库".to_owned(),
        ));
    }
    let mut command = background_process::std_command("git");
    command.current_dir(&root);
    match request.operation.as_str() {
        "status" => {
            command.args(["status", "--short", "--branch"]);
        }
        "diff" => {
            command.args(["diff", "--no-ext-diff", "--"]);
            if let Some(path) = &request.path {
                let resolved = security::resolve_workspace_existing(
                    config,
                    &request.workspace,
                    Path::new(path),
                )?;
                command.arg(resolved.strip_prefix(&root).map_err(|_| {
                    AgentError::PathOutsideWorkspace(resolved.display().to_string())
                })?);
            }
        }
        "staged_diff" => {
            command.args(["diff", "--cached", "--no-ext-diff", "--"]);
        }
        "log" => {
            let limit = request.limit.unwrap_or(20).clamp(1, 100).to_string();
            command.args(["log", "--oneline", "--decorate", "-n", &limit]);
        }
        _ => {
            return Err(AgentError::InvalidArgument(
                "operation 只能是 status、diff、staged_diff 或 log".to_owned(),
            ));
        }
    }
    let output = command.output()?;
    if !output.status.success() {
        return Err(AgentError::Internal(
            String::from_utf8_lossy(&output.stderr)
                .chars()
                .take(500)
                .collect(),
        ));
    }
    let (text, truncated) = bounded_text(&output.stdout);
    Ok(GitInspectResponse {
        operation: request.operation.clone(),
        output: text,
        truncated,
    })
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SystemCategory {
    Summary,
    Processes,
    Services,
    Drivers,
    Network,
    EventLog,
    Registry,
}

impl SystemCategory {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Summary => "summary",
            Self::Processes => "processes",
            Self::Services => "services",
            Self::Drivers => "drivers",
            Self::Network => "network",
            Self::EventLog => "event_log",
            Self::Registry => "registry",
        }
    }
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct InspectSystemRequest {
    pub category: SystemCategory,
    pub path: Option<String>,
    pub filter: Option<String>,
    #[serde(default)]
    pub cursor: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct SystemItem {
    pub fields: serde_json::Value,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct InspectSystemResponse {
    pub category: String,
    pub items: Vec<SystemItem>,
    pub next_cursor: Option<usize>,
}

pub fn inspect_system(request: &InspectSystemRequest) -> AgentResult<InspectSystemResponse> {
    let limit = request.limit.unwrap_or(100).clamp(1, 200);
    let filter = request
        .filter
        .as_deref()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let mut values = match request.category {
        SystemCategory::Summary => summary(),
        SystemCategory::Processes => processes(),
        SystemCategory::Services => fixed_powershell(
            "Get-CimInstance Win32_Service | Select-Object Name,State,StartMode,ProcessId | ConvertTo-Json -Compress",
        )?,
        SystemCategory::Drivers => fixed_powershell(
            "Get-CimInstance Win32_SystemDriver | Select-Object Name,State,StartMode,PathName | ConvertTo-Json -Compress",
        )?,
        SystemCategory::Network => fixed_powershell(
            "Get-NetTCPConnection | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess | ConvertTo-Json -Compress",
        )?,
        SystemCategory::EventLog => event_log(request.path.as_deref().unwrap_or("Application"))?,
        SystemCategory::Registry => registry(request.path.as_deref().ok_or_else(|| AgentError::InvalidArgument(
            "registry 查询需要 path，例如 HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion".to_owned()
        ))?)?,
    };
    if !filter.is_empty() {
        values.retain(|value| value.to_string().to_ascii_lowercase().contains(&filter));
    }
    let total = values.len();
    let items = values
        .into_iter()
        .skip(request.cursor)
        .take(limit)
        .map(|fields| SystemItem { fields })
        .collect();
    let next = request.cursor.saturating_add(limit);
    Ok(InspectSystemResponse {
        category: request.category.as_str().to_owned(),
        items,
        next_cursor: (next < total).then_some(next),
    })
}

fn event_log(log_name: &str) -> AgentResult<Vec<serde_json::Value>> {
    let log_name = match log_name.trim().to_ascii_lowercase().as_str() {
        "system" => "System",
        "application" => "Application",
        _ if log_name.trim() == "系统" => "System",
        _ if log_name.trim() == "应用程序" => "Application",
        _ => log_name.trim(),
    };
    if log_name.is_empty()
        || log_name.len() > 80
        || !log_name
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '/' | ' '))
    {
        return Err(AgentError::InvalidArgument("事件日志名称无效".to_owned()));
    }
    let script = format!(
        "Get-WinEvent -LogName '{}' -MaxEvents 200 -ErrorAction Stop | Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message | ConvertTo-Json -Compress",
        log_name.replace('\'', "''")
    );
    fixed_powershell(&script)
}

fn registry(path: &str) -> AgentResult<Vec<serde_json::Value>> {
    let normalized = path.replace('/', "\\");
    let (root, subkey) = normalized.split_once('\\').ok_or_else(|| {
        AgentError::InvalidArgument("注册表 path 必须包含根键和子路径".to_owned())
    })?;
    let hive = match root.to_ascii_uppercase().as_str() {
        "HKLM" | "HKEY_LOCAL_MACHINE" => RegKey::predef(HKEY_LOCAL_MACHINE),
        "HKCU" | "HKEY_CURRENT_USER" => RegKey::predef(HKEY_CURRENT_USER),
        "HKCR" | "HKEY_CLASSES_ROOT" => RegKey::predef(HKEY_CLASSES_ROOT),
        "HKU" | "HKEY_USERS" => RegKey::predef(HKEY_USERS),
        "HKCC" | "HKEY_CURRENT_CONFIG" => RegKey::predef(HKEY_CURRENT_CONFIG),
        _ => {
            return Err(AgentError::InvalidArgument(
                "注册表根键只允许 HKLM、HKCU、HKCR、HKU 或 HKCC".to_owned(),
            ));
        }
    };
    let key = hive
        .open_subkey(subkey)
        .map_err(|error| AgentError::NotFound(format!("无法读取注册表路径: {error}")))?;
    let mut values = Vec::new();
    for name in key.enum_keys().flatten().take(500) {
        values.push(serde_json::json!({"kind":"subkey", "name":name}));
    }
    for item in key.enum_values().flatten().take(500) {
        let (name, value) = item;
        let mut rendered = format!("{:?}", value);
        if rendered.len() > 4096 {
            rendered.truncate(4096);
            rendered.push_str("...[truncated]");
        }
        values.push(serde_json::json!({"kind":"value", "name":name, "data":rendered}));
    }
    Ok(values)
}

fn summary() -> Vec<serde_json::Value> {
    let mut system = System::new_all();
    system.refresh_all();
    vec![serde_json::json!({
        "os": System::long_os_version(),
        "kernel": System::kernel_version(),
        "host": System::host_name(),
        "cpu_count": system.cpus().len(),
        "memory_total_bytes": system.total_memory(),
        "memory_used_bytes": system.used_memory(),
    })]
}

fn processes() -> Vec<serde_json::Value> {
    let mut system = System::new_all();
    system.refresh_all();
    system
        .processes()
        .iter()
        .map(|(pid, process)| {
            serde_json::json!({
                "pid": pid.as_u32(),
                "name": process.name().to_string_lossy(),
                "cpu_percent": process.cpu_usage(),
                "memory_bytes": process.memory(),
                "status": process.status().to_string(),
            })
        })
        .collect()
}

fn fixed_powershell(script: &str) -> AgentResult<Vec<serde_json::Value>> {
    let script = format!(
        "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [Console]::OutputEncoding; {script}"
    );
    let output = background_process::std_command("powershell.exe")
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &script,
        ])
        .output()?;
    if !output.status.success() {
        return Err(AgentError::Internal(
            String::from_utf8_lossy(&output.stderr)
                .chars()
                .take(500)
                .collect(),
        ));
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let sanitized = sanitize_json_unicode(text.trim_start_matches('\u{feff}'));
    let value: serde_json::Value = serde_json::from_str(&sanitized)
        .map_err(|error| AgentError::Internal(format!("系统查询返回无效 JSON: {error}")))?;
    Ok(match value {
        serde_json::Value::Array(values) => values,
        serde_json::Value::Null => Vec::new(),
        value => vec![value],
    })
}

fn sanitize_json_unicode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut output = String::with_capacity(text.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\\' && index + 1 < bytes.len() {
            if bytes[index + 1] == b'\\' {
                output.push_str("\\\\");
                index += 2;
                continue;
            }
            if bytes[index + 1] == b'u' && index + 6 <= bytes.len() {
                let unit = std::str::from_utf8(&bytes[index + 2..index + 6])
                    .ok()
                    .and_then(|hex| u16::from_str_radix(hex, 16).ok());
                if let Some(unit) = unit {
                    if (0xD800..=0xDBFF).contains(&unit) {
                        let paired = index + 12 <= bytes.len()
                            && bytes[index + 6] == b'\\'
                            && bytes[index + 7] == b'u'
                            && std::str::from_utf8(&bytes[index + 8..index + 12])
                                .ok()
                                .and_then(|hex| u16::from_str_radix(hex, 16).ok())
                                .is_some_and(|low| (0xDC00..=0xDFFF).contains(&low));
                        if !paired {
                            output.push_str("\\uFFFD");
                            index += 6;
                            continue;
                        }
                        output.push_str(&text[index..index + 12]);
                        index += 12;
                        continue;
                    } else if (0xDC00..=0xDFFF).contains(&unit) {
                        output.push_str("\\uFFFD");
                        index += 6;
                        continue;
                    }
                }
            }
        }
        let ch = text[index..].chars().next().expect("valid string boundary");
        output.push(ch);
        index += ch.len_utf8();
    }
    output
}

fn bounded_text(bytes: &[u8]) -> (String, bool) {
    let truncated = bytes.len() > MAX_OUTPUT;
    let end = bytes.len().min(MAX_OUTPUT);
    (
        String::from_utf8_lossy(&bytes[..end]).into_owned(),
        truncated,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_json_replaces_only_unpaired_surrogates() {
        let source = r#"[{"bad":"\uD800","good":"\uD83D\uDE00","literal":"\\uD800"}]"#;
        let sanitized = sanitize_json_unicode(source);
        let value: serde_json::Value = serde_json::from_str(&sanitized).unwrap();
        assert_eq!(value[0]["bad"], "�");
        assert_eq!(value[0]["good"], "😀");
        assert_eq!(value[0]["literal"], r"\uD800");
    }
}
