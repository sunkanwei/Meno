use std::thread;
use std::time::Instant;

use windows::Win32::Foundation::POINT;
use windows::Win32::UI::WindowsAndMessaging::GetCursorPos;

use crate::hid_writer::HidWriter;
use crate::mouse_control::{
    BarrierPoll, RELEASE_BARRIER_CAP, RELEASE_BARRIER_POLL_INTERVAL,
    RELEASE_BARRIER_STABLE_SAMPLES, ReleaseBarrier,
};
use crate::protocol::KeyboardState;
use crate::virtual_hid::{ABSOLUTE_MAXIMUM, DRIVER_ABI, HidReport, MAXIMUM_BATCH};

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
    pub fn queue_high_water(&self) -> usize {
        self.writer.status().queue_high_water
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
        if status.faults != self.observed_faults {
            self.observed_faults = status.faults;
            let error = "Meno HID writer recovered after a runtime failure; the active input session was discarded".to_string();
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.driver_error = None;
        Ok(())
    }

    pub fn prepare(
        &mut self,
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
    ) -> Result<(), String> {
        self.ensure_driver_available()?;
        let initial = report(x, y, maximum_x, maximum_y, 0, 0);
        if let Err(error) = self.writer.submit_initial(initial) {
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.dirty = true;
        Ok(())
    }

    pub fn pointer(
        &mut self,
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
        buttons: u8,
        critical: bool,
    ) -> Result<(), String> {
        self.ensure_driver_available()?;
        let report = report(x, y, maximum_x, maximum_y, buttons, 0);
        let result = if critical {
            self.writer.submit_reports(vec![report])
        } else {
            self.writer.submit_move(report)
        };
        if let Err(error) = result {
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.dirty = true;
        Ok(())
    }

    pub fn wheel(
        &mut self,
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
        buttons: u8,
        lines: i32,
    ) -> Result<(), String> {
        self.ensure_driver_available()?;
        let mut remaining = lines;
        while remaining != 0 {
            let mut reports = Vec::new();
            while remaining != 0 && reports.len() < MAXIMUM_BATCH {
                let wheel = remaining.clamp(-127, 127) as i8;
                reports.push(report(x, y, maximum_x, maximum_y, buttons, wheel));
                remaining -= i32::from(wheel);
            }
            if let Err(error) = self.writer.submit_reports(reports) {
                self.disable_driver(error.clone());
                return Err(error);
            }
        }
        self.dirty = true;
        Ok(())
    }

    pub fn keyboard(&mut self, state: &KeyboardState) -> Result<(), String> {
        self.ensure_driver_available()?;
        if let Err(error) = self
            .writer
            .submit_keyboard(state.modifiers, state.keys.clone())
        {
            self.disable_driver(error.clone());
            return Err(error);
        }
        self.dirty = true;
        Ok(())
    }

    pub fn release_teardown(
        &mut self,
        x: i32,
        y: i32,
        maximum_x: i32,
        maximum_y: i32,
    ) -> ReleaseReport {
        if !self.driver_available() {
            return ReleaseReport {
                reset_ok: false,
                stable: false,
            };
        }
        let position = report(x, y, maximum_x, maximum_y, 0, 0);
        if let Err(error) = self.writer.neutralize_barrier(Some(position)) {
            self.disable_driver(error);
            return ReleaseReport {
                reset_ok: false,
                stable: false,
            };
        }
        self.dirty = false;
        if self.run_release_barrier() {
            return ReleaseReport {
                reset_ok: true,
                stable: true,
            };
        }
        if let Err(error) = self.writer.reset_barrier(None) {
            self.disable_driver(format!("release barrier reset failed: {error}"));
            return ReleaseReport {
                reset_ok: true,
                stable: false,
            };
        }
        ReleaseReport {
            reset_ok: true,
            stable: self.run_release_barrier(),
        }
    }

    pub fn emergency_reset(&mut self) {
        if self.dirty {
            let _ = self.writer.neutralize_barrier(None);
            self.dirty = false;
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
                BarrierPoll::Stable => return true,
                BarrierPoll::Expired => return false,
                BarrierPoll::Waiting => thread::sleep(RELEASE_BARRIER_POLL_INTERVAL),
            }
        }
    }

    fn disable_driver(&mut self, error: String) {
        crate::logging::error(&format!("Meno Virtual Mouse runtime failure: {error}"));
        self.driver_error = Some(error);
    }
}

impl Drop for MouseInputController {
    fn drop(&mut self) {
        self.emergency_reset();
    }
}

fn report(x: i32, y: i32, maximum_x: i32, maximum_y: i32, buttons: u8, wheel: i8) -> HidReport {
    HidReport {
        x: to_hid(x, maximum_x),
        y: to_hid(y, maximum_y),
        wheel,
        buttons,
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
