use std::time::{Duration, Instant};

pub const RELEASE_BARRIER_STABLE_SAMPLES: usize = 3;
pub const RELEASE_BARRIER_POLL_INTERVAL: Duration = Duration::from_millis(1);
pub const RELEASE_BARRIER_CAP: Duration = Duration::from_millis(40);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BarrierPoll {
    Waiting,
    Stable,
    Expired,
}

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
            BarrierPoll::Expired
        } else {
            BarrierPoll::Waiting
        }
    }

    #[cfg(test)]
    #[allow(dead_code)]
    pub fn stable_samples(&self) -> usize {
        self.stable
    }
}
