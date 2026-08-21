use std::time::{Duration, Instant};

use crate::protocol::{MouseEntryEdge, MouseMoveSample};

pub const LEASE_DURATION: Duration = Duration::from_millis(400);

pub const LEFT_BOUNDARY: i32 = 0;

pub const RELEASE_BARRIER_STABLE_SAMPLES: usize = 3;
pub const RELEASE_BARRIER_POLL_INTERVAL: Duration = Duration::from_millis(1);
pub const RELEASE_BARRIER_CAP: Duration = Duration::from_millis(40);

pub fn entry_boundary(entry_edge: MouseEntryEdge, maximum_x: i32) -> i32 {
    match entry_edge {
        MouseEntryEdge::Left => LEFT_BOUNDARY,
        MouseEntryEdge::Right => maximum_x,
    }
}

pub fn entry_position(entry_edge: MouseEntryEdge, maximum_x: i32) -> i32 {
    match entry_edge {
        MouseEntryEdge::Left => (LEFT_BOUNDARY + 1).min(maximum_x),
        MouseEntryEdge::Right => maximum_x.saturating_sub(1).max(LEFT_BOUNDARY),
    }
}

pub fn moves_toward_entry_edge(entry_edge: MouseEntryEdge, dx: i16) -> bool {
    match entry_edge {
        MouseEntryEdge::Left => dx < 0,
        MouseEntryEdge::Right => dx > 0,
    }
}

