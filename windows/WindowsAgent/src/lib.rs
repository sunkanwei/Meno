use std::{
    env, fs,
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU8, Ordering},
        mpsc::{self, SyncSender},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use axum::{
    Router,
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::post,
};
use rmcp::transport::streamable_http_server::{
    StreamableHttpServerConfig, StreamableHttpService, session::never::NeverSessionManager,
};
use tokio_util::sync::CancellationToken;
use windows::{
    Win32::UI::{Shell::ShellExecuteW, WindowsAndMessaging::SW_SHOWNORMAL},
    core::PCWSTR,
};

mod apps;
mod background_process;
pub mod capture;
mod config;
mod credentials;
mod discovery;
mod error;
mod files;
mod inspect;
mod job;
mod model;
mod projects;
mod security;
mod server;
mod settings;
mod task_store;
mod task_tools;
mod task_types;
mod tasks;

const CAPTURE_WORKER_COMMAND: &str = "--meno-agent-capture-worker";
const FIREWALL_INSTALL_COMMAND: &str = "--meno-agent-firewall-install";
const FIREWALL_RULE_NAME: &str = "Meno Windows Agent MCP";
const DISCOVERY_FIREWALL_RULE_NAME: &str = "Meno Windows Agent Discovery";
const STATUS_STARTING: u8 = 1;
const STATUS_RUNNING: u8 = 2;
const STATUS_FAILED: u8 = 3;
const STATUS_STOPPED: u8 = 4;

type LogSink = Arc<dyn Fn(&str, &str) + Send + Sync>;

static SETTINGS_STORE: OnceLock<config::ConfigStore> = OnceLock::new();
static SERVICE_STATUS: AtomicU8 = AtomicU8::new(STATUS_STOPPED);

pub struct EmbeddedAgent {
    shutdown: CancellationToken,
    join: Mutex<Option<JoinHandle<()>>>,
    log: LogSink,
}

impl EmbeddedAgent {
    pub fn start<F>(logger: F) -> Result<Self, String>
    where
        F: Fn(&str, &str) + Send + Sync + 'static,
    {
        SERVICE_STATUS.store(STATUS_STARTING, Ordering::Release);
        let log: LogSink = Arc::new(logger);
        let paths = config::data_paths();
        if let Err(error) = config::ensure_data_directories(&paths) {
            SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
            return Err(error.to_string());
        }
        let loaded = match config::load_or_create(&paths) {
            Ok(config) => config,
            Err(error) => {
                SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
                return Err(error.to_string());
            }
        };
        let store = config::ConfigStore::new(paths.clone(), loaded);
        let _ = SETTINGS_STORE.set(store.clone());
        let shutdown = CancellationToken::new();
        let thread_shutdown = shutdown.clone();
        let thread_log = log.clone();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let join = thread::Builder::new()
            .name("meno-windows-agent".to_owned())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_multi_thread()
                    .worker_threads(2)
                    .thread_name("meno-agent-runtime")
                    .enable_all()
                    .build();
                let result = match runtime {
                    Ok(runtime) => runtime.block_on(run_service(
                        store,
                        paths,
                        thread_shutdown,
                        ready_tx.clone(),
                        thread_log.clone(),
                    )),
                    Err(error) => Err(error.into()),
                };
                if let Err(error) = result {
                    SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
                    let _ = ready_tx.try_send(Err(error.to_string()));
                    thread_log("error", &format!("Windows Agent stopped: {error}"));
                } else {
                    SERVICE_STATUS.store(STATUS_STOPPED, Ordering::Release);
                }
            })
            .map_err(|error| {
                SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
                error.to_string()
            })?;

        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(())) => {
                SERVICE_STATUS.store(STATUS_RUNNING, Ordering::Release);
                Ok(Self {
                    shutdown,
                    join: Mutex::new(Some(join)),
                    log,
                })
            }
            Ok(Err(error)) => {
                SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
                let _ = join.join();
                Err(error)
            }
            Err(error) => {
                shutdown.cancel();
                SERVICE_STATUS.store(STATUS_FAILED, Ordering::Release);
                Err(format!("Windows Agent startup did not complete: {error}"))
            }
        }
    }

    pub fn shutdown(&self) {
        self.shutdown.cancel();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let finished = self
                .join
                .lock()
                .ok()
                .and_then(|join| join.as_ref().map(JoinHandle::is_finished))
                .unwrap_or(true);
            if finished || Instant::now() >= deadline {
                break;
            }
            thread::sleep(Duration::from_millis(25));
        }
        let join = self.join.lock().ok().and_then(|mut join| join.take());
        if let Some(join) = join {
            if join.is_finished() {
                let _ = join.join();
            } else {
                (self.log)("error", "Windows Agent did not stop within 3 seconds");
            }
        }
    }
}

