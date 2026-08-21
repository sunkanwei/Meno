use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::PostMessageW;

use crate::bounded_queue::{BoundedQueue, PushResult};
use crate::connection::NetworkEvent;

pub(crate) const WM_NETWORK_EVENT: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 1;
pub(crate) const WM_FILE_CLIPBOARD_REQUEST: u32 =
    windows::Win32::UI::WindowsAndMessaging::WM_APP + 3;

pub(crate) const EVENT_BATCH: usize = 8;
const NETWORK_MAX_ITEMS: usize = 64;
const NETWORK_MAX_BYTES: usize = 64 * 1024 * 1024;
const FILE_MAX_ITEMS: usize = 32;
const FILE_MAX_BYTES: usize = 1024 * 1024;

pub enum FileUiRequest {
    Publish {
        paths: Vec<PathBuf>,
        result: Sender<Result<(), String>>,
    },
    Referenced {
        result: Sender<Result<Vec<PathBuf>, String>>,
    },
}

static NETWORK_EVENTS: OnceLock<Mutex<BoundedQueue<NetworkEvent>>> = OnceLock::new();
static FILE_REQUESTS: OnceLock<Mutex<BoundedQueue<FileUiRequest>>> = OnceLock::new();

pub(crate) fn post_network(hwnd: HWND, event: NetworkEvent) -> bool {
    let bytes = match &event {
        NetworkEvent::Searching => 1,
        NetworkEvent::Connected { name, address } => name.len().saturating_add(address.len()),
        NetworkEvent::AudioStatus(status) => status.label().map_or(1, str::len),
        NetworkEvent::Clipboard(frame) => frame.payload.len(),
        NetworkEvent::Error(error) => error.len(),
    };
    let queue = NETWORK_EVENTS
        .get_or_init(|| Mutex::new(BoundedQueue::new(NETWORK_MAX_ITEMS, NETWORK_MAX_BYTES)));
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
            crate::logging::error(&format!(
                "network UI queue full: items={} bytes={} rejected={}",
                stats.items, stats.bytes, stats.rejected
            ));
            return false;
        }
    };
    drop(queue);
    !wake || wake_queue(hwnd, WM_NETWORK_EVENT, &NETWORK_EVENTS)
}

pub(crate) fn post_file(hwnd: HWND, request: FileUiRequest) -> bool {
    let bytes = match &request {
        FileUiRequest::Publish { paths, .. } => paths.iter().fold(0_usize, |total, path| {
            total.saturating_add(path.as_os_str().len())
        }),
        FileUiRequest::Referenced { .. } => 1,
    };
    let queue =
        FILE_REQUESTS.get_or_init(|| Mutex::new(BoundedQueue::new(FILE_MAX_ITEMS, FILE_MAX_BYTES)));
    let Ok(mut queue) = queue.lock() else {
        return false;
    };
    let wake = match queue.push(request, bytes) {
        PushResult::Queued { wake } | PushResult::Replaced { wake } => wake,
        PushResult::Full => {
            let stats = queue.stats();
            crate::logging::error(&format!(
                "file UI queue full: items={} bytes={} rejected={}",
                stats.items, stats.bytes, stats.rejected
            ));
            return false;
        }
    };
    drop(queue);
    !wake || wake_queue(hwnd, WM_FILE_CLIPBOARD_REQUEST, &FILE_REQUESTS)
}

pub(crate) fn take_network() -> (Vec<NetworkEvent>, bool) {
    take_batch(&NETWORK_EVENTS)
}

pub(crate) fn take_file() -> (Vec<FileUiRequest>, bool) {
    take_batch(&FILE_REQUESTS)
}

pub(crate) fn wake_network(hwnd: HWND) -> bool {
    wake_queue(hwnd, WM_NETWORK_EVENT, &NETWORK_EVENTS)
}

pub(crate) fn wake_file(hwnd: HWND) -> bool {
    wake_queue(hwnd, WM_FILE_CLIPBOARD_REQUEST, &FILE_REQUESTS)
}

pub(crate) fn clear() {
    clear_queue(&NETWORK_EVENTS);
    clear_queue(&FILE_REQUESTS);
}

fn take_batch<T>(queue: &OnceLock<Mutex<BoundedQueue<T>>>) -> (Vec<T>, bool) {
    let Some(queue) = queue.get() else {
        return (Vec::new(), false);
    };
    match queue.lock() {
        Ok(mut queue) => queue.take_batch(EVENT_BATCH),
        Err(_) => (Vec::new(), false),
    }
}

fn clear_queue<T>(queue: &OnceLock<Mutex<BoundedQueue<T>>>) {
    if let Some(queue) = queue.get()
        && let Ok(mut queue) = queue.lock()
    {
        queue.clear();
    }
}

pub(crate) fn wake_queue<T>(
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
