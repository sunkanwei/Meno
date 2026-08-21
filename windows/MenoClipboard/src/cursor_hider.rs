use std::process::Command;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use windows::Win32::Foundation::{CloseHandle, POINT, WAIT_OBJECT_0};
use windows::Win32::System::Threading::{
    CreateEventW, OpenEventW, OpenProcess, PROCESS_SYNCHRONIZE, SYNCHRONIZATION_SYNCHRONIZE,
    SetEvent, WaitForMultipleObjects,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CopyIcon, CreateCursor, DestroyCursor, GetCursorPos, HCURSOR, HICON, OCR_APPSTARTING,
    OCR_CROSS, OCR_HAND, OCR_HELP, OCR_IBEAM, OCR_NO, OCR_NORMAL, OCR_SIZEALL, OCR_SIZENESW,
    OCR_SIZENS, OCR_SIZENWSE, OCR_SIZEWE, OCR_UP, OCR_WAIT, SPI_SETCURSORS, SYSTEM_CURSOR_ID,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetSystemCursor, SystemParametersInfoW,
};
use windows::core::PCWSTR;

const CURSOR_IDS: [SYSTEM_CURSOR_ID; 14] = [
    OCR_NORMAL,
    OCR_IBEAM,
    OCR_WAIT,
    OCR_CROSS,
    OCR_UP,
    OCR_SIZENWSE,
    OCR_SIZENESW,
    OCR_SIZEWE,
    OCR_SIZENS,
    OCR_SIZEALL,
    OCR_NO,
    OCR_HAND,
    OCR_APPSTARTING,
    OCR_HELP,
];

const POLL_INTERVAL: Duration = Duration::from_millis(50);

static HIDDEN: AtomicBool = AtomicBool::new(false);
static GENERATION: AtomicU64 = AtomicU64::new(0);
static TEMPLATE: AtomicUsize = AtomicUsize::new(0);
static GUARD_EVENT: AtomicUsize = AtomicUsize::new(0);

// The actual cursor swap reloads the scheme from disk and the registry and
// costs tens of milliseconds, so callers only record the desired state; a
// dedicated worker applies it off the input path, coalescing repeats.
static DESIRED: AtomicBool = AtomicBool::new(false);
static APPLY_LOCK: Mutex<()> = Mutex::new(());

struct CursorWorker {
    counter: Mutex<u64>,
    condvar: Condvar,
}

static WORKER: OnceLock<&'static CursorWorker> = OnceLock::new();

// While the Mac owns the pointer the Windows cursor has nothing to show, so
// every system cursor is swapped for a transparent one. Any movement of a
// real local pointer (or the next Mac takeover) restores the originals.
pub fn hide() {
    request(true);
}

pub fn show() {
    request(false);
}

pub fn is_hidden() -> bool {
    HIDDEN.load(Ordering::SeqCst)
}

fn request(hidden: bool) {
    DESIRED.store(hidden, Ordering::SeqCst);
    let worker = WORKER.get_or_init(|| {
        let worker: &'static CursorWorker = Box::leak(Box::new(CursorWorker {
            counter: Mutex::new(0),
            condvar: Condvar::new(),
        }));
        thread::spawn(move || worker_loop(worker));
        worker
    });
    {
        let mut counter = worker
            .counter
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *counter = counter.wrapping_add(1);
    }
    worker.condvar.notify_one();
}

fn worker_loop(worker: &CursorWorker) {
    let mut seen = 0_u64;
    loop {
        let mut guard = worker
            .counter
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        while *guard == seen {
            // The timeout periodically re-affirms the desired state; every
            // apply is idempotent, so a spurious pass costs nothing.
            let (new_guard, timeout) = worker
                .condvar
                .wait_timeout(guard, Duration::from_millis(250))
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            guard = new_guard;
            if timeout.timed_out() {
                break;
            }
        }
        seen = *guard;
        drop(guard);
        apply(DESIRED.load(Ordering::SeqCst));
    }
}

fn apply(hidden: bool) {
    // force_show shares this serializer so a late worker pass can never
    // resurrect transparent cursors after startup or shutdown repairs them.
    let _lock = APPLY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if hidden {
        apply_hide();
    } else {
        apply_show();
    }
}

fn apply_hide() {
    if HIDDEN.swap(true, Ordering::SeqCst) {
        return;
    }
    let Some(template) = blank_template() else {
        HIDDEN.store(false, Ordering::SeqCst);
        crate::logging::error("Cursor hide failed: could not create a blank cursor");
        return;
    };
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    if !start_guard(generation) {
        HIDDEN.store(false, Ordering::SeqCst);
        GENERATION.fetch_add(1, Ordering::SeqCst);
        crate::logging::error("Cursor hide failed: recovery guard did not start");
        return;
    }
    for id in CURSOR_IDS {
        if let Ok(copy) = unsafe { CopyIcon(HICON(template.0)) } {
            // SetSystemCursor takes ownership and destroys the copy itself.
            let _ = unsafe { SetSystemCursor(HCURSOR(copy.0), id) };
        }
    }
    crate::logging::debug("Cursor hidden (control on Mac)");
    let mut parked = POINT::default();
    let _ = unsafe { GetCursorPos(&mut parked) };
    thread::spawn(move || monitor_loop(generation, parked));
}

