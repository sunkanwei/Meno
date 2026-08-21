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
