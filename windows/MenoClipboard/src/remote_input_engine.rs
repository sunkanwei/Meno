use std::collections::VecDeque;
use std::time::{Duration, Instant};

use crate::protocol::{KeyboardState, MouseEnterV2, MouseEntryEdge, MouseMoveSample};

pub const LEASE_DURATION: Duration = Duration::from_millis(400);
const EVENT_HISTORY_CAPACITY: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EngineState {
    Idle,
    Acquiring,
    Remote,
    Releasing,
    Faulted,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SessionKey {
    pub control_id: u64,
    pub route_id: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReleaseReason {
    EdgeCrossed,
    ButtonReleasedAtEdge,
    PeerRelease,
    LeaseExpired,
    DisplayChanged,
    Disconnected,
    Stopped,
    Replaced,
    HidFailed,
    QueueOverflow,
}

impl ReleaseReason {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::EdgeCrossed => "edge-crossed",
            Self::ButtonReleasedAtEdge => "button-up-edge",
            Self::PeerRelease => "peer-release",
            Self::LeaseExpired => "lease-expired",
            Self::DisplayChanged => "display-changed",
            Self::Disconnected => "disconnected",
            Self::Stopped => "stopped",
            Self::Replaced => "replaced",
            Self::HidFailed => "hid-failed",
            Self::QueueOverflow => "queue-overflow",
        }
    }

    fn confirms_peer(self) -> bool {
        !matches!(
            self,
            Self::Disconnected | Self::Stopped | Self::HidFailed | Self::QueueOverflow
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Event {
    Enter {
        generation: u64,
        request: MouseEnterV2,
        width: u32,
        height: u32,
        now: Instant,
    },
    Move {
        control_id: u64,
        samples: Vec<MouseMoveSample>,
        now: Instant,
    },
    Button {
        control_id: u64,
        button: u8,
        down: bool,
        now: Instant,
    },
    Wheel {
        control_id: u64,
        lines: i32,
        now: Instant,
    },
    Keyboard {
        control_id: u64,
        state: KeyboardState,
        now: Instant,
    },
    Heartbeat {
        control_id: u64,
        now: Instant,
    },
    Release {
        control_id: u64,
        reason: ReleaseReason,
    },
    LeaseExpired {
        now: Instant,
    },
    DisplayChanged,
    HidAcquireSucceeded,
    HidAcquireFailed,
    ReleaseCompleted {
        succeeded: bool,
    },
    QueueOverflow,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Effect {
    PrepareHid {
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
    },
    Pointer {
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
        buttons: u8,
        critical: bool,
    },
    Wheel {
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
        buttons: u8,
        lines: i32,
    },
    Keyboard(KeyboardState),
    Neutralize {
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
    },
    CursorVisible(bool),
    SendAcquired(SessionKey),
    SendLeave {
        key: SessionKey,
        normalized_y: u16,
    },
    SendReleased(SessionKey),
    SendDriverUnavailable,
    ScheduleLease(Instant),
    LogEnter(String),
    LogEdge(String),
    LogEnd(String),
    DumpFault(Vec<String>),
    CloseChannel,
}

#[derive(Clone, Debug)]
struct ActiveSession {
    generation: u64,
    key: SessionKey,
    entry_edge: MouseEntryEdge,
    entry_y: i32,
    opening_lower_y: i32,
    opening_upper_y: i32,
    maximum_x: i32,
    maximum_y: i32,
    x: i32,
    y: i32,
    buttons: u8,
    keyboard: KeyboardState,
    lease_deadline: Instant,
    started: Instant,
    release_reason: Option<ReleaseReason>,
    leave_y: Option<u16>,
    recent_outward: bool,
    queue_high_water: usize,
    hid_result: &'static str,
    history: VecDeque<String>,
}

impl ActiveSession {
    fn from_enter(
        generation: u64,
        request: MouseEnterV2,
        width: u32,
        height: u32,
        now: Instant,
    ) -> Result<Self, ()> {
        let width = i32::try_from(width)
            .ok()
            .filter(|value| *value > 1)
            .ok_or(())?;
        let height = i32::try_from(height)
            .ok()
            .filter(|value| *value > 0)
            .ok_or(())?;
        let maximum_x = width - 1;
        let maximum_y = height - 1;
        let convert = |value: u16| ((u64::from(value) * maximum_y as u64 + 32_767) / 65_535) as i32;
        let y = convert(request.normalized_y);
        let opening_lower_y = convert(request.opening_lower_y);
        let opening_upper_y = convert(request.opening_upper_y);
        let x = inner_wall(request.entry_edge, maximum_x);
        let mut history = VecDeque::with_capacity(EVENT_HISTORY_CAPACITY);
        history.push_back(format!(
            "enter controlID={} routeID={} generation={generation} edge={} y={y} opening={opening_lower_y}..{opening_upper_y}",
            request.control_id,
            request.route_id,
            edge_name(request.entry_edge)
        ));
        Ok(Self {
            generation,
            key: SessionKey {
                control_id: request.control_id,
                route_id: request.route_id,
            },
            entry_edge: request.entry_edge,
            entry_y: y,
            opening_lower_y,
            opening_upper_y,
            maximum_x,
            maximum_y,
            x,
            y,
            buttons: 0,
            keyboard: KeyboardState {
                modifiers: 0,
                keys: Vec::new(),
            },
            lease_deadline: now + LEASE_DURATION,
            started: now,
            release_reason: None,
            leave_y: None,
            recent_outward: false,
            queue_high_water: 0,
            hid_result: "pending",
            history,
        })
    }

    fn in_opening(&self) -> bool {
        (self.opening_lower_y..=self.opening_upper_y).contains(&self.y)
    }

    fn push_history(&mut self, value: String) {
        if self.history.len() == EVENT_HISTORY_CAPACITY {
            self.history.pop_front();
        }
        self.history.push_back(value);
    }

    fn summary(&self, now: Instant) -> String {
        format!(
            "mouse route end: controlID={} routeID={} durationMs={} reason={} edge={} final={},{} opening={}..{} buttons={} queueHighWater={} hid={}",
            self.key.control_id,
            self.key.route_id,
            now.saturating_duration_since(self.started).as_millis(),
            self.release_reason
                .unwrap_or(ReleaseReason::Stopped)
                .as_str(),
            edge_name(self.entry_edge),
            self.x,
            self.y,
            self.opening_lower_y,
            self.opening_upper_y,
            self.buttons,
            self.queue_high_water,
            self.hid_result,
        )
    }
}

pub struct RemoteInputEngine {
    state: EngineState,
    active: Option<ActiveSession>,
    pending_enter: Option<ActiveSession>,
    last_released: Option<SessionKey>,
}

impl Default for RemoteInputEngine {
    fn default() -> Self {
        Self {
            state: EngineState::Idle,
            active: None,
            pending_enter: None,
            last_released: None,
        }
    }
}

impl RemoteInputEngine {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn state(&self) -> EngineState {
        self.state
    }
    pub fn lease_deadline(&self) -> Option<Instant> {
        self.active.as_ref().map(|s| s.lease_deadline)
    }
    pub fn active_key(&self) -> Option<SessionKey> {
        self.active.as_ref().map(|s| s.key)
    }
    pub fn observe_queue_high_water(&mut self, value: usize) {
        if let Some(active) = self.active.as_mut() {
            active.queue_high_water = active.queue_high_water.max(value);
        }
    }

    pub fn reduce(&mut self, event: Event) -> Vec<Effect> {
        match event {
            Event::Enter {
                generation,
                request,
                width,
                height,
                now,
            } => self.enter(generation, request, width, height, now),
            Event::Move {
                control_id,
                samples,
                now,
            } => self.move_samples(control_id, &samples, now),
            Event::Button {
                control_id,
                button,
                down,
                now,
            } => self.button(control_id, button, down, now),
            Event::Wheel {
                control_id,
                lines,
                now,
            } => self.wheel(control_id, lines, now),
            Event::Keyboard {
                control_id,
                state,
                now,
            } => self.keyboard(control_id, state, now),
            Event::Heartbeat { control_id, now } => self.refresh(control_id, now),
            Event::Release { control_id, reason } => self.release_by_id(control_id, reason),
            Event::LeaseExpired { now } => {
                if self
                    .active
                    .as_ref()
                    .is_some_and(|s| now >= s.lease_deadline)
                {
                    self.begin_release(ReleaseReason::LeaseExpired, None)
                } else {
                    Vec::new()
                }
            }
            Event::DisplayChanged => self.begin_release(ReleaseReason::DisplayChanged, None),
            Event::HidAcquireSucceeded => self.acquire_succeeded(),
            Event::HidAcquireFailed => self.acquire_failed(),
            Event::ReleaseCompleted { succeeded } => self.release_completed(succeeded),
            Event::QueueOverflow => self.begin_release(ReleaseReason::QueueOverflow, None),
        }
    }

    fn enter(
        &mut self,
        generation: u64,
        request: MouseEnterV2,
        width: u32,
        height: u32,
        now: Instant,
    ) -> Vec<Effect> {
        let Ok(session) = ActiveSession::from_enter(generation, request, width, height, now) else {
            self.state = EngineState::Faulted;
            return vec![Effect::CursorVisible(false), Effect::CloseChannel];
        };
        if self.state == EngineState::Faulted {
            return vec![Effect::CloseChannel];
        }
        if let Some(active) = self.active.as_mut() {
            if active.key == session.key {
                if active.generation != generation
                    || active.entry_edge != session.entry_edge
                    || active.opening_lower_y != session.opening_lower_y
                    || active.opening_upper_y != session.opening_upper_y
                {
                    active.push_history("duplicate enter changed frozen contract".to_string());
                    let dump = active.history.iter().cloned().collect();
                    self.state = EngineState::Faulted;
                    return vec![Effect::DumpFault(dump), Effect::CloseChannel];
                }
                active.lease_deadline = now + LEASE_DURATION;
                return if self.state == EngineState::Remote {
                    vec![
                        Effect::SendAcquired(active.key),
                        Effect::ScheduleLease(active.lease_deadline),
                    ]
                } else {
                    Vec::new()
                };
            }
            self.pending_enter = Some(session);
            return self.begin_release(ReleaseReason::Replaced, None);
        }
        self.start_acquire(session)
    }

    fn start_acquire(&mut self, session: ActiveSession) -> Vec<Effect> {
        let key = session.key;
        let summary = format!(
            "mouse route enter: controlID={} routeID={} edge={} entryY={} opening={}..{} screen={}x{}",
            key.control_id,
            key.route_id,
            edge_name(session.entry_edge),
            session.entry_y,
            session.opening_lower_y,
            session.opening_upper_y,
            session.maximum_x + 1,
            session.maximum_y + 1
        );
        let effect = Effect::PrepareHid {
            x: session.x,
            y: session.y,
            maximum_x: session.maximum_x,
            maximum_y: session.maximum_y,
        };
        self.active = Some(session);
        self.last_released = None;
        self.state = EngineState::Acquiring;
        vec![
            Effect::CursorVisible(false),
            effect,
            Effect::LogEnter(summary),
        ]
    }

    fn acquire_succeeded(&mut self) -> Vec<Effect> {
        if self.state != EngineState::Acquiring {
            return Vec::new();
        }
        let Some(session) = self.active.as_mut() else {
            return Vec::new();
        };
        session.hid_result = "ok";
        session.push_history("acquired".to_string());
        self.state = EngineState::Remote;
        vec![
            Effect::CursorVisible(true),
            Effect::SendAcquired(session.key),
            Effect::ScheduleLease(session.lease_deadline),
        ]
    }

    fn acquire_failed(&mut self) -> Vec<Effect> {
        let history = self
            .active
            .as_mut()
            .map(|s| {
                s.hid_result = "failed";
                s.release_reason = Some(ReleaseReason::HidFailed);
                s.push_history("initial HID failed".to_string());
                s.history.iter().cloned().collect()
            })
            .unwrap_or_default();
        self.state = EngineState::Faulted;
        vec![
            Effect::CursorVisible(false),
            Effect::SendDriverUnavailable,
            Effect::DumpFault(history),
            Effect::CloseChannel,
        ]
    }

    fn refresh(&mut self, control_id: u64, now: Instant) -> Vec<Effect> {
        let Some(session) = self
            .active
            .as_mut()
            .filter(|s| s.key.control_id == control_id && self.state == EngineState::Remote)
        else {
            return Vec::new();
        };
        session.lease_deadline = now + LEASE_DURATION;
        vec![Effect::ScheduleLease(session.lease_deadline)]
    }

    fn move_samples(
        &mut self,
        control_id: u64,
        samples: &[MouseMoveSample],
        now: Instant,
    ) -> Vec<Effect> {
        if self.state != EngineState::Remote
            || self
                .active
                .as_ref()
                .is_none_or(|s| s.key.control_id != control_id)
        {
            return Vec::new();
        }
        let mut effects = self.refresh(control_id, now);
        for sample in samples {
            let mut release_y = None;
            {
                let Some(session) = self.active.as_mut() else {
                    break;
                };
                let previous_x = session.x;
                let proposed_x = previous_x.saturating_add(i32::from(sample.dx));
                session.y = session
                    .y
                    .saturating_add(i32::from(sample.dy))
                    .clamp(0, session.maximum_y);
                let toward = moves_outward(session.entry_edge, sample.dx);
                if sample.dx != 0 {
                    session.recent_outward = toward;
                }
                let crosses = match session.entry_edge {
                    MouseEntryEdge::Left => proposed_x <= 0,
                    MouseEntryEdge::Right => proposed_x >= session.maximum_x,
                };
                if crosses && toward {
                    if session.in_opening() {
                        session.x = boundary(session.entry_edge, session.maximum_x);
                        effects.push(pointer_effect(session, false));
                        if session.buttons == 0 {
                            effects.push(Effect::LogEdge(format!(
                                "mouse edge: controlID={} routeID={} trigger={} previousX={} proposedX={} final={},{} opening={}..{} buttons={}",
                                session.key.control_id, session.key.route_id,
                                if previous_x == session.x { "boundary-outward" } else { "crossed" },
                                previous_x, proposed_x, session.x, session.y,
                                session.opening_lower_y, session.opening_upper_y, session.buttons
                            )));
                            release_y = Some(normalize_y(session.y, session.maximum_y));
                        }
                    } else {
                        session.x = inner_wall(session.entry_edge, session.maximum_x);
                    }
                } else {
                    session.x = proposed_x.clamp(0, session.maximum_x);
                }
                if release_y.is_none() {
                    effects.push(pointer_effect(session, false));
                }
            }
            if let Some(normalized_y) = release_y {
                effects.extend(self.begin_release(ReleaseReason::EdgeCrossed, Some(normalized_y)));
                break;
            }
        }
        effects
    }

    fn button(&mut self, control_id: u64, button: u8, down: bool, now: Instant) -> Vec<Effect> {
        if self.state != EngineState::Remote
            || self
                .active
                .as_ref()
                .is_none_or(|s| s.key.control_id != control_id)
        {
            return Vec::new();
        }
        let mut effects = self.refresh(control_id, now);
        let Some(session) = self.active.as_mut() else {
            return effects;
        };
        let mask = match button {
            1 => 1,
            2 => 2,
            3 => 4,
            _ => return effects,
        };
        if down {
            session.buttons |= mask;
        } else {
            session.buttons &= !mask;
        }
        effects.push(pointer_effect(session, true));
        if !down
            && session.buttons == 0
            && session.in_opening()
            && session.x == boundary(session.entry_edge, session.maximum_x)
            && session.recent_outward
        {
            let leave_y = normalize_y(session.y, session.maximum_y);
            effects.extend(self.begin_release(ReleaseReason::ButtonReleasedAtEdge, Some(leave_y)));
        }
        effects
    }

    fn wheel(&mut self, control_id: u64, lines: i32, now: Instant) -> Vec<Effect> {
        if self.state != EngineState::Remote
            || lines == 0
            || self
                .active
                .as_ref()
                .is_none_or(|s| s.key.control_id != control_id)
        {
            return Vec::new();
        }
        let mut effects = self.refresh(control_id, now);
        let session = self.active.as_ref().unwrap();
        effects.push(Effect::Wheel {
            x: session.x,
            y: session.y,
            maximum_x: session.maximum_x,
            maximum_y: session.maximum_y,
            buttons: session.buttons,
            lines,
        });
        effects
    }

    fn keyboard(&mut self, control_id: u64, state: KeyboardState, now: Instant) -> Vec<Effect> {
        if self.state != EngineState::Remote
            || self
                .active
                .as_ref()
                .is_none_or(|s| s.key.control_id != control_id)
        {
            return Vec::new();
        }
        let mut effects = self.refresh(control_id, now);
        self.active.as_mut().unwrap().keyboard = state.clone();
        effects.push(Effect::Keyboard(state));
        effects
    }

    fn release_by_id(&mut self, control_id: u64, reason: ReleaseReason) -> Vec<Effect> {
        if self
            .active
            .as_ref()
            .is_some_and(|s| s.key.control_id == control_id)
        {
            return self.begin_release(reason, None);
        }
        if reason == ReleaseReason::PeerRelease
            && let Some(key) = self
                .last_released
                .filter(|key| key.control_id == control_id)
        {
            return vec![Effect::SendReleased(key)];
        }
        Vec::new()
    }

    fn begin_release(&mut self, reason: ReleaseReason, leave_y: Option<u16>) -> Vec<Effect> {
        if !matches!(self.state, EngineState::Acquiring | EngineState::Remote) {
            return Vec::new();
        }
        let Some(session) = self.active.as_mut() else {
            return Vec::new();
        };
        session.release_reason = Some(reason);
        session.leave_y = leave_y;
        session.push_history(format!("release reason={}", reason.as_str()));
        self.state = EngineState::Releasing;
        vec![Effect::Neutralize {
            x: session.x,
            y: session.y,
            maximum_x: session.maximum_x,
            maximum_y: session.maximum_y,
        }]
    }

    fn release_completed(&mut self, succeeded: bool) -> Vec<Effect> {
        if self.state != EngineState::Releasing {
            return Vec::new();
        }
        let Some(mut session) = self.active.take() else {
            return Vec::new();
        };
        session.hid_result = if succeeded { "ok" } else { "failed" };
        let mut effects = vec![Effect::CursorVisible(false)];
        if succeeded {
            let reason = session.release_reason.unwrap_or(ReleaseReason::Stopped);
            if matches!(
                reason,
                ReleaseReason::HidFailed | ReleaseReason::QueueOverflow
            ) {
                session.push_history(format!(
                    "fail closed after successful neutralize reason={}",
                    reason.as_str()
                ));
                effects.push(Effect::DumpFault(session.history.iter().cloned().collect()));
                effects.push(Effect::SendDriverUnavailable);
                effects.push(Effect::CloseChannel);
                self.state = EngineState::Faulted;
                return effects;
            }
            if reason.confirms_peer() {
                if let Some(normalized_y) = session.leave_y {
                    effects.push(Effect::SendLeave {
                        key: session.key,
                        normalized_y,
                    });
                } else {
                    effects.push(Effect::SendReleased(session.key));
                }
            }
            self.last_released = Some(session.key);
            effects.push(Effect::LogEnd(session.summary(Instant::now())));
            self.state = EngineState::Idle;
            if let Some(next) = self.pending_enter.take() {
                effects.extend(self.start_acquire(next));
            }
        } else {
            session.push_history("release HID barrier failed".to_string());
            effects.push(Effect::DumpFault(session.history.iter().cloned().collect()));
            effects.push(Effect::SendDriverUnavailable);
            effects.push(Effect::CloseChannel);
            self.state = EngineState::Faulted;
        }
        effects
    }
}

fn edge_name(edge: MouseEntryEdge) -> &'static str {
    match edge {
        MouseEntryEdge::Left => "left",
        MouseEntryEdge::Right => "right",
    }
}
fn boundary(edge: MouseEntryEdge, maximum_x: i32) -> i32 {
    match edge {
        MouseEntryEdge::Left => 0,
        MouseEntryEdge::Right => maximum_x,
    }
}
fn inner_wall(edge: MouseEntryEdge, maximum_x: i32) -> i32 {
    match edge {
        MouseEntryEdge::Left => 1.min(maximum_x),
        MouseEntryEdge::Right => maximum_x.saturating_sub(1),
    }
}
fn moves_outward(edge: MouseEntryEdge, dx: i16) -> bool {
    match edge {
        MouseEntryEdge::Left => dx < 0,
        MouseEntryEdge::Right => dx > 0,
    }
}
fn normalize_y(y: i32, maximum_y: i32) -> u16 {
    let maximum = i64::from(maximum_y.max(1));
    ((i64::from(y) * 65_535 + maximum / 2) / maximum) as u16
}
fn pointer_effect(session: &ActiveSession, critical: bool) -> Effect {
    Effect::Pointer {
        x: session.x,
        y: session.y,
        maximum_x: session.maximum_x,
        maximum_y: session.maximum_y,
        buttons: session.buttons,
        critical,
    }
}
