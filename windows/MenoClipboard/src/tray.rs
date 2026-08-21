use windows::Win32::Foundation::HWND;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NIM_MODIFY, NOTIFYICONDATAW,
    Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{IDI_APPLICATION, LoadIconW};
use windows::core::PCWSTR;

pub const CALLBACK_MESSAGE: u32 = windows::Win32::UI::WindowsAndMessaging::WM_APP + 2;
pub const COMMAND_PAUSE: usize = 1001;
pub const COMMAND_REDISCOVER: usize = 1002;
pub const COMMAND_STARTUP: usize = 1003;
pub const COMMAND_REPAIR_DRIVER: usize = 1004;
pub const COMMAND_VIEW_LOG: usize = 1005;
pub const COMMAND_EXIT: usize = 1006;
pub const COMMAND_CLEAR_LOG: usize = 1007;
pub const COMMAND_CURSOR_THEME: usize = 1008;
pub const COMMAND_INSTALL_AUDIO_DRIVER: usize = 1010;
pub const COMMAND_VB_CABLE_WEBSITE: usize = 1011;
pub const COMMAND_AGENT_SETTINGS: usize = 1012;
pub const ICON_ID: u32 = 1;
const ICON_RESOURCE_ID: usize = 101;

pub fn add(hwnd: HWND, tooltip: &str) {
    let data = notification_data(hwnd, tooltip);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_ADD, &data);
    }
}

pub fn update(hwnd: HWND, tooltip: &str) {
    let data = notification_data(hwnd, tooltip);
    unsafe {
        let _ = Shell_NotifyIconW(NIM_MODIFY, &data);
    }
}

pub fn remove(hwnd: HWND) {
    let data = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: ICON_ID,
        ..Default::default()
    };
    unsafe {
        let _ = Shell_NotifyIconW(NIM_DELETE, &data);
    }
}

fn notification_data(hwnd: HWND, tooltip: &str) -> NOTIFYICONDATAW {
    let mut data = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: ICON_ID,
        uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
        uCallbackMessage: CALLBACK_MESSAGE,
        hIcon: application_icon(),
        ..Default::default()
    };
    let tooltip = wide(tooltip);
    // Keep one trailing slot so the tip stays NUL-terminated even when truncated.
    let length = tooltip.len().min(data.szTip.len() - 1);
    data.szTip[..length].copy_from_slice(&tooltip[..length]);
    data
}

fn application_icon() -> windows::Win32::UI::WindowsAndMessaging::HICON {
    let resource = PCWSTR(ICON_RESOURCE_ID as *const u16);
    unsafe {
        GetModuleHandleW(None)
            .ok()
            .and_then(|module| LoadIconW(Some(module.into()), resource).ok())
            .or_else(|| LoadIconW(None, IDI_APPLICATION).ok())
            .unwrap_or_default()
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
