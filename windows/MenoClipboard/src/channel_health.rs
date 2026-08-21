use std::time::{Duration, Instant};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_BEFORE_PING: Duration = Duration::from_secs(30);
const PONG_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum HealthAction {
    Wait,
    SendPing,
    TimedOut,
}

pub(crate) struct ChannelHealth {
    pub(crate) ready: bool,
    pub(crate) connected_at: Instant,
    pub(crate) last_activity: Instant,
    pub(crate) ping_sent: Option<Instant>,
}

impl ChannelHealth {
    pub(crate) fn new() -> Self {
        let now = Instant::now();
        Self {
            ready: false,
            connected_at: now,
            last_activity: now,
            ping_sent: None,
        }
    }

    pub(crate) fn deadline(&self) -> Instant {
        if !self.ready {
            self.connected_at + HANDSHAKE_TIMEOUT
        } else if let Some(sent) = self.ping_sent {
            sent + PONG_TIMEOUT
        } else {
            self.last_activity + IDLE_BEFORE_PING
        }
    }

    pub(crate) fn action(&self, now: Instant) -> HealthAction {
        if now < self.deadline() {
            HealthAction::Wait
        } else if self.ready && self.ping_sent.is_none() {
            HealthAction::SendPing
        } else {
            HealthAction::TimedOut
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handshake_idle_and_pong_deadlines_share_one_state_machine() {
        let connected_at = Instant::now();
        let mut health = ChannelHealth {
            ready: false,
            connected_at,
            last_activity: connected_at,
            ping_sent: None,
        };
        assert_eq!(
            health.action(connected_at + HANDSHAKE_TIMEOUT),
            HealthAction::TimedOut
        );

        health.ready = true;
        health.last_activity = connected_at;
        assert_eq!(
            health.action(connected_at + IDLE_BEFORE_PING),
            HealthAction::SendPing
        );

        health.ping_sent = Some(connected_at + IDLE_BEFORE_PING);
        assert_eq!(
            health.action(connected_at + IDLE_BEFORE_PING + PONG_TIMEOUT),
            HealthAction::TimedOut
        );
    }
}
