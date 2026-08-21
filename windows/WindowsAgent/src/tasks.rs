use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

use futures_util::FutureExt;
use parking_lot::RwLock;
use serde_json::json;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    config::{ConfigStore, DataPaths, ModelProfile},
    error::{AgentError, AgentResult},
    model::{ModelClient, investigation_tools},
    security,
    task_store::TaskStore,
    task_tools,
};

pub use crate::task_types::*;

pub struct TaskManager {
    config: ConfigStore,
    paths: DataPaths,
    store: TaskStore,
    client: ModelClient,
    tasks: RwLock<HashMap<String, TaskRecord>>,
    images: RwLock<HashMap<String, Vec<TaskImageAttachment>>>,
    cancellations: RwLock<HashMap<String, CancellationToken>>,
    slots: Arc<Semaphore>,
}

impl TaskManager {
    pub fn new(config: ConfigStore, paths: DataPaths) -> AgentResult<Arc<Self>> {
        let max_tasks = config.snapshot().max_tasks.clamp(1, 16);
        let store = TaskStore::new(&paths);
        let manager = Arc::new(Self {
            config,
            paths,
            store,
            client: ModelClient::new()?,
            tasks: RwLock::new(HashMap::new()),
            images: RwLock::new(HashMap::new()),
            cancellations: RwLock::new(HashMap::new()),
            slots: Arc::new(Semaphore::new(max_tasks)),
        });
        manager.load_existing()?;
        Ok(manager)
    }

    pub fn submit(
        self: &Arc<Self>,
        request: SubmitInvestigationRequest,
    ) -> AgentResult<SubmitInvestigationResponse> {
        let config = self.config.snapshot();
        if let Some(workspace) = request.workspace.as_deref() {
            security::workspace(&config, workspace)?;
        }
        let prompt = request.prompt.trim();
        if prompt.is_empty() || prompt.len() > 64 * 1024 {
            return Err(AgentError::InvalidArgument("调查提示长度无效".to_owned()));
        }
        let selected = config
            .current_model
            .as_deref()
            .and_then(|id| config.models.iter().find(|profile| profile.id == id))
            .cloned()
            .ok_or_else(|| AgentError::DependencyUnavailable("尚未选择调查模型".to_owned()))?;
        let id = Uuid::new_v4().to_string();
        let cancellation = CancellationToken::new();
        let record = TaskRecord {
            id: id.clone(),
            workspace: request.workspace.clone(),
            model_profile: selected.id.clone(),
            state: TaskState::Queued,
            created_utc: chrono::Utc::now().to_rfc3339(),
            started_utc: None,
            completed_utc: None,
            elapsed_ms: None,
            stage: "queued".to_owned(),
            cancellation_requested: false,
            error_code: None,
            error: None,
            actual_model: None,
            result: None,
            logs: vec![TaskEvent {
                sequence: 1,
                utc: chrono::Utc::now().to_rfc3339(),
                level: "info".to_owned(),
                event: "task_queued".to_owned(),
                detail: format!("调查任务已排队；模型配置：{}", selected.name),
            }],
            output_truncated: false,
        };
        self.tasks.write().insert(id.clone(), record);
        self.cancellations
            .write()
            .insert(id.clone(), cancellation.clone());
        self.persist(&id)?;
        let manager = self.clone();
        let task_id = id.clone();
        let workspace = request.workspace;
        let prompt = prompt.to_owned();
        tokio::spawn(async move {
            let panic_manager = manager.clone();
            let panic_id = task_id.clone();
            let outcome = std::panic::AssertUnwindSafe(manager.execute(
                task_id,
                workspace,
                selected,
                prompt,
                cancellation,
            ))
            .catch_unwind()
            .await;
            if outcome.is_err() {
                panic_manager.finish_panicked(&panic_id);
            }
        });
        Ok(SubmitInvestigationResponse {
            task_id: id,
            state: TaskState::Queued,
            model_profile: config.current_model.unwrap_or_default(),
        })
    }

    pub fn status(&self, id: &str) -> AgentResult<TaskStatusResponse> {
        let task = self
            .tasks
            .read()
            .get(id)
            .cloned()
            .ok_or_else(|| AgentError::NotFound("任务不存在".to_owned()))?;
        Ok(TaskStatusResponse { task })
    }

    pub fn result(&self, id: &str) -> AgentResult<TaskResultResponse> {
        let task = self
            .tasks
            .read()
            .get(id)
            .cloned()
            .ok_or_else(|| AgentError::NotFound("任务不存在".to_owned()))?;
        let image_count = self.images.read().get(id).map(Vec::len).unwrap_or(0);
        Ok(TaskResultResponse {
            task_id: task.id,
            state: task.state,
            result: task.result,
            error_code: task.error_code,
            error: task.error,
            image_count,
        })
    }

