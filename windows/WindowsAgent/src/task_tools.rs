use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};

use crate::{
    capture::{IsolatedCaptureRequest, capture_isolated},
    config::{AppConfig, DataPaths, ModelProfile},
    error::{AgentError, AgentResult},
    files::{ListFilesRequest, ReadFileRequest, SearchFilesRequest},
    inspect::InspectSystemRequest,
    task_types::{Evidence, TaskImageAttachment},
};

pub(crate) struct ToolExecution {
    pub(crate) content: String,
    pub(crate) image: Option<TaskImageAttachment>,
    pub(crate) evidence: Evidence,
}

impl ToolExecution {
    fn text(
        content: String,
        source_type: &str,
        location: String,
        observed_utc: String,
        fact: String,
    ) -> Self {
        Self {
            content,
            image: None,
            evidence: Evidence {
                source_type: source_type.to_owned(),
                location,
                observed_utc,
                fact,
            },
        }
    }
}

#[derive(Debug, Deserialize)]
struct ModelCaptureRequest {
    action: String,
    target: Option<String>,
    id: Option<String>,
    max_dimension: Option<u32>,
}

pub(crate) async fn execute(
    config: &AppConfig,
    paths: &DataPaths,
    profile: &ModelProfile,
    name: &str,
    arguments: &str,
) -> AgentResult<ToolExecution> {
    let observed_utc = chrono::Utc::now().to_rfc3339();
    match name {
        "list_files" => {
            let request: ListFilesRequest = parse_args(arguments)?;
            let response = crate::files::list(config, &request)?;
            Ok(ToolExecution::text(
                serde_json::to_string(&response)?,
                "directory",
                request.target.path,
                observed_utc,
                format!("列出 {} 个项目", response.entries.len()),
            ))
        }
        "read_file" => {
            let request: ReadFileRequest = parse_args(arguments)?;
            let response = crate::files::read(config, &request)?;
            Ok(ToolExecution::text(
                serde_json::to_string(&response)?,
                "file",
                request.target.path,
                observed_utc,
                format!(
                    "读取 {} 个单位，SHA-256 {}",
                    response.returned, response.sha256
                ),
            ))
        }
        "search_files" => {
            let request: SearchFilesRequest = parse_args(arguments)?;
            let response = crate::files::search(config, &request)?;
            Ok(ToolExecution::text(
                serde_json::to_string(&response)?,
                "search",
                request.root,
                observed_utc,
                format!("搜索得到 {} 条结果", response.matches.len()),
            ))
        }
        "inspect_system" => {
            let request: InspectSystemRequest = parse_args(arguments)?;
            let response = crate::inspect::inspect_system(&request)?;
            Ok(ToolExecution::text(
                serde_json::to_string(&response)?,
                "system",
                request
                    .path
                    .unwrap_or_else(|| request.category.as_str().to_owned()),
                observed_utc,
                format!(
                    "系统查询 {} 返回 {} 项",
                    request.category.as_str(),
                    response.items.len()
                ),
            ))
        }
        "capture_screen" => {
            let request: ModelCaptureRequest = parse_args(arguments)?;
            if request.action == "list" {
                let response = json!({
                    "monitors": crate::capture::enumerate("monitor").map_err(capture_error)?,
                    "windows": crate::capture::enumerate("window").map_err(capture_error)?
                });
                return Ok(ToolExecution::text(
                    response.to_string(),
                    "capture_targets",
                    "Windows desktop".to_owned(),
                    observed_utc,
                    "已枚举可用截图目标".to_owned(),
                ));
            }
            let target = request.target.unwrap_or_else(|| "primary".to_owned());
            let id = request
                .id
                .as_deref()
                .map(str::parse::<u64>)
                .transpose()
                .map_err(|_| AgentError::InvalidArgument("截图 id 无效".to_owned()))?;
            let capture = capture_isolated(
                paths,
                &IsolatedCaptureRequest {
                    target: target.clone(),
                    id,
                    region: None,
                    max_dimension: request.max_dimension.or(Some(1920)),
                },
            )
            .await?;
            let sha = hex::encode(Sha256::digest(&capture.png));
            let location = format!("screenshot://sha256/{sha}");
            let attachment = TaskImageAttachment {
                data: STANDARD.encode(capture.png),
                mime_type: "image/png".to_owned(),
                location: location.clone(),
            };
            let content = json!({
                "ok":true,
                "location":location,
                "target":target,
                "width":capture.width,
                "height":capture.height,
                "scaled":capture.scaled,
                "model_received_image":profile.supports_images
            })
            .to_string();
            Ok(ToolExecution {
                content,
                image: Some(attachment),
                evidence: Evidence {
                    source_type: "screenshot".to_owned(),
                    location,
                    observed_utc,
                    fact: format!(
                        "已截取 {}，尺寸 {}×{}",
                        target, capture.width, capture.height
                    ),
                },
            })
        }
        _ => Err(AgentError::PermissionDenied(
            "模型请求了未授权工具".to_owned(),
        )),
    }
}

fn parse_args<T: for<'de> Deserialize<'de>>(arguments: &str) -> AgentResult<T> {
    serde_json::from_str(arguments)
        .map_err(|error| AgentError::InvalidArgument(format!("模型工具参数无效: {error}")))
}

fn capture_error(code: i32) -> AgentError {
    AgentError::ScreenshotFailed(format!("截图目标枚举失败: {code:#x}"))
}
