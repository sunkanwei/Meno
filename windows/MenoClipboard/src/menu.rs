// Custom Win11-style tray menu: a rounded, shadowed, theme-aware popup
// window painted with plain GDI. No GUI framework and no new dependencies;
// the command IDs stay identical to the previous native menu.
use std::sync::OnceLock;

use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWMWA_USE_IMMERSIVE_DARK_MODE, DWMWA_WINDOW_CORNER_PREFERENCE, DWMWCP_ROUND,
    DwmGetColorizationColor, DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    BeginPaint, BitBlt, CLEARTYPE_QUALITY, CLIP_DEFAULT_PRECIS, CreateCompatibleBitmap,
    CreateCompatibleDC, CreateFontIndirectW, CreateFontW, CreatePen, CreateSolidBrush,
    DEFAULT_CHARSET, DEFAULT_PITCH, DT_CENTER, DT_LEFT, DT_NOPREFIX, DT_SINGLELINE, DT_VCENTER,
    DeleteDC, DeleteObject, DrawTextW, Ellipse, EndPaint, FF_DONTCARE, FW_NORMAL, FillRect, GetDC,
    GetMonitorInfoW, GetTextExtentPoint32W, HDC, HFONT, InvalidateRect, LOGFONTW,
    MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromRect, OUT_DEFAULT_PRECIS, PAINTSTRUCT,
    PS_SOLID, ReleaseDC, RoundRect, SRCCOPY, SelectObject, SetBkMode, SetTextColor, TRANSPARENT,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{
    HKEY_CURRENT_USER, KEY_QUERY_VALUE, RegCloseKey, RegOpenKeyExW, RegQueryValueExW,
};
use windows::Win32::UI::Controls::WM_MOUSELEAVE;
use windows::Win32::UI::HiDpi::{GetDpiForSystem, GetDpiForWindow};
use windows::Win32::UI::Input::KeyboardAndMouse::{TME_LEAVE, TRACKMOUSEEVENT, TrackMouseEvent};
use windows::Win32::UI::Shell::{NOTIFYICONIDENTIFIER, Shell_NotifyIconGetRect};
use windows::Win32::UI::WindowsAndMessaging::{
    CREATESTRUCTW, CS_DROPSHADOW, CreateWindowExW, DefWindowProcW, DestroyWindow, GWLP_USERDATA,
    GetClientRect, GetCursorPos, GetWindowLongPtrW, IDC_ARROW, LoadCursorW, NONCLIENTMETRICSW,
    PostMessageW, RegisterClassW, SPI_GETNONCLIENTMETRICS, SW_SHOW, SWP_NOACTIVATE,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SetForegroundWindow, SetWindowLongPtrW, SetWindowPos,
    ShowWindow, SystemParametersInfoW, WM_COMMAND, WM_CREATE, WM_KEYDOWN, WM_KILLFOCUS,
    WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_NCCREATE, WM_NCDESTROY, WM_PAINT, WNDCLASSW,
    WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};
use windows::core::{Error, PCWSTR, w};

use crate::tray::{
    COMMAND_AGENT_SETTINGS, COMMAND_CLEAR_LOG, COMMAND_CURSOR_THEME, COMMAND_EXIT,
    COMMAND_INSTALL_AUDIO_DRIVER, COMMAND_PAUSE, COMMAND_REDISCOVER, COMMAND_REPAIR_DRIVER,
    COMMAND_STARTUP, COMMAND_VB_CABLE_WEBSITE, COMMAND_VIEW_LOG, ICON_ID,
};

const CLASS_NAME: PCWSTR = w!("MenoTrayMenuWindow");
const APP_LIGHT_THEME_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
const APP_LIGHT_THEME_VALUE: &str = "AppsUseLightTheme";
const MENU_GAP_ABOVE_ICON: i32 = 8;
const MENU_GAP_BELOW_ICON: i32 = 8;

#[derive(Clone, Copy, PartialEq)]
pub enum StatusKind {
    Connected,
    Searching,
    Paused,
}