fn apply_show() {
    if !HIDDEN.swap(false, Ordering::SeqCst) {
        return;
    }
    GENERATION.fetch_add(1, Ordering::SeqCst);
    reload_system_cursors();
    stop_guard();
    crate::logging::debug("Cursor restored");
}

// Startup and shutdown must not trust in-process state: a crashed instance
// may have left transparent cursors behind for the rest of the logon session.
pub fn force_show() {
    let _lock = APPLY_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    DESIRED.store(false, Ordering::SeqCst);
    HIDDEN.store(false, Ordering::SeqCst);
    GENERATION.fetch_add(1, Ordering::SeqCst);
    reload_system_cursors();
    stop_guard();
}

fn reload_system_cursors() {
    if unsafe {
        SystemParametersInfoW(
            SPI_SETCURSORS,
            0,
            None,
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    }
    .is_err()
    {
        crate::logging::error("Cursor reload failed");
    }
}

pub fn run_guard_command() -> bool {
    let mut arguments = std::env::args();
    let _ = arguments.next();
    if arguments.next().as_deref() != Some("--cursor-guard") {
        return false;
    }
    let Some(parent) = arguments.next().and_then(|value| value.parse::<u32>().ok()) else {
        return true;
    };
    let Some(event_name) = arguments.next() else {
        return true;
    };
    if arguments.next().is_some()
        || parent == 0
        || !event_name.starts_with("Local\\MenoCursorGuard-")
    {
        return true;
    }
    let event_name = wide(&event_name);
    let Ok(parent_handle) = (unsafe { OpenProcess(PROCESS_SYNCHRONIZE, false, parent) }) else {
        reload_system_cursors();
        return true;
    };
    let Ok(event_handle) = (unsafe {
        OpenEventW(
            SYNCHRONIZATION_SYNCHRONIZE,
            false,
            PCWSTR(event_name.as_ptr()),
        )
    }) else {
        let _ = unsafe { CloseHandle(parent_handle) };
        reload_system_cursors();
        return true;
    };
    let result = unsafe { WaitForMultipleObjects(&[parent_handle, event_handle], false, u32::MAX) };
    if result == WAIT_OBJECT_0 {
        reload_system_cursors();
    }
    let _ = unsafe { CloseHandle(event_handle) };
    let _ = unsafe { CloseHandle(parent_handle) };
    true
}

fn start_guard(generation: u64) -> bool {
    stop_guard();
    let event_name = format!(
        "Local\\MenoCursorGuard-{}-{generation:016x}",
        std::process::id()
    );
    let event_name_wide = wide(&event_name);
    let Ok(event) = (unsafe { CreateEventW(None, true, false, PCWSTR(event_name_wide.as_ptr())) })
    else {
        return false;
    };
    let executable = match std::env::current_exe() {
        Ok(executable) => executable,
        Err(_) => {
            let _ = unsafe { CloseHandle(event) };
            return false;
        }
    };
    let child = Command::new(executable)
        .arg("--cursor-guard")
        .arg(std::process::id().to_string())
        .arg(event_name)
        .spawn();
    if child.is_err() {
        let _ = unsafe { CloseHandle(event) };
        return false;
    }
    GUARD_EVENT.store(event.0 as usize, Ordering::SeqCst);
    true
}

fn stop_guard() {
    let event = GUARD_EVENT.swap(0, Ordering::SeqCst);
    if event != 0 {
        let event = windows::Win32::Foundation::HANDLE(event as *mut _);
        let _ = unsafe { SetEvent(event) };
        let _ = unsafe { CloseHandle(event) };
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn monitor_loop(generation: u64, parked: POINT) {
    while HIDDEN.load(Ordering::SeqCst) && GENERATION.load(Ordering::SeqCst) == generation {
        thread::sleep(POLL_INTERVAL);
        let mut current = POINT::default();
        if unsafe { GetCursorPos(&mut current) }.is_err() {
            continue;
        }
        // While hidden the virtual mouse is parked, so any movement comes
        // from a real local pointer and the user needs the cursor back.
        if (current.x, current.y) != (parked.x, parked.y) {
            show();
            return;
        }
    }
}

fn blank_template() -> Option<HCURSOR> {
    let existing = TEMPLATE.load(Ordering::Relaxed);
    if existing != 0 {
        return Some(HCURSOR(existing as *mut _));
    }
    // 32x32 monochrome, AND all ones and XOR all zeros: fully transparent.
    let and_plane = [0xFF_u8; 32 * 32 / 8];
    let xor_plane = [0_u8; 32 * 32 / 8];
    let cursor = unsafe {
        CreateCursor(
            None,
            0,
            0,
            32,
            32,
            and_plane.as_ptr().cast(),
            xor_plane.as_ptr().cast(),
        )
    }
    .ok()?;
    match TEMPLATE.compare_exchange(0, cursor.0 as usize, Ordering::Relaxed, Ordering::Relaxed) {
        Ok(_) => Some(cursor),
        Err(existing) => {
            let _ = unsafe { DestroyCursor(cursor) };
            Some(HCURSOR(existing as *mut _))
        }
    }
}