    pub fn result_images(&self, id: &str) -> Vec<TaskImageAttachment> {
        self.images.read().get(id).cloned().unwrap_or_default()
    }

    pub fn logs(&self, request: &TaskLogRequest) -> AgentResult<TaskLogResponse> {
        let tasks = self.tasks.read();
        let task = tasks
            .get(&request.task_id)
            .ok_or_else(|| AgentError::NotFound("任务不存在".to_owned()))?;
        let limit = request.limit.unwrap_or(100).clamp(1, 200);
        let total = task.logs.len();
        let events = task
            .logs
            .iter()
            .skip(request.cursor)
            .take(limit)
            .cloned()
            .collect();
        let next = request.cursor.saturating_add(limit);
        Ok(TaskLogResponse {
            events,
            next_cursor: (next < total).then_some(next),
        })
    }

    pub fn cancel(&self, id: &str) -> AgentResult<TaskStatusResponse> {
        let token = self
            .cancellations
            .read()
            .get(id)
            .cloned()
            .ok_or_else(|| AgentError::TaskEnded("任务已结束或不存在".to_owned()))?;
        token.cancel();
        self.update(id, |task| {
            task.cancellation_requested = true;
            task.stage = "cancellation_requested".to_owned();
            push_log(task, "info", "cancel_requested", "已请求合作式取消");
        })?;
        self.status(id)
    }

    pub async fn shutdown(&self) {
        for token in self.cancellations.read().values() {
            token.cancel();
        }
    }

    async fn execute(
        self: Arc<Self>,
        id: String,
        workspace: Option<String>,
        profile: ModelProfile,
        prompt: String,
        cancellation: CancellationToken,
    ) {
        let permit = tokio::select! {
            value = self.slots.clone().acquire_owned() => value.ok(),
            _ = cancellation.cancelled() => None,
        };
        let Some(_permit) = permit else {
            let _ = self.finish_cancelled(&id, None);
            return;
        };
        let started = Instant::now();
        if self
            .update(&id, |task| {
                task.state = TaskState::Running;
                task.started_utc = Some(chrono::Utc::now().to_rfc3339());
                task.stage = "calling_model".to_owned();
                push_log(
                    task,
                    "info",
                    "task_started",
                    &format!("正在直接调用 {}", profile.name),
                );
            })
            .is_err()
        {
            return;
        }
        let result = self
            .run_investigation(&id, workspace.as_deref(), &profile, &prompt, &cancellation)
            .await;
        match result {
            Ok(result) => {
                let actual = result.model.actual_model.clone();
                let _ = self.update(&id, |task| {
                    task.state = TaskState::Succeeded;
                    task.stage = "completed".to_owned();
                    task.completed_utc = Some(chrono::Utc::now().to_rfc3339());
                    task.elapsed_ms = Some(elapsed_ms(started));
                    task.actual_model = Some(actual);
                    task.result = Some(result);
                    push_log(task, "info", "task_succeeded", "调查任务已成功完成");
                });
            }
            Err(_error) if cancellation.is_cancelled() => {
                let _ = self.finish_cancelled(&id, Some(started));
            }
            Err(error) => {
                let code = error.code().to_owned();
                let detail = error.to_string();
                let _ = self.update(&id, |task| {
                    task.state = TaskState::Failed;
                    task.stage = "failed".to_owned();
                    task.completed_utc = Some(chrono::Utc::now().to_rfc3339());
                    task.elapsed_ms = Some(elapsed_ms(started));
                    task.error_code = Some(code);
                    task.error = Some(detail.clone());
                    push_log(task, "error", "task_failed", &detail);
                });
            }
        }
        self.cancellations.write().remove(&id);
    }