pub struct MenuModel {
    pub status_text: String,
    pub status: StatusKind,
    pub paused: bool,
    pub startup: bool,
    pub macos_cursor: bool,
    pub agent_status: String,
}

impl MenuModel {
    pub fn new(
        detail_status: String,
        connected: bool,
        paused: bool,
        suspended: bool,
        startup: bool,
        macos_cursor: bool,
    ) -> Self {
        let (status_text, status) = if suspended {
            ("系统休眠".to_string(), StatusKind::Paused)
        } else if paused {
            ("已暂停".to_string(), StatusKind::Paused)
        } else if connected {
            (detail_status, StatusKind::Connected)
        } else {
            (detail_status, StatusKind::Searching)
        };
        Self {
            status_text,
            status,
            paused,
            startup,
            macos_cursor,
            agent_status: "已停止".to_owned(),
        }
    }

    pub fn with_agent_status(mut self, agent_status: String) -> Self {
        self.agent_status = agent_status;
        self
    }
}

pub fn connected_status_text(main_status: &str, audio_status: Option<&str>) -> String {
    audio_status.map_or_else(
        || main_status.to_string(),
        |audio_status| format!("{main_status} · {audio_status}"),
    )
}

#[derive(Clone, Copy, PartialEq)]
pub(crate) enum ItemKind {
    Header,
    Action,
    Toggle,
    Separator,
}

impl ItemKind {
    pub(crate) fn actionable(self) -> bool {
        matches!(self, Self::Action | Self::Toggle)
    }
}

pub(crate) struct Item {
    pub(crate) kind: ItemKind,
    pub(crate) id: usize,
    label: Vec<u16>,
    glyph: Option<u16>,
    checked: bool,
}

impl Item {
    fn action(id: usize, label: &str, glyph: u16) -> Self {
        Self {
            kind: ItemKind::Action,
            id,
            label: wide(label),
            glyph: Some(glyph),
            checked: false,
        }
    }

    fn toggle(id: usize, label: &str, checked: bool) -> Self {
        Self {
            kind: ItemKind::Toggle,
            id,
            label: wide(label),
            glyph: None,
            checked,
        }
    }

    fn separator() -> Self {
        Self {
            kind: ItemKind::Separator,
            id: 0,
            label: Vec::new(),
            glyph: None,
            checked: false,
        }
    }
}

struct MenuState {
    owner: HWND,
    status: StatusKind,
    dark: bool,
    accent: COLORREF,
    items: Vec<Item>,
    scale: f64,
    item_h: i32,
    pad_x: i32,
    text_x: i32,
    sep_h: i32,
    edge_pad: i32,
    hover_inset: i32,
    corner_r: i32,
    dot_d: i32,
    glyph_h: i32,
    rects: Vec<RECT>,
    hot: Option<usize>,
    pressed: Option<usize>,
    text_font: HFONT,
    glyph_font: HFONT,
}

impl Drop for MenuState {
    fn drop(&mut self) {
        if !self.text_font.is_invalid() {
            let _ = unsafe { DeleteObject(self.text_font.into()) };
        }
        if !self.glyph_font.is_invalid() {
            let _ = unsafe { DeleteObject(self.glyph_font.into()) };
        }
    }
}

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

static REGISTERED: OnceLock<bool> = OnceLock::new();

