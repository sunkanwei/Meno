use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    process::Stdio,
    time::Instant,
};

use parking_lot::Mutex;
use rmcp::schemars;
use serde::{Deserialize, Serialize};
use similar::TextDiff;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;
use windows::{
    Win32::Storage::FileSystem::{MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW},
    core::HSTRING,
};

use crate::{
    background_process,
    config::AppConfig,
    error::{AgentError, AgentResult},
    files::hash_file,
    security,
};

const MAX_TEXT_FILE: usize = 4 * 1024 * 1024;
const MAX_DIFF: usize = 512 * 1024;
const MAX_DELETE_ENTRIES: usize = 10_000;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ProjectFileAction {
    Write,
    Mkdir,
    Move,
    Delete,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct ProjectFileRequest {
    pub workspace: String,
    pub action: ProjectFileAction,
    pub path: String,
    pub destination: Option<String>,
    pub content: Option<String>,
    pub expected_sha256: Option<String>,
    #[serde(default)]
    pub recursive: bool,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct ProjectFileResponse {
    pub action: String,
    pub path: String,
    pub destination: Option<String>,
    pub previous_sha256: Option<String>,
    pub new_sha256: Option<String>,
    pub diff: Option<String>,
    pub affected_entries: usize,
}

pub fn change_file(
    config: &AppConfig,
    request: &ProjectFileRequest,
) -> AgentResult<ProjectFileResponse> {
    match request.action {
        ProjectFileAction::Write => write_file(config, request),
        ProjectFileAction::Mkdir => create_directory(config, request),
        ProjectFileAction::Move => move_path(config, request),
        ProjectFileAction::Delete => delete_path(config, request),
    }
}

fn write_file(
    config: &AppConfig,
    request: &ProjectFileRequest,
) -> AgentResult<ProjectFileResponse> {
    let content = request
        .content
        .as_deref()
        .ok_or_else(|| AgentError::InvalidArgument("write 操作缺少 content".to_owned()))?;
    if content.len() > MAX_TEXT_FILE {
        return Err(AgentError::PermissionDenied(
            "单个文本文件不能超过 4 MiB".to_owned(),
        ));
    }
    let target =
        security::resolve_workspace_target(config, &request.workspace, Path::new(&request.path))?;
    protect_agent_self(&target)?;
    if target.is_dir() {
        return Err(AgentError::InvalidArgument("目标是目录".to_owned()));
    }
    let (old_text, previous_sha256) = if target.exists() {
        let hash = hash_file(&target)?;
        let expected = request.expected_sha256.as_deref().ok_or_else(|| {
            AgentError::Conflict("修改现有文件必须提供 expected_sha256".to_owned())
        })?;
        if !hash.eq_ignore_ascii_case(expected) {
            return Err(AgentError::Conflict("文件哈希已变化".to_owned()));
        }
        let bytes = fs::read(&target)?;
        let text = String::from_utf8(bytes)
            .map_err(|_| AgentError::PermissionDenied("只允许写入 UTF-8 文本文件".to_owned()))?;
        (text, Some(hash))
    } else {
        if request.expected_sha256.is_some() {
            return Err(AgentError::Conflict(
                "新文件不应提供 expected_sha256".to_owned(),
            ));
        }
        (String::new(), None)
    };
    let diff = bounded_diff(&request.path, &old_text, content);
    atomic_replace(&target, content.as_bytes())?;
    let new_sha256 = hash_file(&target)?;
    Ok(ProjectFileResponse {
        action: "write".to_owned(),
        path: request.path.clone(),
        destination: None,
        previous_sha256,
        new_sha256: Some(new_sha256),
        diff: Some(diff),
        affected_entries: 1,
    })
}

fn create_directory(
    config: &AppConfig,
    request: &ProjectFileRequest,
) -> AgentResult<ProjectFileResponse> {
    let target =
        security::resolve_workspace_target(config, &request.workspace, Path::new(&request.path))?;
    protect_agent_self(&target)?;
    if target.exists() {
        return Err(AgentError::Conflict("目标已经存在".to_owned()));
    }
    fs::create_dir_all(&target)?;
    Ok(ProjectFileResponse {
        action: "mkdir".to_owned(),
        path: request.path.clone(),
        destination: None,
        previous_sha256: None,
        new_sha256: None,
        diff: None,
        affected_entries: 1,
    })
}

fn move_path(config: &AppConfig, request: &ProjectFileRequest) -> AgentResult<ProjectFileResponse> {
    let source =
        security::resolve_workspace_existing(config, &request.workspace, Path::new(&request.path))?;
    let destination_text = request
        .destination
        .as_deref()
        .ok_or_else(|| AgentError::InvalidArgument("move 操作缺少 destination".to_owned()))?;
    let destination = security::resolve_workspace_target(
        config,
        &request.workspace,
        Path::new(destination_text),
    )?;
    protect_agent_self(&source)?;
    protect_agent_self(&destination)?;
    if destination.exists() {
        return Err(AgentError::Conflict("移动目标已经存在".to_owned()));
    }
    let previous_sha256 = if source.is_file() {
        let hash = hash_file(&source)?;
        if let Some(expected) = request.expected_sha256.as_deref()
            && !hash.eq_ignore_ascii_case(expected)
        {
            return Err(AgentError::Conflict("源文件哈希已变化".to_owned()));
        }
        Some(hash)
    } else {
        None
    };
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::rename(&source, &destination)?;
    let new_sha256 = destination
        .is_file()
        .then(|| hash_file(&destination))
        .transpose()?;
    Ok(ProjectFileResponse {
        action: "move".to_owned(),
        path: request.path.clone(),
        destination: Some(destination_text.to_owned()),
        previous_sha256,
        new_sha256,
        diff: None,
        affected_entries: 1,
    })
}

fn delete_path(
    config: &AppConfig,
    request: &ProjectFileRequest,
) -> AgentResult<ProjectFileResponse> {
    let target =
        security::resolve_workspace_existing(config, &request.workspace, Path::new(&request.path))?;
    let workspace = security::workspace(config, &request.workspace)?;
    let root = fs::canonicalize(&workspace.path)?;
    if target == root {
        return Err(AgentError::PermissionDenied(
            "不允许删除登记项目根目录".to_owned(),
        ));
    }
    protect_agent_self(&target)?;
    let previous_sha256 = if target.is_file() {
        let hash = hash_file(&target)?;
        let expected = request
            .expected_sha256
            .as_deref()
            .ok_or_else(|| AgentError::Conflict("删除文件必须提供 expected_sha256".to_owned()))?;
        if !hash.eq_ignore_ascii_case(expected) {
            return Err(AgentError::Conflict("文件哈希已变化".to_owned()));
        }
        fs::remove_file(&target)?;
        Some(hash)
    } else if target.is_dir() {
        if !request.recursive {
            fs::remove_dir(&target)?;
            None
        } else {
            let count = walkdir::WalkDir::new(&target)
                .follow_links(false)
                .into_iter()
                .take(MAX_DELETE_ENTRIES + 1)
                .count();
            if count > MAX_DELETE_ENTRIES {
                return Err(AgentError::PermissionDenied(
                    "目录包含超过 10000 个项目，拒绝远程递归删除".to_owned(),
                ));
            }
            fs::remove_dir_all(&target)?;
            return Ok(ProjectFileResponse {
                action: "delete".to_owned(),
                path: request.path.clone(),
                destination: None,
                previous_sha256: None,
                new_sha256: None,
                diff: None,
                affected_entries: count,
            });
        }
    } else {
        return Err(AgentError::InvalidArgument("不支持该路径类型".to_owned()));
    };
    Ok(ProjectFileResponse {
        action: "delete".to_owned(),
        path: request.path.clone(),
        destination: None,
        previous_sha256,
        new_sha256: None,
        diff: None,
        affected_entries: 1,
    })
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct RunProjectCommandRequest {
    /// Caller-generated unique identifier. It can be passed to cancel_project_command while this call is running.
    pub command_id: Uuid,
    pub workspace: String,
    pub program: String,
    #[serde(default)]
    pub args: Vec<String>,
    pub cwd: Option<String>,
    pub timeout_seconds: Option<u64>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct RunProjectCommandResponse {
    pub command_id: String,
    pub program: String,
    pub exit_code: Option<i32>,
    pub success: bool,
    pub timed_out: bool,
    pub cancelled: bool,
    pub output: String,
    pub output_truncated: bool,
    pub git_status_before: String,
    pub git_status_after: String,
    pub elapsed_ms: u64,
}

#[derive(Clone, Default)]
pub struct ProjectCommandManager {
    running: std::sync::Arc<Mutex<HashMap<Uuid, CancellationToken>>>,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct CancelProjectCommandRequest {
    pub command_id: Uuid,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct CancelProjectCommandResponse {
    pub command_id: String,
    pub cancellation_requested: bool,
}

impl ProjectCommandManager {
    pub async fn run(
        &self,
        config: &AppConfig,
        request: &RunProjectCommandRequest,
    ) -> AgentResult<RunProjectCommandResponse> {
        validate_command_request(request)?;
        let cancellation = CancellationToken::new();
        {
            let mut running = self.running.lock();
            if running.contains_key(&request.command_id) {
                return Err(AgentError::Conflict("项目命令编号正在使用".to_owned()));
            }
            running.insert(request.command_id, cancellation.clone());
        }
        let result = self.run_inner(config, request, cancellation).await;
        self.running.lock().remove(&request.command_id);
        result
    }

    pub fn cancel(
        &self,
        request: &CancelProjectCommandRequest,
    ) -> AgentResult<CancelProjectCommandResponse> {
        let token = self
            .running
            .lock()
            .get(&request.command_id)
            .cloned()
            .ok_or_else(|| AgentError::NotFound("项目命令不存在或已经结束".to_owned()))?;
        token.cancel();
        Ok(CancelProjectCommandResponse {
            command_id: request.command_id.to_string(),
            cancellation_requested: true,
        })
    }

    async fn run_inner(
        &self,
        config: &AppConfig,
        request: &RunProjectCommandRequest,
        cancellation: CancellationToken,
    ) -> AgentResult<RunProjectCommandResponse> {
        let workspace = security::workspace(config, &request.workspace)?;
        let root = fs::canonicalize(&workspace.path)?;
        let cwd = if let Some(path) = request.cwd.as_deref() {
            security::resolve_workspace_existing(config, &request.workspace, Path::new(path))?
        } else {
            root.clone()
        };
        if !cwd.is_dir() {
            return Err(AgentError::InvalidArgument(
                "命令工作目录不是目录".to_owned(),
            ));
        }
        let program = resolve_program(config, &request.workspace, &request.program)?;
        let before = git_status(&root).await;
        let started = Instant::now();
        let mut command = background_process::tokio_command(&program);
        command
            .current_dir(&cwd)
            .args(&request.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let mut child = command.spawn().map_err(|error| {
            AgentError::DependencyUnavailable(format!("项目命令无法启动: {error}"))
        })?;
        let _job = child
            .id()
            .map(crate::job::ProcessJob::assign)
            .transpose()?
            .ok_or_else(|| AgentError::Internal("项目命令没有 PID".to_owned()))?;
        let mut stdout = child.stdout.take();
        let mut stderr = child.stderr.take();
        let stdout_task = tokio::spawn(async move {
            let mut bytes = Vec::new();
            if let Some(stream) = &mut stdout {
                let _ = stream.read_to_end(&mut bytes).await;
            }
            bytes
        });
        let stderr_task = tokio::spawn(async move {
            let mut bytes = Vec::new();
            if let Some(stream) = &mut stderr {
                let _ = stream.read_to_end(&mut bytes).await;
            }
            bytes
        });
        let timeout = Duration::from_secs(request.timeout_seconds.unwrap_or(120).clamp(1, 900));
        let (status, timed_out, cancelled) = tokio::select! {
            status = tokio::time::timeout(timeout, child.wait()) => match status {
                Ok(status) => (Some(status?), false, false),
                Err(_) => {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                    (None, true, false)
                }
            },
            _ = cancellation.cancelled() => {
                let _ = child.kill().await;
                let _ = child.wait().await;
                (None, false, true)
            }
        };
        let mut output = stdout_task
            .await
            .map_err(|error| AgentError::Internal(error.to_string()))?;
        output.extend(
            stderr_task
                .await
                .map_err(|error| AgentError::Internal(error.to_string()))?,
        );
        let max_output = config.max_output_bytes.clamp(64 * 1024, 8 * 1024 * 1024);
        let output_truncated = output.len() > max_output;
        output.truncate(max_output);
        let after = git_status(&root).await;
        Ok(RunProjectCommandResponse {
            command_id: request.command_id.to_string(),
            program: request.program.clone(),
            exit_code: status.as_ref().and_then(|value| value.code()),
            success: status.as_ref().is_some_and(|value| value.success())
                && !timed_out
                && !cancelled,
            timed_out,
            cancelled,
            output: String::from_utf8_lossy(&output).into_owned(),
            output_truncated,
            git_status_before: before,
            git_status_after: after,
            elapsed_ms: started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        })
    }
}

fn validate_command_request(request: &RunProjectCommandRequest) -> AgentResult<()> {
    if request.program.trim().is_empty()
        || request.program.len() > 500
        || request.args.len() > 128
        || request
            .args
            .iter()
            .any(|arg| arg.len() > 4096 || arg.contains(['\0', '\r', '\n']))
    {
        return Err(AgentError::InvalidArgument(
            "项目命令参数超出限制".to_owned(),
        ));
    }
    let name = Path::new(&request.program)
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .trim_end_matches(".exe")
        .to_ascii_lowercase();
    const BLOCKED: &[&str] = &[
        "cmd",
        "powershell",
        "pwsh",
        "wscript",
        "cscript",
        "mshta",
        "msiexec",
        "rundll32",
        "regsvr32",
        "reg",
        "sc",
        "diskpart",
        "bcdedit",
        "pnputil",
        "shutdown",
    ];
    if BLOCKED.contains(&name.as_str()) {
        return Err(AgentError::PermissionDenied(
            "项目命令不允许调用 Shell、安装器或系统修改工具".to_owned(),
        ));
    }
    Ok(())
}

fn resolve_program(config: &AppConfig, workspace: &str, program: &str) -> AgentResult<PathBuf> {
    let path = Path::new(program);
    if path.is_absolute() {
        let resolved = fs::canonicalize(path)?;
        let root = fs::canonicalize(&security::workspace(config, workspace)?.path)?;
        security::ensure_within(&root, &resolved)?;
        if !resolved.is_file() {
            return Err(AgentError::InvalidArgument("项目程序不是文件".to_owned()));
        }
        return Ok(resolved);
    }
    if path.components().count() > 1 {
        let resolved = security::resolve_workspace_existing(config, workspace, path)?;
        if !resolved.is_file() {
            return Err(AgentError::InvalidArgument("项目程序不是文件".to_owned()));
        }
        return Ok(resolved);
    }
    let name = program.trim_end_matches(".exe").to_ascii_lowercase();
    const COMMON: &[&str] = &[
        "cargo", "rustc", "git", "node", "npm", "npx", "pnpm", "yarn", "python", "python3",
        "pytest", "uv", "go", "dotnet", "msbuild", "cmake", "ninja", "make", "clang", "clang++",
        "gcc", "g++", "java", "javac", "gradle", "gradlew", "mvn",
    ];
    if !COMMON.contains(&name.as_str()) {
        return Err(AgentError::PermissionDenied(
            "该程序既不在登记项目内，也不是允许的常用构建、测试或版本控制程序".to_owned(),
        ));
    }
    Ok(PathBuf::from(program))
}

async fn git_status(root: &Path) -> String {
    if !root.join(".git").exists() {
        return String::new();
    }
    background_process::tokio_command("git")
        .current_dir(root)
        .args(["status", "--porcelain=v1", "--untracked-files=all"])
        .output()
        .await
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
        .unwrap_or_default()
}

fn protect_agent_self(path: &Path) -> AgentResult<()> {
    let agent_root = fs::canonicalize(env!("CARGO_MANIFEST_DIR"))?;
    let comparable = if path.exists() {
        fs::canonicalize(path)?
    } else {
        path.to_path_buf()
    };
    if security::ensure_within(&agent_root, &comparable).is_ok() {
        return Err(AgentError::PermissionDenied(
            "Windows Agent 不允许通过自身 MCP 修改自己".to_owned(),
        ));
    }
    Ok(())
}

fn bounded_diff(path: &str, old: &str, new: &str) -> String {
    let mut diff = TextDiff::from_lines(old, new)
        .unified_diff()
        .header(path, path)
        .to_string();
    if diff.len() > MAX_DIFF {
        diff.truncate(MAX_DIFF);
        diff.push_str("\n...[diff truncated]");
    }
    diff
}

fn atomic_replace(target: &Path, content: &[u8]) -> AgentResult<()> {
    let parent = target
        .parent()
        .ok_or_else(|| AgentError::InvalidArgument("目标没有父目录".to_owned()))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(".windows-agent-{}.tmp", Uuid::new_v4()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    if let Err(error) = (|| -> std::io::Result<()> {
        file.write_all(content)?;
        file.sync_all()
    })() {
        let _ = fs::remove_file(&temporary);
        return Err(error.into());
    }
    drop(file);
    let source = HSTRING::from(temporary.as_os_str());
    let destination = HSTRING::from(target.as_os_str());
    let result = unsafe {
        MoveFileExW(
            &source,
            &destination,
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if let Err(error) = result {
        let _ = fs::remove_file(&temporary);
        return Err(AgentError::Io(std::io::Error::other(error.to_string())));
    }
    Ok(())
}

use std::time::Duration;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::WorkspaceConfig;

    #[test]
    fn project_commands_block_shells() {
        let request = RunProjectCommandRequest {
            command_id: Uuid::new_v4(),
            workspace: "demo".to_owned(),
            program: "powershell.exe".to_owned(),
            args: Vec::new(),
            cwd: None,
            timeout_seconds: None,
        };
        assert!(validate_command_request(&request).is_err());
    }

    #[test]
    fn project_file_changes_stay_inside_registered_root_and_use_hashes() {
        let root = std::env::temp_dir().join(format!("windows-agent-test-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let mut config = AppConfig::default();
        config.workspaces.push(WorkspaceConfig {
            id: "demo".to_owned(),
            name: "Demo".to_owned(),
            path: root.clone(),
        });
        let create = change_file(
            &config,
            &ProjectFileRequest {
                workspace: "demo".to_owned(),
                action: ProjectFileAction::Write,
                path: "src\\main.txt".to_owned(),
                destination: None,
                content: Some("one\n".to_owned()),
                expected_sha256: None,
                recursive: false,
            },
        )
        .unwrap();
        let first_hash = create.new_sha256.unwrap();
        let update = change_file(
            &config,
            &ProjectFileRequest {
                workspace: "demo".to_owned(),
                action: ProjectFileAction::Write,
                path: "src\\main.txt".to_owned(),
                destination: None,
                content: Some("two\n".to_owned()),
                expected_sha256: Some(first_hash),
                recursive: false,
            },
        )
        .unwrap();
        assert!(update.diff.unwrap().contains("+two"));
        assert!(
            change_file(
                &config,
                &ProjectFileRequest {
                    workspace: "demo".to_owned(),
                    action: ProjectFileAction::Write,
                    path: "..\\outside.txt".to_owned(),
                    destination: None,
                    content: Some("bad".to_owned()),
                    expected_sha256: None,
                    recursive: false,
                }
            )
            .is_err()
        );
        fs::remove_dir_all(root).unwrap();
    }
}
