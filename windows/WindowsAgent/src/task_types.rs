use rmcp::schemars;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskState {
    Queued,
    Running,
    Succeeded,
    Failed,
    Cancelled,
    Expired,
}

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
pub struct Evidence {
    pub source_type: String,
    pub location: String,
    pub observed_utc: String,
    pub fact: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ModelResult {
    pub profile: String,
    pub service: String,
    pub actual_model: String,
    pub input_tokens: Option<u64>,
    pub output_tokens: Option<u64>,
    pub estimated_cost: Option<String>,
    pub tool_calls: usize,
}

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
pub struct InvestigationResult {
    pub conclusion: String,
    pub evidence: Vec<Evidence>,
    pub model: ModelResult,
    pub limitations: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TaskEvent {
    pub sequence: u64,
    pub utc: String,
    pub level: String,
    pub event: String,
    pub detail: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TaskRecord {
    pub id: String,
    pub workspace: Option<String>,
    pub model_profile: String,
    pub state: TaskState,
    pub created_utc: String,
    pub started_utc: Option<String>,
    pub completed_utc: Option<String>,
    pub elapsed_ms: Option<u64>,
    pub stage: String,
    pub cancellation_requested: bool,
    pub error_code: Option<String>,
    pub error: Option<String>,
    pub actual_model: Option<String>,
    pub result: Option<InvestigationResult>,
    pub logs: Vec<TaskEvent>,
    pub output_truncated: bool,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct SubmitInvestigationRequest {
    /// Optional registered project used as context. System-wide investigations may omit it.
    #[serde(default)]
    pub workspace: Option<String>,
    pub prompt: String,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct SubmitInvestigationResponse {
    pub task_id: String,
    pub state: TaskState,
    pub model_profile: String,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct TaskIdRequest {
    pub task_id: String,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct TaskStatusResponse {
    pub task: TaskRecord,
}

pub type CancelTaskResponse = TaskStatusResponse;

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct TaskResultResponse {
    pub task_id: String,
    pub state: TaskState,
    pub result: Option<InvestigationResult>,
    pub error_code: Option<String>,
    pub error: Option<String>,
    pub image_count: usize,
}

#[derive(Clone, Debug)]
pub struct TaskImageAttachment {
    pub data: String,
    pub mime_type: String,
    pub location: String,
}

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct TaskLogRequest {
    pub task_id: String,
    #[serde(default)]
    pub cursor: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct TaskLogResponse {
    pub events: Vec<TaskEvent>,
    pub next_cursor: Option<usize>,
}