impl Drop for EmbeddedAgent {
    fn drop(&mut self) {
        self.shutdown.cancel();
    }
}

pub fn status_label() -> &'static str {
    match SERVICE_STATUS.load(Ordering::Acquire) {
        STATUS_STARTING => "正在启动",
        STATUS_RUNNING => "运行中",
        STATUS_FAILED => "启动失败",
        _ => "已停止",
    }
}

pub fn open_settings() -> Result<(), String> {
    let store = SETTINGS_STORE
        .get()
        .cloned()
        .ok_or_else(|| "Windows Agent configuration is unavailable".to_owned())?;
    settings::open(store);
    Ok(())
}

pub fn handle_process_command() -> bool {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    let Some(command) = arguments.first().map(String::as_str) else {
        return false;
    };
    let result = match command {
        CAPTURE_WORKER_COMMAND => run_capture_worker(&arguments[1..]),
        FIREWALL_INSTALL_COMMAND if arguments.len() == 1 => install_firewall_rules(),
        _ => return false,
    };
    if let Err(error) = result {
        eprintln!("{error}");
    }
    true
}

pub(crate) fn request_firewall_update() -> error::AgentResult<()> {
    let executable = env::current_exe()?;
    let executable = wide_os(executable.as_os_str());
    let parameters = wide(FIREWALL_INSTALL_COMMAND);
    let result = unsafe {
        ShellExecuteW(
            None,
            windows::core::w!("runas"),
            PCWSTR(executable.as_ptr()),
            PCWSTR(parameters.as_ptr()),
            None,
            SW_SHOWNORMAL,
        )
    };
    if result.0 as usize <= 32 {
        return Err(error::AgentError::PermissionDenied(
            "防火墙更新提权被取消或失败".to_owned(),
        ));
    }
    Ok(())
}

async fn run_service(
    store: config::ConfigStore,
    paths: config::DataPaths,
    shutdown: CancellationToken,
    ready: SyncSender<Result<(), String>>,
    log: LogSink,
) -> error::AgentResult<()> {
    let config = store.snapshot();
    let listen_address = format!("{}:{}", config.bind_address, config.port);
    let listener = tokio::net::TcpListener::bind(&listen_address).await?;
    let admin_token = format!("wa-admin-{}", uuid::Uuid::new_v4());
    let _runtime_files = RuntimeFiles::new(paths.config_dir.clone());
    fs::write(paths.config_dir.join("admin.token"), &admin_token)?;
    fs::write(
        paths.config_dir.join("agent.pid"),
        std::process::id().to_string(),
    )?;
    let state = Arc::new(server::AppState::new(
        store,
        paths.clone(),
        shutdown.clone(),
        admin_token,
    )?);
    let service = mcp_service(state.clone(), shutdown.child_token());
    let router = Router::new()
        .nest_service("/mcp", service)
        .route("/admin/stop", post(admin_stop))
        .with_state(state.clone());
    let _discovery = discovery::DiscoveryService::start(config.port)?;
    let _ = ready.send(Ok(()));
    log(
        "info",
        &format!("Windows Agent listening on {listen_address}"),
    );
    let result = axum::serve(listener, router)
        .with_graceful_shutdown({
            let shutdown = shutdown.clone();
            async move {
                shutdown.cancelled().await;
                shutdown.cancel();
            }
        })
        .await;
    state.tasks.shutdown().await;
    result?;
    log("info", "Windows Agent stopped normally");
    Ok(())
}

fn mcp_service(
    state: Arc<server::AppState>,
    cancellation_token: CancellationToken,
) -> StreamableHttpService<server::WindowsAgent, NeverSessionManager> {
    StreamableHttpService::new(
        move || Ok(server::WindowsAgent::new(state.clone())),
        Default::default(),
        StreamableHttpServerConfig::default()
            .disable_allowed_hosts()
            .with_legacy_session_mode(false)
            .with_cancellation_token(cancellation_token),
    )
}

struct RuntimeFiles {
    config_dir: PathBuf,
}

impl RuntimeFiles {
    fn new(config_dir: PathBuf) -> Self {
        Self { config_dir }
    }
}

impl Drop for RuntimeFiles {
    fn drop(&mut self) {
        let _ = fs::remove_file(self.config_dir.join("admin.token"));
        let _ = fs::remove_file(self.config_dir.join("agent.pid"));
    }
}

async fn admin_stop(State(state): State<Arc<server::AppState>>, headers: HeaderMap) -> StatusCode {
    let authenticated = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|token| token == state.admin_token);
    if !authenticated {
        return StatusCode::UNAUTHORIZED;
    }
    state.shutdown.cancel();
    StatusCode::ACCEPTED
}