pub fn show_menu(owner: HWND, model: &MenuModel) {
    let Some(instance) = module_instance() else {
        crate::logging::error("Tray menu module handle lookup failed");
        return;
    };
    if !register_class(instance) {
        return;
    }
    let items = build_items(model);
    let anchor = tray_anchor(owner);
    let initial_x = anchor.left;
    let initial_y = anchor.top;
    let mut state = Some(Box::new(MenuState {
        owner,
        status: model.status,
        dark: dark_mode_enabled(),
        accent: system_accent(),
        items,
        scale: 1.0,
        item_h: 0,
        pad_x: 0,
        text_x: 0,
        sep_h: 0,
        edge_pad: 0,
        hover_inset: 0,
        corner_r: 0,
        dot_d: 0,
        glyph_h: 0,
        rects: Vec::new(),
        hot: None,
        pressed: None,
        text_font: HFONT::default(),
        glyph_font: HFONT::default(),
    }));

    // CreateWindowExW is synchronous. WM_NCCREATE takes the Box from this
    // stack slot; if creation fails before that, the local Option drops it.
    let state_slot = &raw mut state;
    let hwnd = match unsafe {
        CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            CLASS_NAME,
            PCWSTR::null(),
            WS_POPUP,
            initial_x,
            initial_y,
            1,
            1,
            Some(owner),
            None,
            Some(instance),
            Some(state_slot.cast::<core::ffi::c_void>().cast_const()),
        )
    } {
        Ok(hwnd) => hwnd,
        Err(error) => {
            crate::logging::error(&format!("Tray menu window creation failed: {error}"));
            return;
        }
    };
    let _ = unsafe { ShowWindow(hwnd, SW_SHOW) };
    let _ = unsafe { SetForegroundWindow(hwnd) };
}

pub(crate) fn build_items(model: &MenuModel) -> Vec<Item> {
    let mut items = Vec::new();
    items.push(Item {
        kind: ItemKind::Header,
        id: 0,
        label: wide(&model.status_text),
        glyph: None,
        checked: false,
    });
    items.push(Item::separator());
    items.push(Item::action(
        COMMAND_PAUSE,
        if model.paused { "继续" } else { "暂停" },
        if model.paused { 0xE768 } else { 0xE769 },
    ));
    items.push(Item::action(COMMAND_REDISCOVER, "重新发现", 0xE72C));
    items.push(Item::action(
        COMMAND_AGENT_SETTINGS,
        &format!("Windows Agent：{}", model.agent_status),
        0xE713,
    ));
    items.push(Item::separator());
    items.push(Item::toggle(COMMAND_STARTUP, "开机启动", model.startup));
    items.push(Item::toggle(
        COMMAND_CURSOR_THEME,
        "macOS 光标",
        model.macos_cursor,
    ));
    items.push(Item::separator());
    items.push(Item::action(COMMAND_REPAIR_DRIVER, "修复鼠标驱动", 0xE90F));
    items.push(Item::action(
        COMMAND_INSTALL_AUDIO_DRIVER,
        "安装音频驱动 (VB-CABLE)",
        0xE8D6,
    ));
    items.push(Item::action(
        COMMAND_VB_CABLE_WEBSITE,
        "VB-CABLE 官网与捐赠",
        0xE774,
    ));
    items.push(Item::action(COMMAND_VIEW_LOG, "查看日志", 0xE8A5));
    items.push(Item::action(COMMAND_CLEAR_LOG, "清理日志", 0xE74D));
    items.push(Item::separator());
    items.push(Item::action(COMMAND_EXIT, "退出", 0xE711));
    items
}

fn module_instance() -> Option<HINSTANCE> {
    unsafe {
        GetModuleHandleW(None)
            .ok()
            .map(|module| HINSTANCE(module.0))
    }
}

fn register_class(instance: HINSTANCE) -> bool {
    *REGISTERED.get_or_init(|| {
        let class = WNDCLASSW {
            style: CS_DROPSHADOW,
            lpfnWndProc: Some(menu_proc),
            hCursor: unsafe { LoadCursorW(None, IDC_ARROW).unwrap_or_default() },
            hInstance: instance,
            lpszClassName: CLASS_NAME,
            ..Default::default()
        };
        if unsafe { RegisterClassW(&class) } == 0 {
            crate::logging::error(&format!(
                "Tray menu class registration failed: {}",
                Error::from_thread()
            ));
            false
        } else {
            true
        }
    })
}

