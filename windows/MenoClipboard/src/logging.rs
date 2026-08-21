use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use windows::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_DWORD, REG_OPTION_NON_VOLATILE,
    REG_SAM_FLAGS, RegCloseKey, RegCreateKeyExW, RegQueryValueExW, RegSetValueExW,
};
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::core::PCWSTR;

// Two bounded generations (active + .old) keep an always-on tray app bounded
// on disk even when it runs for weeks without a restart.
const MAX_LOG_BYTES: u64 = 2 * 1024 * 1024;
const REPEAT_RELOG_AFTER: Duration = Duration::from_secs(60);
const VERBOSE_KEY: &str = r"Software\Meno";
const VERBOSE_VALUE: &str = "VerboseLogging";

#[derive(Clone, Copy, Eq, PartialEq)]
pub enum Level {
    Error,
    Info,
    Debug,
}

impl Level {
    fn tag(self) -> &'static str {
        match self {
            Level::Error => "ERROR",
            Level::Info => "INFO ",
            Level::Debug => "DEBUG",
        }
    }
}

static LOG: OnceLock<Mutex<LogState>> = OnceLock::new();
static VERBOSE: AtomicBool = AtomicBool::new(false);

struct LogState {
    file: Option<File>,
    path: PathBuf,
    written: u64,
    repeat: Option<Repeat>,
}

pub(crate) struct Repeat {
    level: Level,
    message: String,
    count: u32,
    logged_at: Instant,
}

pub(crate) enum FoldDecision {
    Write { summary: Option<String> },
    Suppress,
}

pub fn initialize(path: &Path) {
    if let Some(directory) = path.parent() {
        let _ = fs::create_dir_all(directory);
    }
    VERBOSE.store(read_verbose_setting(), Ordering::Relaxed);
    let Ok(file) = OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };
    let written = file.metadata().map_or(0, |metadata| metadata.len());
    let state = LogState {
        file: Some(file),
        path: path.to_path_buf(),
        written,
        repeat: None,
    };
    if LOG.set(Mutex::new(state)).is_err() {
        return;
    }
    install_panic_hook();
    info(&format!(
        "session start: version={} pid={} verbose={}",
        env!("CARGO_PKG_VERSION"),
        std::process::id(),
        verbose()
    ));
}

pub fn verbose() -> bool {
    VERBOSE.load(Ordering::Relaxed)
}

pub fn set_verbose(enabled: bool) {
    VERBOSE.store(enabled, Ordering::Relaxed);
    write_verbose_setting(enabled);
    info(if enabled {
        "verbose logging enabled"
    } else {
        "verbose logging disabled"
    });
}

pub fn error(message: &str) {
    log(Level::Error, message);
}

pub fn info(message: &str) {
    log(Level::Info, message);
}

pub fn debug(message: &str) {
    log(Level::Debug, message);
}

pub fn clear() {
    let Some(state) = LOG.get() else { return };
    {
        let mut state = lock(state);
        state.repeat = None;
        drop(state.file.take());
        let _ = fs::remove_file(old_path(&state.path));
        // Append mode keeps concurrent writers correct; set_len(0) resets the
        // file in place so later appends continue from offset zero.
        match OpenOptions::new()
            .create(true)
            .append(true)
            .open(&state.path)
        {
            Ok(file) => {
                let _ = file.set_len(0);
                let _ = file.sync_data();
                state.written = file.metadata().map_or(0, |metadata| metadata.len());
                state.file = Some(file);
            }
            Err(_) => {
                state.file = None;
                state.written = 0;
            }
        }
    }
    info("log cleared from tray menu");
}

pub(crate) fn log(level: Level, message: &str) {
    if level == Level::Debug && !verbose() {
        return;
    }
    let Some(state) = LOG.get() else { return };
    let mut state = lock(state);
    match fold(&mut state.repeat, level, message, Instant::now()) {
        FoldDecision::Suppress => {}
        FoldDecision::Write { summary } => {
            if let Some(summary) = summary {
                state.write_line(Level::Info, &summary);
            }
            state.write_line(level, message);
        }
    }
}