fn run_capture_worker(arguments: &[String]) -> error::AgentResult<()> {
    let mut target = None;
    let mut id = None;
    let mut x = None;
    let mut y = None;
    let mut width = None;
    let mut height = None;
    let mut max_dimension = None;
    let mut output = None;
    let mut index = 0;
    while index < arguments.len() {
        let option = arguments[index].as_str();
        index += 1;
        let value = arguments.get(index).ok_or_else(|| {
            error::AgentError::InvalidArgument(format!("截图参数缺少值: {option}"))
        })?;
        index += 1;
        match option {
            "--target" => target = Some(value.clone()),
            "--id" => id = Some(parse_number(value, option)?),
            "--x" => x = Some(parse_number(value, option)?),
            "--y" => y = Some(parse_number(value, option)?),
            "--width" => width = Some(parse_number(value, option)?),
            "--height" => height = Some(parse_number(value, option)?),
            "--max-dimension" => max_dimension = Some(parse_number(value, option)?),
            "--output" => output = Some(PathBuf::from(value)),
            _ => {
                return Err(error::AgentError::InvalidArgument(format!(
                    "未知截图参数: {option}"
                )));
            }
        }
    }
    let region = match (x, y, width, height) {
        (None, None, None, None) => None,
        (Some(x), Some(y), Some(width), Some(height)) => Some((x, y, width, height)),
        _ => {
            return Err(error::AgentError::InvalidArgument(
                "截图区域参数必须完整".to_owned(),
            ));
        }
    };
    capture::run_capture_worker(
        &config::data_paths(),
        target
            .as_deref()
            .ok_or_else(|| error::AgentError::InvalidArgument("缺少截图目标".to_owned()))?,
        id,
        region,
        max_dimension,
        output.ok_or_else(|| error::AgentError::InvalidArgument("缺少截图输出".to_owned()))?,
    )
}

fn parse_number<T>(value: &str, option: &str) -> error::AgentResult<T>
where
    T: std::str::FromStr,
{
    value
        .parse()
        .map_err(|_| error::AgentError::InvalidArgument(format!("截图参数无效: {option}")))
}

fn install_firewall_rules() -> error::AgentResult<()> {
    let paths = config::data_paths();
    let config = config::load_or_create(&paths)?;
    let port = format!("localport={}", config.port);
    let executable = env::current_exe()?;
    let program = format!("program={}", executable.display());
    let netsh = system_executable("netsh.exe")?;
    for rule in [FIREWALL_RULE_NAME, DISCOVERY_FIREWALL_RULE_NAME] {
        let _ = background_process::std_command(&netsh)
            .args([
                "advfirewall",
                "firewall",
                "delete",
                "rule",
                &format!("name={rule}"),
            ])
            .output();
    }
    run_checked(
        &netsh,
        &[
            "advfirewall",
            "firewall",
            "add",
            "rule",
            &format!("name={FIREWALL_RULE_NAME}"),
            "dir=in",
            "action=allow",
            "protocol=TCP",
            &port,
            "profile=private",
            "remoteip=LocalSubnet",
        ],
    )?;
    run_checked(
        &netsh,
        &[
            "advfirewall",
            "firewall",
            "add",
            "rule",
            &format!("name={DISCOVERY_FIREWALL_RULE_NAME}"),
            "dir=in",
            "action=allow",
            "protocol=UDP",
            "localport=5353",
            &program,
            "profile=private",
            "remoteip=LocalSubnet",
        ],
    )?;
    Ok(())
}