unsafe extern "system" fn menu_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe {
        match message {
            WM_NCCREATE => {
                let create = &*(lparam.0 as *const CREATESTRUCTW);
                let slot = create.lpCreateParams as *mut Option<Box<MenuState>>;
                if slot.is_null() {
                    return LRESULT(0);
                }
                let Some(state) = (*slot).take() else {
                    return LRESULT(0);
                };
                let state = Box::into_raw(state);
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, state as isize);
                LRESULT(1)
            }
            WM_CREATE => {
                let state = &mut *user_state(hwnd);
                setup_window(hwnd, state);
                LRESULT(0)
            }
            WM_PAINT => {
                let mut paint_struct = PAINTSTRUCT::default();
                let hdc = BeginPaint(hwnd, &raw mut paint_struct);
                let state = user_state(hwnd);
                if !state.is_null() {
                    paint(hwnd, &mut *state, hdc);
                }
                let _ = EndPaint(hwnd, &raw const paint_struct);
                LRESULT(0)
            }
            WM_MOUSEMOVE => {
                let state = &mut *user_state(hwnd);
                let point = client_point(lparam);
                let index = action_at_point(state, point);
                if state.hot != index {
                    state.hot = index;
                    invalidate(hwnd);
                }
                track_leave(hwnd);
                LRESULT(0)
            }
            WM_MOUSELEAVE => {
                let state = &mut *user_state(hwnd);
                if state.hot.is_some() || state.pressed.is_some() {
                    state.hot = None;
                    state.pressed = None;
                    invalidate(hwnd);
                }
                LRESULT(0)
            }
            WM_LBUTTONDOWN => {
                let state = &mut *user_state(hwnd);
                let index = action_at_point(state, client_point(lparam));
                if state.pressed != index {
                    state.pressed = index;
                    invalidate(hwnd);
                }
                LRESULT(0)
            }
            WM_LBUTTONUP => {
                let state = &mut *user_state(hwnd);
                let index = action_at_point(state, client_point(lparam));
                let execute = index.filter(|index| state.pressed == Some(*index));
                state.pressed = None;
                if let Some(index) = execute {
                    let id = state.items[index].id;
                    let _ = PostMessageW(Some(state.owner), WM_COMMAND, WPARAM(id), LPARAM(0));
                    let _ = DestroyWindow(hwnd);
                }
                LRESULT(0)
            }
            WM_KEYDOWN => {
                let state = &mut *user_state(hwnd);
                match wparam.0 as u32 {
                    0x1B => {
                        // VK_ESCAPE
                        let _ = DestroyWindow(hwnd);
                    }
                    0x0D => {
                        // VK_RETURN
                        if let Some(index) = state
                            .hot
                            .filter(|index| state.items[*index].kind.actionable())
                        {
                            let id = state.items[index].id;
                            let _ =
                                PostMessageW(Some(state.owner), WM_COMMAND, WPARAM(id), LPARAM(0));
                            let _ = DestroyWindow(hwnd);
                        }
                    }
                    0x26 | 0x28 => {
                        // VK_UP / VK_DOWN
                        let step: isize = if wparam.0 as u32 == 0x28 { 1 } else { -1 };
                        if let Some(index) = next_actionable(&state.items, state.hot, step) {
                            state.hot = Some(index);
                            invalidate(hwnd);
                        }
                    }
                    _ => {}
                }
                LRESULT(0)
            }
            WM_KILLFOCUS => {
                let _ = DestroyWindow(hwnd);
                LRESULT(0)
            }
            WM_NCDESTROY => {
                let result = DefWindowProcW(hwnd, message, wparam, lparam);
                let state = user_state(hwnd);
                if !state.is_null() {
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                    drop(Box::from_raw(state));
                }
                result
            }
            _ => DefWindowProcW(hwnd, message, wparam, lparam),
        }
    }
}

fn user_state(hwnd: HWND) -> *mut MenuState {
    unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut MenuState }
}

fn client_point(lparam: LPARAM) -> POINT {
    POINT {
        x: (lparam.0 & 0xFFFF) as u16 as i16 as i32,
        y: ((lparam.0 >> 16) & 0xFFFF) as u16 as i16 as i32,
    }
}

