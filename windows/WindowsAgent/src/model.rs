use std::time::Duration;

use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use crate::{
    config::ModelProfile,
    credentials,
    error::{AgentError, AgentResult},
};

#[derive(Clone)]
pub struct ModelClient {
    client: reqwest::Client,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: String,
}

#[derive(Clone, Debug)]
pub struct ModelTurn {
    pub message: Value,
    pub content: String,
    pub tool_calls: Vec<ToolCall>,
    pub actual_model: String,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
}

impl ModelClient {
    pub fn new() -> AgentResult<Self> {
        let client = reqwest::Client::builder()
            .user_agent(format!("Meno-Windows-Agent/{}", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|error| AgentError::Internal(error.to_string()))?;
        Ok(Self { client })
    }

    pub async fn complete(
        &self,
        profile: &ModelProfile,
        messages: &[Value],
        tools: &[Value],
        cancellation: &CancellationToken,
    ) -> AgentResult<ModelTurn> {
        profile.validate()?;
        let mut request = self
            .client
            .post(profile.chat_completions_url())
            .timeout(Duration::from_secs(profile.timeout_seconds.clamp(5, 900)))
            .json(&json!({
                "model": profile.model,
                "messages": messages,
                "tools": tools,
                "tool_choice": "auto"
            }));
        if !profile.credential.trim().is_empty() {
            let secret = credentials::read(&profile.credential).map_err(|_| {
                AgentError::DependencyUnavailable(format!(
                    "模型“{}”的 API 密钥尚未配置",
                    profile.name
                ))
            })?;
            request = request.bearer_auth(secret);
        }
        let response = tokio::select! {
            _ = cancellation.cancelled() => {
                return Err(AgentError::TaskEnded("模型调用已取消".to_owned()));
            }
            result = request.send() => result.map_err(map_transport_error)?,
        };
        let status = response.status();
        let body = response
            .bytes()
            .await
            .map_err(|error| AgentError::DependencyUnavailable(error.to_string()))?;
        if !status.is_success() {
            return Err(map_api_error(status, &body));
        }
        let response: ChatResponse = serde_json::from_slice(&body).map_err(|error| {
            AgentError::DependencyUnavailable(format!("模型 API 返回无效 JSON: {error}"))
        })?;
        let choice =
            response.choices.into_iter().next().ok_or_else(|| {
                AgentError::DependencyUnavailable("模型 API 没有返回结果".to_owned())
            })?;
        let content = choice.message.content.unwrap_or_default();
        let tool_calls = choice
            .message
            .tool_calls
            .unwrap_or_default()
            .into_iter()
            .map(|call| ToolCall {
                id: call.id,
                name: call.function.name,
                arguments: call.function.arguments,
            })
            .collect::<Vec<_>>();
        let mut message = json!({"role":"assistant", "content": content});
        if !tool_calls.is_empty() {
            message["tool_calls"] = Value::Array(
                tool_calls
                    .iter()
                    .map(|call| {
                        json!({
                            "id": call.id,
                            "type": "function",
                            "function": {"name": call.name, "arguments": call.arguments}
                        })
                    })
                    .collect(),
            );
        }
        Ok(ModelTurn {
            message,
            content,
            tool_calls,
            actual_model: response.model.unwrap_or_else(|| profile.model.clone()),
            input_tokens: response
                .usage
                .as_ref()
                .and_then(|usage| usage.prompt_tokens),
            output_tokens: response
                .usage
                .as_ref()
                .and_then(|usage| usage.completion_tokens),
        })
    }

    pub async fn test_profile(&self, profile: &ModelProfile) -> AgentResult<String> {
        let cancellation = CancellationToken::new();
        let mut request = self
            .client
            .post(profile.chat_completions_url())
            .timeout(Duration::from_secs(profile.timeout_seconds.clamp(5, 30)))
            .json(&json!({
                "model": profile.model,
                "messages": [{"role":"user", "content":"Reply with OK."}],
                "max_tokens": 8
            }));
        if !profile.credential.trim().is_empty() {
            request = request.bearer_auth(credentials::read(&profile.credential)?);
        }
        let response = tokio::select! {
            _ = cancellation.cancelled() => unreachable!(),
            result = request.send() => result.map_err(map_transport_error)?,
        };
        let status = response.status();
        let body = response.bytes().await.map_err(map_transport_error)?;
        if !status.is_success() {
            return Err(map_api_error(status, &body));
        }
        let parsed: ChatResponse = serde_json::from_slice(&body).map_err(|error| {
            AgentError::DependencyUnavailable(format!("模型 API 返回无效 JSON: {error}"))
        })?;
        Ok(parsed.model.unwrap_or_else(|| profile.model.clone()))
    }
}

pub fn investigation_tools() -> Vec<Value> {
    vec![
        function_tool(
            "list_files",
            "列出任意 Windows 目录或登记项目目录，结果分页返回",
            json!({
                "type":"object",
                "properties":{
                    "scope":{"type":"string","enum":["system","workspace"]},
                    "workspace":{"type":["string","null"]},
                    "path":{"type":"string"},
                    "cursor":{"type":"integer","minimum":0},
                    "limit":{"type":"integer","minimum":1,"maximum":200}
                },
                "required":["scope","path"]
            }),
        ),
        function_tool(
            "read_file",
            "读取任意 Windows 普通文件的有限行范围，并返回完整文件哈希",
            json!({
                "type":"object",
                "properties":{
                    "scope":{"type":"string","enum":["system","workspace"]},
                    "workspace":{"type":["string","null"]},
                    "path":{"type":"string"},
                    "start_line":{"type":"integer","minimum":1},
                    "line_count":{"type":"integer","minimum":1,"maximum":500}
                },
                "required":["scope","path"]
            }),
        ),
        function_tool(
            "search_files",
            "按文件名、扩展名或文本搜索任意 Windows 目录，结果有扫描上限",
            json!({
                "type":"object",
                "properties":{
                    "scope":{"type":"string","enum":["system","workspace"]},
                    "workspace":{"type":["string","null"]},
                    "root":{"type":"string"},
                    "name_contains":{"type":["string","null"]},
                    "extension":{"type":["string","null"]},
                    "text":{"type":["string","null"]},
                    "cursor":{"type":"integer","minimum":0},
                    "limit":{"type":"integer","minimum":1,"maximum":200}
                },
                "required":["scope","root"]
            }),
        ),
        function_tool(
            "inspect_system",
            "读取 Windows 摘要、进程、服务、驱动、网络、事件日志或注册表",
            json!({
                "type":"object",
                "properties":{
                    "category":{"type":"string","enum":["summary","processes","services","drivers","network","event_log","registry"]},
                    "path":{"type":["string","null"]},
                    "filter":{"type":["string","null"]},
                    "cursor":{"type":"integer","minimum":0},
                    "limit":{"type":"integer","minimum":1,"maximum":200}
                },
                "required":["category"]
            }),
        ),
        function_tool(
            "capture_screen",
            "枚举截图目标，或截取桌面、显示器、主显示器或指定可见窗口",
            json!({
                "type":"object",
                "properties":{
                    "action":{"type":"string","enum":["list","capture"]},
                    "target":{"type":"string","enum":["virtual_desktop","primary","monitor","window"]},
                    "id":{"type":["string","null"]},
                    "max_dimension":{"type":"integer","minimum":320,"maximum":4096}
                },
                "required":["action"]
            }),
        ),
    ]
}

fn function_tool(name: &str, description: &str, parameters: Value) -> Value {
    json!({
        "type":"function",
        "function": {"name":name, "description":description, "parameters":parameters}
    })
}

fn map_transport_error(error: reqwest::Error) -> AgentError {
    if error.is_timeout() {
        AgentError::Timeout("模型 API 调用超时".to_owned())
    } else {
        AgentError::DependencyUnavailable(format!("模型 API 无法访问: {error}"))
    }
}

fn map_api_error(status: StatusCode, body: &[u8]) -> AgentError {
    let detail = serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|value| {
            value
                .pointer("/error/message")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .unwrap_or_else(|| String::from_utf8_lossy(body).chars().take(500).collect());
    match status {
        StatusCode::TOO_MANY_REQUESTS => AgentError::CloudRateLimited(detail),
        StatusCode::PAYMENT_REQUIRED => AgentError::CloudQuotaExceeded(detail),
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            AgentError::PermissionDenied(format!("模型 API 拒绝认证: {detail}"))
        }
        _ => AgentError::DependencyUnavailable(format!("模型 API HTTP {status}: {detail}")),
    }
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    model: Option<String>,
    choices: Vec<ChatChoice>,
    usage: Option<Usage>,
}

#[derive(Debug, Deserialize)]
struct ChatChoice {
    message: AssistantMessage,
}

#[derive(Debug, Deserialize)]
struct AssistantMessage {
    content: Option<String>,
    tool_calls: Option<Vec<ApiToolCall>>,
}

#[derive(Debug, Deserialize)]
struct ApiToolCall {
    id: String,
    function: ApiFunction,
}

#[derive(Debug, Deserialize)]
struct ApiFunction {
    name: String,
    arguments: String,
}

#[derive(Debug, Deserialize)]
struct Usage {
    prompt_tokens: Option<u64>,
    completion_tokens: Option<u64>,
}