fn run_checked(program: &Path, arguments: &[&str]) -> error::AgentResult<()> {
    let output = background_process::std_command(program)
        .args(arguments)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(error::AgentError::Internal(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

fn system_executable(name: &str) -> error::AgentResult<PathBuf> {
    if name.is_empty() || name.contains(['\\', '/']) {
        return Err(error::AgentError::InvalidArgument(
            "系统程序名称无效".to_owned(),
        ));
    }
    let system_root = env::var_os("SystemRoot")
        .ok_or_else(|| error::AgentError::DependencyUnavailable("SystemRoot 缺失".to_owned()))?;
    let path = PathBuf::from(system_root).join("System32").join(name);
    if !path.is_file() {
        return Err(error::AgentError::DependencyUnavailable(format!(
            "系统程序不存在: {name}"
        )));
    }
    Ok(path)
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn wide_os(value: &std::ffi::OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const MCP_ACCEPT: &str = "application/json, text/event-stream";

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path = env::temp_dir().join(format!("meno-windows-agent-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).expect("create test directory");
            Self(path)
        }

        fn data_paths(&self) -> config::DataPaths {
            config::DataPaths {
                root: self.0.clone(),
                config_dir: self.0.join("config"),
                tasks_dir: self.0.join("tasks"),
                logs_dir: self.0.join("logs"),
                temp_dir: self.0.join("tmp"),
                config_file: self.0.join("config").join("config.json"),
            }
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    async fn spawn_test_mcp() -> (
        reqwest::Client,
        String,
        CancellationToken,
        Arc<server::AppState>,
        tokio::task::JoinHandle<()>,
    ) {
        let directory = TestDirectory::new();
        let paths = directory.data_paths();
        config::ensure_data_directories(&paths).expect("create test data directories");
        let shutdown = CancellationToken::new();
        let state = Arc::new(
            server::AppState::new(
                config::ConfigStore::new(paths.clone(), config::AppConfig::default()),
                paths,
                shutdown.clone(),
                "test-admin-token".to_owned(),
            )
            .expect("create app state"),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind test MCP server");
        let address = listener.local_addr().expect("read test MCP address");
        let service = mcp_service(state.clone(), shutdown.child_token());
        let router = Router::new().nest_service("/mcp", service);
        let server_task = tokio::spawn({
            let shutdown = shutdown.clone();
            async move {
                let _directory = directory;
                axum::serve(listener, router)
                    .with_graceful_shutdown(async move { shutdown.cancelled_owned().await })
                    .await
                    .expect("run test MCP server");
            }
        });
        (
            reqwest::Client::new(),
            format!("http://{address}/mcp"),
            shutdown,
            state,
            server_task,
        )
    }

    async fn mcp_post(
        client: &reqwest::Client,
        url: &str,
        body: serde_json::Value,
        session_id: Option<&str>,
    ) -> reqwest::Response {
        let mut request = client
            .post(url)
            .header(reqwest::header::ACCEPT, MCP_ACCEPT)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .json(&body);
        if let Some(session_id) = session_id {
            request = request.header("Mcp-Session-Id", session_id);
        }
        request.send().await.expect("send MCP request")
    }

    async fn mcp_json(response: reqwest::Response) -> serde_json::Value {
        assert!(
            response.status().is_success(),
            "MCP request failed with {}",
            response.status()
        );
        let body = response.text().await.expect("read MCP response");
        let data = body
            .lines()
            .find_map(|line| line.strip_prefix("data:"))
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .expect("MCP SSE response contains JSON data");
        serde_json::from_str(data).expect("parse MCP response JSON")
    }

    #[tokio::test]
    async fn mcp_is_stateless_for_initialize_tools_and_health() {
        let (client, url, shutdown, state, server_task) = spawn_test_mcp().await;
        let initialize = mcp_post(
            &client,
            &url,
            serde_json::json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "stateless-test", "version": "1.0"}
                }
            }),
            None,
        )
        .await;
        assert!(initialize.status().is_success());
        assert!(initialize.headers().get("Mcp-Session-Id").is_none());
        assert_eq!(
            mcp_json(initialize).await["result"]["protocolVersion"],
            "2025-03-26"
        );

        let tools = mcp_json(
            mcp_post(
                &client,
                &url,
                serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(
            tools["result"]["tools"]
                .as_array()
                .expect("tools/list returns tools")
                .len(),
            17
        );

        for session_id in [None, Some("stale-session-from-before-restart")] {
            let health = mcp_json(
                mcp_post(
                    &client,
                    &url,
                    serde_json::json!({
                        "jsonrpc": "2.0",
                        "id": 3,
                        "method": "tools/call",
                        "params": {"name": "health", "arguments": {}}
                    }),
                    session_id,
                )
                .await,
            )
            .await;
            assert_eq!(
                health["result"]["isError"], false,
                "health failed: {health}"
            );
            assert_eq!(
                health["result"]["structuredContent"]["status"], "ok",
                "health failed: {health}"
            );
        }

        shutdown.cancel();
        state.tasks.shutdown().await;
        server_task.await.expect("join test MCP server");
    }

    #[test]
    fn status_labels_are_stable() {
        for (status, label) in [
            (STATUS_STARTING, "正在启动"),
            (STATUS_RUNNING, "运行中"),
            (STATUS_FAILED, "启动失败"),
            (STATUS_STOPPED, "已停止"),
        ] {
            SERVICE_STATUS.store(status, Ordering::Release);
            assert_eq!(status_label(), label);
        }
    }

    #[test]
    fn unrelated_process_arguments_are_not_claimed() {
        assert_ne!(CAPTURE_WORKER_COMMAND, FIREWALL_INSTALL_COMMAND);
        assert!(system_executable("..\\netsh.exe").is_err());
    }
}
