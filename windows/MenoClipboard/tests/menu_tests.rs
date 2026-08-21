#![allow(dead_code)]

// Minimal crate-root stubs for the production module's command IDs and
// logging. The tests exercise only its pure model/navigation behavior.
mod tray {
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
}

mod logging {
    pub fn error(_message: &str) {}
}

#[path = "../src/menu.rs"]
mod menu;
#[path = "../src/menu_items.rs"]
mod menu_items;
#[path = "../src/menu_model.rs"]
mod menu_model;

fn model(connected: bool, paused: bool, suspended: bool) -> menu::MenuModel {
    menu::MenuModel::new(
        if connected {
            "已连接 Mac".to_string()
        } else {
            "正在查找 Mac".to_string()
        },
        connected,
        paused,
        suspended,
        false,
        false,
    )
    .with_agent_status("运行中".to_owned())
}

#[test]
fn connected_status_includes_audio_detail_without_changing_navigation() {
    assert_eq!(
        menu::connected_status_text("已连接 Mac", Some("麦克风可用")),
        "已连接 Mac · 麦克风可用"
    );
    assert_eq!(
        menu::connected_status_text("已连接 Mac", None),
        "已连接 Mac"
    );
    let connected = menu::MenuModel::new(
        "已连接 Mac · 麦克风可用".to_string(),
        true,
        false,
        false,
        false,
        false,
    )
    .with_agent_status("运行中".to_owned());
    assert_eq!(connected.status_text, "已连接 Mac · 麦克风可用");
    let items = menu::build_items(&connected);
    assert!(!items[0].kind.actionable());
}

#[test]
fn status_header_is_short_and_state_consistent() {
    let connected = model(true, false, false);
    assert_eq!(connected.status_text, "已连接 Mac");
    assert!(connected.status == menu::StatusKind::Connected);

    let paused = model(true, true, false);
    assert_eq!(paused.status_text, "已暂停");
    assert!(paused.status == menu::StatusKind::Paused);

    let suspended = model(true, false, true);
    assert_eq!(suspended.status_text, "系统休眠");
    assert!(suspended.status == menu::StatusKind::Paused);
}

#[test]
fn keyboard_navigation_wraps_and_skips_inert_rows() {
    let items = menu::build_items(&model(false, false, false));
    let actionable: Vec<usize> = items
        .iter()
        .enumerate()
        .filter_map(|(index, item)| item.kind.actionable().then_some(index))
        .collect();
    let first = actionable[0];
    let last = *actionable.last().unwrap();

    assert_eq!(menu::next_actionable(&items, None, 1), Some(first));
    assert_eq!(menu::next_actionable(&items, None, -1), Some(last));
    assert_eq!(menu::next_actionable(&items, Some(last), 1), Some(first));
    assert_eq!(menu::next_actionable(&items, Some(first), -1), Some(last));
    assert!(
        items
            .iter()
            .filter(|item| !item.kind.actionable())
            .all(|item| item.id == 0)
    );
}

#[test]
fn menu_exposes_audio_driver_installation_and_donation_links() {
    let items = menu::build_items(&model(false, false, false));
    assert!(
        items
            .iter()
            .any(|item| item.id == tray::COMMAND_INSTALL_AUDIO_DRIVER)
    );
    assert!(
        items
            .iter()
            .any(|item| item.id == tray::COMMAND_VB_CABLE_WEBSITE)
    );
}

#[test]
fn menu_exposes_the_embedded_agent_without_a_second_tray() {
    let items = menu::build_items(&model(false, false, false));
    assert!(
        items
            .iter()
            .any(|item| item.id == tray::COMMAND_AGENT_SETTINGS)
    );
}

#[test]
fn application_manifest_enables_common_controls_v6() {
    let manifest = include_str!("../assets/MenoClipboard.manifest");
    assert!(manifest.contains("Microsoft.Windows.Common-Controls"));
    assert!(manifest.contains("version=\"6.0.0.0\""));
}
