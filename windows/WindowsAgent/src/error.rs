use rmcp::ErrorData;
use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum AgentError {
    #[error("invalid_argument: {0}")]
    InvalidArgument(String),
    #[error("path_outside_workspace: {0}")]
    PathOutsideWorkspace(String),
    #[error("permission_denied: {0}")]
    PermissionDenied(String),
    #[error("workspace_not_found: {0}")]
    WorkspaceNotFound(String),
    #[error("not_found: {0}")]
    NotFound(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("dependency_unavailable: {0}")]
    DependencyUnavailable(String),
    #[error("timeout: {0}")]
    Timeout(String),
    #[error("model_mismatch: {0}")]
    ModelMismatch(String),
    #[error("screenshot_protected: {0}")]
    ScreenshotProtected(String),
    #[error("screenshot_failed: {0}")]
    ScreenshotFailed(String),
    #[error("visual_evidence_missing: {0}")]
    VisualEvidenceMissing(String),
    #[error("cloud_rate_limited: {0}")]
    CloudRateLimited(String),
    #[error("cloud_quota_exceeded: {0}")]
    CloudQuotaExceeded(String),
    #[error("task_ended: {0}")]
    TaskEnded(String),
    #[error("io_error: {0}")]
    Io(#[from] std::io::Error),
    #[error("internal_error: {0}")]
    Internal(String),
}

impl AgentError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidArgument(_) => "invalid_argument",
            Self::PathOutsideWorkspace(_) => "path_outside_workspace",
            Self::PermissionDenied(_) => "permission_denied",
            Self::WorkspaceNotFound(_) => "workspace_not_found",
            Self::NotFound(_) => "not_found",
            Self::Conflict(_) => "conflict",
            Self::DependencyUnavailable(_) => "dependency_unavailable",
            Self::Timeout(_) => "timeout",
            Self::ModelMismatch(_) => "model_mismatch",
            Self::ScreenshotProtected(_) => "screenshot_protected",
            Self::ScreenshotFailed(_) => "screenshot_failed",
            Self::VisualEvidenceMissing(_) => "visual_evidence_missing",
            Self::CloudRateLimited(_) => "cloud_rate_limited",
            Self::CloudQuotaExceeded(_) => "cloud_quota_exceeded",
            Self::TaskEnded(_) => "task_ended",
            Self::Io(_) => "io_error",
            Self::Internal(_) => "internal_error",
        }
    }
}

#[derive(Debug, Serialize)]
struct ErrorDetails<'a> {
    code: &'static str,
    message: &'a str,
}

impl From<AgentError> for ErrorData {
    fn from(error: AgentError) -> Self {
        let message = error.to_string();
        let data = serde_json::to_value(ErrorDetails {
            code: error.code(),
            message: &message,
        })
        .ok();
        match error {
            AgentError::InvalidArgument(_)
            | AgentError::PathOutsideWorkspace(_)
            | AgentError::PermissionDenied(_)
            | AgentError::WorkspaceNotFound(_)
            | AgentError::NotFound(_)
            | AgentError::Conflict(_)
            | AgentError::TaskEnded(_)
            | AgentError::ModelMismatch(_)
            | AgentError::ScreenshotProtected(_)
            | AgentError::VisualEvidenceMissing(_) => ErrorData::invalid_params(message, data),
            _ => ErrorData::internal_error(message, data),
        }
    }
}

pub type AgentResult<T> = Result<T, AgentError>;