    async fn run_investigation(
        &self,
        id: &str,
        workspace: Option<&str>,
        profile: &ModelProfile,
        prompt: &str,
        cancellation: &CancellationToken,
    ) -> AgentResult<InvestigationResult> {
        let config = self.config.snapshot();
        let workspace_context = workspace
            .and_then(|id| config.workspaces.iter().find(|item| item.id == id))
            .map(|item| format!("登记项目：{}，根目录：{}", item.name, item.path.display()))
            .unwrap_or_else(|| "未绑定登记项目，可以调查整个 Windows。".to_owned());
        let mut messages = vec![
            json!({
                "role":"system",
                "content": format!(
                    "你是 Windows 调查代理。通过提供的只读工具核对事实，不能修改文件、执行命令或声称看到了未取得的内容。最终用中文直接回答，并说明证据位置。{workspace_context}"
                )
            }),
            json!({"role":"user", "content":prompt}),
        ];
        let tools = investigation_tools();
        let mut evidence = Vec::new();
        let mut limitations = Vec::new();
        let mut total_input = 0_u64;
        let mut total_output = 0_u64;
        let mut has_input_usage = false;
        let mut has_output_usage = false;
        let mut tool_call_count = 0_usize;
        let mut screenshot_count = 0_usize;
        let max_steps = config.max_model_tool_steps.clamp(1, 32);

        for step in 0..=max_steps {
            self.update(id, |task| {
                task.stage = format!("model_step_{}", step + 1);
            })?;
            let turn = self
                .client
                .complete(profile, &messages, &tools, cancellation)
                .await?;
            if let Some(value) = turn.input_tokens {
                total_input = total_input.saturating_add(value);
                has_input_usage = true;
            }
            if let Some(value) = turn.output_tokens {
                total_output = total_output.saturating_add(value);
                has_output_usage = true;
            }
            messages.push(turn.message);
            if turn.tool_calls.is_empty() {
                if turn.content.trim().is_empty() {
                    return Err(AgentError::DependencyUnavailable(
                        "模型没有返回调查结论".to_owned(),
                    ));
                }
                if requires_visual_analysis(prompt) {
                    if screenshot_count == 0 {
                        return Err(AgentError::VisualEvidenceMissing(
                            "视觉调查没有取得截图".to_owned(),
                        ));
                    }
                    if !profile.supports_images {
                        return Err(AgentError::VisualEvidenceMissing(
                            "当前模型不支持图片；截图已返回调用方，但模型不能完成识图".to_owned(),
                        ));
                    }
                }
                let model = ModelResult {
                    profile: profile.id.clone(),
                    service: profile.base_url.clone(),
                    actual_model: turn.actual_model.clone(),
                    input_tokens: has_input_usage.then_some(total_input),
                    output_tokens: has_output_usage.then_some(total_output),
                    estimated_cost: estimate_cost(profile, total_input, total_output),
                    tool_calls: tool_call_count,
                };
                return Ok(InvestigationResult {
                    conclusion: turn.content.trim().to_owned(),
                    evidence,
                    model,
                    limitations,
                });
            }
            if step == max_steps {
                return Err(AgentError::Timeout("模型工具调用步数超过限制".to_owned()));
            }
            for call in turn.tool_calls {
                tool_call_count += 1;
                let execution =
                    task_tools::execute(&config, &self.paths, profile, &call.name, &call.arguments)
                        .await;
                match execution {
                    Ok(execution) => {
                        evidence.push(execution.evidence);
                        messages.push(json!({
                            "role":"tool",
                            "tool_call_id":call.id,
                            "content":execution.content
                        }));
                        if let Some(image) = execution.image {
                            screenshot_count += 1;
                            self.images
                                .write()
                                .entry(id.to_owned())
                                .or_default()
                                .push(image.clone());
                            if profile.supports_images {
                                messages.push(json!({
                                    "role":"user",
                                    "content":[
                                        {"type":"text", "text":format!("这是工具刚取得的截图证据：{}", image.location)},
                                        {"type":"image_url", "image_url":{"url":format!("data:{};base64,{}", image.mime_type, image.data)}}
                                    ]
                                }));
                            } else {
                                limitations.push(format!(
                                    "截图 {} 已返回调用方，但当前文字模型未接收图片数据",
                                    image.location
                                ));
                            }
                        }
                        self.update(id, |task| {
                            push_log(
                                task,
                                "info",
                                "model_tool_completed",
                                &format!("只读工具 {} 已完成", call.name),
                            );
                        })?;
                    }
                    Err(error) => {
                        let detail = error.to_string();
                        messages.push(json!({
                            "role":"tool",
                            "tool_call_id":call.id,
                            "content":json!({"ok":false,"error":detail}).to_string()
                        }));
                        self.update(id, |task| {
                            push_log(
                                task,
                                "warning",
                                "model_tool_failed",
                                &format!("只读工具 {} 失败：{}", call.name, detail),
                            );
                        })?;
                    }
                }
            }
        }
        Err(AgentError::Internal("模型调查循环异常结束".to_owned()))
    }

    fn update<F>(&self, id: &str, update: F) -> AgentResult<()>
    where
        F: FnOnce(&mut TaskRecord),
    {
        let mut tasks = self.tasks.write();
        let task = tasks
            .get_mut(id)
            .ok_or_else(|| AgentError::NotFound("任务不存在".to_owned()))?;
        update(task);
        let record = task.clone();
        drop(tasks);
        self.persist_record(&record)
    }

    fn persist(&self, id: &str) -> AgentResult<()> {
        let tasks = self.tasks.read();
        let task = tasks
            .get(id)
            .ok_or_else(|| AgentError::NotFound("任务不存在".to_owned()))?;
        self.persist_record(task)
    }

    fn persist_record(&self, task: &TaskRecord) -> AgentResult<()> {
        self.store.persist(task)
    }

