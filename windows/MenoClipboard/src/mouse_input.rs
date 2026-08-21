use std::collections::VecDeque;
use std::thread;
use std::time::Instant;
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

use crate::diagnostics::{DiagnosticMotionSample, MAX_RECENT_MOTION_SAMPLES};
use crate::hid_writer::HidWriter;
use crate::mouse_control::{
    BarrierPoll, EdgeTriggerKind, LogicalCursor, RELEASE_BARRIER_CAP,
    RELEASE_BARRIER_POLL_INTERVAL, RELEASE_BARRIER_STABLE_SAMPLES, ReleaseBarrier, entry_boundary,
    entry_position, moves_toward_entry_edge, should_leave_on_button_up,
};
use crate::protocol::{KeyboardState, MouseEntryEdge, MouseMoveSample};
use crate::virtual_hid::{ABSOLUTE_MAXIMUM, DRIVER_ABI, HidReport, MAXIMUM_BATCH};

const LEFT_BUTTON: u8 = 1;
const RIGHT_BUTTON: u8 = 2;
const MIDDLE_BUTTON: u8 = 3;

#[derive(Clone, Debug)]
pub struct LeaveInfo {
    pub normalized_y: u16,
    pub entry_edge: MouseEntryEdge,
    pub boundary: i32,
    pub previous_x: i32,
    pub proposed_x: i32,
    pub dx: i16,
    pub cursor_x: i32,
    pub cursor_y: i32,
    pub dy: i16,
    pub condition: &'static str,
    pub injected: usize,
    pub total: usize,
    pub queue_depth: u32,
    pub recent_motion_samples: Vec<DiagnosticMotionSample>,
}

#[derive(Clone, Copy, Debug)]
struct ObservedMotionSample {
    observed_at: Instant,
    cursor_x: i32,
    cursor_y: i32,
    delta_x: i16,
    delta_y: i16,
}

#[derive(Clone, Debug)]
pub enum InputOutcome {
    Applied,
    Leaving(LeaveInfo),
    DriverFailed,
}

#[derive(Clone, Copy, Debug)]
pub struct ReleaseReport {
    pub reset_ok: bool,
    pub second_reset: bool,
    pub barrier_us: u128,
    pub stable_samples: usize,
    pub stable: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct InputStats {
    pub logical_samples: u64,
    pub hid_calls: u64,
    pub hid_move_calls: u64,
    pub hid_max_us: u128,
    pub hid_queue_max_us: u128,
    pub hid_queue_high: usize,
    pub hid_coalesced_moves: u64,
    pub hid_dropped_moves: u64,
    pub hid_timeouts: u64,
}

pub struct MouseInputController {
    writer: HidWriter,
    driver_error: Option<String>,
    observed_faults: u64,
    dirty: bool,
    pressed_buttons: u8,
    active: bool,
    cursor: Option<LogicalCursor>,
    recent_moved_toward_edge: bool,
    recent_motion_samples: VecDeque<ObservedMotionSample>,
    stats: InputStats,
}

impl MouseInputController {
    pub fn new() -> Self {
        let writer = HidWriter::start();
        let status = writer.status();
        Self {
            writer,
            driver_error: if status.available {
                None
            } else {
                status.last_error.clone()
            },
            observed_faults: status.faults,
            dirty: false,
            pressed_buttons: 0,
            active: false,
            cursor: None,
            recent_moved_toward_edge: false,
            recent_motion_samples: VecDeque::with_capacity(MAX_RECENT_MOTION_SAMPLES),
            stats: InputStats::default(),
        }
    }

    pub fn driver_available(&self) -> bool {
        self.writer.status().available
    }

    pub fn driver_abi(&self) -> u16 {
        if self.driver_available() {
            DRIVER_ABI
        } else {
            0
        }
    }

    pub fn driver_error(&self) -> Option<&str> {
        self.driver_error.as_deref()
    }

