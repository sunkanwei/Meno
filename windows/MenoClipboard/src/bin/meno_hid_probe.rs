#[allow(dead_code)]
#[path = "../display_contract.rs"]
mod display_contract;
#[path = "../hid_broker_protocol.rs"]
mod hid_broker_protocol;
#[allow(dead_code)]
#[path = "../virtual_hid.rs"]
mod virtual_hid;

use std::env;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use virtual_hid::{HidReport, MAXIMUM_BATCH, VirtualHid};
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_F24, VK_LCONTROL};
use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, SetCursorPos};

fn main() -> ExitCode {
    if virtual_hid::run_broker_command() {
        return ExitCode::SUCCESS;
    }
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Meno HID probe failed: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let arguments: Vec<String> = env::args().skip(1).collect();
    match arguments.first().map(String::as_str).unwrap_or("info") {
        "info" if arguments.len() == 1 || arguments.is_empty() => print_info(),
        "reset" if arguments.len() == 1 => reset(),
        "move-test" if arguments.len() == 1 => move_test(),
        "keyboard-key" if arguments.len() == 1 => keyboard_key(),
        "keyboard-watchdog" if arguments.len() == 1 => keyboard_watchdog(),
        "neutral-rate" if arguments.len() <= 3 => {
            let seconds = parse_number(arguments.get(1), 10_u64, 1, 600, "seconds")?;
            let batch = parse_number(arguments.get(2), 1_usize, 1, MAXIMUM_BATCH, "batch")?;
            neutral_rate(seconds, batch)
        }
        _ => Err(format!(
            "usage: MenoHidProbe.exe [info | reset | move-test | keyboard-key | keyboard-watchdog | neutral-rate [seconds 1..600] [batch 1..{MAXIMUM_BATCH}]]"
        )),
    }
}

fn print_info() -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    let display = display_contract::DisplayContract::current()?;
    let stats = device.stats()?;
    println!(
        "Meno Virtual Mouse ABI {} is available",
        virtual_hid::DRIVER_ABI
    );
    println!("accepted_reports={}", stats.accepted_reports);
    println!("maximum_queue_depth={}", stats.maximum_queue_depth);
    println!("merge_count={}", stats.merge_count);
    println!("current_queue_depth={}", stats.current_queue_depth);
    println!("output_writes={}", stats.output_writes);
    println!("last_output_sequence={}", stats.last_output_sequence);
    println!("last_write_duration_us={}", stats.last_write_duration_us);
    println!(
        "maximum_write_duration_us={}",
        stats.maximum_write_duration_us
    );
    println!("last_write_status=0x{:08X}", stats.last_write_status as u32);
    println!("display_id={}", display.monitor_id);
    println!("display_device={}", display.device_name);
    println!(
        "primary_screen={}x{}",
        display.screen_width, display.screen_height
    );
    Ok(())
}

fn reset() -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    device.reset().map_err(|error| error.to_string())?;
    println!("Meno Virtual Mouse state and pending reports were reset");
    Ok(())
}

fn move_test() -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    let display = display_contract::DisplayContract::current()?;
    device.reset().map_err(|error| error.to_string())?;
    let before = cursor_position()?;
    let screen_width = display.screen_width as i32;
    let screen_height = display.screen_height as i32;
    let maximum_x = screen_width - 1;
    let maximum_y = screen_height - 1;
    let start_x = before.x.clamp(0, maximum_x);
    let target_y = before.y.clamp(0, maximum_y);
    let step = 40.min(maximum_x);
    let target_x = if start_x < screen_width / 2 {
        (start_x + step).min(maximum_x)
    } else {
        (start_x - step).max(0)
    };
    let submit = device.submit(&[HidReport {
        x: to_hid(target_x, maximum_x),
        y: to_hid(target_y, maximum_y),
        wheel: 0,
        buttons: 0,
    }]);
    if let Err(error) = submit {
        restore_cursor(&mut device, before, maximum_x, maximum_y)?;
        return Err(error.to_string());
    }
    thread::sleep(Duration::from_millis(100));
    let after = cursor_position();
    let restore = restore_cursor(&mut device, before, maximum_x, maximum_y);
    let after = after?;
    restore?;
    println!("cursor_before={},{}", before.x, before.y);
    println!("cursor_after={},{}", after.x, after.y);
    if (after.x - target_x).abs() > 2 || (after.y - target_y).abs() > 2 {
        return Err(format!(
            "absolute cursor missed the target: expected {target_x},{target_y}, got {},{}",
            after.x, after.y
        ));
    }
    println!("cursor_restored={},{}", before.x, before.y);
    println!("absolute_precision=true");
    Ok(())
}

