#![windows_subsystem = "windows"]

mod audio_output;
mod audio_session;
mod bounded_queue;
mod clipboard_flow;
mod connection;
mod cursor_hider;
mod cursor_theme;
// Windows is the sender in this capability. The decoder and future reason
// values remain here for fixed-wire tests and Mac parity.
#[allow(dead_code)]
mod diagnostics;
mod discovery;
mod display_contract;
mod file_cache;
mod file_clipboard;
mod file_manifest;
mod file_protocol;
mod file_transfer;
mod hid_writer;
mod image_codec;
mod image_tasks;
mod install;
mod logging;
mod menu;
mod mouse_control;
mod mouse_input;
mod mouse_session;
mod peer_name;
mod protocol;
mod qos_flow;
mod remote_shutdown;
mod tray;
mod virtual_hid;

use std::sync::mpsc::{Sender, SyncSender, TrySendError, sync_channel};
use std::sync::{Mutex, OnceLock};
use std::thread;

use arboard::Error as ClipboardError;
use audio_session::AudioStatus;
use bounded_queue::{BoundedQueue, PushResult};
use connection::{NetworkCommand, NetworkEvent};
use protocol::{Frame, MessageKind};
use windows::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, HINSTANCE, HWND, LPARAM, LRESULT, WPARAM,
};
use windows::Win32::System::DataExchange::{
    AddClipboardFormatListener, GetClipboardSequenceNumber, IsClipboardFormatAvailable,
    RemoveClipboardFormatListener,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::WindowsAndMessaging::{
    CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, CreateWindowExW, DefWindowProcW, DestroyWindow,
    DispatchMessageW, GetMessageW, MSG, PBT_APMRESUMEAUTOMATIC, PBT_APMSUSPEND, PostMessageW,
    PostQuitMessage, RegisterClassW, RegisterWindowMessageW, TranslateMessage, WM_CLIPBOARDUPDATE,
    WM_COMMAND, WM_DESTROY, WM_DISPLAYCHANGE, WM_LBUTTONUP, WM_POWERBROADCAST, WM_RBUTTONUP,
    WNDCLASSW, WS_OVERLAPPED,
};
use windows::core::{Error, Result as WinResult, w};

pub const WM_NETWORK_EVENT: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 1;
pub const WM_FILE_CLIPBOARD_REQUEST: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 3;
pub(crate) const UI_EVENT_BATCH: usize = 8;
const NETWORK_UI_MAX_ITEMS: usize = 64;
const NETWORK_UI_MAX_BYTES: usize = 64 * 1024 * 1024;
const FILE_UI_MAX_ITEMS: usize = 32;
const FILE_UI_MAX_BYTES: usize = 1024 * 1024;
const FILE_WORKER_EVENT_CAPACITY: usize = 16;

// The file worker cannot touch the system clipboard directly: publishing the
// received cache paths and reading the active CF_HDROP both happen on the UI
// thread through these requests, with a oneshot channel for the answer.
pub enum FileUiRequest {
    Publish {
        paths: Vec<std::path::PathBuf>,
        result: Sender<Result<(), String>>,
    },
    Referenced {
        result: Sender<Result<Vec<std::path::PathBuf>, String>>,
    },
}

static APP: OnceLock<Mutex<AppState>> = OnceLock::new();
static TASKBAR_CREATED: OnceLock<u32> = OnceLock::new();
static NETWORK_UI_EVENTS: OnceLock<Mutex<BoundedQueue<NetworkEvent>>> = OnceLock::new();
static FILE_UI_REQUESTS: OnceLock<Mutex<BoundedQueue<FileUiRequest>>> = OnceLock::new();

pub(crate) struct AppState {
    pub(crate) network: SyncSender<NetworkCommand>,
    file_events: SyncSender<file_transfer::WorkerEvent>,
    pub(crate) image_tasks: image_tasks::ImageTaskSender,
    agent: Option<windows_agent::EmbeddedAgent>,
    status: String,
    audio_status: AudioStatus,
    connected: bool,
    pub(crate) paused: bool,
    pub(crate) suspended: bool,
    startup: bool,
    pub(crate) ignored_sequence: Option<u32>,
    pub(crate) image_generation: u64,
}

fn main() -> WinResult<()> {
    if virtual_hid::run_broker_command() {
        return Ok(());
    }
    if cursor_hider::run_guard_command() {
        return Ok(());
    }
    if windows_agent::handle_process_command() {
        return Ok(());
    }
    if let Ok(path) = install::log_path() {
        logging::initialize(&path);
    }
    if install::handle_driver_install_command() {
        logging::info("session end: driver maintenance completed");
        return Ok(());
    }
    let portable = std::env::args().any(|argument| argument == "--portable");
    let first_install = std::env::args().any(|argument| argument == "--first-install");
    let install_error = match install::install_if_needed(portable) {
        Ok(true) => {
            logging::info("session end: relaunched from the fixed location");
            return Ok(());
        }
        Ok(false) => None,
        Err(error) => Some(error),
    };
    if let Some(error) = install_error {
        logging::error(&format!(
            "Self-install failed, continuing in place: {error}"
        ));
    }
    logging::info(&format!(
        "startup: driver_abi={} driver_embedded={} audio_driver_embedded={}",
        virtual_hid::DRIVER_ABI,
        install::driver_package_embedded(),
        install::audio_driver_package_embedded()
    ));

    let mutex = match unsafe { CreateMutexW(None, false, w!("Local\\MenoClipboard")) } {
        Ok(mutex) => mutex,
        Err(error) => {
            logging::error(&format!("Instance mutex creation failed: {error}"));
            return Err(error);
        }
    };
    if unsafe { windows::Win32::Foundation::GetLastError() } == ERROR_ALREADY_EXISTS {
        logging::info("session end: another instance is already running");
        return Ok(());
    }
    diagnostics::initialize();
    cursor_hider::force_show();
    cursor_theme::ensure_applied();
    let agent = match windows_agent::EmbeddedAgent::start(|level, message| match level {
        "error" => logging::error(message),
        "debug" => logging::debug(message),
        _ => logging::info(message),
    }) {
        Ok(agent) => Some(agent),
        Err(error) => {
            logging::error(&format!("Windows Agent could not start: {error}"));
            None
        }
    };

    unsafe {
        let instance = GetModuleHandleW(None)?;
        let instance = HINSTANCE(instance.0);
        let class_name = w!("MenoClipboardMessageWindow");
        let window_class = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: class_name,
            ..Default::default()
        };
        if RegisterClassW(&window_class) == 0 {
            let error = Error::from_thread();
            logging::error(&format!("Window class registration failed: {error}"));
            return Err(error);
        }
        let hwnd = match CreateWindowExW(
            Default::default(),
            class_name,
            w!("MenoClipboard"),
            WS_OVERLAPPED,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            0,
            0,
            None,
            None,
            Some(instance),
            None,
        ) {
            Ok(hwnd) => hwnd,
            Err(error) => {
                logging::error(&format!("Window creation failed: {error}"));
                return Err(error);
            }
        };

        let (file_events, file_inbox) =
            sync_channel::<file_transfer::WorkerEvent>(FILE_WORKER_EVENT_CAPACITY);
        let network = connection::spawn(hwnd, file_events.clone());
        file_transfer::spawn(hwnd, network.clone(), file_inbox);
        let image_tasks = image_tasks::spawn_image_worker(hwnd);
        let _ = APP.set(Mutex::new(AppState {
            network,
            file_events,
            image_tasks,
            agent,
            status: "正在查找 Mac".to_string(),
            audio_status: AudioStatus::Disabled,
            connected: false,
            paused: false,
            suspended: false,
            startup: install::startup_enabled(),
            ignored_sequence: None,
            image_generation: 0,
        }));
        let _ = TASKBAR_CREATED.set(RegisterWindowMessageW(w!("TaskbarCreated")));
        if let Err(error) = AddClipboardFormatListener(hwnd) {
            logging::error(&format!("Clipboard listener registration failed: {error}"));
            return Err(error);
        }
        tray::add(hwnd, "Meno Windows：正在查找 Mac");
        if first_install {
            match install::request_audio_driver_install_if_missing() {
                Ok(true) => {}
                Ok(false) => {}
                Err(error) => logging::error(&format!(
                    "First-run audio driver installation prompt failed: {error}"
                )),
            }
        }

        let mut message = MSG::default();
        loop {
            let result = GetMessageW(&mut message, None, 0, 0);
            if result.0 == -1 {
                let error = Error::from_thread();
                logging::error(&format!("Message loop failed: {error}"));
                let _ = CloseHandle(mutex);
                return Err(error);
            }
            if result.0 == 0 {
                break;
            }
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    unsafe {
        let _ = CloseHandle(mutex);
    }
    Ok(())
}

pub(crate) fn post_network_event(hwnd: HWND, event: NetworkEvent) -> bool {
    let bytes = match &event {
        NetworkEvent::Searching => 1,
        NetworkEvent::Connected { name, address } => name.len().saturating_add(address.len()),
        NetworkEvent::AudioStatus(status) => status.label().map_or(1, str::len),
        NetworkEvent::Clipboard(frame) => frame.payload.len(),
        NetworkEvent::Error(error) => error.len(),
    };
    let queue = NETWORK_UI_EVENTS.get_or_init(|| {
        Mutex::new(BoundedQueue::new(
            NETWORK_UI_MAX_ITEMS,
            NETWORK_UI_MAX_BYTES,
        ))
    });
    let Ok(mut queue) = queue.lock() else {
        return false;
    };
    let result = match &event {
        NetworkEvent::Clipboard(_) => queue.push_latest(event, bytes, |queued| {
            matches!(queued, NetworkEvent::Clipboard(_))
        }),
        NetworkEvent::AudioStatus(_) => queue.push_latest(event, bytes, |queued| {
            matches!(queued, NetworkEvent::AudioStatus(_))
        }),
        _ => queue.push(event, bytes),
    };
    let wake = match result {
        PushResult::Queued { wake } | PushResult::Replaced { wake } => wake,
        PushResult::Full => {
            let stats = queue.stats();
            logging::error(&format!(
                "network UI queue full: items={} bytes={} rejected={}",
                stats.items, stats.bytes, stats.rejected
            ));
            return false;
        }
    };
    drop(queue);
    !wake || post_wakeup(hwnd, WM_NETWORK_EVENT, &NETWORK_UI_EVENTS)
}

pub(crate) fn post_file_ui_request(hwnd: HWND, request: FileUiRequest) -> bool {
    let bytes = match &request {
        FileUiRequest::Publish { paths, .. } => paths.iter().fold(0_usize, |total, path| {
            total.saturating_add(path.as_os_str().len())
        }),
        FileUiRequest::Referenced { .. } => 1,
    };
    let queue = FILE_UI_REQUESTS
        .get_or_init(|| Mutex::new(BoundedQueue::new(FILE_UI_MAX_ITEMS, FILE_UI_MAX_BYTES)));
    let Ok(mut queue) = queue.lock() else {
        return false;
    };
    let result = queue.push(request, bytes);
    let wake = match result {
        PushResult::Queued { wake } | PushResult::Replaced { wake } => wake,
        PushResult::Full => {
            let stats = queue.stats();
            logging::error(&format!(
                "file UI queue full: items={} bytes={} rejected={}",
                stats.items, stats.bytes, stats.rejected
            ));
            return false;
        }
    };
    drop(queue);
    !wake || post_wakeup(hwnd, WM_FILE_CLIPBOARD_REQUEST, &FILE_UI_REQUESTS)
}

pub(crate) fn post_wakeup<T>(
    hwnd: HWND,
    message: u32,
    queue: &OnceLock<Mutex<BoundedQueue<T>>>,
) -> bool {
    if unsafe { PostMessageW(Some(hwnd), message, WPARAM(0), LPARAM(0)) }.is_ok() {
        return true;
    }
    if let Some(queue) = queue.get()
        && let Ok(mut queue) = queue.lock()
    {
        queue.wake_failed();
    }
    false
}

fn drain_network_events(hwnd: HWND) {
    let Some(queue) = NETWORK_UI_EVENTS.get() else {
        return;
    };
    let (events, more) = match queue.lock() {
        Ok(mut queue) => queue.take_batch(UI_EVENT_BATCH),
        Err(_) => return,
    };
    for event in events {
        handle_network_event(hwnd, event);
    }
    if more {
        let _ = post_wakeup(hwnd, WM_NETWORK_EVENT, &NETWORK_UI_EVENTS);
    }
}

fn handle_network_event(hwnd: HWND, event: NetworkEvent) {
    match event {
        NetworkEvent::Searching => {
            let _ = with_state(|state| {
                state.connected = false;
                state.audio_status = AudioStatus::Disabled;
            });
            update_status(hwnd, "正在查找 Mac".to_string());
        }
        NetworkEvent::Connected { name, address } => {
            let status = format!("已连接 {name}");
            let accepted = with_state(|state| {
                if state.paused || state.suspended {
                    state.connected = false;
                    return false;
                }
                state.connected = true;
                state.status = status;
                update_connected_tray(hwnd, state);
                true
            })
            .unwrap_or(false);
            if accepted {
                logging::info(&format!("Connected to {name} at {address}"));
            }
        }
        NetworkEvent::AudioStatus(status) => {
            let _ = with_state(|state| {
                if state.paused || state.suspended {
                    state.audio_status = AudioStatus::Disabled;
                    return;
                }
                state.audio_status = status;
                if state.connected {
                    update_connected_tray(hwnd, state);
                }
            });
        }
        NetworkEvent::Error(error) => {
            logging::error(&format!("Network error: {error}"));
            let _ = with_state(|state| {
                state.connected = false;
                state.audio_status = AudioStatus::Disabled;
            });
            update_status(hwnd, "局域网连接错误".to_string());
        }
        NetworkEvent::Clipboard(frame) => {
            if with_state(|state| state.paused || state.suspended).unwrap_or(true) {
                logging::debug("clipboard <- mac dropped: application is paused");
                return;
            }
            // Newer remote content replaces any file transfer still arriving.
            notify_file_worker(file_transfer::WorkerEvent::RemoteContent);
            let Some(generation) = image_tasks::next_image_generation() else {
                return;
            };
            write_remote_clipboard(frame, generation);
        }
    }
}

fn write_remote_clipboard(frame: Frame, generation: u64) {
    let kind = frame.kind;
    let bytes = frame.payload.len();
    match frame.kind {
        MessageKind::Text => match String::from_utf8(frame.payload) {
            Ok(text) => {
                clipboard_flow::apply_remote_clipboard(kind, bytes, |clipboard| {
                    clipboard.set_text(text.clone())
                });
            }
            Err(_) => {
                logging::error("Remote clipboard text was not valid UTF-8");
            }
        },
        MessageKind::Png => image_tasks::submit_image_task(image_tasks::ImageTask::Decode {
            generation,
            payload: frame.payload,
        }),
        _ => (),
    }
}

fn drain_file_ui_requests(hwnd: HWND) {
    let Some(queue) = FILE_UI_REQUESTS.get() else {
        return;
    };
    let (requests, more) = match queue.lock() {
        Ok(mut queue) => queue.take_batch(UI_EVENT_BATCH),
        Err(_) => return,
    };
    for request in requests {
        handle_file_ui_request(request);
    }
    if more {
        let _ = post_wakeup(hwnd, WM_FILE_CLIPBOARD_REQUEST, &FILE_UI_REQUESTS);
    }
}

fn clear_ui_queues() {
    if let Some(queue) = NETWORK_UI_EVENTS.get()
        && let Ok(mut queue) = queue.lock()
    {
        queue.clear();
    }
    if let Some(queue) = FILE_UI_REQUESTS.get()
        && let Ok(mut queue) = queue.lock()
    {
        queue.clear();
    }
    image_tasks::clear_events();
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if TASKBAR_CREATED.get().is_some_and(|value| *value == message) {
        if let Some(status) = with_state(|state| display_status(state)) {
            tray::add(hwnd, &format!("Meno Windows：{status}"));
        }
        return LRESULT(0);
    }

    match message {
        WM_CLIPBOARDUPDATE => {
            handle_local_clipboard();
            LRESULT(0)
        }
        WM_NETWORK_EVENT => {
            let _ = (wparam, lparam);
            drain_network_events(hwnd);
            LRESULT(0)
        }
        WM_FILE_CLIPBOARD_REQUEST => {
            let _ = (wparam, lparam);
            drain_file_ui_requests(hwnd);
            LRESULT(0)
        }
        image_tasks::WM_IMAGE_WORKER_EVENT => {
            let _ = (wparam, lparam);
            image_tasks::drain_events(hwnd);
            LRESULT(0)
        }
        tray::CALLBACK_MESSAGE
            if lparam.0 as u32 == WM_RBUTTONUP || lparam.0 as u32 == WM_LBUTTONUP =>
        {
            if let Some((status, connected, paused, suspended, startup)) = with_state(|state| {
                (
                    display_status(state),
                    state.connected,
                    state.paused,
                    state.suspended,
                    state.startup,
                )
            }) {
                menu::show_menu(
                    hwnd,
                    &menu::MenuModel::new(
                        status,
                        connected,
                        paused,
                        suspended,
                        startup,
                        cursor_theme::enabled(),
                        logging::verbose(),
                    )
                    .with_agent_status(windows_agent::status_label().to_owned()),
                );
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            handle_command(hwnd, wparam.0 & 0xFFFF);
            LRESULT(0)
        }
        WM_POWERBROADCAST => {
            handle_power_event(hwnd, wparam.0 as u32);
            LRESULT(1)
        }
        WM_DISPLAYCHANGE => {
            handle_display_change(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            let _ = unsafe { RemoveClipboardFormatListener(hwnd) };
            tray::remove(hwnd);
            cursor_hider::force_show();
            let _ = with_state(|state| {
                let _ = state.network.send(NetworkCommand::Stop);
                if let Some(agent) = state.agent.as_ref() {
                    agent.shutdown();
                }
            });
            clear_ui_queues();
            logging::info("session end");
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn handle_command(hwnd: HWND, command: usize) {
    match command {
        tray::COMMAND_PAUSE => {
            let _ = with_state(|state| {
                state.paused = !state.paused;
                state.connected = false;
                state.audio_status = AudioStatus::Disabled;
                state.status = if state.suspended {
                    "系统休眠".to_string()
                } else if state.paused {
                    "已暂停".to_string()
                } else {
                    "正在查找 Mac".to_string()
                };
                let _ = state
                    .network
                    .send(NetworkCommand::Pause(state.paused || state.suspended));
                tray::update(hwnd, &format!("Meno Windows：{}", state.status));
            });
        }
        tray::COMMAND_REDISCOVER => {
            let _ = with_state(|state| {
                if !state.paused && !state.suspended {
                    state.connected = false;
                    state.audio_status = AudioStatus::Disabled;
                    state.status = "正在查找 Mac".to_string();
                    let _ = state.network.send(NetworkCommand::Rediscover);
                    tray::update(hwnd, "Meno Windows：正在查找 Mac");
                }
            });
        }
        tray::COMMAND_STARTUP => {
            let _ = with_state(|state| {
                let desired = !state.startup;
                if install::set_startup_enabled(desired).is_ok() {
                    state.startup = desired;
                }
            });
        }
        tray::COMMAND_REPAIR_DRIVER => match install::request_driver_install() {
            Ok(true) => {}
            Ok(false) => {}
            Err(error) => logging::error(&format!("Driver repair elevation failed: {error}")),
        },
        tray::COMMAND_INSTALL_AUDIO_DRIVER => match install::request_audio_driver_install() {
            Ok(true) => {}
            Ok(false) => {}
            Err(error) => logging::error(&format!(
                "Audio driver installation elevation failed: {error}"
            )),
        },
        tray::COMMAND_VB_CABLE_WEBSITE => {
            if let Err(error) = install::open_vb_cable_website() {
                logging::error(&format!("Could not open the VB-CABLE website: {error}"));
            }
        }
        tray::COMMAND_VIEW_LOG => {
            if let Err(error) = install::open_log() {
                logging::error(&format!("Could not open log: {error}"));
            }
        }
        tray::COMMAND_CLEAR_LOG => {
            logging::clear();
        }
        tray::COMMAND_VERBOSE_LOG => {
            logging::set_verbose(!logging::verbose());
        }
        tray::COMMAND_CURSOR_THEME => {
            let desired = !cursor_theme::enabled();
            if let Err(error) = cursor_theme::set_enabled(desired) {
                logging::error(&format!("Cursor theme toggle failed: {error}"));
            }
        }
        tray::COMMAND_AGENT_SETTINGS => {
            if let Err(error) = windows_agent::open_settings() {
                logging::error(&format!("Windows Agent settings could not open: {error}"));
            }
        }
        tray::COMMAND_EXIT => unsafe {
            let _ = DestroyWindow(hwnd);
        },
        _ => {}
    }
}

fn handle_display_change(hwnd: HWND) {
    let _ = with_state(|state| {
        if !state.paused && !state.suspended {
            logging::info("Display settings changed, rediscovering");
            state.connected = false;
            state.audio_status = AudioStatus::Disabled;
            state.status = "正在查找 Mac".to_string();
            let _ = state.network.send(NetworkCommand::Rediscover);
            tray::update(hwnd, "Meno Windows：正在查找 Mac");
        }
    });
}

fn handle_power_event(hwnd: HWND, event: u32) {
    match event {
        PBT_APMSUSPEND => {
            let _ = with_state(|state| {
                state.suspended = true;
                state.connected = false;
                state.audio_status = AudioStatus::Disabled;
                let _ = state.network.send(NetworkCommand::Pause(true));
                state.status = "系统休眠".to_string();
                tray::update(hwnd, "Meno Windows：系统休眠");
            });
        }
        PBT_APMRESUMEAUTOMATIC => {
            let _ = with_state(|state| {
                if state.suspended {
                    state.suspended = false;
                    state.connected = false;
                    state.audio_status = AudioStatus::Disabled;
                    if !state.paused {
                        state.status = "正在查找 Mac".to_string();
                        let _ = state.network.send(NetworkCommand::Pause(false));
                    } else {
                        state.status = "已暂停".to_string();
                    }
                    tray::update(hwnd, &format!("Meno Windows：{}", state.status));
                }
            });
        }
        _ => {}
    }
}

fn handle_local_clipboard() {
    let sequence = unsafe { GetClipboardSequenceNumber() };
    if with_state(|state| {
        if state.ignored_sequence == Some(sequence) {
            state.ignored_sequence = None;
            true
        } else {
            state.ignored_sequence = None;
            state.paused || state.suspended
        }
    })
    .unwrap_or(true)
    {
        return;
    }
    let Some(generation) = image_tasks::next_image_generation() else {
        return;
    };
    if unsafe { IsClipboardFormatAvailable(file_clipboard::CF_HDROP) }.is_ok() {
        handle_local_files();
        return;
    }

    for attempt in 0..clipboard_flow::CLIPBOARD_RETRY_COUNT {
        match clipboard_flow::read_local_clipboard() {
            Ok(Some(clipboard_flow::LocalClipboard::Frame(frame))) => {
                clipboard_flow::send_clipboard(frame);
                notify_file_worker(file_transfer::WorkerEvent::LocalOther);
                return;
            }
            Ok(Some(clipboard_flow::LocalClipboard::Image(image))) => {
                image_tasks::submit_image_task(image_tasks::ImageTask::Encode {
                    generation,
                    image,
                });
                notify_file_worker(file_transfer::WorkerEvent::LocalOther);
                return;
            }
            Ok(None) => {
                notify_file_worker(file_transfer::WorkerEvent::LocalOther);
                return;
            }
            Err(ClipboardError::ContentNotAvailable) => return,
            Err(ClipboardError::ClipboardOccupied)
                if attempt + 1 < clipboard_flow::CLIPBOARD_RETRY_COUNT =>
            {
                thread::sleep(clipboard_flow::CLIPBOARD_RETRY_DELAY);
            }
            Err(ClipboardError::ClipboardOccupied) => {
                logging::error("Local clipboard read failed: occupied through all retries");
                return;
            }
            Err(error) => {
                logging::error(&format!("Local clipboard read failed: {error}"));
                return;
            }
        }
    }
}

// File paths are only snapshotted here; enumeration, hashing-free metadata
// checks and all network flow live in the file worker thread.
fn handle_local_files() {
    for attempt in 0..clipboard_flow::CLIPBOARD_RETRY_COUNT {
        match file_clipboard::read_hdrop_paths() {
            Ok(Some(paths)) if !paths.is_empty() => {
                crate::logging::debug(&format!("clipboard -> mac: files top={}", paths.len()));
                notify_file_worker(file_transfer::WorkerEvent::LocalFiles(paths));
                return;
            }
            Ok(_) => return,
            Err(file_clipboard::ClipboardFailure::Occupied)
                if attempt + 1 < clipboard_flow::CLIPBOARD_RETRY_COUNT =>
            {
                thread::sleep(clipboard_flow::CLIPBOARD_RETRY_DELAY);
            }
            Err(file_clipboard::ClipboardFailure::Occupied) => {
                crate::logging::error(
                    "Local file clipboard read failed: occupied through all retries",
                );
                return;
            }
            Err(file_clipboard::ClipboardFailure::Failed(message)) => {
                crate::logging::error(&format!("Local file clipboard read failed: {message}"));
                return;
            }
        }
    }
}

fn notify_file_worker(event: file_transfer::WorkerEvent) {
    match with_state(|state| state.file_events.try_send(event)) {
        Some(Ok(())) => {}
        Some(Err(TrySendError::Full(_))) => {
            logging::error("file worker overload: event was rejected")
        }
        Some(Err(TrySendError::Disconnected(_))) | None => {
            logging::error("file worker is unavailable")
        }
    }
}

fn handle_file_ui_request(request: FileUiRequest) {
    match request {
        FileUiRequest::Publish { paths, result } => {
            let _ = image_tasks::next_image_generation();
            let mut outcome = Err("clipboard publish did not run".to_string());
            for attempt in 0..clipboard_flow::CLIPBOARD_RETRY_COUNT {
                match file_clipboard::write_hdrop(&paths) {
                    Ok(()) => {
                        let sequence = unsafe { GetClipboardSequenceNumber() };
                        let _ = with_state(|state| state.ignored_sequence = Some(sequence));
                        crate::logging::debug(&format!(
                            "clipboard <- mac: files top={}",
                            paths.len()
                        ));
                        outcome = Ok(());
                        break;
                    }
                    Err(file_clipboard::ClipboardFailure::Occupied)
                        if attempt + 1 < clipboard_flow::CLIPBOARD_RETRY_COUNT =>
                    {
                        thread::sleep(clipboard_flow::CLIPBOARD_RETRY_DELAY);
                    }
                    Err(file_clipboard::ClipboardFailure::Occupied) => {
                        outcome = Err("clipboard occupied through all retries".to_string());
                        break;
                    }
                    Err(file_clipboard::ClipboardFailure::Failed(message)) => {
                        outcome = Err(message);
                        break;
                    }
                }
            }
            let _ = result.send(outcome);
        }
        FileUiRequest::Referenced { result } => {
            let mut outcome = Err("clipboard reference read did not run".to_string());
            for attempt in 0..clipboard_flow::CLIPBOARD_RETRY_COUNT {
                match file_clipboard::read_hdrop_paths() {
                    Ok(paths) => {
                        outcome = Ok(paths.unwrap_or_default());
                        break;
                    }
                    Err(file_clipboard::ClipboardFailure::Occupied)
                        if attempt + 1 < clipboard_flow::CLIPBOARD_RETRY_COUNT =>
                    {
                        thread::sleep(clipboard_flow::CLIPBOARD_RETRY_DELAY);
                    }
                    Err(file_clipboard::ClipboardFailure::Occupied) => {
                        outcome = Err("clipboard occupied through all retries".to_string());
                        break;
                    }
                    Err(file_clipboard::ClipboardFailure::Failed(message)) => {
                        outcome = Err(message);
                        break;
                    }
                }
            }
            let _ = result.send(outcome);
        }
    }
}

fn update_status(hwnd: HWND, status: String) {
    let _ = with_state(|state| {
        if !state.paused && !state.suspended {
            state.status = status;
            tray::update(hwnd, &format!("Meno Windows：{}", state.status));
        }
    });
}

fn update_connected_tray(hwnd: HWND, state: &AppState) {
    tray::update(hwnd, &format!("Meno Windows：{}", display_status(state)));
}

fn display_status(state: &AppState) -> String {
    if state.connected {
        menu::connected_status_text(&state.status, state.audio_status.label())
    } else {
        state.status.clone()
    }
}

pub(crate) fn with_state<T>(action: impl FnOnce(&mut AppState) -> T) -> Option<T> {
    APP.get()?.lock().ok().map(|mut state| action(&mut state))
}