fn setup_window(hwnd: HWND, state: &mut MenuState) {
    let dpi = unsafe { GetDpiForWindow(hwnd) };
    let scale = f64::from(dpi) / 96.0;
    state.scale = scale;
    state.item_h = (32.0 * scale).round() as i32;
    state.pad_x = (12.0 * scale).round() as i32;
    let gutter = (16.0 * scale).round() as i32;
    let gap = (12.0 * scale).round() as i32;
    state.text_x = state.pad_x + gutter + gap;
    state.sep_h = (9.0 * scale).round() as i32;
    state.edge_pad = (4.0 * scale).round() as i32;
    state.hover_inset = (4.0 * scale).round() as i32;
    state.corner_r = (4.0 * scale).round() as i32;
    state.dot_d = (8.0 * scale).round() as i32;
    state.glyph_h = (16.0 * scale).round() as i32;

    let hdc = unsafe { GetDC(Some(hwnd)) };
    replace_font(&mut state.text_font, message_font(dpi));
    replace_font(&mut state.glyph_font, glyph_font(state.glyph_h));

    // Measure the widest label to size the menu.
    let old = unsafe { SelectObject(hdc, state.text_font.into()) };
    let mut max_text = 0_i32;
    for item in &state.items {
        if item.kind != ItemKind::Separator && !item.label.is_empty() {
            let mut size = windows::Win32::Foundation::SIZE::default();
            let _ = unsafe { GetTextExtentPoint32W(hdc, &item.label, &mut size) };
            max_text = max_text.max(size.cx);
        }
    }
    let _ = unsafe { SelectObject(hdc, old) };
    let _ = unsafe { ReleaseDC(Some(hwnd), hdc) };

    let min_width = (200.0 * scale).round() as i32;
    let width = (max_text + state.text_x + state.pad_x).max(min_width);
    let mut height = state.edge_pad * 2;
    for item in &state.items {
        height += if item.kind == ItemKind::Separator {
            state.sep_h
        } else {
            state.item_h
        };
    }

    // Hit rectangles.
    let mut y = state.edge_pad;
    state.rects.clear();
    for item in &state.items {
        let item_height = if item.kind == ItemKind::Separator {
            state.sep_h
        } else {
            state.item_h
        };
        state.rects.push(RECT {
            left: 0,
            top: y,
            right: width,
            bottom: y + item_height,
        });
        y += item_height;
    }

    // Theme and shape.
    let dark_value = u32::from(state.dark);
    let _ = unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark_value as *const u32 as *const core::ffi::c_void,
            std::mem::size_of::<u32>() as u32,
        )
    };
    let _ = unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            &DWMWCP_ROUND as *const _ as *const core::ffi::c_void,
            std::mem::size_of::<u32>() as u32,
        )
    };
    let (x, y) = position(state.owner, width, height, state.scale);
    let _ = unsafe { SetWindowPos(hwnd, None, x, y, width, height, SWP_NOACTIVATE) };
}

fn replace_font(slot: &mut HFONT, replacement: HFONT) {
    if !slot.is_invalid() {
        let _ = unsafe { DeleteObject((*slot).into()) };
    }
    *slot = replacement;
}

fn tray_anchor(owner: HWND) -> RECT {
    unsafe {
        let identifier = NOTIFYICONIDENTIFIER {
            cbSize: std::mem::size_of::<NOTIFYICONIDENTIFIER>() as u32,
            hWnd: owner,
            uID: ICON_ID,
            guidItem: windows::core::GUID::zeroed(),
        };
        match Shell_NotifyIconGetRect(&identifier) {
            Ok(rect) => rect,
            Err(_) => {
                let mut point = POINT::default();
                let _ = GetCursorPos(&mut point);
                RECT {
                    left: point.x,
                    top: point.y,
                    right: point.x,
                    bottom: point.y,
                }
            }
        }
    }
}

fn position(owner: HWND, width: i32, height: i32, scale: f64) -> (i32, i32) {
    let icon = tray_anchor(owner);
    let monitor = unsafe { MonitorFromRect(&icon, MONITOR_DEFAULTTONEAREST) };
    let mut info = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    let _ = unsafe { GetMonitorInfoW(monitor, &mut info) };
    let work = info.rcWork;

    let mut x = icon.left + (icon.right - icon.left) / 2 - width / 2;
    let max_x = (work.right - width).max(work.left);
    x = x.clamp(work.left, max_x);
    let gap_above = (f64::from(MENU_GAP_ABOVE_ICON) * scale).round() as i32;
    let gap_below = (f64::from(MENU_GAP_BELOW_ICON) * scale).round() as i32;
    let mut y = icon.top - height - gap_above;
    if y < work.top {
        y = icon.bottom + gap_below;
    }
    let max_y = (work.bottom - height).max(work.top);
    y = y.clamp(work.top, max_y);
    (x, y)
}