// A release may not be confirmed while another button is still held, and it
// only makes sense at the session's entry edge after motion toward that edge.
pub fn should_leave_on_button_up(
    buttons_after: u8,
    cursor_x: i32,
    maximum_x: i32,
    entry_edge: MouseEntryEdge,
    recent_moved_toward_edge: bool,
) -> bool {
    buttons_after == 0
        && cursor_x == entry_boundary(entry_edge, maximum_x)
        && recent_moved_toward_edge
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReleaseVerdict {
    ConfirmLeave,
    ConfirmReleased,
    DriverUnavailable,
}

// A release may only be confirmed (MouseLeave/MouseReleased) after the
// teardown succeeded; otherwise the peer must be told the driver is
// unavailable so ownership never splits.
pub fn release_verdict(succeeded: bool, is_leave: bool) -> ReleaseVerdict {
    match (succeeded, is_leave) {
        (true, true) => ReleaseVerdict::ConfirmLeave,
        (true, false) => ReleaseVerdict::ConfirmReleased,
        (false, _) => ReleaseVerdict::DriverUnavailable,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BarrierPoll {
    Waiting,
    Stable,
    Expired,
}

// Detects that previously submitted reports stopped affecting the system
// cursor: position must stay identical across several consecutive polls
// before the monotonic cap is reached.
pub struct ReleaseBarrier {
    stable_needed: usize,
    cap: Duration,
    started: Instant,
    last: Option<(i32, i32)>,
    stable: usize,
}

impl ReleaseBarrier {
    pub fn new(stable_needed: usize, cap: Duration, now: Instant) -> Self {
        Self {
            stable_needed,
            cap,
            started: now,
            last: None,
            stable: 0,
        }
    }

    pub fn poll(&mut self, position: (i32, i32), now: Instant) -> BarrierPoll {
        if Some(position) == self.last {
            self.stable += 1;
            if self.stable >= self.stable_needed {
                return BarrierPoll::Stable;
            }
        } else {
            self.last = Some(position);
            self.stable = 0;
        }
        if now.duration_since(self.started) >= self.cap {
            return BarrierPoll::Expired;
        }
        BarrierPoll::Waiting
    }

    #[cfg(test)]
    #[allow(dead_code)]
    pub fn stable_samples(&self) -> usize {
        self.stable
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EdgeTriggerKind {
    Crossed,
    AtBoundary,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EdgeTrigger {
    pub kind: EdgeTriggerKind,
    pub previous_x: i32,
    pub proposed_x: i32,
    pub dx: i16,
    pub dy: i16,
}

// Authoritative cursor position in screen pixels, integrated from raw HID
// counts before injection. The driver reports absolute positions, which
// Windows applies verbatim (no pointer ballistics), so this tracker is the
// exact visible position and the only source of the edge decision.
pub struct LogicalCursor {
    x: i32,
    y: i32,
    maximum_x: i32,
    maximum_y: i32,
}

impl LogicalCursor {
    pub fn new(x: i32, y: i32, maximum_x: i32, maximum_y: i32) -> Self {
        Self {
            x: x.clamp(LEFT_BOUNDARY, maximum_x),
            y: y.clamp(0, maximum_y),
            maximum_x,
            maximum_y,
        }
    }

    pub fn x(&self) -> i32 {
        self.x
    }

    pub fn y(&self) -> i32 {
        self.y
    }

    pub fn maximum_x(&self) -> i32 {
        self.maximum_x
    }

    pub fn maximum_y(&self) -> i32 {
        self.maximum_y
    }

    pub fn advance(&mut self, dx: i16, dy: i16) -> (i32, i32) {
        self.x = self
            .x
            .saturating_add(i32::from(dx))
            .clamp(LEFT_BOUNDARY, self.maximum_x);
        self.y = self
            .y
            .saturating_add(i32::from(dy))
            .clamp(0, self.maximum_y);
        (self.x, self.y)
    }

    pub fn advance_batch(
        &mut self,
        samples: &[MouseMoveSample],
        detect_edge: bool,
        entry_edge: MouseEntryEdge,
    ) -> (Vec<(i32, i32)>, Option<EdgeTrigger>) {
        let mut positions = Vec::with_capacity(samples.len());
        for sample in samples {
            let previous_x = self.x;
            let proposed_x = previous_x.saturating_add(i32::from(sample.dx));
            positions.push(self.advance(sample.dx, sample.dy));
            let boundary = entry_boundary(entry_edge, self.maximum_x);
            let crossed = match entry_edge {
                MouseEntryEdge::Left => previous_x > boundary && proposed_x <= boundary,
                MouseEntryEdge::Right => previous_x < boundary && proposed_x >= boundary,
            };
            if detect_edge && crossed {
                return (
                    positions,
                    Some(EdgeTrigger {
                        kind: EdgeTriggerKind::Crossed,
                        previous_x,
                        proposed_x,
                        dx: sample.dx,
                        dy: sample.dy,
                    }),
                );
            }
            if detect_edge
                && previous_x == boundary
                && moves_toward_entry_edge(entry_edge, sample.dx)
            {
                return (
                    positions,
                    Some(EdgeTrigger {
                        kind: EdgeTriggerKind::AtBoundary,
                        previous_x,
                        proposed_x,
                        dx: sample.dx,
                        dy: sample.dy,
                    }),
                );
            }
        }
        (positions, None)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EnterOutcome {
    pub control_id: u64,
    pub replaced: Option<u64>,
    pub already_active: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReleaseOutcome {
    Released(u64),
    ReAck(u64),
    Stale,
}

#[derive(Clone, Copy)]
struct ControlSession {
    control_id: u64,
    entry_edge: MouseEntryEdge,
    lease_expiry: Instant,
}

#[derive(Default)]
pub struct MouseControl {
    active: Option<ControlSession>,
    last_released: Option<u64>,
}

impl MouseControl {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn active_control_id(&self) -> Option<u64> {
        self.active.map(|session| session.control_id)
    }

    pub fn active_entry_edge(&self) -> Option<MouseEntryEdge> {
        self.active.map(|session| session.entry_edge)
    }

    pub fn lease_deadline(&self) -> Option<Instant> {
        self.active.map(|session| session.lease_expiry)
    }

    pub fn enter(
        &mut self,
        control_id: u64,
        entry_edge: MouseEntryEdge,
        now: Instant,
    ) -> Result<EnterOutcome, String> {
        if self.active.is_some_and(|session| {
            session.control_id == control_id && session.entry_edge != entry_edge
        }) {
            return Err("active mouse control id changed entry edge".to_string());
        }
        let session = ControlSession {
            control_id,
            entry_edge,
            lease_expiry: now + LEASE_DURATION,
        };
        let previous = self.active.replace(session);
        // A new acquisition closes the previous release cycle: from now on the
        // old controlID is stale and its ReleaseAll must be ignored, not re-acked.
        self.last_released = None;
        match previous {
            Some(old) if old.control_id == control_id => Ok(EnterOutcome {
                control_id,
                replaced: None,
                already_active: true,
            }),
            Some(old) => Ok(EnterOutcome {
                control_id,
                replaced: Some(old.control_id),
                already_active: false,
            }),
            None => Ok(EnterOutcome {
                control_id,
                replaced: None,
                already_active: false,
            }),
        }
    }

    pub fn accept(&mut self, control_id: u64, now: Instant) -> bool {
        let Some(session) = self
            .active
            .as_mut()
            .filter(|session| session.control_id == control_id)
        else {
            return false;
        };
        session.lease_expiry = now + LEASE_DURATION;
        true
    }

    pub fn release_all(&mut self, control_id: u64) -> ReleaseOutcome {
        if self
            .active
            .is_some_and(|session| session.control_id == control_id)
        {
            self.active = None;
            self.last_released = Some(control_id);
            ReleaseOutcome::Released(control_id)
        } else if self.last_released == Some(control_id) {
            ReleaseOutcome::ReAck(control_id)
        } else {
            ReleaseOutcome::Stale
        }
    }

    pub fn expire_lease(&mut self, now: Instant) -> Option<u64> {
        let session = self.active?;
        if now < session.lease_expiry {
            return None;
        }
        self.active = None;
        self.last_released = Some(session.control_id);
        Some(session.control_id)
    }

    pub fn leave(&mut self, control_id: u64) -> bool {
        if self
            .active
            .is_some_and(|session| session.control_id == control_id)
        {
            self.active = None;
            self.last_released = Some(control_id);
            true
        } else {
            false
        }
    }

    pub fn clear(&mut self) -> Option<u64> {
        let session = self.active.take()?;
        self.last_released = Some(session.control_id);
        Some(session.control_id)
    }
}