fn to_hid(value: i32, maximum: i32) -> u16 {
    let maximum = maximum.max(1);
    let value = value.clamp(0, maximum);
    let maximum = i64::from(maximum);
    ((i64::from(value) * 32767 + maximum / 2) / maximum) as u16
}

fn restore_cursor(
    device: &mut VirtualHid,
    position: POINT,
    maximum_x: i32,
    maximum_y: i32,
) -> Result<(), String> {
    let restored_by_hid = if point_in_primary(position, maximum_x, maximum_y) {
        device
            .submit(&[HidReport {
                x: to_hid(position.x, maximum_x),
                y: to_hid(position.y, maximum_y),
                wheel: 0,
                buttons: 0,
            }])
            .is_ok()
    } else {
        false
    };
    if restored_by_hid {
        thread::sleep(Duration::from_millis(100));
    }
    let needs_fallback = !restored_by_hid
        || match cursor_position() {
            Ok(current) => (current.x - position.x).abs() > 2 || (current.y - position.y).abs() > 2,
            Err(_) => true,
        };
    if needs_fallback {
        unsafe { SetCursorPos(position.x, position.y) }.map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn point_in_primary(position: POINT, maximum_x: i32, maximum_y: i32) -> bool {
    (0..=maximum_x).contains(&position.x) && (0..=maximum_y).contains(&position.y)
}

fn keyboard_watchdog() -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    device.reset().map_err(|error| error.to_string())?;
    thread::sleep(Duration::from_millis(100));
    if key_is_down(VK_LCONTROL.0) {
        return Err("left Ctrl is already held; release it before running this test".to_string());
    }

    let started = Instant::now();
    device
        .set_keyboard_state(0x01, &[])
        .map_err(|error| error.to_string())?;
    if !wait_for_key_state(VK_LCONTROL.0, true, Duration::from_millis(300)) {
        device.reset().map_err(|error| error.to_string())?;
        return Err("Windows did not consume the virtual left Ctrl press".to_string());
    }
    if !wait_for_key_state(VK_LCONTROL.0, false, Duration::from_millis(900)) {
        device.reset().map_err(|error| error.to_string())?;
        thread::sleep(Duration::from_millis(100));
        return Err("keyboard watchdog did not release virtual left Ctrl".to_string());
    }

    println!("virtual_left_ctrl_pressed=true");
    println!("watchdog_released=true");
    println!("release_elapsed_ms={}", started.elapsed().as_millis());
    Ok(())
}

fn keyboard_key() -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    device.reset().map_err(|error| error.to_string())?;
    thread::sleep(Duration::from_millis(100));
    if key_is_down(VK_F24.0) {
        return Err("F24 is already held; release it before running this test".to_string());
    }

    device
        .set_keyboard_state(0, &[0x73])
        .map_err(|error| error.to_string())?;
    if !wait_for_key_state(VK_F24.0, true, Duration::from_millis(300)) {
        device.reset().map_err(|error| error.to_string())?;
        return Err("Windows did not consume the virtual F24 press".to_string());
    }
    device
        .set_keyboard_state(0, &[])
        .map_err(|error| error.to_string())?;
    if !wait_for_key_state(VK_F24.0, false, Duration::from_millis(300)) {
        device.reset().map_err(|error| error.to_string())?;
        return Err("Windows did not consume the virtual F24 release".to_string());
    }

    println!("virtual_f24_pressed=true");
    println!("virtual_f24_released=true");
    Ok(())
}