fn paint(hwnd: HWND, state: &mut MenuState, hdc: HDC) {
    if state.text_font.is_invalid() || state.rects.is_empty() {
        return;
    }
    let mut client = RECT::default();
    let _ = unsafe { GetClientRect(hwnd, &mut client) };
    let width = client.right - client.left;
    let height = client.bottom - client.top;
    if width <= 0 || height <= 0 {
        return;
    }
    let mem = unsafe { CreateCompatibleDC(Some(hdc)) };
    let bitmap = unsafe { CreateCompatibleBitmap(hdc, width, height) };
    let old_bitmap = unsafe { SelectObject(mem, bitmap.into()) };

    let bg = theme_color(state.dark, (0xF9, 0xF9, 0xF9), (0x2C, 0x2C, 0x2C));
    let border = theme_color(state.dark, (0xE6, 0xE6, 0xE6), (0x3C, 0x3C, 0x3C));
    let text = theme_color(state.dark, (0x1B, 0x1B, 0x1B), (0xFF, 0xFF, 0xFF));
    let secondary = theme_color(state.dark, (0x66, 0x66, 0x66), (0xB3, 0xB3, 0xB3));
    let hover = theme_color(state.dark, (0xEC, 0xEC, 0xEC), (0x38, 0x38, 0x38));
    let pressed = theme_color(state.dark, (0xF1, 0xF1, 0xF1), (0x34, 0x34, 0x34));

    let brush = unsafe { CreateSolidBrush(bg) };
    let _ = unsafe {
        FillRect(
            mem,
            &RECT {
                left: 0,
                top: 0,
                right: width,
                bottom: height,
            },
            brush,
        )
    };
    let _ = unsafe { DeleteObject(brush.into()) };

    // Rounded outline so the theme matches the DWM-rounded window shape.
    let pen = unsafe { CreatePen(PS_SOLID, 1, border) };
    let brush = unsafe { CreateSolidBrush(bg) };
    let old_pen = unsafe { SelectObject(mem, pen.into()) };
    let old_brush = unsafe { SelectObject(mem, brush.into()) };
    let _ = unsafe {
        RoundRect(
            mem,
            1,
            1,
            width - 2,
            height - 2,
            state.corner_r * 2,
            state.corner_r * 2,
        )
    };
    let _ = unsafe { SelectObject(mem, old_brush) };
    let _ = unsafe { SelectObject(mem, old_pen) };
    let _ = unsafe { DeleteObject(brush.into()) };
    let _ = unsafe { DeleteObject(pen.into()) };

    let _ = unsafe { SetBkMode(mem, TRANSPARENT) };
    let _ = unsafe { SelectObject(mem, state.text_font.into()) };

    for (index, item) in state.items.iter().enumerate() {
        let rect = state.rects[index];
        let cx = state.pad_x + (state.text_x - state.pad_x) / 2;
        let cy = rect.top + (rect.bottom - rect.top) / 2;
        match item.kind {
            ItemKind::Separator => {
                let line = RECT {
                    left: state.pad_x,
                    top: cy,
                    right: rect.right - state.pad_x,
                    bottom: cy + 1,
                };
                let brush = unsafe { CreateSolidBrush(border) };
                let _ = unsafe { FillRect(mem, &line, brush) };
                let _ = unsafe { DeleteObject(brush.into()) };
            }
            ItemKind::Header => {
                let dot = match state.status {
                    StatusKind::Connected => rgb(0x10, 0xC2, 0x60),
                    StatusKind::Searching => rgb(0xCA, 0x50, 0x10),
                    StatusKind::Paused => rgb(0x8A, 0x8A, 0x8A),
                };
                let brush = unsafe { CreateSolidBrush(dot) };
                let pen = unsafe { CreatePen(PS_SOLID, 1, dot) };
                let old_brush = unsafe { SelectObject(mem, brush.into()) };
                let old_pen = unsafe { SelectObject(mem, pen.into()) };
                let half = state.dot_d / 2;
                let _ = unsafe { Ellipse(mem, cx - half, cy - half, cx + half, cy + half) };
                let _ = unsafe { SelectObject(mem, old_pen) };
                let _ = unsafe { SelectObject(mem, old_brush) };
                let _ = unsafe { DeleteObject(pen.into()) };
                let _ = unsafe { DeleteObject(brush.into()) };
                let _ = unsafe { SetTextColor(mem, secondary) };
                draw_text(mem, &item.label, rect, state.text_x);
            }
            ItemKind::Action | ItemKind::Toggle => {
                let fill = if state.pressed == Some(index) {
                    pressed
                } else if state.hot == Some(index) {
                    hover
                } else {
                    bg
                };
                if fill != bg {
                    let brush = unsafe { CreateSolidBrush(fill) };
                    let pen = unsafe { CreatePen(PS_SOLID, 1, fill) };
                    let old_brush = unsafe { SelectObject(mem, brush.into()) };
                    let old_pen = unsafe { SelectObject(mem, pen.into()) };
                    let inset = state.hover_inset;
                    let _ = unsafe {
                        RoundRect(
                            mem,
                            rect.left + inset,
                            rect.top + inset,
                            rect.right - inset,
                            rect.bottom - inset,
                            state.corner_r * 2,
                            state.corner_r * 2,
                        )
                    };
                    let _ = unsafe { SelectObject(mem, old_pen) };
                    let _ = unsafe { SelectObject(mem, old_brush) };
                    let _ = unsafe { DeleteObject(pen.into()) };
                    let _ = unsafe { DeleteObject(brush.into()) };
                }
                if item.kind == ItemKind::Toggle {
                    if item.checked {
                        let _ = unsafe { SetTextColor(mem, state.accent) };
                        let _ = unsafe { SelectObject(mem, state.glyph_font.into()) };
                        draw_glyph(mem, cx, cy, state.glyph_h, 0xE73E);
                        let _ = unsafe { SelectObject(mem, state.text_font.into()) };
                    }
                } else if let Some(glyph) = item.glyph {
                    let _ = unsafe { SetTextColor(mem, text) };
                    let _ = unsafe { SelectObject(mem, state.glyph_font.into()) };
                    draw_glyph(mem, cx, cy, state.glyph_h, glyph);
                    let _ = unsafe { SelectObject(mem, state.text_font.into()) };
                }
                let _ = unsafe { SetTextColor(mem, text) };
                draw_text(mem, &item.label, rect, state.text_x);
            }
        }
    }

    let _ = unsafe { BitBlt(hdc, 0, 0, width, height, Some(mem), 0, 0, SRCCOPY) };
    let _ = unsafe { SelectObject(mem, old_bitmap) };
    let _ = unsafe { DeleteObject(bitmap.into()) };
    let _ = unsafe { DeleteDC(mem) };
}

