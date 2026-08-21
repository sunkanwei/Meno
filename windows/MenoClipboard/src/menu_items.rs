use crate::menu_model::MenuModel;
use crate::tray::{
    COMMAND_AGENT_SETTINGS, COMMAND_CLEAR_LOG, COMMAND_CURSOR_THEME, COMMAND_EXIT,
    COMMAND_INSTALL_AUDIO_DRIVER, COMMAND_PAUSE, COMMAND_REDISCOVER, COMMAND_REPAIR_DRIVER,
    COMMAND_STARTUP, COMMAND_VB_CABLE_WEBSITE, COMMAND_VIEW_LOG,
};

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
    pub(crate) label: Vec<u16>,
    pub(crate) glyph: Option<u16>,
    pub(crate) checked: bool,
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

pub(crate) fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}
