use std::sync::Arc;

use base64::{Engine, engine::general_purpose::STANDARD};
use rmcp::{
    ErrorData, ServerHandler,
    handler::server::{
        router::tool::ToolRouter,
        wrapper::{Json, Parameters},
    },
    model::{CallToolResult, ContentBlock, ServerCapabilities, ServerInfo},
    schemars, tool, tool_handler, tool_router,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

use crate::{
    apps::{LaunchApplicationRequest, LaunchApplicationResponse},
    background_process,
    capture::{CaptureTarget, IsolatedCaptureRequest},
    config::{AppConfig, ConfigStore, DataPaths},
    files::{
        ListFilesRequest, ListFilesResponse, ReadFileRequest, ReadFileResponse, SearchFilesRequest,
        SearchFilesResponse,
    },
    inspect::{
        GitInspectRequest, GitInspectResponse, InspectSystemRequest, InspectSystemResponse,
        WorkspaceStatus,
    },
    projects::{
        CancelProjectCommandRequest, CancelProjectCommandResponse, ProjectCommandManager,
        ProjectFileRequest, ProjectFileResponse, RunProjectCommandRequest,
        RunProjectCommandResponse,
    },
    tasks::{
        CancelTaskResponse, SubmitInvestigationRequest, SubmitInvestigationResponse, TaskIdRequest,
        TaskLogRequest, TaskLogResponse, TaskManager, TaskStatusResponse,
    },
};

#[derive(Clone)]
pub struct AppState {
    pub config: ConfigStore,
    pub tasks: Arc<TaskManager>,
    pub commands: ProjectCommandManager,
    pub shutdown: CancellationToken,
    pub admin_token: String,
    pub paths: DataPaths,
}

impl AppState {
    pub fn new(
        config: ConfigStore,
        paths: DataPaths,
        shutdown: CancellationToken,
        admin_token: String,
    ) -> crate::error::AgentResult<Self> {
        let tasks = TaskManager::new(config.clone(), paths.clone())?;
        Ok(Self {
            config,
            tasks,
            commands: ProjectCommandManager::default(),
            shutdown,
            admin_token,
            paths,
        })
    }
}

#[derive(Clone)]
pub struct WindowsAgent {
    tool_router: ToolRouter<Self>,
    state: Arc<AppState>,
}

impl WindowsAgent {
    pub fn new(state: Arc<AppState>) -> Self {
        Self {
            tool_router: Self::tool_router(),
            state,
        }
    }
}

#[derive(Debug, Serialize, schemars::JsonSchema)]
pub struct HealthResponse {
    pub status: String,
    pub service: String,
    pub version: String,
    pub protocol: String,
    pub current_model: Option<String>,
    pub current_model_name: Option<String>,
    pub current_model_supports_images: Option<bool>,
    pub current_model_credential_configured: Option<bool>,
    pub registered_projects: usize,
    pub memory_total_bytes: u64,
    pub memory_used_bytes: u64,
    pub gpu: Option<String>,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct CaptureScreenRequest {
    #[serde(default = "capture_action")]
    pub action: String,
    #[serde(default = "desktop_target")]
    pub target: String,
    pub id: Option<String>,
    pub region: Option<CaptureRegion>,
    pub max_dimension: Option<u32>,
}

fn capture_action() -> String {
    "capture".to_owned()
}

fn desktop_target() -> String {
    "virtual_desktop".to_owned()
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct CaptureRegion {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Serialize)]
struct CaptureTargets {
    monitors: Vec<CaptureTarget>,
    windows: Vec<CaptureTarget>,
}

#[derive(Debug, Serialize, schemars::JsonSchema)]
struct ListWorkspacesResponse {
    workspaces: Vec<WorkspaceStatus>,
}

#[derive(Debug, Serialize)]
struct CaptureMetadata {
    target: String,
    location: String,
    width: u32,
    height: u32,
    captured_utc: String,
    mime_type: String,
    bytes: usize,
    scaled: bool,
}

#[tool_router]
impl WindowsAgent {
    #[tool(
        description = "Return stable Windows Agent health plus the current Windows-managed model status",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn health(&self) -> Json<HealthResponse> {
        Json(build_health(&self.state.config.snapshot()))
    }

    #[tool(
        description = "List code projects registered in the Windows tray settings",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn list_workspaces(&self) -> Json<ListWorkspacesResponse> {
        Json(ListWorkspacesResponse {
            workspaces: crate::inspect::list_workspaces(&self.state.config.snapshot()),
        })
    }

    #[tool(
        description = "List any Windows directory in read-only system scope, or a registered project directory, with bounded pagination",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn list_files(
        &self,
        Parameters(request): Parameters<ListFilesRequest>,
    ) -> Result<Json<ListFilesResponse>, ErrorData> {
        crate::files::list(&self.state.config.snapshot(), &request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Read a bounded line or byte range from any Windows file and return the complete file SHA-256",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn read_file(
        &self,
        Parameters(request): Parameters<ReadFileRequest>,
    ) -> Result<Json<ReadFileResponse>, ErrorData> {
        crate::files::read(&self.state.config.snapshot(), &request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Search names, extensions or bounded text under any Windows directory or registered project",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn search_files(
        &self,
        Parameters(request): Parameters<SearchFilesRequest>,
    ) -> Result<Json<SearchFilesResponse>, ErrorData> {
        crate::files::search(&self.state.config.snapshot(), &request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Inspect Git status, diff, staged diff or recent commits in a registered project without mutation",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn git_inspect(
        &self,
        Parameters(request): Parameters<GitInspectRequest>,
    ) -> Result<Json<GitInspectResponse>, ErrorData> {
        crate::inspect::git_inspect(&self.state.config.snapshot(), &request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Inspect bounded Windows summary, processes, services, drivers, network, event logs or registry in read-only mode",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn inspect_system(
        &self,
        Parameters(request): Parameters<InspectSystemRequest>,
    ) -> Result<Json<InspectSystemResponse>, ErrorData> {
        crate::inspect::inspect_system(&request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Enumerate capture targets or capture the desktop, a monitor or a visible window as PNG evidence",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    async fn capture_screen(
        &self,
        Parameters(request): Parameters<CaptureScreenRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        if request.action == "list" {
            let targets = CaptureTargets {
                monitors: crate::capture::enumerate("monitor").map_err(capture_agent_error)?,
                windows: crate::capture::enumerate("window").map_err(capture_agent_error)?,
            };
            return Ok(CallToolResult::success(vec![ContentBlock::text(
                serde_json::to_string(&targets)
                    .map_err(|error| crate::error::AgentError::Internal(error.to_string()))?,
            )]));
        }
        if request.action != "capture" {
            return Err(crate::error::AgentError::InvalidArgument(
                "action 只能是 list 或 capture".to_owned(),
            )
            .into());
        }
        if !matches!(
            request.target.as_str(),
            "virtual_desktop" | "primary" | "monitor" | "window"
        ) {
            return Err(crate::error::AgentError::InvalidArgument(
                "target 只能是 virtual_desktop、primary、monitor 或 window".to_owned(),
            )
            .into());
        }
        let id = request
            .id
            .as_deref()
            .map(str::parse::<u64>)
            .transpose()
            .map_err(|_| {
                crate::error::AgentError::InvalidArgument("id 必须来自 action=list".to_owned())
            })?;
        if matches!(request.target.as_str(), "monitor" | "window") && id.is_none() {
            return Err(crate::error::AgentError::InvalidArgument(
                "monitor 或 window 截图必须提供 action=list 返回的 id".to_owned(),
            )
            .into());
        }
        let region = request
            .region
            .map(|value| (value.x, value.y, value.width, value.height));
        let capture = crate::capture::capture_isolated(
            &self.state.paths,
            &IsolatedCaptureRequest {
                target: request.target.clone(),
                id,
                region,
                max_dimension: request.max_dimension,
            },
        )
        .await
        .map_err(ErrorData::from)?;
        let location = format!(
            "screenshot://sha256/{}",
            hex::encode(Sha256::digest(&capture.png))
        );
        let metadata = CaptureMetadata {
            target: request.target,
            location,
            width: capture.width,
            height: capture.height,
            captured_utc: chrono::Utc::now().to_rfc3339(),
            mime_type: "image/png".to_owned(),
            bytes: capture.png.len(),
            scaled: capture.scaled,
        };
        Ok(CallToolResult::success(vec![
            ContentBlock::text(
                serde_json::to_string(&metadata)
                    .map_err(|error| crate::error::AgentError::Internal(error.to_string()))?,
            ),
            ContentBlock::image(STANDARD.encode(capture.png), "image/png"),
        ]))
    }

    #[tool(
        description = "Launch a normal Windows EXE directly and report its PID, running state and visible-window observation; shells, installers and system mutators are rejected",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    async fn launch_application(
        &self,
        Parameters(request): Parameters<LaunchApplicationRequest>,
    ) -> Result<Json<LaunchApplicationResponse>, ErrorData> {
        crate::apps::launch(&request)
            .await
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Create, replace, move or delete files and directories strictly inside a registered code project; existing file writes and deletes require the current SHA-256",
        annotations(
            read_only_hint = false,
            destructive_hint = true,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    fn project_file(
        &self,
        Parameters(request): Parameters<ProjectFileRequest>,
    ) -> Result<Json<ProjectFileResponse>, ErrorData> {
        crate::projects::change_file(&self.state.config.snapshot(), &request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Run a common build, test or version-control program in a registered project without a command shell; returns output, timeout state and Git status before and after",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    async fn run_project_command(
        &self,
        Parameters(request): Parameters<RunProjectCommandRequest>,
    ) -> Result<Json<RunProjectCommandResponse>, ErrorData> {
        self.state
            .commands
            .run(&self.state.config.snapshot(), &request)
            .await
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Cancel a running project build or test by its caller-generated command_id; the whole child process tree is terminated",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn cancel_project_command(
        &self,
        Parameters(request): Parameters<CancelProjectCommandRequest>,
    ) -> Result<Json<CancelProjectCommandResponse>, ErrorData> {
        self.state
            .commands
            .cancel(&request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Submit a background investigation using the model currently selected in the Windows tray. The model may iteratively call only read-only Windows tools. Image-capable models can inspect screenshots; other models leave PNG evidence for the caller.",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = true
        )
    )]
    fn submit_investigation(
        &self,
        Parameters(request): Parameters<SubmitInvestigationRequest>,
    ) -> Result<Json<SubmitInvestigationResponse>, ErrorData> {
        self.state
            .tasks
            .submit(request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Return the persisted status of an investigation task",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn task_status(
        &self,
        Parameters(request): Parameters<TaskIdRequest>,
    ) -> Result<Json<TaskStatusResponse>, ErrorData> {
        self.state
            .tasks
            .status(&request.task_id)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Return the structured investigation result and every PNG screenshot captured as image content blocks",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn task_result(
        &self,
        Parameters(request): Parameters<TaskIdRequest>,
    ) -> Result<CallToolResult, ErrorData> {
        let result = self
            .state
            .tasks
            .result(&request.task_id)
            .map_err(ErrorData::from)?;
        let structured = serde_json::to_value(&result)
            .map_err(|error| crate::error::AgentError::Internal(error.to_string()))?;
        let mut content = vec![ContentBlock::text(structured.to_string())];
        for image in self.state.tasks.result_images(&request.task_id) {
            content.push(ContentBlock::image(image.data, image.mime_type));
        }
        let mut response = CallToolResult::success(content);
        response.structured_content = Some(structured);
        Ok(response)
    }

    #[tool(
        description = "Read bounded structured investigation task events with pagination",
        annotations(
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn task_log(
        &self,
        Parameters(request): Parameters<TaskLogRequest>,
    ) -> Result<Json<TaskLogResponse>, ErrorData> {
        self.state
            .tasks
            .logs(&request)
            .map(Json)
            .map_err(Into::into)
    }

    #[tool(
        description = "Request cooperative cancellation of a queued or running investigation task",
        annotations(
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    fn cancel_task(
        &self,
        Parameters(request): Parameters<TaskIdRequest>,
    ) -> Result<Json<CancelTaskResponse>, ErrorData> {
        self.state
            .tasks
            .cancel(&request.task_id)
            .map(Json)
            .map_err(Into::into)
    }
}

fn capture_agent_error(code: i32) -> crate::error::AgentError {
    let message = crate::capture::hr(code);
    if message.starts_with("screenshot_protected:") {
        crate::error::AgentError::ScreenshotProtected(message)
    } else {
        crate::error::AgentError::ScreenshotFailed(message)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for WindowsAgent {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build()).with_instructions(
            "Windows Agent 允许 Mac Codex 直接读取和搜索 Windows、查看系统状态、截图、启动普通应用，并在托盘登记的代码项目内修改文件和运行构建测试。system 范围永久只读，项目写入严格限制在登记根目录内。调查任务使用 Windows 托盘当前选择的 API 模型；模型只能调用只读调查工具。图片模型可以识别截图，文字模型只把 PNG 返回调用方。服务不提供鼠标、键盘、复杂界面控制、任意 Shell 或系统修改工具。模型总结不是唯一证据，应核对返回的文件、日志、系统状态、截图、哈希、差异和退出码。",
        )
    }
}

fn build_health(config: &AppConfig) -> HealthResponse {
    let profile = config
        .current_model
        .as_deref()
        .and_then(|id| config.models.iter().find(|profile| profile.id == id));
    let mut system = sysinfo::System::new_all();
    system.refresh_all();
    let mut gpu_command = background_process::std_command("nvidia-smi");
    gpu_command.args([
        "--query-gpu=name,memory.used,memory.total",
        "--format=csv,noheader,nounits",
    ]);
    let gpu = gpu_command
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_owned());
    HealthResponse {
        status: "ok".to_owned(),
        service: "windows-agent".to_owned(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        protocol: "mcp-streamable-http".to_owned(),
        current_model: profile.map(|value| value.model.clone()),
        current_model_name: profile.map(|value| value.name.clone()),
        current_model_supports_images: profile.map(|value| value.supports_images),
        current_model_credential_configured: profile.map(|value| {
            value.credential.trim().is_empty()
                || crate::credentials::read(&value.credential).is_ok()
        }),
        registered_projects: config.workspaces.len(),
        memory_total_bytes: system.total_memory(),
        memory_used_bytes: system.used_memory(),
        gpu,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_advertises_an_object_output_schema() {
        let tools = WindowsAgent::tool_router().list_all();
        assert_eq!(tools.len(), 17);

        for tool in &tools {
            if let Some(schema) = &tool.output_schema {
                assert_eq!(
                    schema.get("type").and_then(serde_json::Value::as_str),
                    Some("object"),
                    "{} advertises a non-object output schema",
                    tool.name
                );
            }
        }

        let workspace_schema = tools
            .iter()
            .find(|tool| tool.name == "list_workspaces")
            .and_then(|tool| tool.output_schema.as_ref())
            .expect("list_workspaces must advertise an output schema");
        assert_eq!(
            workspace_schema
                .get("properties")
                .and_then(|properties| properties.get("workspaces"))
                .and_then(|workspaces| workspaces.get("type"))
                .and_then(serde_json::Value::as_str),
            Some("array")
        );
    }
}