fn draw_text(hdc: HDC, label: &[u16], mut rect: RECT, left: i32) {
    let mut label = label.to_vec();
    rect.left = left;
    let _ = unsafe {
        DrawTextW(
            hdc,
            &mut label,
            &raw mut rect,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        )
    };
}

fn draw_glyph(hdc: HDC, cx: i32, cy: i32, size: i32, code: u16) {
    let mut rect = RECT {
        left: cx - size / 2,
        top: cy - size / 2,
        right: cx + size / 2 + 1,
        bottom: cy + size / 2 + 1,
    };
    let mut glyph = [code, 0];
    let _ = unsafe {
        DrawTextW(
            hdc,
            &mut glyph,
            &raw mut rect,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX,
        )
    };
}

fn hit_test(state: &MenuState, point: POINT) -> Option<usize> {
    state.rects.iter().position(|rect| {
        point.x >= rect.left && point.x < rect.right && point.y >= rect.top && point.y < rect.bottom
    })
}

fn action_at_point(state: &MenuState, point: POINT) -> Option<usize> {
    hit_test(state, point).filter(|index| state.items[*index].kind.actionable())
}

pub(crate) fn next_actionable(
    items: &[Item],
    current: Option<usize>,
    step: isize,
) -> Option<usize> {
    if items.is_empty() || !matches!(step, -1 | 1) {
        return None;
    }
    let len = items.len() as isize;
    let mut index = current.map_or(if step > 0 { -1 } else { len }, |index| index as isize);
    for _ in 0..items.len() {
        index = (index + step).rem_euclid(len);
        if items[index as usize].kind.actionable() {
            return Some(index as usize);
        }
    }
    None
}