    pub fn ensure_driver_available(&mut self) -> Result<(), String> {
        let status = self.writer.status();
        if !status.available {
            let error = status
                .last_error
                .unwrap_or_else(|| "Meno Virtual Mouse is unavailable".to_string());
            self.disable_driver(error.clone());
            return Err(error);
        }
        if self.active && status.faults != self.observed_faults {
            self.observed_faults = status.faults;
            let error = "Meno HID writer recovered after a runtime failure; the active input session was discarded".to_string();
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.observed_faults = status.faults;
        self.driver_error = None;
        Ok(())
    }

    pub fn begin_session(
        &mut self,
        normalized_y: u16,
        entry_edge: MouseEntryEdge,
        screen_width: u32,
        screen_height: u32,
    ) -> Result<(), String> {
        let width = i32::try_from(screen_width)
            .ok()
            .filter(|value| *value > 1)
            .ok_or_else(|| "invalid mouse target width".to_string())?;
        let height = i32::try_from(screen_height)
            .ok()
            .filter(|value| *value > 0)
            .ok_or_else(|| "invalid mouse target height".to_string())?;
        let y = ((u64::from(normalized_y) * (height as u64 - 1) + 32767) / 65535) as i32;
        let maximum_x = width - 1;
        let cursor = LogicalCursor::new(
            entry_position(entry_edge, maximum_x),
            y,
            maximum_x,
            height - 1,
        );
        self.ensure_driver_available()?;
        // Absolute mode places the cursor exactly; no SetCursorPos, no ballistics.
        let report = HidReport {
            x: to_hid(cursor.x(), width - 1),
            y: to_hid(cursor.y(), height - 1),
            wheel: 0,
            buttons: 0,
        };
        self.dirty = true;
        if let Err(error) = self.writer.submit_initial(report) {
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.cursor = Some(cursor);
        self.active = true;
        self.recent_moved_toward_edge = false;
        self.recent_motion_samples.clear();
        Ok(())
    }

    pub fn take_stats(&mut self) -> InputStats {
        let mut stats = std::mem::take(&mut self.stats);
        let writer = self.writer.take_stats();
        stats.hid_calls = writer.calls;
        stats.hid_move_calls = writer.move_calls;
        stats.hid_max_us = writer.max_us;
        stats.hid_queue_max_us = writer.queue_delay_max_us;
        stats.hid_queue_high = writer.queue_high;
        stats.hid_coalesced_moves = writer.coalesced_moves;
        stats.hid_dropped_moves = writer.dropped_moves;
        stats.hid_timeouts = writer.timeouts;
        stats
    }

    pub fn queue_depth(&self) -> u32 {
        u32::try_from(self.writer.status().queue_depth).unwrap_or(u32::MAX)
    }

    // A movement batch collapses to its final position: every sample still
    // advances the authoritative tracker one by one (screen clamping, edge
    // detection), but intermediate trajectory points are never injected.
    pub fn submit_move(
        &mut self,
        samples: &[MouseMoveSample],
        entry_edge: MouseEntryEdge,
    ) -> Result<InputOutcome, String> {
        if !self.active {
            return Ok(InputOutcome::Applied);
        }
        if self.ensure_driver_available().is_err() {
            return Ok(InputOutcome::DriverFailed);
        }
        self.stats.logical_samples += samples.len() as u64;
        if let Some(last) = samples.iter().rev().find(|sample| sample.dx != 0) {
            self.recent_moved_toward_edge = moves_toward_entry_edge(entry_edge, last.dx);
        }
        let Some(cursor) = self.cursor.as_mut() else {
            return Ok(InputOutcome::Applied);
        };
        let maximum_x = cursor.maximum_x();
        let maximum_y = cursor.maximum_y();
        // The edge decision runs on the authoritative tracker before injection.
        let (positions, trigger) =
            cursor.advance_batch(samples, self.pressed_buttons == 0, entry_edge);
        let kept_from = positions.len().saturating_sub(MAX_RECENT_MOTION_SAMPLES);
        let observed_at = Instant::now();
        for (sample, &(sample_x, sample_y)) in samples.iter().zip(&positions).skip(kept_from) {
            self.record_motion(observed_at, sample_x, sample_y, sample.dx, sample.dy);
        }
        let &(x, y) = positions
            .last()
            .expect("advance_batch yields one position per sample");
        let report = HidReport {
            x: to_hid(x, maximum_x),
            y: to_hid(y, maximum_y),
            wheel: 0,
            buttons: self.pressed_buttons,
        };
        if let Err(error) = self.writer.submit_move(report) {
            self.disable_driver(error);
            return Ok(InputOutcome::DriverFailed);
        }
        self.dirty = true;

        if let Some(trigger) = trigger {
            let queue_depth = self.queue_depth();
            let cursor = self.cursor.as_ref().unwrap();
            return Ok(InputOutcome::Leaving(LeaveInfo {
                normalized_y: normalized_y(cursor.y(), maximum_y),
                entry_edge,
                boundary: entry_boundary(entry_edge, maximum_x),
                previous_x: trigger.previous_x,
                proposed_x: trigger.proposed_x,
                dx: trigger.dx,
                cursor_x: x,
                cursor_y: y,
                dy: trigger.dy,
                condition: match trigger.kind {
                    EdgeTriggerKind::Crossed => "absolute-cross",
                    EdgeTriggerKind::AtBoundary => "absolute-at-boundary",
                },
                injected: 1,
                total: samples.len(),
                queue_depth,
                recent_motion_samples: self.recent_motion_samples(),
            }));
        }
        Ok(InputOutcome::Applied)
    }

    pub fn button(
        &mut self,
        button: u8,
        down: bool,
        entry_edge: MouseEntryEdge,
    ) -> Result<InputOutcome, String> {
        if !self.active {
            return Ok(InputOutcome::Applied);
        }
        if self.ensure_driver_available().is_err() {
            return Ok(InputOutcome::DriverFailed);
        }
        let mask = match button {
            LEFT_BUTTON => 1,
            RIGHT_BUTTON => 2,
            MIDDLE_BUTTON => 4,
            _ => return Err("unsupported mouse button".to_string()),
        };
        let previous = self.pressed_buttons;
        if down {
            self.pressed_buttons |= mask;
        } else {
            self.pressed_buttons &= !mask;
        }
        let report = self.position_report(0);
        if let Err(error) = self.writer.submit_reports(vec![report]) {
            self.pressed_buttons = previous;
            self.disable_driver(error);
            return Ok(InputOutcome::DriverFailed);
        }
        self.dirty = true;
        // Releasing the last button while parked at the session's entry edge
        // after motion toward that edge completes the return immediately.
        if !down
            && let Some(cursor) = self.cursor.as_ref()
            && should_leave_on_button_up(
                self.pressed_buttons,
                cursor.x(),
                cursor.maximum_x(),
                entry_edge,
                self.recent_moved_toward_edge,
            )
        {
            let queue_depth = self.queue_depth();
            return Ok(InputOutcome::Leaving(LeaveInfo {
                normalized_y: normalized_y(cursor.y(), cursor.maximum_y()),
                entry_edge,
                boundary: entry_boundary(entry_edge, cursor.maximum_x()),
                previous_x: cursor.x(),
                proposed_x: cursor.x(),
                dx: 0,
                cursor_x: cursor.x(),
                cursor_y: cursor.y(),
                dy: 0,
                condition: "button-up-edge",
                injected: 0,
                total: 0,
                queue_depth,
                recent_motion_samples: self.recent_motion_samples(),
            }));
        }
        Ok(InputOutcome::Applied)
    }

    pub fn wheel(&mut self, lines: i32) -> Result<InputOutcome, String> {
        if !self.active {
            return Ok(InputOutcome::Applied);
        }
        if self.ensure_driver_available().is_err() {
            return Ok(InputOutcome::DriverFailed);
        }
        let mut remaining = lines;
        if remaining == 0 {
            return Ok(InputOutcome::Applied);
        }
        let mut reports = Vec::new();
        while remaining != 0 {
            let wheel = remaining.clamp(-127, 127) as i8;
            reports.push(self.position_report(wheel));
            remaining -= i32::from(wheel);
            if reports.len() == MAXIMUM_BATCH || remaining == 0 {
                if let Err(error) = self.writer.submit_reports(std::mem::take(&mut reports)) {
                    self.disable_driver(error);
                    return Ok(InputOutcome::DriverFailed);
                }
                self.dirty = true;
            }
        }
        Ok(InputOutcome::Applied)
    }

    pub fn keyboard(&mut self, state: &KeyboardState) -> Result<InputOutcome, String> {
        if !self.active {
            return Ok(InputOutcome::Applied);
        }
        if self.ensure_driver_available().is_err() {
            return Ok(InputOutcome::DriverFailed);
        }
        if let Err(error) = self
            .writer
            .submit_keyboard(state.modifiers, state.keys.clone())
        {
            self.disable_driver(error);
            return Ok(InputOutcome::DriverFailed);
        }
        self.dirty = true;
        Ok(InputOutcome::Applied)
    }

    pub fn finish_remote(&mut self) -> Result<(), String> {
        let reset_position = self.cursor.as_ref().map(|cursor| HidReport {
            x: to_hid(cursor.x(), cursor.maximum_x()),
            y: to_hid(cursor.y(), cursor.maximum_y()),
            wheel: 0,
            buttons: 0,
        });
        let result = if self.dirty {
            self.writer.reset_barrier(reset_position)
        } else {
            Ok(())
        };
        if let Err(error) = &result {
            self.disable_driver(error.clone());
        }
        if result.is_ok() {
            self.dirty = false;
        }
        self.pressed_buttons = 0;
        self.active = false;
        self.cursor = None;
        self.recent_moved_toward_edge = false;
        self.recent_motion_samples.clear();
        result
    }

    // Unified release teardown: full reset, then wait until reports already
    // handed to the Windows input pipeline stop moving the system cursor.
    pub fn release_teardown(&mut self) -> ReleaseReport {
        if !self.driver_available() {
            let _ = self.finish_remote();
            return ReleaseReport {
                reset_ok: false,
                second_reset: false,
                barrier_us: 0,
                stable_samples: 0,
                stable: false,
            };
        }
        if self.finish_remote().is_err() {
            return ReleaseReport {
                reset_ok: false,
                second_reset: false,
                barrier_us: 0,
                stable_samples: 0,
                stable: false,
            };
        }
        let (elapsed_us, stable_samples, stable) = self.run_release_barrier();
        if stable {
            return ReleaseReport {
                reset_ok: true,
                second_reset: false,
                barrier_us: elapsed_us,
                stable_samples,
                stable: true,
            };
        }
        self.dirty = true;
        let second_reset = self.writer.reset_barrier(None);
        if second_reset.is_ok() {
            self.dirty = false;
        }
        if let Err(error) = second_reset {
            self.disable_driver(format!("release barrier reset failed: {error}"));
            return ReleaseReport {
                reset_ok: true,
                second_reset: false,
                barrier_us: elapsed_us,
                stable_samples,
                stable: false,
            };
        }
        let (retry_us, retry_samples, retry_stable) = self.run_release_barrier();
        ReleaseReport {
            reset_ok: true,
            second_reset: true,
            barrier_us: elapsed_us + retry_us,
            stable_samples: stable_samples.max(retry_samples),
            stable: retry_stable,
        }
    }

    fn run_release_barrier(&self) -> (u128, usize, bool) {
        let started = Instant::now();
        let mut barrier =
            ReleaseBarrier::new(RELEASE_BARRIER_STABLE_SAMPLES, RELEASE_BARRIER_CAP, started);
        loop {
            let position = match cursor_position() {
                Ok(position) => (position.x, position.y),
                Err(error) => {
                    crate::logging::error(&format!(
                        "mouse release barrier could not read the cursor: {error}"
                    ));
                    return (
                        started.elapsed().as_micros(),
                        barrier.stable_samples(),
                        false,
                    );
                }
            };
            match barrier.poll(position, Instant::now()) {
                BarrierPoll::Stable => {
                    return (
                        started.elapsed().as_micros(),
                        barrier.stable_samples(),
                        true,
                    );
                }
                BarrierPoll::Expired => {
                    return (
                        started.elapsed().as_micros(),
                        barrier.stable_samples(),
                        false,
                    );
                }
                BarrierPoll::Waiting => thread::sleep(RELEASE_BARRIER_POLL_INTERVAL),
            }
        }
    }

    fn position_report(&self, wheel: i8) -> HidReport {
        let cursor = self.cursor.as_ref().expect("cursor exists while active");
        HidReport {
            x: to_hid(cursor.x(), cursor.maximum_x()),
            y: to_hid(cursor.y(), cursor.maximum_y()),
            wheel,
            buttons: self.pressed_buttons,
        }
    }

    fn record_motion(
        &mut self,
        observed_at: Instant,
        cursor_x: i32,
        cursor_y: i32,
        delta_x: i16,
        delta_y: i16,
    ) {
        if self.recent_motion_samples.len() == MAX_RECENT_MOTION_SAMPLES {
            self.recent_motion_samples.pop_front();
        }
        self.recent_motion_samples.push_back(ObservedMotionSample {
            observed_at,
            cursor_x,
            cursor_y,
            delta_x,
            delta_y,
        });
    }

    fn recent_motion_samples(&self) -> Vec<DiagnosticMotionSample> {
        let now = Instant::now();
        self.recent_motion_samples
            .iter()
            .map(|sample| DiagnosticMotionSample {
                age_micros: now
                    .saturating_duration_since(sample.observed_at)
                    .as_micros()
                    .min(u128::from(u32::MAX)) as u32,
                cursor_x: sample.cursor_x,
                cursor_y: sample.cursor_y,
                delta_x: sample.delta_x,
                delta_y: sample.delta_y,
            })
            .collect()
    }

    fn disable_driver(&mut self, error: String) {
        crate::logging::error(&format!("Meno Virtual Mouse runtime failure: {error}"));
        self.driver_error = Some(error);
        self.pressed_buttons = 0;
        self.active = false;
        self.cursor = None;
        self.recent_moved_toward_edge = false;
        self.recent_motion_samples.clear();
    }
}

impl Drop for MouseInputController {
    fn drop(&mut self) {
        let _ = self.finish_remote();
    }
}

fn cursor_position() -> Result<POINT, String> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point) }
        .map(|()| point)
        .map_err(|error| error.to_string())
}

fn to_hid(value: i32, maximum: i32) -> u16 {
    let maximum = maximum.max(1);
    let value = value.clamp(0, maximum);
    let maximum = i64::from(maximum);
    ((i64::from(value) * i64::from(ABSOLUTE_MAXIMUM) + maximum / 2) / maximum) as u16
}

fn normalized_y(y: i32, maximum_y: i32) -> u16 {
    let maximum = i64::from(maximum_y.max(1));
    ((i64::from(y) * 65535 + maximum / 2) / maximum) as u16
}