// Consecutive duplicates collapse into a counter so a stuck retry loop cannot
// flood the log; once the streak outlives the relog window it is written
// again as proof the condition still holds.
pub(crate) fn fold(
    repeat: &mut Option<Repeat>,
    level: Level,
    message: &str,
    now: Instant,
) -> FoldDecision {
    let summary = match repeat.as_mut() {
        Some(active)
            if active.level == level
                && active.message == message
                && now.duration_since(active.logged_at) < REPEAT_RELOG_AFTER =>
        {
            active.count += 1;
            return FoldDecision::Suppress;
        }
        Some(active) if active.level == level && active.message == message => {
            let suppressed = active.count - 1;
            (suppressed > 0).then(|| summary_text(suppressed))
        }
        Some(active) => {
            let suppressed = active.count - 1;
            (suppressed > 0).then(|| summary_text(suppressed))
        }
        None => None,
    };
    *repeat = Some(Repeat {
        level,
        message: message.to_string(),
        count: 1,
        logged_at: now,
    });
    FoldDecision::Write { summary }
}

fn summary_text(suppressed: u32) -> String {
    let plural = if suppressed == 1 { "" } else { "s" };
    format!("(previous message repeated {suppressed} time{plural})")
}

impl LogState {
    fn write_line(&mut self, level: Level, message: &str) {
        self.rotate_if_needed();
        let Some(file) = self.file.as_mut() else {
            return;
        };
        let line = format!("{} {} {}\n", timestamp(), level.tag(), message);
        if file.write_all(line.as_bytes()).is_ok() {
            self.written += line.len() as u64;
        }
    }

    fn rotate_if_needed(&mut self) {
        if self.written < MAX_LOG_BYTES {
            return;
        }
        drop(self.file.take());
        let _ = fs::remove_file(old_path(&self.path));
        let renamed = fs::rename(&self.path, old_path(&self.path)).is_ok();
        let Ok(file) = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
        else {
            self.file = None;
            self.written = 0;
            return;
        };
        // A log that cannot be renamed (locked by another process) must still
        // stay bounded, so fall back to truncating it in place.
        if !renamed {
            let _ = file.set_len(0);
        }
        self.written = file.metadata().map_or(0, |metadata| metadata.len());
        self.file = Some(file);
    }
}

fn timestamp() -> String {
    let now = unsafe { GetLocalTime() };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond, now.wMilliseconds
    )
}

fn old_path(path: &Path) -> PathBuf {
    let mut old = path.as_os_str().to_owned();
    old.push(".old");
    PathBuf::from(old)
}

fn lock(state: &Mutex<LogState>) -> MutexGuard<'_, LogState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn install_panic_hook() {
    std::panic::set_hook(Box::new(|info| {
        let Some(state) = LOG.get() else { return };
        // A thread that panicked while logging must not deadlock the hook.
        let mut state = match state.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::Poisoned(poisoned)) => poisoned.into_inner(),
            Err(std::sync::TryLockError::WouldBlock) => return,
        };
        if let Some(active) = state.repeat.take()
            && active.count > 1
        {
            state.write_line(Level::Info, &summary_text(active.count - 1));
        }
        state.write_line(Level::Error, &format!("PANIC: {info}"));
        if let Some(file) = state.file.as_mut() {
            let _ = file.sync_data();
        }
    }));
}

fn read_verbose_setting() -> bool {
    let Some(key) = open_settings_key(KEY_QUERY_VALUE) else {
        return false;
    };
    let name = wide(VERBOSE_VALUE);
    let mut value = 0_u32;
    let mut length = std::mem::size_of::<u32>() as u32;
    let error = unsafe {
        RegQueryValueExW(
            key,
            PCWSTR(name.as_ptr()),
            None,
            None,
            Some((&raw mut value).cast()),
            Some(&mut length),
        )
    };
    let _ = unsafe { RegCloseKey(key) };
    error.is_ok() && value != 0
}

fn write_verbose_setting(enabled: bool) {
    let Some(key) = open_settings_key(KEY_SET_VALUE) else {
        return;
    };
    let name = wide(VERBOSE_VALUE);
    let value = u32::from(enabled);
    let bytes = unsafe {
        std::slice::from_raw_parts((&raw const value).cast::<u8>(), std::mem::size_of::<u32>())
    };
    let _ = unsafe { RegSetValueExW(key, PCWSTR(name.as_ptr()), None, REG_DWORD, Some(bytes)) };
    let _ = unsafe { RegCloseKey(key) };
}

fn open_settings_key(access: REG_SAM_FLAGS) -> Option<HKEY> {
    let subkey = wide(VERBOSE_KEY);
    let mut key = HKEY::default();
    let error = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            access,
            None,
            &mut key,
            None,
        )
    };
    if error.is_err() {
        return None;
    }
    Some(key)
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