fn invalidate(hwnd: HWND) {
    let _ = unsafe { InvalidateRect(Some(hwnd), None, false) };
}

fn track_leave(hwnd: HWND) {
    let mut event = TRACKMOUSEEVENT {
        cbSize: std::mem::size_of::<TRACKMOUSEEVENT>() as u32,
        dwFlags: TME_LEAVE,
        hwndTrack: hwnd,
        dwHoverTime: 0,
    };
    let _ = unsafe { TrackMouseEvent(&mut event) };
}

fn message_font(dpi: u32) -> HFONT {
    let mut metrics = NONCLIENTMETRICSW {
        cbSize: std::mem::size_of::<NONCLIENTMETRICSW>() as u32,
        ..Default::default()
    };
    let mut logfont = LOGFONTW::default();
    if unsafe {
        SystemParametersInfoW(
            SPI_GETNONCLIENTMETRICS,
            metrics.cbSize,
            Some((&raw mut metrics).cast()),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
    }
    .is_ok()
    {
        logfont = metrics.lfMessageFont;
    } else {
        // Extremely unlikely fallback: YaHei UI on Chinese Windows.
        let fallback = wide("Microsoft YaHei UI");
        logfont.lfFaceName[..fallback.len()].copy_from_slice(&fallback);
    }
    let primary = unsafe { GetDpiForSystem() }.max(96);
    let scale = f64::from(dpi) / f64::from(primary);
    logfont.lfHeight = (f64::from(logfont.lfHeight) * scale).round() as i32;
    unsafe { CreateFontIndirectW(&logfont) }
}

fn glyph_font(height: i32) -> HFONT {
    let name = wide("Segoe MDL2 Assets");
    unsafe {
        CreateFontW(
            -height,
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            (DEFAULT_PITCH.0 | FF_DONTCARE.0) as u32,
            PCWSTR(name.as_ptr()),
        )
    }
}

fn dark_mode_enabled() -> bool {
    let subkey = wide(APP_LIGHT_THEME_KEY);
    let mut key = HKEY_CURRENT_USER;
    let opened = unsafe {
        RegOpenKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            None,
            KEY_QUERY_VALUE,
            &mut key,
        )
    };
    if opened.is_err() {
        return false;
    }
    let name = wide(APP_LIGHT_THEME_VALUE);
    let mut value = 1_u32;
    let mut length = std::mem::size_of::<u32>() as u32;
    let result = unsafe {
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
    result.is_ok() && value == 0
}

fn system_accent() -> COLORREF {
    let mut color = 0_u32;
    let mut opaque = windows::core::BOOL::default();
    if unsafe { DwmGetColorizationColor(&raw mut color, &raw mut opaque) }.is_ok() {
        // The value is ARGB; COLORREF stores the RGB bytes in reverse order.
        return rgb(
            ((color >> 16) & 0xFF) as u8,
            ((color >> 8) & 0xFF) as u8,
            (color & 0xFF) as u8,
        );
    }
    rgb(0x00, 0x67, 0xC0)
}

fn theme_color(dark: bool, light: (u8, u8, u8), dark_value: (u8, u8, u8)) -> COLORREF {
    let (r, g, b) = if dark { dark_value } else { light };
    rgb(r, g, b)
}

fn rgb(r: u8, g: u8, b: u8) -> COLORREF {
    COLORREF(u32::from(r) | (u32::from(g) << 8) | (u32::from(b) << 16))
}
