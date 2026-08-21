use std::thread;
use std::time::Instant;
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

use crate::hid_writer::HidWriter;
use crate::mouse_control::{
    BarrierPoll, LogicalCursor, RELEASE_BARRIER_CAP, RELEASE_BARRIER_POLL_INTERVAL,
    RELEASE_BARRIER_STABLE_SAMPLES, ReleaseBarrier, entry_position, moves_toward_entry_edge,
    should_leave_on_button_up,
};
use crate::protocol::{KeyboardState, MouseEntryEdge, MouseMoveSample};
use crate::virtual_hid::{ABSOLUTE_MAXIMUM, DRIVER_ABI, HidReport, MAXIMUM_BATCH};

const LEFT_BUTTON: u8 = 1;
const RIGHT_BUTTON: u8 = 2;
const MIDDLE_BUTTON: u8 = 3;

#[derive(Clone, Debug)]
pub struct LeaveInfo {
    pub normalized_y: u16,
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
    pub stable: bool,
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
        Ok(())
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

        if trigger.is_some() {
            let cursor = self.cursor.as_ref().unwrap();
            return Ok(InputOutcome::Leaving(LeaveInfo {
                normalized_y: normalized_y(cursor.y(), maximum_y),
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
            return Ok(InputOutcome::Leaving(LeaveInfo {
                normalized_y: normalized_y(cursor.y(), cursor.maximum_y()),
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
        result
    }

    // Unified release teardown: full reset, then wait until reports already
    // handed to the Windows input pipeline stop moving the system cursor.
    pub fn release_teardown(&mut self) -> ReleaseReport {
        if !self.driver_available() {
            let _ = self.finish_remote();
            return ReleaseReport {
                reset_ok: false,
                stable: false,
            };
        }
        if self.finish_remote().is_err() {
            return ReleaseReport {
                reset_ok: false,
                stable: false,
            };
        }
        let stable = self.run_release_barrier();
        if stable {
            return ReleaseReport {
                reset_ok: true,
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
                stable: false,
            };
        }
        let retry_stable = self.run_release_barrier();
        ReleaseReport {
            reset_ok: true,
            stable: retry_stable,
        }
    }

    fn run_release_barrier(&self) -> bool {
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
                    return false;
                }
            };
            match barrier.poll(position, Instant::now()) {
                BarrierPoll::Stable => {
                    return true;
                }
                BarrierPoll::Expired => {
                    return false;
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

    fn disable_driver(&mut self, error: String) {
        crate::logging::error(&format!("Meno Virtual Mouse runtime failure: {error}"));
        self.driver_error = Some(error);
        self.pressed_buttons = 0;
        self.active = false;
        self.cursor = None;
        self.recent_moved_toward_edge = false;
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