fn wait_for_key_state(key: u16, down: bool, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if key_is_down(key) == down {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    key_is_down(key) == down
}

fn key_is_down(key: u16) -> bool {
    (unsafe { GetAsyncKeyState(i32::from(key)) } as u16 & 0x8000) != 0
}

fn neutral_rate(seconds: u64, batch: usize) -> Result<(), String> {
    let mut device = VirtualHid::open()?;
    let display = display_contract::DisplayContract::current()?;
    device.reset().map_err(|error| error.to_string())?;
    let before = device.stats()?;
    let total = seconds
        .checked_mul(1000)
        .ok_or_else(|| "report count overflow".to_string())?;
    let position = cursor_position()?;
    let screen_width = display.screen_width as i32;
    let screen_height = display.screen_height as i32;
    if !point_in_primary(position, screen_width - 1, screen_height - 1) {
        return Err(
            "cursor is outside the Philips primary display; move it there before running neutral-rate"
                .to_string(),
        );
    }
    let neutral = HidReport {
        x: to_hid(position.x, screen_width - 1),
        y: to_hid(position.y, screen_height - 1),
        wheel: 0,
        buttons: 0,
    };
    let reports = [neutral; MAXIMUM_BATCH];
    let start = Instant::now();
    let mut sent = 0_u64;

    while sent < total {
        let count = usize::try_from((total - sent).min(batch as u64)).unwrap();
        device
            .submit(&reports[..count])
            .map_err(|error| error.to_string())?;
        sent += count as u64;

        let target = start + Duration::from_micros(sent * 1000);
        let now = Instant::now();
        if target > now + Duration::from_micros(250) {
            thread::sleep(target.duration_since(now) - Duration::from_micros(200));
        }
        while Instant::now() < target {
            std::hint::spin_loop();
        }
    }

    let elapsed = start.elapsed();
    let after = device.stats()?;
    let accepted = after
        .accepted_reports
        .saturating_sub(before.accepted_reports);
    let merged = after.merge_count.saturating_sub(before.merge_count);
    let output_writes = after.output_writes.saturating_sub(before.output_writes);
    let expected_writes = total.div_ceil(batch as u64);
    let measured_rate = accepted as f64 / elapsed.as_secs_f64();
    println!("requested_reports={sent}");
    println!("accepted_reports={accepted}");
    println!("elapsed_seconds={:.3}", elapsed.as_secs_f64());
    println!("measured_reports_per_second={measured_rate:.1}");
    println!("maximum_queue_depth={}", after.maximum_queue_depth);
    println!("merged_reports={merged}");
    println!("current_queue_depth={}", after.current_queue_depth);
    println!("output_writes={output_writes}");
    println!("expected_output_writes={expected_writes}");
    println!("last_output_sequence={}", after.last_output_sequence);
    println!("last_write_duration_us={}", after.last_write_duration_us);
    println!(
        "maximum_write_duration_us={}",
        after.maximum_write_duration_us
    );

    if accepted != sent {
        return Err(format!(
            "driver accepted {accepted} of {sent} neutral reports"
        ));
    }
    if output_writes != expected_writes {
        return Err(format!(
            "driver completed {output_writes} of {expected_writes} expected output writes"
        ));
    }
    Ok(())
}

fn parse_number<T>(
    value: Option<&String>,
    default: T,
    minimum: T,
    maximum: T,
    name: &str,
) -> Result<T, String>
where
    T: Copy + Ord + std::str::FromStr,
{
    let value = match value {
        Some(value) => value.parse::<T>().map_err(|_| format!("invalid {name}"))?,
        None => default,
    };
    if value < minimum || value > maximum {
        return Err(format!("{name} is outside the supported range"));
    }
    Ok(value)
}

fn cursor_position() -> Result<POINT, String> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point) }
        .map(|()| point)
        .map_err(|error| error.to_string())
}