    fn load_existing(&self) -> AgentResult<()> {
        let retention = Duration::from_secs(
            self.config.snapshot().task_retention_days.clamp(1, 365) * 24 * 60 * 60,
        );
        for mut task in self.store.load(retention)? {
            if matches!(task.state, TaskState::Queued | TaskState::Running) {
                task.state = TaskState::Failed;
                task.stage = "interrupted".to_owned();
                task.error_code = Some("service_restarted".to_owned());
                task.error = Some("服务重启中断了任务".to_owned());
                task.completed_utc = Some(chrono::Utc::now().to_rfc3339());
                let _ = self.persist_record(&task);
            }
            self.tasks.write().insert(task.id.clone(), task);
        }
        Ok(())
    }

    fn finish_cancelled(&self, id: &str, started: Option<Instant>) -> AgentResult<()> {
        self.update(id, |task| {
            task.state = TaskState::Cancelled;
            task.stage = "cancelled".to_owned();
            task.completed_utc = Some(chrono::Utc::now().to_rfc3339());
            task.elapsed_ms = started.map(elapsed_ms);
            task.error_code = Some("cancelled".to_owned());
            task.error = Some("任务已取消".to_owned());
            push_log(task, "info", "task_cancelled", "调查任务已取消");
        })
    }

    fn finish_panicked(&self, id: &str) {
        let _ = self.update(id, |task| {
            task.state = TaskState::Failed;
            task.stage = "panicked".to_owned();
            task.completed_utc = Some(chrono::Utc::now().to_rfc3339());
            task.error_code = Some("task_panicked".to_owned());
            task.error = Some("调查任务发生内部异常，主服务仍在运行".to_owned());
            push_log(
                task,
                "error",
                "task_panicked",
                "调查任务发生内部异常，已被任务级防护隔离",
            );
        });
        self.cancellations.write().remove(id);
    }
}
fn estimate_cost(profile: &ModelProfile, input: u64, output: u64) -> Option<String> {
    let input_cost = profile
        .input_cost_per_million
        .map(|price| price * input as f64 / 1_000_000.0);
    let output_cost = profile
        .output_cost_per_million
        .map(|price| price * output as f64 / 1_000_000.0);
    match (input_cost, output_cost) {
        (None, None) => None,
        (left, right) => Some(format!("{:.6}", left.unwrap_or(0.0) + right.unwrap_or(0.0))),
    }
}

fn requires_visual_analysis(prompt: &str) -> bool {
    let lower = prompt.to_ascii_lowercase();
    if [
        "不要识别",
        "无需识别",
        "不识别",
        "不要分析",
        "无需分析",
        "不分析",
        "do not identify",
        "do not analyze",
        "without analyzing",
    ]
    .iter()
    .any(|phrase| lower.contains(phrase))
    {
        return false;
    }
    let visual_subject = [
        "截图",
        "屏幕",
        "界面",
        "窗口",
        "图片",
        "图像",
        "screenshot",
        "screen image",
        "window image",
    ]
    .iter()
    .any(|keyword| lower.contains(keyword));
    let interpretation = [
        "识别",
        "分析",
        "看图",
        "读出",
        "显示什么",
        "是什么",
        "identify",
        "recognize",
        "analyse",
        "analyze",
        "what is shown",
        "read from",
    ]
    .iter()
    .any(|keyword| lower.contains(keyword));
    visual_subject && interpretation
}

fn push_log(task: &mut TaskRecord, level: &str, event: &str, detail: &str) {
    let sequence = task.logs.last().map(|item| item.sequence + 1).unwrap_or(1);
    task.logs.push(TaskEvent {
        sequence,
        utc: chrono::Utc::now().to_rfc3339(),
        level: level.to_owned(),
        event: event.to_owned(),
        detail: detail.chars().take(1000).collect(),
    });
}

fn elapsed_ms(started: Instant) -> u64 {
    started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

impl From<serde_json::Error> for AgentError {
    fn from(error: serde_json::Error) -> Self {
        AgentError::Internal(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn visual_prompt_detection_avoids_product_name_false_positive() {
        assert!(requires_visual_analysis("识别当前任务管理器截图"));
        assert!(!requires_visual_analysis("请截一张当前屏幕并返回图片"));
        assert!(!requires_visual_analysis(
            "请截图返回，不要识别、分析或描述图片内容"
        ));
        assert!(!requires_visual_analysis(
            "Windows Agent 默认调查链路正在验收"
        ));
        assert!(!requires_visual_analysis("读取 Cargo.toml 并总结依赖"));
    }

    #[test]
    fn cost_uses_configured_token_prices() {
        let mut profile = ModelProfile::deepseek_default();
        profile.input_cost_per_million = Some(1.0);
        profile.output_cost_per_million = Some(2.0);
        assert_eq!(
            estimate_cost(&profile, 1_000_000, 500_000).as_deref(),
            Some("2.000000")
        );
    }
}
