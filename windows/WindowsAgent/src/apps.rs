use std::{collections::HashSet, path::PathBuf, process::Stdio, time::Duration};

use rmcp::schemars;
use serde::{Deserialize, Serialize};
use sysinfo::System;
use tokio::process::Command;
use windows::Win32::{
    Foundation::{HWND, LPARAM},
    UI::WindowsAndMessaging::{EnumWindows, GetWindowThreadProcessId, IsWindowVisible},
};
use windows::core::BOOL;

use crate::error::{AgentError, AgentResult};

#[derive(Clone, Debug, Deserialize, schemars::JsonSchema)]
pub struct LaunchApplicationRequest {
    #[schemars(regex(pattern = r"^(?:[A-Za-z]:[\\/]|\\\\)"))]
    pub executable: String,
    #[serde(default)]
    pub args: Vec<String>,
}

#[derive(Clone, Debug, Serialize, schemars::JsonSchema)]
pub struct LaunchApplicationResponse {
    pub executable: String,
    pub pid: u32,
    pub running: bool,
    pub visible_window_found: bool,
    pub visible_window_pid: Option<u32>,
    pub checked_utc: String,
}

pub async fn launch(request: &LaunchApplicationRequest) -> AgentResult<LaunchApplicationResponse> {
    if request.args.len() > 64
        || request
            .args
            .iter()
            .any(|arg| arg.len() > 2048 || arg.contains(['\0', '\r', '\n']))
    {
        return Err(AgentError::InvalidArgument("应用参数超出限制".to_owned()));
    }
    let requested = PathBuf::from(request.executable.trim());
    if !requested.is_absolute() {
        return Err(AgentError::InvalidArgument(
            "应用程序必须使用绝对路径".to_owned(),
        ));
    }
    let executable = std::fs::canonicalize(&requested)
        .map_err(|_| AgentError::NotFound("应用程序不存在".to_owned()))?;
    if !executable.is_file()
        || !executable
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case("exe"))
    {
        return Err(AgentError::InvalidArgument(
            "只允许直接启动普通 EXE 应用".to_owned(),
        ));
    }
    let name = executable
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if is_system_mutator(&name) {
        return Err(AgentError::PermissionDenied(
            "该程序属于命令解释器、安装器或系统修改工具，Windows Agent 不允许远程启动".to_owned(),
        ));
    }

    let mut child = Command::new(&executable)
        .args(&request.args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| AgentError::DependencyUnavailable(format!("应用无法启动: {error}")))?;
    let pid = child
        .id()
        .ok_or_else(|| AgentError::Internal("应用进程没有 PID".to_owned()))?;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let (running, visible_window_pid) = loop {
        let root_running = child.try_wait()?.is_none();
        let visible_pid = visible_window_in_process_tree(pid);
        if visible_pid.is_some() || tokio::time::Instant::now() >= deadline {
            break (root_running || visible_pid.is_some(), visible_pid);
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    Ok(LaunchApplicationResponse {
        executable: executable.to_string_lossy().into_owned(),
        pid,
        running,
        visible_window_found: visible_window_pid.is_some(),
        visible_window_pid,
        checked_utc: chrono::Utc::now().to_rfc3339(),
    })
}

fn is_system_mutator(name: &str) -> bool {
    const BLOCKED: &[&str] = &[
        "cmd.exe",
        "powershell.exe",
        "pwsh.exe",
        "wscript.exe",
        "cscript.exe",
        "mshta.exe",
        "msiexec.exe",
        "rundll32.exe",
        "regsvr32.exe",
        "reg.exe",
        "sc.exe",
        "diskpart.exe",
        "format.com",
        "bcdedit.exe",
        "pnputil.exe",
        "devcon.exe",
        "shutdown.exe",
        "manage-bde.exe",
    ];
    BLOCKED.contains(&name)
}

fn visible_window_in_process_tree(root_pid: u32) -> Option<u32> {
    let mut system = System::new_all();
    system.refresh_all();
    let mut pids = HashSet::from([root_pid]);
    loop {
        let before = pids.len();
        for (pid, process) in system.processes() {
            if process
                .parent()
                .is_some_and(|parent| pids.contains(&parent.as_u32()))
            {
                pids.insert(pid.as_u32());
            }
        }
        if pids.len() == before {
            break;
        }
    }
    process_tree_visible_window(&pids)
}

fn process_tree_visible_window(pids: &HashSet<u32>) -> Option<u32> {
    struct Search<'a> {
        pids: &'a HashSet<u32>,
        found: Option<u32>,
    }
    unsafe extern "system" fn callback(hwnd: HWND, parameter: LPARAM) -> BOOL {
        let search = unsafe { &mut *(parameter.0 as *mut Search<'_>) };
        let mut window_pid = 0_u32;
        unsafe {
            GetWindowThreadProcessId(hwnd, Some(&mut window_pid));
        }
        if search.pids.contains(&window_pid) && unsafe { IsWindowVisible(hwnd).as_bool() } {
            search.found = Some(window_pid);
            return BOOL(0);
        }
        BOOL(1)
    }
    let mut search = Search { pids, found: None };
    let _ = unsafe {
        EnumWindows(
            Some(callback),
            LPARAM((&mut search as *mut Search).cast::<core::ffi::c_void>() as isize),
        )
    };
    search.found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_shells_and_system_mutators() {
        assert!(is_system_mutator("powershell.exe"));
        assert!(is_system_mutator("diskpart.exe"));
        assert!(!is_system_mutator("notepad.exe"));
    }
}
